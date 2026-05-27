import Foundation
import UserNotifications

/// Schedules a single daily reminder to log expenses.
/// Identified by a stable identifier so re-scheduling overwrites cleanly.
enum NotificationManager {

    private static let reminderID = "tula.daily.reminder"

    // MARK: - Authorization

    /// Requests notification permission. Idempotent — safe to call multiple
    /// times; iOS only shows the prompt once.
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Returns whether the user has granted (or denied) notification permission.
    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Scheduling

    /// Schedule (or reschedule) the daily reminder at the given hour:minute.
    /// Replaces any previously-scheduled reminder.
    static func scheduleDailyReminder(at hour: Int, minute: Int) {
        cancel()

        let content = UNMutableNotificationContent()
        content.title = "Time to log your day"
        content.body = "Tap to capture today's expenses in Tula."
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Cancel any scheduled daily reminder.
    static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID])
    }

    /// Check whether a daily reminder is currently scheduled.
    static func isScheduled() async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == reminderID }
    }
}
