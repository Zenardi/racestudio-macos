import Foundation

/// Is the Mac joined to a MyChron's own Wi-Fi? (issue #179)
///
/// The logger is its own access point at `10.0.0.1` and hands its client an
/// address in `10.0.0.x`. When no interface has one, a failed search or
/// connection is almost always "the Mac is on the wrong network", and the panel
/// says how to join the logger's network instead of showing a bare error.
public enum DeviceNetwork {

    /// The address prefix a MyChron's access point hands out.
    public static let accessPointPrefix = "10.0.0."

    /// Whether any of `addresses` is on a MyChron access point's network.
    public static func isJoined(addresses: [String]) -> Bool {
        addresses.contains { $0.hasPrefix(accessPointPrefix) }
    }

    /// Whether the Mac is joined to a MyChron access point now.
    public static func isJoined() -> Bool {
        isJoined(addresses: currentIPv4Addresses())
    }

    /// The IPv4 addresses of this Mac's interfaces.
    public static func currentIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            if status == 0 { addresses.append(String(cString: host)) }
        }
        return addresses
    }
}
