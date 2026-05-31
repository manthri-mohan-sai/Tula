import Foundation
import UserNotifications
import SwiftData

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
    ///
    /// Uses a **non-repeating** trigger so the notification body can be
    /// dynamic (today's spend summary vs "no spends logged" nudge).
    /// The app re-schedules this every foreground via `refreshDailyReminder`.
    static func scheduleDailyReminder(at hour: Int, minute: Int, context: ModelContext? = nil) {
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.sound = .default

        // Build dynamic body from today's expenses (if context available).
        if let context = context {
            let (title, body) = dailyReminderContent(using: context)
            content.title = title
            content.body = body
        } else {
            content.title = "Time to log your day"
            content.body = "Tap to capture today's expenses in Tula."
        }

        // Schedule for the next occurrence of hour:minute. Repeats daily
        // so the notification fires even if the user doesn't open the app.
        // Content is refreshed with up-to-date spend data every foreground.
        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Re-schedules the daily reminder with fresh, dynamic content based
    /// on today's spending. Call on every foreground so the notification
    /// body stays up-to-date even if the user logged expenses after the
    /// initial schedule.
    static func refreshDailyReminder(using context: ModelContext) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "reminderEnabled") else { return }
        let hour = defaults.integer(forKey: "reminderHour")
        let minute = defaults.integer(forKey: "reminderMinute")
        // If hour is 0 and minute is 0, check if this is intentional
        // (midnight) vs never-set. AppStorage defaults reminderHour=21,
        // but standard UserDefaults returns 0 for missing keys.
        // Use a sentinel: if both are 0 and reminderEnabled is true,
        // treat as 21:00 (the AppStorage default).
        let effectiveHour = (hour == 0 && minute == 0 && !defaults.bool(forKey: "reminderHourExplicitlySet")) ? 21 : hour
        scheduleDailyReminder(at: effectiveHour, minute: minute, context: context)
    }

    /// Builds dynamic title + body for the daily reminder based on
    /// whether the user has logged any expenses today.
    private static func dailyReminderContent(using context: ModelContext) -> (title: String, body: String) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)

        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= dayStart }
        )
        let todayExpenses = (try? context.fetch(descriptor)) ?? []

        if todayExpenses.isEmpty {
            // No spends logged — nudge
            let titles = [
                "No spends logged today",
                "Quiet day?",
                "Nothing logged yet"
            ]
            let bodies = [
                "Did you miss any expenses? Tap to log them now.",
                "If you spent anything today, take a moment to log it.",
                "Even a coffee counts — tap to capture today's spending."
            ]
            let idx = calendar.component(.day, from: .now) % titles.count
            return (titles[idx], bodies[idx])
        } else {
            // Has spends — give summary
            let total = todayExpenses.reduce(0.0) { $0 + $1.amount }
            let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
            let formatted = Currency.format(total, code: code)
            let count = todayExpenses.count

            let title = "Today's spending: \(formatted)"
            let body = "\(count) expense\(count == 1 ? "" : "s") logged. Missed any? Tap to add more."
            return (title, body)
        }
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
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                // Surface the failure to the diagnostic log so the user
                // can see what iOS rejected. Common failure modes:
                //   • Authorization revoked since launch
                //   • Trigger date is in the past (caller should have
                //     filtered, but defensive)
                //   • Quota exceeded (>64 pending notifications app-wide)
                NotificationDiagnostics.recordScheduleFailure(
                    ruleID: ruleID,
                    dueDate: dueDate,
                    error: error
                )
            } else {
                NotificationDiagnostics.recordScheduleSuccess(
                    ruleID: ruleID,
                    dueDate: dueDate
                )
            }
        }
    }

    /// Lightweight diagnostic counter so the user can see whether
    /// scheduling is actually attempting to register notifications.
    /// Counts successes and failures since app launch; the diagnostics
    /// Settings section reads these to surface "scheduled N, failed M"
    /// stats to help isolate "the engine isn't running" from "iOS
    /// rejected our requests" failure modes.
    enum NotificationDiagnostics {
        static var scheduleSuccessCount: Int = 0
        static var scheduleFailureCount: Int = 0
        static var lastError: String? = nil
        static var lastScheduledRuleID: UUID? = nil
        static var lastScheduledDate: Date? = nil

        /// Counts of action-button taps observed by the app. Persisted
        /// in-memory only — survives nothing — but useful for "did the
        /// last tap reach my code" during diagnostic sessions where
        /// you're trying a notification, tapping a button, then
        /// returning to Settings to verify the path executed.
        static var logTapCount: Int = 0
        static var skipTapCount: Int = 0
        static var bodyTapCount: Int = 0
        /// Timestamp of the most recent action tap; surfaced in
        /// diagnostics as "Last action: Log · 2:14 PM".
        static var lastActionAt: Date? = nil
        static var lastActionLabel: String? = nil

        enum Action: String {
            case log = "Log"
            case skip = "Skip"
            case body = "Body"
        }

        static func recordScheduleSuccess(ruleID: UUID, dueDate: Date) {
            scheduleSuccessCount += 1
            lastScheduledRuleID = ruleID
            lastScheduledDate = dueDate
        }

        static func recordScheduleFailure(ruleID: UUID, dueDate: Date, error: Error) {
            scheduleFailureCount += 1
            lastError = "\(error.localizedDescription) (rule \(ruleID.uuidString.prefix(8)), due \(dueDate.formatted(.dateTime.day().month().hour().minute())))"
        }

        /// Records that the user tapped an action button on a delivered
        /// notification. If you tap Log and the diagnostics doesn't
        /// increment, the action handler never ran — i.e. iOS dropped
        /// the action route, or the action identifier isn't matching
        /// what we registered in the category.
        static func recordActionTapped(_ action: Action, ruleID: UUID) {
            switch action {
            case .log:  logTapCount += 1
            case .skip: skipTapCount += 1
            case .body: bodyTapCount += 1
            }
            lastActionAt = Date.now
            lastActionLabel = action.rawValue
        }
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

    /// Cancels a single pending confirmation notification for a specific
    /// rule occurrence. Used when the user logs or skips that occurrence
    /// from inside the app — without this, the queued notification would
    /// still fire later and ask the user to act on it again, even though
    /// they've already resolved it.
    static func cancelConfirmation(ruleID: UUID, dueDate: Date) {
        let id = identifier(for: ruleID, dueDate: dueDate)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id])
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
