import Foundation
import UserNotifications

/// Schedules notifications: a daily reminder to log expenses, and
/// threshold alerts for budgets (75% / 100%).
///
/// All notifications use stable identifier prefixes so re-scheduling
/// overwrites cleanly without piling up duplicate pending requests.
enum NotificationManager {

    private static let reminderID = "tula.daily.reminder"
    private static let budgetAlertPrefix = "tula.budget."

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

    // MARK: - Daily Reminder

    /// Schedule (or reschedule) the daily reminder at the given hour:minute.
    /// Replaces any previously-scheduled reminder.
    static func scheduleDailyReminder(at hour: Int, minute: Int) {
        cancelDailyReminder()

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
    static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID])
    }

    /// Legacy single-cancel API — kept for backward compat with older
    /// callers; behaves identically to `cancelDailyReminder()`.
    static func cancel() { cancelDailyReminder() }

    /// Check whether a daily reminder is currently scheduled.
    static func isScheduled() async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == reminderID }
    }

    // MARK: - Budget Threshold Alerts

    /// Fires *immediate* alerts for any budget that has just crossed a
    /// 75% or 100% threshold. Crossing state is tracked per-budget via
    /// UserDefaults flags so we don't double-fire on every refresh.
    ///
    /// Call this whenever expense data may have changed — after a Quick
    /// Log save, after Add Expense save, on app foreground, etc.
    ///
    /// Silent (no-op) when notifications are denied; the user opt-in
    /// gate is handled at the Settings toggle, not here.
    static func evaluateBudgetThresholds(
        budgets: [Budget],
        expenses: [Expense]
    ) {
        let prefix = budgetAlertPrefix
        let defaults = UserDefaults.standard

        for budget in budgets where budget.isActive {
            let progress = budget.progress(in: expenses)
            let key75 = "\(prefix)\(budget.id.uuidString).75"
            let key100 = "\(prefix)\(budget.id.uuidString).100"

            // Reset flags if user is back under threshold (period reset
            // or budget edit lowered the spend). Lets the alert fire
            // again next time they cross.
            if progress < 0.75 {
                defaults.removeObject(forKey: key75)
                defaults.removeObject(forKey: key100)
                continue
            }

            // 100% crossed — fire the over-budget alert (single per period).
            if progress >= 1.0 && !defaults.bool(forKey: key100) {
                fireBudgetAlert(budget: budget, progress: progress, level: .over)
                defaults.set(true, forKey: key100)
                // Mark 75% as already fired too — no need to chain notifications.
                defaults.set(true, forKey: key75)
                continue
            }

            // 75% crossed — fire the warning alert (single per period).
            if progress >= 0.75 && !defaults.bool(forKey: key75) {
                fireBudgetAlert(budget: budget, progress: progress, level: .warning)
                defaults.set(true, forKey: key75)
            }
        }
    }

    private enum BudgetAlertLevel {
        case warning, over

        var title: String {
            switch self {
            case .warning: return "75% of budget used"
            case .over:    return "Budget exceeded"
            }
        }

        var sound: UNNotificationSound { .default }
    }

    private static func fireBudgetAlert(
        budget: Budget,
        progress: Double,
        level: BudgetAlertLevel
    ) {
        let content = UNMutableNotificationContent()
        content.title = "\(budget.displayName) · \(level.title)"
        let percent = Int((progress * 100).rounded())
        content.body = level == .over
            ? "You've spent \(percent)% of your \(budget.period.shortLabel) budget."
            : "You've spent \(percent)% — keep an eye on \(budget.displayName.lowercased()) spend."
        content.sound = level.sound

        // Fire-immediately style notification — no trigger means it
        // delivers as soon as the system can dispatch it (~seconds).
        let request = UNNotificationRequest(
            identifier: "\(budgetAlertPrefix)\(budget.id.uuidString).\(level == .over ? "100" : "75")",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Clears the "has fired" flags for every budget. Useful when the
    /// user toggles off budget alerts in Settings and we want a clean
    /// slate if they re-enable.
    static func resetAllBudgetAlertFlags() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(budgetAlertPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Recurring Confirmations
    //
    // For RecurringRules with `confirmationRequired = true`, the engine
    // doesn't auto-create expenses. Instead it pre-schedules interactive
    // notifications that fire at each due date — the user taps "Log it"
    // or "Skip" right from the notification banner, no app open needed.

    /// Category identifier on every confirmation notification. Tying
    /// them all to this category lets us register the Log/Skip actions
    /// once at app launch and have iOS show them on every fire.
    static let confirmCategoryID = "tula.recurring.confirm"
    /// Action identifiers carried in `UNNotificationResponse.actionIdentifier`.
    static let confirmLogActionID = "tula.confirm.log"
    static let confirmSkipActionID = "tula.confirm.skip"
    /// Stable identifier prefix for confirmation notification requests.
    /// Format: `{prefix}{ruleUUID}-{dueDateEpoch}` — both pieces are
    /// recoverable from the request ID alone if userInfo is ever lost.
    private static let confirmRequestPrefix = "tula.confirm."

    /// Registers the iOS notification category that gives confirmation
    /// notifications their two action buttons. Call once at app launch.
    /// Idempotent — calling repeatedly just replaces the registration.
    static func registerCategories() {
        let logAction = UNNotificationAction(
            identifier: confirmLogActionID,
            title: "Log it",
            options: []   // background action — doesn't open app
        )
        let skipAction = UNNotificationAction(
            identifier: confirmSkipActionID,
            title: "Skip",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: confirmCategoryID,
            actions: [logAction, skipAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Schedules a single confirmation notification for the given rule at
    /// the given due date. Existing request with the same identifier is
    /// replaced — safe to call repeatedly across app launches.
    static func scheduleConfirmation(ruleID: UUID, ruleName: String,
                                       amount: Double, currencyCode: String,
                                       dueDate: Date) {
        let content = UNMutableNotificationContent()
        content.title = ruleName
        let amountStr = Currency.format(amount, code: currencyCode)
        content.body = "\(amountStr) · Did you have this?"
        content.sound = .default
        content.categoryIdentifier = confirmCategoryID
        content.userInfo = [
            "ruleID": ruleID.uuidString,
            "dueDate": dueDate.timeIntervalSince1970
        ]

        // Calendar trigger fires at the exact date+time. Using
        // dateComponents (not timeIntervalSince) lets the system
        // schedule reliably across reboots.
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: dueDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let id = identifier(for: ruleID, dueDate: dueDate)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Cancels all pending confirmation notifications for a given rule.
    /// Called when the rule is paused, deleted, or has its
    /// confirmationRequired flag turned off.
    static func cancelConfirmations(for ruleID: UUID) {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let prefix = "\(confirmRequestPrefix)\(ruleID.uuidString)"
            let idsToCancel = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            if !idsToCancel.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: idsToCancel)
            }
        }
    }

    /// Cancels every pending confirmation notification across all rules.
    /// Used when the user toggles off recurring notifications globally.
    static func cancelAllConfirmations() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(confirmRequestPrefix) }
            if !ids.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    /// Builds the stable per-occurrence identifier. The dueDate is
    /// floored to whole seconds so identical dates always produce
    /// identical IDs (iOS will dedupe re-adds).
    private static func identifier(for ruleID: UUID, dueDate: Date) -> String {
        "\(confirmRequestPrefix)\(ruleID.uuidString)-\(Int(dueDate.timeIntervalSince1970))"
    }
}
