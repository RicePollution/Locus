import Darwin
import Foundation

/// What one raw TCP connect to a candidate tunnel port did.
struct TunnelProbeResult: Sendable, Identifiable {
    enum Outcome: Sendable, Equatable {
        /// The handshake completed: the port is reachable and something is listening.
        case connected
        /// `connect` settled on a definite failure. The errno is the whole point of this probe.
        case failed(errno: Int32)
        /// Nothing came back inside the timeout — no SYN-ACK, no RST, no ICMP.
        case timedOut
        /// A local call failed before anything left the device; nothing was sent.
        case setupFailed(errno: Int32)
    }

    let port: UInt16
    let outcome: Outcome
    let elapsed: TimeInterval

    var id: UInt16 { port }
}

/// One run of the probe. An unparseable IP is its own case because no socket is opened in it.
enum TunnelProbeReport: Sendable {
    case invalidIP(String)
    case probed(targetIP: String, results: [TunnelProbeResult])
}

/// Raw TCP reachability check against the ports `LocationEngine` would try.
///
/// `tunnel_create_rppairing` does TCP connect → RPPairing handshake → tunnel and reports all
/// of it as one code, so "the packets never arrived" and "they arrived and the handshake
/// failed" are indistinguishable from the engine. That is why teleport working on Wi‑Fi and
/// in Airplane Mode but failing on cellular has stayed undiagnosed: every test so far has
/// come back as the same `tunnelCreate`. This opens its own socket and reports the errno,
/// which separates those two — and a successful connect rules out reachability entirely,
/// which is the outcome that would move the investigation up to the handshake.
///
/// Deliberately independent of `LocationEngine`: its own queue, its own descriptors, no FFI
/// handle touched, so it is safe to run while a session is live.
enum TunnelProbe {
    /// Per-port budget. Long enough that a slow path still answers, short enough that every
    /// candidate finishes inside one impatient tap. Same value discovery uses.
    static let timeout: TimeInterval = 2.0

    private static let queue = DispatchQueue(label: "com.ricepollution.locus.tunnelprobe", qos: .userInitiated)

    /// Probes every port `LocationEngine` would try, in the order it would try them.
    ///
    /// Sequential rather than concurrent: at most one descriptor exists at a time, so a probe
    /// run can never compete with the engine for file descriptors. Worst case is `timeout`
    /// times the number of candidates.
    static func run(targetIP: String) async -> TunnelProbeReport {
        // TunnelConfig trims before the engine ever sees it, so probe the same string.
        let target = targetIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = ipv4Address(target) else { return .invalidIP(target) }

        var results: [TunnelProbeResult] = []
        for port in RemotePairingDiscovery.candidates(for: target) {
            results.append(await onQueue { probe(port: port, address: address) })
        }
        return .probed(targetIP: target, results: results)
    }

    /// Same validation `LocationEngine.buildLocked` does, run once before any socket is opened:
    /// the IP is free text from the Settings field.
    private static func ipv4Address(_ text: String) -> in_addr_t? {
        var parsed = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &parsed) }) == 1 else { return nil }
        return parsed.s_addr
    }

    /// Hops onto the probe's own queue without ever blocking the caller's thread — `poll`
    /// below parks a thread for up to `timeout`, and that must not be a cooperative one.
    private static func onQueue(_ work: @escaping @Sendable () -> TunnelProbeResult) async -> TunnelProbeResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<TunnelProbeResult, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private static func probe(port: UInt16, address: in_addr_t) -> TunnelProbeResult {
        let started = Date()
        let outcome = connectOutcome(port: port, address: address, deadline: started.addingTimeInterval(timeout))
        return TunnelProbeResult(port: port, outcome: outcome, elapsed: Date().timeIntervalSince(started))
    }

    private static func connectOutcome(port: UInt16, address: in_addr_t, deadline: Date) -> TunnelProbeResult.Outcome {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(port).bigEndian
        destination.sin_addr.s_addr = address

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return .setupFailed(errno: errno) }
        // Every path below has to reach this, the timeout included: a descriptor leaked here
        // would accumulate across runs and starve the app's real networking.
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .setupFailed(errno: errno)
        }

        let started = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if started == 0 { return .connected }
        let code = errno
        // EINPROGRESS is the only "not finished yet" answer a non-blocking connect gives;
        // anything else is already decided and the errno is final.
        guard code == EINPROGRESS else { return .failed(errno: code) }

        return waitForConnect(descriptor: descriptor, deadline: deadline)
    }

    private static func waitForConnect(descriptor: Int32, deadline: Date) -> TunnelProbeResult.Outcome {
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            let ready = poll(&poller, 1, Int32((remaining * 1000).rounded(.up)))
            if ready == 0 { return .timedOut }
            if ready > 0 { break }
            // A signal can wake poll early. That is not a result, so wait out the deadline.
            let code = errno
            guard code == EINTR else { return .setupFailed(errno: code) }
        }

        // poll only reports that the connect *finished*. For a non-blocking connect, SO_ERROR
        // is the only place the real errno appears — reading errno here would report nothing.
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else {
            return .setupFailed(errno: errno)
        }
        return failure == 0 ? .connected : .failed(errno: failure)
    }

    /// Symbolic name for the errnos this probe exists to tell apart. `nil` for anything else —
    /// the number and `strerror` still carry it.
    fileprivate static func symbol(for code: Int32) -> String? {
        switch code {
        case ECONNREFUSED: return "ECONNREFUSED"
        case ETIMEDOUT: return "ETIMEDOUT"
        case EHOSTUNREACH: return "EHOSTUNREACH"
        case ENETUNREACH: return "ENETUNREACH"
        case ENETDOWN: return "ENETDOWN"
        case EADDRNOTAVAIL: return "EADDRNOTAVAIL"
        case EPERM: return "EPERM"
        case EACCES: return "EACCES"
        default: return nil
        }
    }

    fileprivate static func errnoText(_ code: Int32) -> String {
        // strerror hands back a shared buffer; strerror_r fills one we own.
        var buffer = [CChar](repeating: 0, count: 256)
        let message = strerror_r(code, &buffer, buffer.count) == 0 ? String(cString: buffer) : "no message"
        guard let symbol = symbol(for: code) else { return "errno \(code) (\(message))" }
        return "errno \(code) \(symbol) (\(message))"
    }

    fileprivate static func meaning(for code: Int32) -> String {
        switch code {
        case ECONNREFUSED:
            return "the packets reached the host and nothing is listening on that port"
        case ETIMEDOUT:
            return "nothing on the path answered, so they never reached a listener"
        case EHOSTUNREACH, ENETUNREACH, ENETDOWN, EADDRNOTAVAIL:
            return "there is no usable route to that address on any current interface"
        case EPERM, EACCES:
            return "the connection was blocked on this device before it left it"
        default:
            return "an errno this probe has no reading for; the number above is the finding"
        }
    }
}

extension TunnelProbeResult {
    /// Short outcome, for the leading label.
    var status: String {
        switch outcome {
        case .connected: return "connected"
        case .failed(let code): return TunnelProbe.symbol(for: code) ?? "errno \(code)"
        case .timedOut: return "no answer"
        case .setupFailed: return "probe failed"
        }
    }

    /// The line under `status`. The raw errno is the finding; the prose after it is there so a
    /// screenshot reads on its own, never instead of the number.
    var detail: String {
        switch outcome {
        case .connected:
            return "TCP connected in \(elapsedText). The port is reachable and something is listening, so a tunnel failure here is the RPPairing handshake above TCP, not the network."
        case .failed(let code):
            return "\(TunnelProbe.errnoText(code)) after \(elapsedText) — \(TunnelProbe.meaning(for: code))."
        case .timedOut:
            return "No reply in \(elapsedText): no SYN-ACK and no RST. Same class as ETIMEDOUT — the packets never reached anything that answers."
        case .setupFailed(let code):
            return "The probe could not open or wait on a socket: \(TunnelProbe.errnoText(code)). Nothing was sent to the device."
        }
    }

    private var elapsedText: String {
        elapsed < 1 ? String(format: "%.0f ms", elapsed * 1000) : String(format: "%.2f s", elapsed)
    }
}
