import Darwin
import Foundation
import SystemConfiguration

/// Network changes as they happen, for the VPN guard.
///
/// The kernel's routing socket (AF_ROUTE) carries a message the moment a VPN tunnel comes up or
/// goes down, an address changes, Wi-Fi switches or the default route moves: a VPN that blinks
/// for a few milliseconds is seen. The system's proxy settings are watched in SystemConfiguration
/// (a proxy app switched on or off is a new route too). The routing socket also chatters about
/// every new connection, so a "fingerprint" of the network (each interface's IPv4 address, and
/// the proxy settings) tells a real change from noise.
enum NetWatch {
    /// Calls `onChange` on the main queue, at most once per 100 ms burst, whenever the routing
    /// table or the proxy settings may have changed. Started once; it lives as long as Cooldown.
    @MainActor static func start(_ onChange: @escaping @MainActor () -> Void) {
        guard handler == nil else { handler = onChange; return }
        handler = onChange
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        if fd >= 0 {
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 { if relevant(buffer, count) { DispatchQueue.main.async { MainActor.assumeIsolated { poke() } } }; continue }
                    if count < 0 && errno == EINTR { continue }
                    break
                }
            }
            thread.qualityOfService = .utility
            thread.start()
        }
        var context = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        if let store = SCDynamicStoreCreate(nil, "Cooldown VPN guard" as CFString, proxiesChanged, &context) {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/Proxies", "State:/Network/Global/IPv4",
                                                      "State:/Network/Global/IPv6"] as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, .main)
            proxyStore = store
        }
    }

    @MainActor private static var handler: (@MainActor () -> Void)?
    @MainActor private static var proxyStore: SCDynamicStore?
    @MainActor private static var waiting = false

    /// Addresses, interfaces and real routes; not the stream of host routes and ARP entries every
    /// new connection adds (that would wake the main thread hundreds of times a second).
    private static func relevant(_ buffer: [UInt8], _ count: Int) -> Bool {
        guard count >= 12 else { return false }
        let type = Int32(buffer[3])
        switch type {
        case RTM_NEWADDR, RTM_DELADDR, RTM_IFINFO, RTM_IFINFO2: return true
        case RTM_ADD, RTM_DELETE, RTM_CHANGE:
            // rt_msghdr: msglen (2), version, type, index (2), padding (2), flags (4).
            let flags = buffer.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
            return flags & (RTF_HOST | RTF_LLINFO | RTF_WASCLONED) == 0
        default: return false
        }
    }

    @MainActor fileprivate static func poke() {
        guard !waiting else { return }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated {
                waiting = false
                handler?()
            }
        }
    }

    /// Each interface's IPv4 address (VPN tunnels included; loopback, link-local and the
    /// system's own virtual interfaces left out), then the proxy settings.
    static func fingerprint() -> String {
        var entries: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = cursor?.pointee {
                cursor = entry.ifa_next
                guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                      entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
                let name = String(cString: entry.ifa_name)
                if ["lo", "bridge", "awdl", "llw", "anpi", "ap", "gif", "stf", "vmenet", "vmnet"].contains(where: name.hasPrefix) { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(cString: host)
                if ip.hasPrefix("169.254.") { continue }
                entries.append("\(name)=\(ip)")
            }
            freeifaddrs(first)
        }
        return entries.sorted().joined(separator: ",") + "|" + primary() + "|" + proxyMark()
    }

    /// Where the default routes go (IPv4 and IPv6): an exit node or a full/split tunnel switched
    /// with the addresses unchanged moves these.
    private static let store = SCDynamicStoreCreate(nil, "Cooldown VPN guard fingerprint" as CFString, nil, nil)

    private static func primary() -> String {
        guard let store else { return "" }
        return ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].map { key in
            let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:]
            return "\(value["PrimaryInterface"] ?? "")>\(value["Router"] ?? "")"
        }.joined(separator: ";")
    }

    private static func proxyMark() -> String {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return "" }
        let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                    "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "ProxyAutoConfigEnable", "ProxyAutoConfigURLString"]
        return keys.map { "\(settings[$0] ?? "")" }.joined(separator: ";")
    }
}

/// SystemConfiguration's callback (a C function: it cannot capture anything).
private func proxiesChanged(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async { MainActor.assumeIsolated { NetWatch.poke() } }
}
