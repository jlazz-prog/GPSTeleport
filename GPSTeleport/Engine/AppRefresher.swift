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

    /// The bundle ID in this project, before a sideloader adds the team ID.
    private static let originalBundleID = "com.jlazzprog.gpsteleport"

    private let codeAnswered = DispatchSemaphore(value: 0)
    private var codeAnswer: String?

    var isRunning: Bool {
        switch state {
        case .working, .needsCode: return true
        default: return false
        }
    }

    func refresh(email: String, password: String) {
        guard !isRunning else { return }
        state = .working("Preparing…")

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let signed = try sign(email: email, password: password)
                publish(.working("Connecting through LocalDevVPN…"))
                try install(signedPath: signed)
                publish(.finished)
            } catch {
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
            Unmanaged.passUnretainedValue(self).toOpaque(),
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
                Unmanaged.passUnretainedValue(self).toOpaque()
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
        refresher.publish(.needsCode(sentBySMS: sentBySMS, lastError: lastError.map { String(cString: $0) }))
        refresher.codeAnswered.wait()
        guard let answer = refresher.codeAnswer else { return nil }
        return strdup(answer)
    }
}
