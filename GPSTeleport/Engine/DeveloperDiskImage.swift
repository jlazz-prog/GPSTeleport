import Foundation
import idevice

/// Apple's location simulation service lives on the Developer Disk Image (DDI).
/// On iOS 26.4 and later it's installed as a cryptex, which needs a one-time
/// download and stays installed until the phone restarts.
enum DeveloperDiskImage {
    static var canAutoInstall: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)
    }

    static func isInstalled(adapter: OpaquePointer, handshake: OpaquePointer) throws -> Bool {
        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        if let error = consume(cryptexd_installed_ddi(adapter, handshake, &installed),
                               "Couldn't check whether the Developer Disk Image is installed.") {
            throw error
        }
        defer { cryptexd_free_installed_cryptex(installed) }
        return installed != nil
    }

    static func install(adapter: OpaquePointer, handshake: OpaquePointer, progress: (String) -> Void) throws {
        guard canAutoInstall else {
            throw DeviceError(message: "Automatic Developer Disk Image install needs iOS 26.4 or later.")
        }
        try downloadIfNeeded(progress: progress)

        progress("Installing Developer Disk Image…")
        var assets: OpaquePointer?
        if let error = consume(cryptex1_assets_load(directory.path, &assets),
                               "The downloaded Developer Disk Image files are damaged. Try again.") {
            removeDownloads()
            throw error
        }
        defer { cryptex1_assets_free(assets) }

        if let error = consume(cryptexd_install_ddi(adapter, handshake, assets, nil),
                               "Couldn't install the Developer Disk Image. Check that Developer Mode is on and you're online.") {
            throw error
        }
    }

    // MARK: - Downloads

    private static let baseURL =
        "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Cryptex/"
    private static let fileNames = [
        "BuildManifest.plist",
        "Image.dmg",
        "Image.dmg.trustcache",
        "Image.dmg.cryptex_info",
        "Image.dmg.root_hash",
    ]

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("DDI", isDirectory: true)
    }

    private static func downloadIfNeeded(progress: (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in fileNames.enumerated() {
            let destination = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { continue }
            progress("Downloading Developer Disk Image (\(index + 1)/\(fileNames.count))…")
            try download(URL(string: baseURL + name)!, to: destination)
        }
    }

    private static func download(_ source: URL, to destination: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.downloadTask(with: source) { temporary, response, error in
            defer { done.signal() }
            if let error { failure = error; return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let temporary else {
                failure = DeviceError(message: "The Developer Disk Image download failed.")
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                failure = error
            }
        }
        task.resume()
        done.wait()
        if let failure {
            throw DeviceError(message: "Couldn't download the Developer Disk Image. Check your internet connection.",
                              detail: failure.localizedDescription)
        }
    }

    private static func removeDownloads() {
        try? FileManager.default.removeItem(at: directory)
    }
}
