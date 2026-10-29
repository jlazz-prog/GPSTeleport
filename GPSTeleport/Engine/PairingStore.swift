import Foundation
import idevice

/// Keeps the one RPPairing file the app uses to open the developer tunnel.
enum PairingStore {
    static var url: URL {
        directory.appendingPathComponent("rp_pairing.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Imports a pairing file picked in the Files app or shared into the app.
    static func importFile(at source: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        try importData(data)
    }

    /// Imports pairing file contents, for example pasted from the clipboard.
    static func importData(_ data: Data) throws {
        try validate(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Picks up a pairing file dropped into the app's Documents folder
    /// (for example with the Apple Devices app on Windows) and moves it into place.
    static func importFromDocumentsIfPresent() {
        let fm = FileManager.default
        let documents = URL.documentsDirectory
        guard let items = try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil) else { return }
        let extensions = ["plist", "mobiledevicepairing", "mobiledevicepair"]
        for item in items where extensions.contains(item.pathExtension.lowercased()) {
            if (try? importFile(at: item)) != nil {
                try? fm.removeItem(at: item)
                return
            }
        }
    }

    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Pairing", isDirectory: true)
    }

    private static func validate(_ data: Data) throws {
        var handle: OpaquePointer?
        let ffiError = data.withUnsafeBytes { buffer in
            rp_pairing_file_from_bytes(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                UInt(buffer.count),
                &handle
            )
        }
        if let error = consume(ffiError, "That file isn't a valid pairing file. Make one by running GPSTeleport-Pairing.exe on your PC.") {
            throw error
        }
        rp_pairing_file_free(handle)
    }
}
