import Foundation
import CoreLocation

/// App-facing state for spoofing: teleport, drive a route, keep alive, stop.
@MainActor
final class SpoofController: ObservableObject {
    struct DriveProgress: Equatable {
        var latitude: Double
        var longitude: Double
        var fractionComplete: Double
        var remainingMeters: Double
        var remainingSeconds: Double
        var isPaused: Bool
        var isReconnecting: Bool

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    enum Status: Equatable {
        case off
        case working(String)
        case active(CLLocationCoordinate2D)
        case driving(DriveProgress)
        case failed(String)

        static func == (lhs: Status, rhs: Status) -> Bool {
            switch (lhs, rhs) {
            case (.off, .off): return true
            case let (.working(a), .working(b)): return a == b
            case let (.active(a), .active(b)): return a.latitude == b.latitude && a.longitude == b.longitude
            case let (.driving(a), .driving(b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .off

    /// How often a stationary location is re-sent. Re-sending keeps the session alive
    /// and reconnects automatically if the tunnel dropped.
    private let refreshInterval: TimeInterval = 4
    /// How often the position moves along a route.
    private let driveInterval: TimeInterval = 1

    private var timer: Timer?
    private var target: CLLocationCoordinate2D?
    private var sendInFlight = false
    private let keepAlive = BackgroundKeepAlive()
    /// Sends and the final clear run in order here, so a late send can't undo Stop.
    private let sendQueue = DispatchQueue(label: "com.jlazzprog.gpsteleport.send", qos: .userInitiated)

    private var playback: RoutePlayback?
    private var metersPerSecond: Double = 0
    private var lastDriveTick = Date()
    private var isPaused = false
    private var isReconnecting = false

    /// True while the phone is reporting a spoofed location.
    var isActive: Bool {
        switch status {
        case .active, .driving: return true
        default: return false
        }
    }

    var isBusy: Bool {
        if case .working = status { return true }
        return false
    }

    /// Where the phone is currently pretending to be.
    var spoofedCoordinate: CLLocationCoordinate2D? {
        switch status {
        case .active(let coordinate): return coordinate
        case .driving(let progress): return progress.coordinate
        default: return nil
        }
    }

    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard !isBusy else { return }
        stopTimer()
        playback = nil
        target = coordinate
        connect(to: coordinate) { [weak self] in
            self?.holdPosition(at: coordinate)
        }
    }

    /// Moves along the route's points at the given speed, then stays at the end.
    func drive(along points: [CLLocationCoordinate2D], metersPerSecond: Double) {
        guard !isBusy, let route = RoutePlayback(points: points), metersPerSecond > 0 else { return }
        stopTimer()
        target = nil
        playback = route
        self.metersPerSecond = metersPerSecond
        isPaused = false
        isReconnecting = false

        connect(to: route.coordinate) { [weak self] in
            self?.startDriving()
        }
    }

    func setDriveSpeed(metersPerSecond: Double) {
        guard metersPerSecond > 0 else { return }
        self.metersPerSecond = metersPerSecond
        publishDriveProgress()
    }

    func setDrivePaused(_ paused: Bool) {
        isPaused = paused
        publishDriveProgress()
    }

    func stop() {
        stopTimer()
        target = nil
        playback = nil
        status = .working("Returning to your real location…")
        sendQueue.async {
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

    // MARK: - Connecting

    private func connect(to coordinate: CLLocationCoordinate2D, then onConnected: @escaping @MainActor () -> Void) {
        status = .working("Connecting…")
        keepAlive.start()

        sendQueue.async {
            do {
                try DeviceLink.shared.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude) { message in
                    DispatchQueue.main.async { [weak self] in
                        if self?.isBusy == true { self?.status = .working(message) }
                    }
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onConnected() }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error)
                }
            }
        }
    }

    private func fail(_ error: Error) {
        stopTimer()
        target = nil
        playback = nil
        keepAlive.stop()
        status = .failed(error.localizedDescription)
    }

    // MARK: - Staying in one place

    private func holdPosition(at coordinate: CLLocationCoordinate2D) {
        target = coordinate
        status = .active(coordinate)
        startTimer(interval: refreshInterval) { [weak self] in
            self?.refreshTarget()
        }
    }

    private func refreshTarget() {
        guard let target else { return }
        // Failures here are retried on the next tick; the session reconnects itself.
        send(target, onResult: { _ in })
    }

    // MARK: - Driving

    private func startDriving() {
        lastDriveTick = Date()
        publishDriveProgress()
        startTimer(interval: driveInterval) { [weak self] in
            self?.driveTick()
        }
    }

    private func driveTick() {
        guard var route = playback else { return }

        // Measure real elapsed time, because iOS can delay timers in the background.
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDriveTick)
        lastDriveTick = now

        // Hold position while the tunnel is down, so the trip doesn't jump ahead when it returns.
        if !isPaused && !isReconnecting {
            route.advance(by: metersPerSecond * elapsed)
            playback = route
        }

        send(route.coordinate) { [weak self] succeeded in
            self?.isReconnecting = !succeeded
            self?.publishDriveProgress()
        }

        if route.isFinished {
            stopTimer()
            playback = nil
            holdPosition(at: route.coordinate)
        } else {
            publishDriveProgress()
        }
    }

    private func publishDriveProgress() {
        guard let route = playback else { return }
        let coordinate = route.coordinate
        status = .driving(DriveProgress(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            fractionComplete: route.fractionComplete,
            remainingMeters: route.remaining,
            remainingSeconds: route.remaining / metersPerSecond,
            isPaused: isPaused,
            isReconnecting: isReconnecting
        ))
    }

    // MARK: - Shared

    private func send(_ coordinate: CLLocationCoordinate2D, onResult: @escaping @MainActor (Bool) -> Void) {
        guard !sendInFlight else { return }
        sendInFlight = true
        sendQueue.async {
            let succeeded = (try? DeviceLink.shared.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) != nil
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.sendInFlight = false
                    onResult(succeeded)
                }
            }
        }
    }

    private func startTimer(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        stopTimer()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
