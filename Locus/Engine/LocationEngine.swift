import Foundation
import idevice

enum LocationEngineError: LocalizedError {
    case invalidIP
    case pairingRead
    case tunnelCreate
    case remoteServer
    case simulationCreate
    case locationSet
    case locationClear
    case notActive
    case portUnavailable
    case channelLost

    var errorDescription: String? {
        switch self {
        case .invalidIP: return "Tunnel IP is invalid. Check Settings → Tunnel IP (usually 10.7.0.1)."
        case .pairingRead: return "Could not read the RPPairing file. Generate one with idevice_pair in RPPairing mode."
        case .tunnelCreate: return "Could not open the developer tunnel. Is LocalDevVPN connected on Wi‑Fi?"
        case .remoteServer: return "Connected to the tunnel but RemoteXPC handshake failed."
        case .simulationCreate: return "Could not open Apple’s location simulation service."
        case .locationSet: return "Failed to set simulated coordinates."
        case .locationClear: return "Failed to clear simulated location."
        case .notActive: return "No active simulation session."
        case .portUnavailable:
            // Deliberately vague about which ports: up to three candidates are tried, and
            // discovery may have found a port, found none, or found one already tried.
            // Naming a single port here sent people debugging the wrong thing.
            return "No developer tunnel answered on \(TunnelConfig.targetIP) on any port tried, including \(RemotePairingDiscovery.fallbackPort). Is LocalDevVPN connected on Wi‑Fi?"
        case .channelLost: return "The developer tunnel closed. Reconnect and arm again."
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 4: return .portUnavailable
        case 5: return .channelLost
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// What the engine currently holds. `LocationEngine` on its own queue is the sole authority;
/// every copy of this that reaches the UI is assigned from an engine result, never derived.
enum EngineArmState: Sendable, Equatable {
    case disarmed
    case armed
    case spoofing
}

/// A successful engine operation and the state it left the engine in.
struct EngineOutcome: Sendable, Equatable {
    let state: EngineArmState
    /// Port the live chain sits on. nil iff `state == .disarmed`.
    let port: UInt16?
    /// Address the live chain was actually dialled on, which is not necessarily the one
    /// Settings holds now — a chain is bound to its address and `apply` never re-dials. nil
    /// iff `state == .disarmed`, so it is the only thing that may vouch for an address.
    let deviceIP: String?
    /// True when this call built a chain, as opposed to reusing a live one.
    let builtChain: Bool
    /// When a round-trip to the device last completed on this chain. nil iff
    /// `state == .disarmed`, or while an armed chain has never been verified.
    let verifiedAt: Date?
    /// Why an armed chain is unverified, when the build succeeded and the probe round-trip
    /// that followed it did not. nil on a result with nothing to explain.
    let detail: String?
}

/// A failed engine operation. `state` is what the engine holds AFTER the failure, so the
/// caller never has to infer whether the arm survived.
struct EngineFailure: Error, Sendable, Equatable {
    let error: LocationEngineError
    let state: EngineArmState
    /// Where the chain that survived this failure is dialled — or, when nothing survived,
    /// the port that answered at the tunnel layer before a higher one refused. `deviceIP`
    /// is set only for a live chain: a failed message is no evidence against the address it
    /// was sent to, and nothing short of a live chain proves an address at all.
    let port: UInt16?
    let deviceIP: String?
    /// Consecutive failed asserts on the live chain. 0 when `state == .disarmed`.
    let consecutiveChannelFailures: Int
    /// `IdeviceFfiError.message` / `.code` / `.sub_code`, verbatim. Displayed, never
    /// branched on: the discriminant is an unstable Rust enum in a vendored archive, and a
    /// misclassification here would free a working chain.
    let detail: String?
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
///
/// Building the chain and asserting a coordinate are separate operations, because the build
/// is the fragile half: `tunnel_create_rppairing` fails on cellular while an already-open
/// chain keeps working across a path change. So the chain outlives a Stop, and only an
/// explicit `release()` — or the dead-chain rule below — frees it.
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.ricepollution.locus.location", qos: .userInitiated)

    /// All four handles, or none. Kept as one value so a half-built chain is
    /// unrepresentable: `buildLocked` holds the pointers as locals and constructs this only
    /// when all four exist.
    private struct Chain {
        let adapter: OpaquePointer
        let handshake: OpaquePointer
        let remoteServer: OpaquePointer
        let simulation: OpaquePointer
        let port: UInt16
        /// The address this chain was dialled on. A live chain is bound to it, so this is
        /// the only address the app may claim a tunnel for — the one in Settings can have
        /// been edited to something nothing has ever answered on.
        let deviceIP: String

        /// The only place a live chain is freed, and the order is load-bearing.
        /// `location_simulation_new` takes a mutable *borrow* of the remote server
        /// (`ffi/src/dvt/location_simulation.rs` does `&mut (*server).0` and never
        /// `Box::from_raw`s it); the simulation handle holds that reference with its
        /// lifetime transmuted to `'static`. So the server has to outlive the simulation
        /// AND still be freed afterwards — which is exactly simulation → remoteServer →
        /// handshake → adapter. Upstream believed the call consumed the server and nil'd
        /// the pointer, which leaked one `RemoteServerHandle`, and its transport, per build.
        func free() {
            location_simulation_free(simulation)
            remote_server_free(remoteServer)
            rsd_handshake_free(handshake)
            adapter_free(adapter)
        }
    }

    /// The sole authority on ARMED: `chain != nil` *is* the armed state. There is no second
    /// copy of that truth anywhere, and nothing but `releaseLocked` and
    /// `dropDeadChainLocked` may assign nil here.
    private static var chain: Chain?
    /// Consecutive failed *asserts* on the current chain — the only round-trip whose failure
    /// is unambiguous evidence. A failing `clear` is not counted: whether an unmatched clear
    /// succeeds at all is unmeasured (device test D2), so counting it would let a device that
    /// simply refuses to clear nothing walk the counter up to the teardown threshold and free
    /// a healthy chain. Reset to 0 on any success and on every build.
    private static var channelFailures = 0
    private static var lastVerified: Date?

    /// Consecutive failed asserts after which a chain is presumed dead and freed. A guess,
    /// copied from the session's own drop threshold because 3 has worked there. Freeing is a
    /// one-way door on cellular, so this is the only automatic teardown in the file and it
    /// fires only while something is actively asserting on the chain.
    private static let deadChannelThreshold = 3

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let channelLost: Int32 = 5
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    /// What a queue hop should do once the chain exists.
    private enum ChainWork: Sendable {
        case assert(latitude: Double, longitude: Double)
        /// One round-trip that asserts nothing — `location_simulation_clear` on a channel
        /// with nothing running. Proves the channel end-to-end without moving the device.
        case probe
    }

    /// Builds the chain if absent and asserts nothing. Idempotent: a live chain is returned
    /// untouched. Never frees.
    static func arm(pairingPath: String, deviceIP: String) async -> Result<EngineOutcome, EngineFailure> {
        await run(.probe, pairingPath: pairingPath, deviceIP: deviceIP)
    }

    /// Builds the chain if absent, then asserts the coordinate. Frees only via the
    /// dead-chain rule.
    static func apply(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<EngineOutcome, EngineFailure> {
        await run(.assert(latitude: latitude, longitude: longitude), pairingPath: pairingPath, deviceIP: deviceIP)
    }

    /// Stops the simulation and KEEPS the chain. Never builds and never frees. A failure
    /// leaves the engine armed, and the caller stops re-asserting, so the fix expires anyway.
    static func hold() async -> Result<EngineOutcome, EngineFailure> {
        await onQueue { clearLocked() }
    }

    /// One liveness round-trip on the live chain. No-op success when disarmed. Never frees.
    static func verify() async -> Result<EngineOutcome, EngineFailure> {
        await onQueue { clearLocked() }
    }

    /// Frees the chain in borrow order. Always lands disarmed; cannot fail.
    static func release() async -> EngineOutcome {
        await onQueue { releaseLocked() }
    }

    /// Makes sure a chain exists — trying every candidate port, then browsing once every one
    /// of them has refused at the tunnel layer — and runs `work` on it.
    private static func run(_ work: ChainWork, pairingPath: String, deviceIP: String) async -> Result<EngineOutcome, EngineFailure> {
        let tried = RemotePairingDiscovery.candidates(for: deviceIP)
        let first = await onQueue {
            attemptLocked(ports: tried, work: work, pairingPath: pairingPath, deviceIP: deviceIP)
        }
        if first.code == ok { return .success(first.outcome) }
        guard first.code == tunnelCreate else { return .failure(first.failure()) }

        // Every candidate refused at the tunnel layer, so the port is what we got wrong.
        // Browsing is off the queue: Bonjour must not block the FFI serializer.
        guard let discovered = await RemotePairingDiscovery.discover(targetIP: deviceIP),
              !tried.contains(discovered) else { return .failure(first.failure(.portUnavailable)) }

        let second = await onQueue {
            attemptLocked(ports: [discovered], work: work, pairingPath: pairingPath, deviceIP: deviceIP)
        }
        guard second.code == ok else {
            // Every candidate and the discovered port refused at the tunnel layer. Say
            // that, rather than repeating the generic "could not open the tunnel".
            return .failure(second.code == tunnelCreate ? second.failure(.portUnavailable) : second.failure())
        }
        return .success(second.outcome)
    }

    /// Hops onto the FFI serializer without ever blocking the caller's thread.
    private static func onQueue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// One queue hop's result, carrying everything both the success and the failure shape
    /// need so the caller never has to re-read engine state off the queue.
    private struct Attempt: Sendable {
        let code: Int32
        let state: EngineArmState
        let port: UInt16?
        let deviceIP: String?
        let builtChain: Bool
        let verifiedAt: Date?
        let channelFailures: Int
        let detail: String?

        /// A failure that left nothing built.
        static func failed(_ code: Int32, port: UInt16? = nil, detail: String?) -> Attempt {
            Attempt(code: code, state: .disarmed, port: port, deviceIP: nil, builtChain: false, verifiedAt: nil, channelFailures: 0, detail: detail)
        }

        var outcome: EngineOutcome {
            EngineOutcome(state: state, port: port, deviceIP: deviceIP, builtChain: builtChain, verifiedAt: verifiedAt, detail: detail)
        }

        /// `override` names the error where the caller knows better than the raw code —
        /// the exhausted-candidates case, which reads as `.portUnavailable`.
        func failure(_ override: LocationEngineError? = nil) -> EngineFailure {
            EngineFailure(
                error: override ?? .from(code: code),
                state: state,
                port: port,
                deviceIP: deviceIP,
                consecutiveChannelFailures: channelFailures,
                detail: detail
            )
        }
    }

    /// Tries each candidate port in turn inside a single queue hop, then runs `work`. A
    /// returned `ok` always carries the port the live chain sits on.
    private static func attemptLocked(
        ports: [UInt16],
        work: ChainWork,
        pairingPath: String,
        deviceIP: String
    ) -> Attempt {
        dispatchPrecondition(condition: .onQueue(queue))
        if let chain {
            return performLocked(work, on: chain, builtChain: false)
        }

        var tunnelDetail: String?
        for port in ports {
            switch buildLocked(pairingPath: pairingPath, deviceIP: deviceIP, port: port) {
            case .success(let built):
                chain = built
                channelFailures = 0
                lastVerified = nil
                RemotePairingDiscovery.recordSuccess(port: port, for: deviceIP)
                return performLocked(work, on: built, builtChain: true)
            case .failure(let failure):
                switch failure.code {
                case tunnelCreate:
                    tunnelDetail = failure.detail
                    RemotePairingDiscovery.invalidate(port: port, for: deviceIP)
                    continue
                case remoteServerCode, simulationCreate:
                    // The tunnel itself answered here, so the port was right and only the
                    // layers above it failed — keep it rather than hunting for another.
                    RemotePairingDiscovery.recordSuccess(port: port, for: deviceIP)
                    return .failed(failure.code, port: port, detail: failure.detail)
                default:
                    return .failed(failure.code, detail: failure.detail)
                }
            }
        }
        // Every candidate refused the tunnel; `run` takes this as its cue to browse.
        return .failed(tunnelCreate, detail: tunnelDetail)
    }

    /// The message half: runs on a chain that already exists and never builds one.
    private static func performLocked(_ work: ChainWork, on chain: Chain, builtChain: Bool) -> Attempt {
        dispatchPrecondition(condition: .onQueue(queue))
        switch work {
        case .probe:
            // A probe failure must never fail an arm that holds a live chain. Whether
            // `location_simulation_clear` succeeds when nothing is simulated is unmeasured
            // (device test D2), so a failure here is evidence of nothing — the chain stands,
            // `lastVerified` stays where it was, and the UI says "unverified" until a real
            // `set` proves the channel.
            // The detail is kept even though the arm succeeds: "unverified" on its own says
            // nothing about why, and this is the one case the diagnostics row exists for.
            var probeDetail: String?
            if case .failure(let probe) = clearLocked() { probeDetail = probe.detail }
            return Attempt(
                code: ok,
                state: .armed,
                port: chain.port,
                deviceIP: chain.deviceIP,
                builtChain: builtChain,
                verifiedAt: lastVerified,
                channelFailures: channelFailures,
                detail: probeDetail
            )
        case .assert(let latitude, let longitude):
            // The only `location_simulation_set` in the file: nothing but an apply ever
            // moves the device, so an arm is observable to no other app.
            if let setError = location_simulation_set(chain.simulation, latitude, longitude) {
                let detail = describe(setError)
                channelFailures += 1
                if channelFailures >= deadChannelThreshold {
                    dropDeadChainLocked()
                    return .failed(channelLost, detail: detail)
                }
                return Attempt(
                    code: locationSet,
                    state: .armed,
                    port: chain.port,
                    deviceIP: chain.deviceIP,
                    builtChain: builtChain,
                    verifiedAt: lastVerified,
                    channelFailures: channelFailures,
                    detail: detail
                )
            }
            lastVerified = Date()
            channelFailures = 0
            return Attempt(
                code: ok,
                state: .spoofing,
                port: chain.port,
                deviceIP: chain.deviceIP,
                builtChain: builtChain,
                verifiedAt: lastVerified,
                channelFailures: 0,
                detail: nil
            )
        }
    }

    /// One `location_simulation_clear` round-trip on the live chain. Asserts nothing, frees
    /// nothing, and counts toward nothing. Shared by the arm probe, Stop and the verify timer.
    private static func clearLocked() -> Result<EngineOutcome, EngineFailure> {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let chain else {
            // Nothing to clear is a successful stop, not a failure. Reporting it as an error
            // made Stop raise an alert every time after a session that never came up.
            return .success(EngineOutcome(state: .disarmed, port: nil, deviceIP: nil, builtChain: false, verifiedAt: nil, detail: nil))
        }
        if let clearError = location_simulation_clear(chain.simulation) {
            return .failure(EngineFailure(
                error: .locationClear,
                state: .armed,
                port: chain.port,
                deviceIP: chain.deviceIP,
                consecutiveChannelFailures: channelFailures,
                detail: describe(clearError)
            ))
        }
        lastVerified = Date()
        channelFailures = 0
        return .success(EngineOutcome(state: .armed, port: chain.port, deviceIP: chain.deviceIP, builtChain: false, verifiedAt: lastVerified, detail: nil))
    }

    /// The only automatic teardown: reached only when an assert has failed
    /// `deadChannelThreshold` times in a row, which means something was actively asserting on
    /// the chain. A chain nobody is using is never freed on its own, however dead it looks —
    /// freeing would guarantee the user cannot spoof, where keeping costs one socket.
    private static func dropDeadChainLocked() {
        dispatchPrecondition(condition: .onQueue(queue))
        chain?.free()
        chain = nil
        channelFailures = 0
        lastVerified = nil
    }

    private static func releaseLocked() -> EngineOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        if let chain {
            // Best effort, and the result is genuinely not worth reporting: freeing the
            // transport closes the socket, which ends any assertion whether or not the clear
            // landed, and the caller asked to be disarmed either way.
            if let clearError = location_simulation_clear(chain.simulation) {
                idevice_error_free(clearError)
            }
            chain.free()
        }
        chain = nil
        channelFailures = 0
        lastVerified = nil
        return EngineOutcome(state: .disarmed, port: nil, deviceIP: nil, builtChain: false, verifiedAt: nil, detail: nil)
    }

    private struct BuildFailure: Error {
        let code: Int32
        let detail: String?
    }

    /// Builds all four handles or none of them. The pointers are locals until every one of
    /// them exists, so `chain` can never observe a partial build.
    private static func buildLocked(pairingPath: String, deviceIP: String, port: UInt16) -> Result<Chain, BuildFailure> {
        dispatchPrecondition(condition: .onQueue(queue))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return .failure(BuildFailure(code: invalidIP, detail: nil)) }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            return .failure(BuildFailure(code: pairingRead, detail: describe(pairingError)))
        }
        guard let pairingHandle else { return .failure(BuildFailure(code: pairingRead, detail: nil)) }
        defer { rp_pairing_file_free(pairingHandle) }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        var remoteServer: OpaquePointer?
        var simulation: OpaquePointer?
        var handedOver = false
        // The unwind path: frees exactly the locals that exist, in the reverse of the order
        // `Chain.free()` documents. Once `handedOver` is set the Chain owns them and freeing
        // is its job alone, so this runs on every early exit and on no successful one.
        defer {
            if !handedOver {
                if let simulation { location_simulation_free(simulation) }
                if let remoteServer { remote_server_free(remoteServer) }
                if let handshake { rsd_handshake_free(handshake) }
                if let adapter { adapter_free(adapter) }
            }
        }

        let providerError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "LocusLocation",
                    pairingHandle,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if let providerError {
            return .failure(BuildFailure(code: tunnelCreate, detail: describe(providerError)))
        }
        guard let adapter, let handshake else {
            return .failure(BuildFailure(code: tunnelCreate, detail: "tunnel reported success without a handle"))
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            return .failure(BuildFailure(code: remoteServerCode, detail: describe(remoteServerError)))
        }
        guard let remoteServer else {
            return .failure(BuildFailure(code: remoteServerCode, detail: "handshake reported success without a handle"))
        }

        if let simError = location_simulation_new(remoteServer, &simulation) {
            return .failure(BuildFailure(code: simulationCreate, detail: describe(simError)))
        }
        guard let simulation else {
            return .failure(BuildFailure(code: simulationCreate, detail: "simulation reported success without a handle"))
        }

        handedOver = true
        return .success(Chain(
            adapter: adapter,
            handshake: handshake,
            remoteServer: remoteServer,
            simulation: simulation,
            port: port,
            deviceIP: deviceIP
        ))
    }

    /// Captures an FFI error's fields for display and frees it. Every error the engine sees
    /// goes through here, so `idevice_error_free` is never skipped on a failure path.
    private static func describe(_ error: UnsafeMutablePointer<IdeviceFfiError>) -> String {
        let code = error.pointee.code
        let subCode = error.pointee.sub_code
        var message = ""
        if let cMessage = error.pointee.message {
            message = String(cString: cMessage)
        }
        idevice_error_free(error)
        return message.isEmpty ? "code \(code)/\(subCode)" : "\(message) (code \(code)/\(subCode))"
    }
}
