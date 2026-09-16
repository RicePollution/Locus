import Darwin
import Foundation
import UIKit

/// How sure we are that the developer tunnel is reachable. Nothing here gates a
/// teleport — the engine is the only thing that actually knows.
enum TunnelReachability: Equatable {
    case confirmed
    case likely
    case unknown
}

enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let detectURL = URL(string: "localdevvpn://")!

    /// Starts the tunnel, then returns to Locus via `rplocus://`.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=rplocus")!

    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(detectURL)
    }

    /// LocalDevVPN puts the tunnel network on a `10.7.0.x` (or custom) utun when connected.
    static var isConnected: Bool {
        let addresses = ipv4InterfaceAddresses()
        let target = TunnelConfig.targetIP
        if addresses.contains(target) { return true }

        let parts = target.split(separator: ".")
        guard parts.count == 4 else { return false }
        let prefix = parts.dropLast().joined(separator: ".") + "."
        return addresses.contains { $0.hasPrefix(prefix) }
    }

    static func openInstalled() {
        UIApplication.shared.open(enableURL)
    }

    static func openAppStore() {
        UIApplication.shared.open(appStoreURL)
    }

    /// Open LocalDevVPN to connect if installed; otherwise App Store.
    static func openOrInstall() {
        if isInstalled {
            openInstalled()
        } else {
            openAppStore()
        }
    }

    private static func ipv4InterfaceAddresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var results: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let interface = current.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(
                    interface.ifa_addr,
                    nameLen,
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    results.append(String(cString: host))
                }
            }
            ptr = interface.ifa_next
        }
        return results
    }
}

extension LocalDevVPN {
    /// `isConnected` only sees the tunnel when it lands on a local interface, so it reads
    /// false for loopback-mode proxies (Clash, SingBox) whose tunnel works fine. An engine
    /// round-trip that actually reached `confirmedTarget` outranks it, and a negative
    /// interface scan is reported as "can't tell" rather than "not connected".
    static func reachability(confirmedTarget: String?, proven: Bool = false) -> TunnelReachability {
        if let confirmedTarget, confirmedTarget == TunnelConfig.targetIP { return .confirmed }
        if isConnected { return .likely }
        // The scan says no. If this exact IP has already answered once this process, the
        // scan is demonstrably unreliable for this setup, so don't assert a disconnection
        // we have disproved before. Only a never-worked IP is genuinely unknown.
        return proven ? .likely : .unknown
    }
}
