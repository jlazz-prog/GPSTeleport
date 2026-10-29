import Foundation
import idevice

/// An error with a message written for the person using the app.
struct DeviceError: LocalizedError {
    let message: String
    var detail: String?

    var errorDescription: String? {
        guard let detail, !detail.isEmpty else { return message }
        return "\(message)\n\n(\(detail))"
    }
}

/// Turns an idevice FFI error into a `DeviceError` and frees it.
/// Returns nil when `ffiError` is nil (the call succeeded).
func consume(_ ffiError: UnsafeMutablePointer<IdeviceFfiError>?, _ message: String) -> DeviceError? {
    guard let ffiError else { return nil }
    defer { idevice_error_free(ffiError) }
    let code = ffiError.pointee.code
    let text = ffiError.pointee.message.map { String(cString: $0) } ?? "unknown error"
    return DeviceError(message: message, detail: "code \(code): \(text)")
}
