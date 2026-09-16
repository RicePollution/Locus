import Foundation
import Network
import os

/// Finds the TCP port the on-device developer tunnel is listening on.
///
/// `tunnel_create_rppairing` needs an explicit port, and upstream hardcodes Darwin's
/// first ephemeral port — which is only correct while nothing else has claimed it.
/// `_remotepairing._tcp` (already declared in `NSBonjourServices`) is the fallback for
/// everyone whose tunnel landed somewhere else.
enum RemotePairingDiscovery {
    /// Darwin's first ephemeral port, and what LocationEngine hardcodes today.
    static let fallbackPort: UInt16 = 49152
    static let discoveryTimeout: TimeInterval = 2.0
    static let discoveryCooldown: TimeInterval = 30.0

    private static let serviceType = "_remotepairing._tcp"

    private struct Cache {
        var knownGood: UInt16?
        var discovered: UInt16?
        var lastDiscoveryAttempt: Date?
    }

    private static let caches = OSAllocatedUnfairLock(initialState: [String: Cache]())

    /// Ports worth trying, cheapest-first. Never empty, and always contains `fallbackPort`
    /// so this can't regress installs where the hardcoded port already works.
    static func candidates(for targetIP: String) -> [UInt16] {
        let cache = caches.withLock { $0[targetIP] }
        var ports: [UInt16] = []
        for port in [cache?.knownGood, fallbackPort, cache?.discovered] {
            guard let port, !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    /// Bonjour browse + resolve, filtered to `targetIP`. `nil` on timeout or no match.
    static func discover(targetIP: String) async -> UInt16? {
        let now = Date()
        let allowed = caches.withLock { store -> Bool in
            var cache = store[targetIP] ?? Cache()
            if let last = cache.lastDiscoveryAttempt, now.timeIntervalSince(last) < discoveryCooldown {
                return false
            }
            cache.lastDiscoveryAttempt = now
            store[targetIP] = cache
            return true
        }
        guard allowed else {
            // Still in the cooldown window: hand back whatever the last browse found.
            return caches.withLock { $0[targetIP]?.discovered }
        }

        let port = await browse(targetIP: targetIP)
        if let port {
            caches.withLock { store in
                var cache = store[targetIP] ?? Cache()
                cache.discovered = port
                store[targetIP] = cache
            }
        }
        return port
    }

    /// Called the moment `tunnel_create_rppairing` returns nil — tunnel success, not
    /// full-chain success, so a later RSD failure doesn't throw away a good port.
    static func recordSuccess(port: UInt16, for targetIP: String) {
        caches.withLock { store in
            var cache = store[targetIP] ?? Cache()
            cache.knownGood = port
            store[targetIP] = cache
        }
    }

    /// Called when `tunnel_create_rppairing` fails on `port`.
    static func invalidate(port: UInt16, for targetIP: String) {
        caches.withLock { store in
            guard var cache = store[targetIP] else { return }
            if cache.knownGood == port { cache.knownGood = nil }
            if cache.discovered == port { cache.discovered = nil }
            store[targetIP] = cache
        }
    }

    private static func browse(targetIP: String) async -> UInt16? {
        let queue = DispatchQueue(label: "com.ricepollution.locus.discovery")
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: browseParameters())
        let attempt = BrowseAttempt()

        return await withCheckedContinuation { (continuation: CheckedContinuation<UInt16?, Never>) in
            let finish: (UInt16?) -> Void = { port in
                guard attempt.claim() else { return }
                browser.cancel()
                attempt.cancelAll()
                continuation.resume(returning: port)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .failed:
                    finish(nil)
                case .waiting(let error):
                    // A denied Local Network permission parks the browser here rather than
                    // failing it, so every exhausted teleport used to pay the full timeout
                    // for a browse that was never going to return anything. Giving up costs
                    // nothing: the caller falls back to the fixed port, which is the
                    // behaviour before discovery existed.
                    NSLog("[Locus] discovery browser waiting, giving up: %@", String(describing: error))
                    finish(nil)
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { results, _ in
                // Bonjour redelivers the WHOLE result set on every change, so iterating it
                // naively dials each advertiser once per change — quadratic in the number
                // of instances. claimDial dedupes and caps the fan-out.
                for result in results {
                    guard case .service = result.endpoint,
                          attempt.claimDial(result.endpoint) else { continue }
                    let connection = NWConnection(to: result.endpoint, using: browseParameters())
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            let port = matchedPort(connection, targetIP: targetIP)
                            // Cancel unconditionally and before finishing: a connection
                            // that readies after the claim is taken is no longer reachable
                            // by cancelAll and would leak for the life of the process.
                            connection.cancel()
                            if let port { finish(port) }
                        case .failed, .waiting:
                            connection.cancel()
                        default:
                            break
                        }
                    }
                    attempt.track(connection)
                    connection.start(queue: queue)
                }
            }

            browser.start(queue: queue)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(discoveryTimeout * 1_000_000_000))
                finish(nil)
            }
        }
    }

    /// Deliberately the opposite of `PairableHostAdvertiser`: that one advertises to a
    /// peer, this one seeks a tunnel already on this device's own interfaces.
    private static func browseParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        return parameters
    }

    /// Only an endpoint that resolved to the configured tunnel IP counts; TXT records
    /// are never trusted for this.
    private static func matchedPort(_ connection: NWConnection, targetIP: String) -> UInt16? {
        guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
              case let .ipv4(address) = host else { return nil }
        // IPv4Address prints an interface scope suffix ("10.7.0.1%utun3") when it has one.
        let resolved = String(describing: address).split(separator: "%").first.map(String.init)
        return resolved == targetIP ? port.rawValue : nil
    }
}

/// Per-browse bookkeeping, so the browse queue and the timeout arm can race to finish
/// the continuation exactly once.
private final class BrowseAttempt: @unchecked Sendable {
    /// A hostile advertiser can register hundreds of `_remotepairing._tcp` instances with
    /// nothing but `dns-sd`. Without a ceiling that becomes file-descriptor exhaustion in
    /// this process, which breaks the app's real networking too.
    private static let maxProbes = 8

    private let lock = OSAllocatedUnfairLock()
    private var finished = false
    private var connections: [NWConnection] = []
    private var dialled: Set<NWEndpoint> = []

    /// True at most once per endpoint, and at most `maxProbes` times per browse.
    func claimDial(_ endpoint: NWEndpoint) -> Bool {
        lock.withLock {
            guard !finished, dialled.count < Self.maxProbes else { return false }
            return dialled.insert(endpoint).inserted
        }
    }

    func track(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
    }

    /// True for exactly one caller; that caller owns the teardown and the resume.
    func claim() -> Bool {
        lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
    }

    func cancelAll() {
        lock.withLock {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }
}
