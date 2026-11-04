import Foundation
import UserNotifications

/// Knows when this install stops opening, and schedules reminders before then.
enum AppExpiry {
    /// When the app's provisioning profile runs out. Nil if it can't be read.
    static var date: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              // The profile is a signed wrapper around a plain XML plist.
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    static var isExpiringSoon: Bool {
        guard let date else { return false }
        return date.timeIntervalSinceNow < 2 * 86400
    }

    /// A description like "in 3 days", for showing in the app.
    static var timeLeftDescription: String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in less than an hour" }
        if seconds < 86400 {
            let hours = Int(seconds / 3600)
            return "in \(hours) hour\(hours == 1 ? "" : "s")"
        }
        let days = Int(seconds / 86400)
        return "in \(days) day\(days == 1 ? "" : "s")"
    }

    private static let reminders: [(id: String, secondsBefore: TimeInterval, message: String)] = [
        ("refresh-2-days", 2 * 86400, "GPS Teleport stops opening in 2 days. Open it and tap Refresh."),
        ("refresh-1-day", 86400, "GPS Teleport stops opening tomorrow. Open it and tap Refresh."),
        ("refresh-4-hours", 4 * 3600, "GPS Teleport stops opening in 4 hours. Refresh it now, or you'll need a PC to reinstall it."),
    ]

    /// Asks for permission the first time, then replaces the reminders with ones for the
    /// current expiry date. Safe to call often. A refreshed app reschedules when it next opens.
    static func scheduleReminders() async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true,
              let date
        else { return }

        center.removePendingNotificationRequests(withIdentifiers: reminders.map(\.id))

        for reminder in reminders {
            let seconds = date.timeIntervalSinceNow - reminder.secondsBefore
            guard seconds > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Refresh GPS Teleport"
            content.body = reminder.message
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    /// False if the user turned off this app's notifications.
    static func notificationsAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status != .denied
    }
}
