import Foundation

/// Connecting when the iPhone has no Wi-Fi.
///
/// iOS refuses connections to its developer services while cellular data is on, even ones
/// from LocalDevVPN, but accepts them while it's off. Apps can't switch cellular data, so
/// the app asks the user to turn it off, connects, and asks them to turn it back on. The
/// connection stays open after that.
enum CellularLink {
    static let turnOffMessage = "Not on Wi-Fi: turn off Cellular Data in Control Center to connect."
    static let turnOnMessage = "Location set. Turn Cellular Data back on."

    /// How long to wait for the user to turn cellular data off.
    static let connectTimeout: TimeInterval = 60
    /// How long the reminder to turn cellular data back on stays up.
    static let turnOnMessageSeconds: TimeInterval = 5

    /// True when the Wi-Fi interface has a real address, meaning it has joined a network.
    static var isOnWiFi: Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // 169.254.x.x is what an interface gives itself when it hasn't joined anything.
            if ip & 0xFFFF_0000 != 0xA9FE_0000 { return true }
        }
        return false
    }
}
