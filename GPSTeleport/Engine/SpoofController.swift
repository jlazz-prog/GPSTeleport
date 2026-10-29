import Foundation
import CoreLocation

/// App-facing state for teleporting: start, keep alive, stop.
@MainActor
final class SpoofController: ObservableObject {
    enum Status: Equatable {
        case off
        case working(String)
        case active(CLLocationCoordinate2D)
        case failed(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.off, .off): return true
            case let (.working(a), .working(b)): return a == b
            case let (.active(a), .active(b)): return a.latitude == b.latitude && a.longitude == b.longitude
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .off

    /// How often the location is re-sent. Re-sending keeps the session alive and
    /// reconnects automatically if the tunnel dropped.
    private let refreshInterval: TimeInterval = 4
    private var refreshTimer: Timer?
    private var target: CLLocationCoordinate2D?
    private var refreshInFlight = false
    private let keepAlive = BackgroundKeepAlive()

    var isActive: Bool {
        if case .active = status { return true }
        return false
    }

    var isBusy: Bool {
        if case .working = status { return true }
        return false
    }

    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard !isBusy else { return }
        target = coordinate
        status = .working("Connecting…")
        keepAlive.start()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try DeviceLink.shared.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude) { message in
                    DispatchQueue.main.async { [weak self] in
                        if self?.isBusy == true { self?.status = .working(message) }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    self?.status = .active(coordinate)
                    self?.startRefreshing()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error)
                }
            }
        }
    }

    func stop() {
        stopRefreshing()
        target = nil
        status = .working("Returning to your real location…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try DeviceLink.shared.clearLocation() }
            DispatchQueue.main.async { [weak self] in
                self?.keepAlive.stop()
                switch result {
                case .success: self?.status = .off
                case .failure(let error): self?.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func requestLocationPermission() {
        keepAlive.requestPermission()
    }

    func dismissError() {
        if case .failed = status { status = .off }
    }

    private func fail(_ error: Error) {
        stopRefreshing()
        target = nil
        keepAlive.stop()
        status = .failed(error.localizedDescription)
    }

    private func startRefreshing() {
        stopRefreshing()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        guard let target, !refreshInFlight else { return }
        refreshInFlight = true
        DispatchQueue.global(qos: .utility).async {
            // Failures here are retried on the next tick; the session reconnects itself.
            try? DeviceLink.shared.setLocation(latitude: target.latitude, longitude: target.longitude)
            DispatchQueue.main.async { [weak self] in self?.refreshInFlight = false }
        }
    }
}
