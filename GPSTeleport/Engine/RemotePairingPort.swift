import Foundation

/// Finds the port the iPhone's remote pairing service listens on, using Bonjour.
/// Falls back to the usual port when nothing answers in time.
final class RemotePairingPort: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let fallback: UInt16 = 49152

    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var found: UInt16?

    /// Blocks for up to `timeout` seconds. Call off the main thread.
    static func resolve(timeout: TimeInterval = 4) -> UInt16 {
        let worker = RemotePairingPort()
        let done = DispatchSemaphore(value: 0)
        Thread {
            worker.search(timeout: timeout)
            done.signal()
        }.start()
        _ = done.wait(timeout: .now() + timeout + 1)
        return worker.found ?? fallback
    }

    private func search(timeout: TimeInterval) {
        browser.delegate = self
        browser.schedule(in: .current, forMode: .default)
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        let deadline = Date().addingTimeInterval(timeout)
        while found == nil && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        browser.stop()
        services.forEach { $0.stop() }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.schedule(in: .current, forMode: .default)
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if found == nil, (1...65535).contains(sender.port) {
            found = UInt16(sender.port)
        }
    }
}
