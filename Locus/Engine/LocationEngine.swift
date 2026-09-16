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
        }
    }

    static func from(code: Int32) -> LocationEngineError {
        switch code {
        case 1: return .invalidIP
        case 2: return .pairingRead
        case 3: return .tunnelCreate
        case 4: return .portUnavailable
        case 9: return .remoteServer
        case 10: return .simulationCreate
        case 11: return .locationSet
        case 12: return .locationClear
        default: return .locationSet
        }
    }
}

/// Outcome of a successful `set`, for diagnostics in Settings.
struct LocationApplied: Sendable, Equatable {
    let port: UInt16
    let rebuiltTunnel: Bool
}

/// Thin Swift wrapper around idevice’s DVT location simulation (injects into locationd).
enum LocationEngine {
    private static let queue = DispatchQueue(label: "com.ricepollution.locus.location", qos: .userInitiated)

    private static var adapter: OpaquePointer?
    private static var handshake: OpaquePointer?
    private static var remoteServer: OpaquePointer?
    private static var locationSimulation: OpaquePointer?

    private static let ok: Int32 = 0
    private static let invalidIP: Int32 = 1
    private static let pairingRead: Int32 = 2
    private static let tunnelCreate: Int32 = 3
    private static let remoteServerCode: Int32 = 9
    private static let simulationCreate: Int32 = 10
    private static let locationSet: Int32 = 11
    private static let locationClear: Int32 = 12

    /// Port the live session was built on, so the fast path can still report one.
    private static var sessionPort: UInt16?

    static func set(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String) async -> Result<LocationApplied, LocationEngineError> {
        let tried = RemotePairingDiscovery.candidates(for: deviceIP)
        let first = await onQueue {
            attemptLocked(ports: tried, latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
        }
        if first.code == ok {
            // `ok` always carries a port; the coalesce only exists to keep the type honest,
            // and the historical hardcoded port is the right thing to name if it ever fires.
            return .success(LocationApplied(port: first.reachedPort ?? RemotePairingDiscovery.fallbackPort, rebuiltTunnel: first.rebuiltTunnel))
        }
        guard first.code == tunnelCreate else { return .failure(.from(code: first.code)) }

        // Every candidate refused at the tunnel layer, so the port is what we got wrong.
        // Browsing is off the queue: Bonjour must not block the FFI serializer.
        guard let discovered = await RemotePairingDiscovery.discover(targetIP: deviceIP),
              !tried.contains(discovered) else { return .failure(.portUnavailable) }

        let second = await onQueue {
            attemptLocked(ports: [discovered], latitude: latitude, longitude: longitude, pairingPath: pairingPath, deviceIP: deviceIP)
        }
        guard second.code == ok else {
            // Every candidate and the discovered port refused at the tunnel layer. Say
            // that, rather than repeating the generic "could not open the tunnel".
            return .failure(second.code == tunnelCreate ? .portUnavailable : .from(code: second.code))
        }
        return .success(LocationApplied(port: second.reachedPort ?? discovered, rebuiltTunnel: second.rebuiltTunnel))
    }

    static func clear() async -> Result<Void, LocationEngineError> {
        let code = await onQueue { clearLocked() }
        return code == ok ? .success(()) : .failure(.from(code: code))
    }

    /// Hops onto the FFI serializer without ever blocking the caller's thread.
    private static func onQueue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Tries each candidate port in turn inside a single queue hop. A returned `ok`
    /// always carries the port the live session sits on.
    private static func attemptLocked(
        ports: [UInt16],
        latitude: Double,
        longitude: Double,
        pairingPath: String,
        deviceIP: String
    ) -> (code: Int32, reachedPort: UInt16?, rebuiltTunnel: Bool) {
        if let locationSimulation {
            if let err = location_simulation_set(locationSimulation, latitude, longitude) {
                idevice_error_free(err)
                cleanup()
            } else {
                return (ok, sessionPort, false)
            }
        }

        for port in ports {
            let code = setLocked(
                latitude: latitude,
                longitude: longitude,
                pairingPath: pairingPath,
                deviceIP: deviceIP,
                port: port
            )
            switch code {
            case ok:
                sessionPort = port
                RemotePairingDiscovery.recordSuccess(port: port, for: deviceIP)
                return (ok, port, true)
            case tunnelCreate:
                RemotePairingDiscovery.invalidate(port: port, for: deviceIP)
                continue
            case remoteServerCode, simulationCreate, locationSet:
                // The tunnel itself answered here, so the port was right and only the
                // layers above it failed — keep it rather than hunting for another.
                RemotePairingDiscovery.recordSuccess(port: port, for: deviceIP)
                return (code, port, true)
            default:
                return (code, nil, false)
            }
        }
        // Every candidate refused the tunnel; `set` takes this as its cue to browse.
        return (tunnelCreate, nil, false)
    }

    private static func cleanup() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    private static func setLocked(latitude: Double, longitude: Double, pairingPath: String, deviceIP: String, port: UInt16) -> Int32 {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        let inetResult = deviceIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard inetResult == 1 else { return invalidIP }

        var pairingHandle: OpaquePointer?
        if let pairingError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingHandle) }) {
            idevice_error_free(pairingError)
            return pairingRead
        }
        guard let pairingHandle else { return pairingRead }
        defer { rp_pairing_file_free(pairingHandle) }

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
            idevice_error_free(providerError)
            cleanup()
            return tunnelCreate
        }

        if let remoteServerError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
            idevice_error_free(remoteServerError)
            cleanup()
            return remoteServerCode
        }

        if let simError = location_simulation_new(remoteServer, &locationSimulation) {
            idevice_error_free(simError)
            cleanup()
            return simulationCreate
        }
        // NOT consumed. The Rust side takes a mutable *borrow* of the remote server
        // (ffi/src/dvt/location_simulation.rs does `&mut (*server).0` and never
        // Box::from_raw's it); the simulation handle holds that reference with its
        // lifetime transmuted to 'static. So the server has to outlive the simulation
        // AND still be freed afterwards. cleanup() frees the simulation first and the
        // server second, which is exactly that order. The original code nil'd the
        // pointer here believing the call consumed it, which leaked one
        // RemoteServerHandle for every tunnel build.

        if let setError = location_simulation_set(locationSimulation, latitude, longitude) {
            idevice_error_free(setError)
            cleanup()
            return locationSet
        }
        return ok
    }

    private static func clearLocked() -> Int32 {
        guard let locationSimulation else {
            // Nothing to clear is a successful stop, not a failure. Every failing apply
            // already ran cleanup(), so this is the ordinary state after a dropped
            // session — reporting it as an error made Stop raise an alert every time.
            // Running cleanup() here keeps "clear leaves all handles nil" structural.
            cleanup()
            return ok
        }
        let err = location_simulation_clear(locationSimulation)
        cleanup()
        if let err {
            idevice_error_free(err)
            return locationClear
        }
        return ok
    }
}
