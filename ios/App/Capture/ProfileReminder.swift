import Foundation
import FTModel
import UserNotifications

/// Local notifications, only after the user opts in: the profile's expiry (a day ahead), and the capture
/// countdown's "do it now" and "your sysdiagnose should be ready" for when the user has left FieldTap. Nothing
/// is shown while FieldTap is open (there is no foreground presentation), which is the point: the countdown on
/// screen already says it.
enum ProfileReminder {
    static let expiryId = "ft.profile.expiry"
    static let doItNowId = "ft.capture.doItNow"
    static let readyId = "ft.capture.ready"
    static let noticedId = "ft.capture.noticed"

    /// Asks for permission (iOS asks the user only the first time). Called when a reminder is turned on.
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// A day before iOS removes Apple's profile; right away when that is already less than a day off. The fire
    /// date is `ProfileState.expiryReminderDate`, so the timing is one tested function.
    static func scheduleExpiry(_ profile: ProfileState) async {
        guard let removal = profile.removalDate, let fireAt = profile.expiryReminderDate() else { return }
        let lead = max(1, fireAt.timeIntervalSinceNow)
        let when = removal.formatted(.dateTime.weekday(.wide).hour().minute())
        await add(expiryId, after: lead, title: "Modem logging ends soon",
                  body: "Apple's logging profile expires \(when). Renew it in FieldTap's Modem logging guide before your next test.")
    }

    /// "Your sysdiagnose should be ready", `interval` seconds from now.
    static func scheduleSysdiagnoseReady(after interval: TimeInterval) async {
        await add(readyId, after: interval, title: "Your sysdiagnose should be ready",
                  body: "Open Settings > Privacy & Security > Analytics & Improvements > Analytics Data and share it to FieldTap.")
    }

    /// "Do it now": the moment to reproduce the problem (R2), `interval` seconds from now.
    static func scheduleDoItNow(after interval: TimeInterval) async {
        await add(doItNowId, after: interval, title: "Do it now",
                  body: "Make the problem happen now: place the call, open the app, or go to the spot.")
    }

    /// The SysdiagnoseWatcher spotted a likely sysdiagnose (a screenshot plus the sysdiagnose directory
    /// present). Best-effort: only fires if notifications are already authorised, so it never prompts for
    /// permission on a screenshot. Fires a few seconds out so it lands after the user leaves for Settings.
    static func notifyNoticedCapture() async {
        let center = UNUserNotificationCenter.current()
        guard (await center.notificationSettings()).authorizationStatus == .authorized else { return }
        await add(noticedId, after: 3, title: "Did you just take a sysdiagnose?",
                  body: "When it's ready, open Settings > Privacy & Security > Analytics & Improvements > Analytics Data and share the newest sysdiagnose into FieldTap.")
    }

    static func cancelCapture() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [doItNowId, readyId])
    }

    static func cancelExpiry() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [expiryId])
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [expiryId, doItNowId, readyId])
    }

    private static func add(_ id: String, after interval: TimeInterval, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
