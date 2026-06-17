import Foundation
import UIKit
import UserNotifications
import SwiftData

/// Schedules notifications: a daily reminder to log expenses, and
/// threshold alerts for budgets (75% / 100%).
///
/// All notifications use stable identifier prefixes so re-scheduling
/// overwrites cleanly without piling up duplicate pending requests.
enum NotificationManager {

    private static let reminderID = "tula.daily.reminder"
    private static let summaryID = "tula.daily.summary"
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

    // MARK: - Log Reminder

    static func scheduleLogReminder(at hour: Int, minute: Int) {
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Time to log your day"
        content.body = "Tap to capture today's expenses in Tula."

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Daily Summary

    static func scheduleDailySummary(at hour: Int, minute: Int, context: ModelContext? = nil) {
        cancelDailySummary()

        let content = UNMutableNotificationContent()
        content.sound = .default

        if let context {
            let (title, body) = dailySummaryContent(using: context)
            content.title = title
            content.body = body
        } else {
            content.title = "Your daily spending summary"
            content.body = "Tap to see how your day went."
        }

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: summaryID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Legacy compat

    static func scheduleDailyReminder(at hour: Int, minute: Int, context: ModelContext? = nil) {
        scheduleLogReminder(at: hour, minute: minute)
    }

    static func refreshDailyReminder(using context: ModelContext) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "reminderEnabled") {
            let hour = defaults.integer(forKey: "reminderHour")
            let minute = defaults.integer(forKey: "reminderMinute")
            let effectiveHour = (hour == 0 && minute == 0 && !defaults.bool(forKey: "reminderHourExplicitlySet")) ? 21 : hour
            scheduleLogReminder(at: effectiveHour, minute: minute)
        }
        if defaults.bool(forKey: "summaryEnabled") {
            let hour = defaults.integer(forKey: "summaryHour")
            let minute = defaults.integer(forKey: "summaryMinute")
            let effectiveHour = (hour == 0 && minute == 0) ? 21 : hour
            scheduleDailySummary(at: effectiveHour, minute: minute, context: context)
        }
        // Monthly summary auto-schedules when daily summary is enabled
        if defaults.bool(forKey: "summaryEnabled") {
            scheduleMonthlySummary(context: context)
        } else {
            cancelMonthlySummary()
        }
    }

    private static func dailySummaryContent(using context: ModelContext) -> (title: String, body: String) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: .now)
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"

        let todayDescriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= dayStart }
        )
        let todayExpenses = (try? context.fetch(todayDescriptor)) ?? []

        if todayExpenses.isEmpty {
            return emptyDayContent(calendar: calendar, context: context, code: code)
        } else {
            return spendDayContent(todayExpenses, calendar: calendar, context: context, code: code)
        }
    }

    private static func emptyDayContent(calendar: Calendar, context: ModelContext, code: String) -> (String, String) {
        let weekday = calendar.component(.weekday, from: .now)
        let day = calendar.component(.day, from: .now)
        let isWeekend = weekday == 1 || weekday == 7

        let recentAvg = recentDailyAverage(calendar: calendar, context: context)
        // Gentle nudge — no streak pressure. The under-budget streak
        // lives in the app UI, not in push notifications.

        if isWeekend {
            let nudges = [
                ("Weekend spending?", "Brunch, outings, groceries — weekends add up. Tap to log anything you spent."),
                ("Enjoy your weekend!", "If you grabbed coffee or ordered in, take a sec to log it.")
            ]
            return nudges[day % nudges.count]
        }

        if let avg = recentAvg, avg > 0 {
            let formatted = Currency.format(avg, code: code)
            return (
                "Nothing logged yet",
                "You usually spend about \(formatted)/day. Did today really cost zero?"
            )
        }

        let fallbacks = [
            ("No spends today?", "Even a chai counts. Tap to capture anything you spent."),
            ("Quiet day so far", "If you spent anything, take a moment to log it before you forget."),
            ("Nothing logged yet", "The best time to log is right after you spend. Tap to add.")
        ]
        return fallbacks[day % fallbacks.count]
    }

    private static func spendDayContent(_ expenses: [Expense], calendar: Calendar, context: ModelContext, code: String) -> (String, String) {
        let total = expenses.reduce(0.0) { $0 + $1.amount }
        let formatted = Currency.format(total, code: code)
        let count = expenses.count
        let day = calendar.component(.day, from: .now)

        let topCategory = Dictionary(grouping: expenses) { $0.category?.name ?? "Other" }
            .max(by: { $0.value.reduce(0) { $0 + $1.amount } < $1.value.reduce(0) { $0 + $1.amount } })

        let recentAvg = recentDailyAverage(calendar: calendar, context: context)

        var insights: [(String, String)] = []

        if let topCat = topCategory, topCat.value.count > 1 {
            let catTotal = Currency.format(topCat.value.reduce(0) { $0 + $1.amount }, code: code)
            insights.append((
                "Today: \(formatted)",
                "\(topCat.key) led the day at \(catTotal). \(count) expense\(count == 1 ? "" : "s") total."
            ))
        }

        if let avg = recentAvg, avg > 0 {
            let ratio = total / avg
            if ratio > 1.5 {
                insights.append((
                    "Spent \(formatted) today",
                    "That's higher than your usual \(Currency.format(avg, code: code))/day. Anything else to add?"
                ))
            } else if ratio < 0.5 {
                insights.append((
                    "Light day: \(formatted)",
                    "Well under your average of \(Currency.format(avg, code: code))/day. Nice!"
                ))
            }
        }

        if let merchant = expenses.first?.merchant, count == 1 {
            insights.append((
                "\(formatted) at \(merchant)",
                "Just one expense today. Missed anything else?"
            ))
        }

        insights.append((
            "Today's spending: \(formatted)",
            "\(count) expense\(count == 1 ? "" : "s") logged. Missed any? Tap to add more."
        ))

        return insights[day % insights.count]
    }

    private static func recentDailyAverage(calendar: Calendar, context: ModelContext) -> Double? {
        guard let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)) else { return nil }
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= weekAgo }
        )
        let expenses = (try? context.fetch(descriptor)) ?? []
        guard !expenses.isEmpty else { return nil }
        let total = expenses.reduce(0.0) { $0 + $1.amount }
        return total / 7.0
    }

    private static func loggingStreak(calendar: Calendar, context: ModelContext) -> Int {
        var streak = 0
        var checkDate = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        for _ in 0..<30 {
            let dayStart = calendar.startOfDay(for: checkDate)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let descriptor = FetchDescriptor<Expense>(
                predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
            )
            let count = (try? context.fetchCount(descriptor)) ?? 0
            if count > 0 {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        return streak
    }

    static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID])
    }

    static func cancelDailySummary() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [summaryID])
    }

    static func cancel() { cancelDailyReminder(); cancelDailySummary(); cancelMonthlySummary() }

    // MARK: - Monthly Summary

    private static let monthlySummaryID = "tula.monthly.summary"

    /// Schedules a notification on the last day of each month at 9 PM
    /// with a spending wrap-up: total spent, top category, and comparison
    /// with the previous month.
    static func scheduleMonthlySummary(context: ModelContext) {
        cancelMonthlySummary()

        let calendar = Calendar.current
        let now = Date.now
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"

        // Build content from this month's data
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= monthStart }
        )
        let thisMonthExpenses = (try? context.fetch(descriptor)) ?? []
        let thisTotal = thisMonthExpenses.reduce(0.0) { $0 + $1.amount }

        // Previous month total for comparison
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)!
        let prevDescriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= prevMonthStart && $0.date < monthStart }
        )
        let prevMonthExpenses = (try? context.fetch(prevDescriptor)) ?? []
        let prevTotal = prevMonthExpenses.reduce(0.0) { $0 + $1.amount }

        let content = UNMutableNotificationContent()
        content.sound = .default

        let totalStr = Currency.format(thisTotal, code: code)
        let monthName = now.formatted(.dateTime.month(.wide))

        if thisTotal > 0 {
            content.title = "\(monthName) Wrap-up: \(totalStr)"

            // Top category
            let topCat = Dictionary(grouping: thisMonthExpenses) { $0.category?.name ?? "Other" }
                .max(by: { $0.value.reduce(0) { $0 + $1.amount } < $1.value.reduce(0) { $0 + $1.amount } })

            var body = "\(thisMonthExpenses.count) expense\(thisMonthExpenses.count == 1 ? "" : "s") logged."
            if let top = topCat {
                let catTotal = Currency.format(top.value.reduce(0) { $0 + $1.amount }, code: code)
                body += " Top: \(top.key) (\(catTotal))."
            }
            if prevTotal > 0 {
                let diff = thisTotal - prevTotal
                let pct = Int((abs(diff) / prevTotal * 100).rounded())
                body += diff > 0 ? " Up \(pct)% from last month." : " Down \(pct)% from last month."
            }
            content.body = body
        } else {
            content.title = "\(monthName) Summary"
            content.body = "No expenses logged this month. Tap to catch up."
        }

        // Fire on the last day of the current month at 21:00
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: nextMonth) else { return }

        var comps = calendar.dateComponents([.year, .month, .day], from: lastDay)
        comps.hour = 21
        comps.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: monthlySummaryID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    static func cancelMonthlySummary() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [monthlySummaryID])
    }

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
    /// Category for bill reminder notifications with "Pay Now" action.
    static let billCategoryID = "tula.bill.reminder"
    static let billPayActionID = "tula.bill.pay"
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
        let confirmCategory = UNNotificationCategory(
            identifier: confirmCategoryID,
            actions: [logAction, skipAction],
            intentIdentifiers: [],
            options: []
        )

        // Bill reminder category with "Pay Now" action
        let payAction = UNNotificationAction(
            identifier: billPayActionID,
            title: "Pay Now",
            options: [.foreground]  // opens app to complete payment
        )
        let billCategory = UNNotificationCategory(
            identifier: billCategoryID,
            actions: [payAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([confirmCategory, billCategory])
    }

    /// Schedules a single confirmation notification for the given rule at
    /// the given due date. Existing request with the same identifier is
    /// replaced — safe to call repeatedly across app launches.
    static func scheduleConfirmation(ruleID: UUID, ruleName: String,
                                       amount: Double, currencyCode: String,
                                       dueDate: Date, isBill: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = ruleName
        let amountStr = Currency.format(amount, code: currencyCode)
        content.body = isBill
            ? "\(amountStr) · Due — tap to log payment"
            : "\(amountStr) · Did you have this?"
        content.sound = .default
        content.categoryIdentifier = confirmCategoryID

        content.userInfo = [
            "ruleID": ruleID.uuidString,
            "ruleName": ruleName,
            "amount": amount,
            "currencyCode": currencyCode,
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
