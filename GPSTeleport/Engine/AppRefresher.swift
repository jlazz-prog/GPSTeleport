import Foundation
import idevice

/// Gives the app a fresh 7-day signature: signs a copy of itself with the user's
/// Apple ID, then installs that copy over itself through LocalDevVPN.
final class AppRefresher: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case needsCode(sentBySMS: Bool, lastError: String?)
        case finished
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// True when the current or last run started by itself, rather than from the Refresh screen.
    @Published private(set) var isAutomatic = false

    /// The bundle ID in this project, before a sideloader adds the team ID.
    private static let originalBundleID = "com.jlazzprog.gpsteleport"

    /// The UserDefaults key for the Apple ID.
    static let emailKey = "refreshAppleID"

    /// Refresh by itself once there's less than this long left.
    private static let automaticWindow: TimeInterval = 3 * 86400
    /// Apple can lock an account after repeated failed sign-ins, so keep attempts rare and few.
    private static let automaticRetryDelay: TimeInterval = 6 * 3600
    private static let automaticMaxFailures = 3
    private static let lastAttemptKey = "refreshLastAutomaticAttempt"
    private static let failuresKey = "refreshAutomaticFailures"

    private let codeAnswered = DispatchSemaphore(value: 0)
    private var codeAnswer: String?
    private var isCheckingAutomatic = false

    var isRunning: Bool {
        switch state {
        case .working, .needsCode: return true
        default: return false
        }
    }

    func refresh(email: String, password: String) {
        guard !isRunning, !isCheckingAutomatic else { return }
        // Trying by hand means the user may have fixed whatever was failing.
        UserDefaults.standard.set(0, forKey: Self.failuresKey)
        run(email: email, password: password, automatic: false)
    }

    /// Refreshes if the app is close to expiring and the user turned on automatic refresh.
    /// Does nothing if LocalDevVPN is off, so it never uses up a sign-in it can't finish.
    /// Call on the main thread.
    func refreshAutomaticallyIfNeeded(isSpoofing: @escaping @MainActor () -> Bool) {
        let defaults = UserDefaults.standard
        guard !isRunning, !isCheckingAutomatic,
              let expiry = AppExpiry.date
        else { return }

        guard expiry.timeIntervalSinceNow < Self.automaticWindow else {
            defaults.set(0, forKey: Self.failuresKey)
            return
        }

        let lastAttempt = defaults.double(forKey: Self.lastAttemptKey)
        guard defaults.integer(forKey: Self.failuresKey) < Self.automaticMaxFailures,
              Date().timeIntervalSince1970 - lastAttempt >= Self.automaticRetryDelay,
              let email = defaults.string(forKey: Self.emailKey), !email.isEmpty,
              let password = SavedPassword.load()
        else { return }

        isCheckingAutomatic = true
        DispatchQueue.global(qos: .utility).async { [self] in
            let tunnelWorks = (try? DeviceLink.shared.withDeveloperTunnel { _, _ in }) != nil
            DispatchQueue.main.async { [self] in
                isCheckingAutomatic = false
                let spoofing = MainActor.assumeIsolated { isSpoofing() }
                guard tunnelWorks, !spoofing, !isRunning else { return }
                defaults.set(Date().timeIntervalSince1970, forKey: Self.lastAttemptKey)
                run(email: email, password: password, automatic: true)
            }
        }
    }

    private func run(email: String, password: String, automatic: Bool) {
        isAutomatic = automatic
        state = .working("Preparing…")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let signed = try sign(email: email, password: password)
                publish(.working("Connecting through LocalDevVPN…"))
                try install(signedPath: signed)
                publish(.finished)
            } catch {
                if automatic {
                    let defaults = UserDefaults.standard
                    defaults.set(defaults.integer(forKey: Self.failuresKey) + 1, forKey: Self.failuresKey)
                }
                publish(.failed(error.localizedDescription))
            }
        }
    }

    /// Answers a 2FA prompt. Pass nil to cancel.
    func submitCode(_ code: String?) {
        guard case .needsCode = state else { return }
        state = .working("Checking the code…")
        codeAnswer = code
        codeAnswered.signal()
    }

    func requestSMS() {
        submitCode("sms")
    }

    func reset() {
        if !isRunning { state = .idle }
    }

    // MARK: - Steps

    private func sign(email: String, password: String) throws -> String {
        guard let currentBundleID = Bundle.main.bundleIdentifier else {
            throw DeviceError(message: "Couldn't read this app's bundle ID.")
        }
        let copy = try makeWritableCopy()
        let storage = try Self.workDirectory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        var signedPointer: UnsafeMutablePointer<CChar>?
        let error = gps_refresh_sign(
            email,
            password,
            copy.path,
            storage.path,
            currentBundleID,
            Self.progressCallback,
            Self.codeCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &signedPointer
        )
        try Self.throwIfError(error)

        guard let signedPointer else {
            throw DeviceError(message: "Signing finished without producing an app.")
        }
        defer { gps_refresh_string_free(signedPointer) }
        return String(cString: signedPointer)
    }

    private func install(signedPath: String) throws {
        try DeviceLink.shared.withDeveloperTunnel { adapter, handshake in
            let error = gps_refresh_install(
                adapter,
                handshake,
                signedPath,
                Self.progressCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.throwIfError(error)
        }
    }

    /// Signing changes the bundle in place, and the installed app is read-only.
    private func makeWritableCopy() throws -> URL {
        let files = FileManager.default
        let directory = try Self.workDirectory.appendingPathComponent("Signing", isDirectory: true)
        try? files.removeItem(at: directory)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)

        let copy = directory.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent, isDirectory: true)
        try files.copyItem(at: Bundle.main.bundleURL, to: copy)

        if let contents = files.enumerator(at: copy, includingPropertiesForKeys: nil) {
            for case let item as URL in contents {
                let mode = (try? files.attributesOfItem(atPath: item.path)[.posixPermissions] as? Int) ?? 0o644
                try? files.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: item.path)
            }
        }
        try? files.removeItem(at: copy.appendingPathComponent("_CodeSignature"))
        try? files.removeItem(at: copy.appendingPathComponent("embedded.mobileprovision"))

        // The signer adds the team ID itself, so it has to start from the original ID.
        // Otherwise the suffix doubles and iOS installs a second copy of the app.
        let infoURL = copy.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        let data = try Data(contentsOf: infoURL)
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any] else {
            throw DeviceError(message: "Couldn't read this app's Info.plist.")
        }
        info["CFBundleIdentifier"] = Self.originalBundleID
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        return copy
    }

    private static var workDirectory: URL {
        get throws {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("Refresh", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    private static func throwIfError(_ error: UnsafeMutablePointer<CChar>?) throws {
        guard let error else { return }
        defer { gps_refresh_string_free(error) }
        throw DeviceError(message: String(cString: error))
    }

    /// Reads `isAutomatic` from the Rust callback's thread.
    private var isAutomaticRun: Bool {
        DispatchQueue.main.sync { isAutomatic }
    }

    private func publish(_ state: State) {
        DispatchQueue.main.async { self.state = state }
    }

    // MARK: - Callbacks from Rust (off the main thread)

    private static let progressCallback: gps_refresh_progress_fn = { message, context in
        guard let message, let context else { return }
        let refresher = Unmanaged<AppRefresher>.fromOpaque(context).takeUnretainedValue()
        refresher.publish(.working(String(cString: message)))
    }

    private static let codeCallback: gps_refresh_code_fn = { sentBySMS, lastError, context in
        guard let context else { return nil }
        let refresher = Unmanaged<AppRefresher>.fromOpaque(context).takeUnretainedValue()
        // Nobody may be looking at the app, so don't make Apple send a code and wait for it.
        if refresher.isAutomaticRun { return nil }
        refresher.publish(.needsCode(sentBySMS: sentBySMS, lastError: lastError.map { String(cString: $0) }))
        refresher.codeAnswered.wait()
        guard let answer = refresher.codeAnswer else { return nil }
        return strdup(answer)
    }
}
