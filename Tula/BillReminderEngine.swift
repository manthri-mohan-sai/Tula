import Foundation
import SwiftData
import UserNotifications

/// Schedules advance-warning notifications for bill-type recurring rules.
/// Bills get reminders at `reminderDaysBefore`, 1 day before, and on the
/// due date itself. Overdue bills get an additional nudge.
enum BillReminderEngine {

    private static let billPrefix = "tula.bill."

    // MARK: - Due date computation

    /// The effective due day for a bill rule. Falls back to `dayOfMonth`
    /// if `dueDayOfMonth` is 0 (unset).
    static func effectiveDueDay(for rule: RecurringRule) -> Int {
        rule.dueDayOfMonth > 0 ? rule.dueDayOfMonth : rule.dayOfMonth
    }

    /// Next due date for this bill in the current or next month.
    /// Returns the upcoming due date that hasn't been paid yet.
    static func nextBillDueDate(for rule: RecurringRule, now: Date = .now) -> Date? {
        guard rule.isBill, !rule.isPaused else { return nil }
        let calendar = Calendar.current
        let dueDay = effectiveDueDay(for: rule)

        // This month's due date
        var comps = calendar.dateComponents([.year, .month], from: now)
        comps.day = min(dueDay, calendar.range(of: .day, in: .month, for: now)?.count ?? 28)
        guard let thisMonthDue = calendar.date(from: comps) else { return nil }

        // If already paid this period, return next month's due
        if let lastPaid = rule.lastPaidDate,
           calendar.isDate(lastPaid, equalTo: thisMonthDue, toGranularity: .month) {
            // Paid this month — next due is next month
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonthDue) else { return nil }
            var nextComps = calendar.dateComponents([.year, .month], from: nextMonth)
            nextComps.day = min(dueDay, calendar.range(of: .day, in: .month, for: nextMonth)?.count ?? 28)
            return calendar.date(from: nextComps)
        }

        // If this month's due is in the past and unpaid, return it (overdue)
        // If in the future, return it (upcoming)
        return thisMonthDue
    }

    /// Days until the next bill due date. Negative means overdue.
    static func daysUntilDue(for rule: RecurringRule, now: Date = .now) -> Int? {
        guard let dueDate = nextBillDueDate(for: rule, now: now) else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: dueDate)).day
    }

    /// Whether this bill is overdue (past due date, not yet paid).
    static func isOverdue(for rule: RecurringRule, now: Date = .now) -> Bool {
        guard let days = daysUntilDue(for: rule, now: now) else { return false }
        return days < 0
    }

    /// Human-readable countdown string for a bill.
    static func countdownLabel(for rule: RecurringRule, now: Date = .now) -> String {
        guard let days = daysUntilDue(for: rule, now: now) else { return "" }
        if days < -1 { return "Overdue by \(abs(days)) days" }
        if days == -1 { return "Overdue by 1 day" }
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        return "Due in \(days) days"
    }

    /// Color for the countdown badge.
    static func countdownColor(for rule: RecurringRule, now: Date = .now) -> CountdownUrgency {
        guard let days = daysUntilDue(for: rule, now: now) else { return .normal }
        if days < 0 { return .overdue }
        if days <= 1 { return .urgent }
        if days <= 3 { return .warning }
        return .normal
    }

    enum CountdownUrgency {
        case normal   // green — >3 days
        case warning  // amber — 1-3 days
        case urgent   // red — due today/tomorrow
        case overdue  // red — past due
    }

    // MARK: - Notification scheduling

    /// Schedule bill reminder notifications for all active bill rules.
    /// Called on app launch and whenever bill rules change.
    static func scheduleBillReminders(rules: [RecurringRule]) {
        // Cancel all existing bill notifications first
        cancelAllBillNotifications()

        let calendar = Calendar.current
        let now = Date.now
        let currencyCode = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"

        for rule in rules where rule.isBill && !rule.isPaused {
            guard let dueDate = nextBillDueDate(for: rule, now: now) else { continue }
            let dueStart = calendar.startOfDay(for: dueDate)

            // Schedule reminders: N days before, 1 day before, and on due day
            let reminderOffsets: [Int] = {
                var offsets = [0, 1]  // Due day and 1 day before
                if rule.reminderDaysBefore > 1 {
                    offsets.append(rule.reminderDaysBefore)
                }
                return Array(Set(offsets)).sorted(by: >)  // Deduplicate and sort
            }()

            for offset in reminderOffsets {
                guard let reminderDate = calendar.date(byAdding: .day, value: -offset, to: dueStart) else { continue }
                // Don't schedule past notifications
                guard reminderDate > now else { continue }

                let content = UNMutableNotificationContent()
                content.sound = .default
                content.categoryIdentifier = NotificationManager.billCategoryID

                let amountStr = Currency.format(rule.amount, code: currencyCode)

                if offset == 0 {
                    content.title = "\(rule.name) is due today"
                    content.body = "\(amountStr) · Tap to mark as paid."
                } else if offset == 1 {
                    content.title = "\(rule.name) due tomorrow"
                    content.body = "\(amountStr) · Don't forget to pay."
                } else {
                    content.title = "\(rule.name) due in \(offset) days"
                    content.body = "\(amountStr) · Heads up on your upcoming bill."
                }

                content.userInfo = [
                    "ruleID": rule.id.uuidString,
                    "type": "bill"
                ]

                // Schedule at 9 AM on the reminder day
                var comps = calendar.dateComponents([.year, .month, .day], from: reminderDate)
                comps.hour = 9
                comps.minute = 0

                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                let id = "\(billPrefix)\(rule.id.uuidString)-\(offset)"
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request) { _ in }
            }
        }
    }

    /// Cancel all pending bill notification requests.
    static func cancelAllBillNotifications() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.filter { $0.identifier.hasPrefix(billPrefix) }.map(\.identifier)
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    /// Mark a bill as paid: create an expense and update lastPaidDate.
    @MainActor
    static func markAsPaid(rule: RecurringRule, in context: ModelContext) {
        let expense = Expense(
            amount: rule.amount,
            merchant: rule.merchant ?? rule.name,
            note: rule.note,
            source: .recurring,
            category: rule.category,
            account: rule.account
        )
        context.insert(expense)
        rule.lastPaidDate = Date.now

        // Also advance lastGeneratedDate so the recurring engine doesn't
        // double-generate for this period.
        if let dueDate = nextBillDueDate(for: rule) {
            if rule.lastGeneratedDate == nil || rule.lastGeneratedDate! < dueDate {
                rule.lastGeneratedDate = dueDate
            }
        }

        context.safeSave()
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
    }
}
