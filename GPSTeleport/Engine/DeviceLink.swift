import Foundation
import idevice

/// Talks to this iPhone's own developer services through the LocalDevVPN loopback
/// tunnel and drives Apple's location simulation (the same service Xcode uses).
///
/// Every method blocks, so call them off the main thread. Calls are serialized
/// on an internal queue.
final class DeviceLink {
    static let shared = DeviceLink()

    /// The address LocalDevVPN routes back to this phone.
    static let tunnelIP = "10.7.0.1"

    private static let lastPortKey = "remotePairingLastPort"

    private let queue = DispatchQueue(label: "com.jlazzprog.gpsteleport.device")
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationSimulation: OpaquePointer?

    private init() {
        _ = idevice_init_logger(Info, Disabled, nil)
    }

    /// Sets the simulated location, connecting (and reconnecting) as needed.
    func setLocation(latitude: Double, longitude: Double, progress: @escaping (String) -> Void = { _ in }) throws {
        try queue.sync {
            if let locationSimulation {
                guard let staleError = location_simulation_set(locationSimulation, latitude, longitude) else {
                    return
                }
                // The session dropped (sleep, network change, VPN off). Start over.
                idevice_error_free(staleError)
                disconnectLocked()
            }

            try connectLocked(progress: progress)
            if let error = consume(location_simulation_set(locationSimulation, latitude, longitude),
                                   "Connected, but setting the location failed.") {
                disconnectLocked()
                throw error
            }
        }
    }

    /// True when a location session is open. It may still turn out to have dropped.
    var hasOpenSession: Bool {
        queue.sync { locationSimulation != nil }
    }

    /// Repeats `work` while the iPhone refuses the connection, giving the user time to
    /// turn cellular data off. Any other error stops it straight away.
    static func retryWhileUnreachable(timeout: TimeInterval, _ work: () throws -> Void) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try work()
            } catch let error as DeviceError where error.isUnreachable {
                guard Date() < deadline else {
                    throw DeviceError(
                        message: "Couldn't connect. Turn off Cellular Data in Control Center, check that LocalDevVPN is connected, and try again.",
                        detail: error.detail,
                        isUnreachable: true
                    )
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// Stops simulating, so the phone goes back to its real location.
    func clearLocation() throws {
        try queue.sync {
            guard let locationSimulation else { return }
            let error = consume(location_simulation_clear(locationSimulation),
                                "Couldn't clear the simulated location. Restarting your iPhone always clears it.")
            disconnectLocked()
            if let error { throw error }
        }
    }

    /// Opens the tunnel and checks the Developer Disk Image, without changing location.
    func testConnection(progress: @escaping (String) -> Void) throws {
        try queue.sync {
            if locationSimulation != nil { return }
            try connectLocked(progress: progress)
        }
    }

    /// Opens a tunnel only for `work`, closing any session already open. Other calls wait.
    func withDeveloperTunnel<T>(_ work: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            disconnectLocked()
            guard PairingStore.exists else {
                throw DeviceError(message: "No pairing file yet. Import one in Setup first.")
            }
            try openTunnelLocked()
            defer { disconnectLocked() }
            guard let adapter, let handshake else {
                throw DeviceError(message: "Couldn't connect to your iPhone. Make sure LocalDevVPN is connected.")
            }
            return try work(adapter, handshake)
        }
    }

    // MARK: - Connection (queue only)

    private func connectLocked(progress: (String) -> Void) throws {
        disconnectLocked()

        guard PairingStore.exists else {
            throw DeviceError(message: "No pairing file yet. Import one in Setup first.")
        }

        // No progress message here: without Wi-Fi this repeats, and the request to turn
        // cellular data off has to stay on screen.
        try openTunnelLocked()

        progress("Opening location service…")
        do {
            try openLocationServiceLocked()
        } catch {
            // Usually means the Developer Disk Image isn't installed yet (it goes away on restart).
            guard let adapter, let handshake else { throw error }
            if try DeveloperDiskImage.isInstalled(adapter: adapter, handshake: handshake) {
                disconnectLocked()
                throw error
            }
            try DeveloperDiskImage.install(adapter: adapter, handshake: handshake, progress: progress)

            // Services from the new image show up on a fresh tunnel.
            disconnectLocked()
            progress("Reconnecting…")
            try openTunnelLocked()
            progress("Opening location service…")
            try openLocationServiceLocked()
        }
    }

    /// Tries the port that worked last time first, because Bonjour takes seconds at best
    /// and connecting without Wi-Fi retries this until cellular data is off.
    private func openTunnelLocked() throws {
        let defaults = UserDefaults.standard
        let savedPort = defaults.integer(forKey: Self.lastPortKey)
        if (1...65535).contains(savedPort) {
            do {
                try openTunnelLocked(port: UInt16(savedPort))
                return
            } catch let error as DeviceError where error.isUnreachable {
                // The port can change after a restart, so look it up below.
            }
        }

        let port = RemotePairingPort.resolve()
        try openTunnelLocked(port: port)
        defaults.set(Int(port), forKey: Self.lastPortKey)
    }

    private func openTunnelLocked(port: UInt16) throws {
        var pairing: OpaquePointer?
        let pairingPath = PairingStore.url.path
        if let error = consume(rp_pairing_file_read(pairingPath, &pairing),
                               "Couldn't read your pairing file. Import it again in Setup.") {
            throw error
        }
        defer { rp_pairing_file_free(pairing) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        _ = Self.tunnelIP.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }

        let ffiError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                tunnel_create_rppairing(
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "GPSTeleport",
                    pairing,
                    nil,
                    nil,
                    &adapter,
                    &handshake
                )
            }
        }
        if var error = consume(ffiError, "Couldn't connect to your iPhone. Make sure LocalDevVPN is connected. If you're not on Wi-Fi, turn off Cellular Data while it connects.") {
            error.isUnreachable = true
            disconnectLocked()
            throw error
        }

        // The library refreshes the pairing in place if it had to re-pair; keep that.
        if let writeError = rp_pairing_file_write(pairing, pairingPath) {
            idevice_error_free(writeError)
        }
    }

    private func openLocationServiceLocked() throws {
        if let error = consume(remote_server_connect_rsd(adapter, handshake, &remoteServer),
                               "Couldn't open Apple's developer services.") {
            throw error
        }
        // The location client borrows the remote server, so both stay open together.
        if let error = consume(location_simulation_new(remoteServer, &locationSimulation),
                               "Couldn't open Apple's location simulation service.") {
            throw error
        }
    }

    private func disconnectLocked() {
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
}
