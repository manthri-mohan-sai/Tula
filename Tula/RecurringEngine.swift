import Foundation
import SwiftData

/// Generates missed transactions for active RecurringRules at app launch.
///
/// Each rule has a `frequency` (weekly/monthly/yearly):
/// - **weekly**: fires every 7 days starting from startDate
/// - **monthly**: fires on `dayOfMonth` each month (clamped for short months)
/// - **yearly**: fires on the same month + day as startDate every year
///
/// The engine walks forward from `lastGeneratedDate` (or startDate) and
/// creates a transaction for each missed occurrence up to today.
enum RecurringEngine {

    static func generateMissing(in context: ModelContext) {
        let descriptor = FetchDescriptor<RecurringRule>()
        guard let rules = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let calendar = Calendar.current
        var didGenerateAnything = false

        for rule in rules where !rule.isPaused {
            if let endDate = rule.endDate, now > endDate { continue }

            let startFrom = rule.lastGeneratedDate ?? rule.startDate
            var currentTarget = nextOccurrence(
                strictlyAfter: startFrom,
                rule: rule,
                calendar: calendar
            )

            while currentTarget <= now {
                if let endDate = rule.endDate, currentTarget > endDate { break }

                createTransaction(rule: rule, date: currentTarget, in: context)
                rule.lastGeneratedDate = currentTarget
                didGenerateAnything = true

                currentTarget = nextOccurrence(
                    strictlyAfter: currentTarget,
                    rule: rule,
                    calendar: calendar
                )
            }
        }

        if didGenerateAnything {
            try? context.save()
        }
    }

    /// Returns the next date strictly after `date` that the rule should fire.
    /// Dispatches to the per-frequency helpers below.
    private static func nextOccurrence(
        strictlyAfter date: Date,
        rule: RecurringRule,
        calendar: Calendar
    ) -> Date {
        switch rule.frequency {
        case .weekly:
            return nextWeekly(strictlyAfter: date, anchoredTo: rule.startDate, calendar: calendar)
        case .monthly:
            return nextMonthly(strictlyAfter: date, dayOfMonth: rule.dayOfMonth, calendar: calendar)
        case .yearly:
            return nextYearly(strictlyAfter: date, anchoredTo: rule.startDate, calendar: calendar)
        }
    }

    // MARK: - Per-frequency next-occurrence logic

    /// Weekly: anchored to startDate's weekday + time of day. Always adds 7 days.
    private static func nextWeekly(
        strictlyAfter date: Date,
        anchoredTo anchor: Date,
        calendar: Calendar
    ) -> Date {
        // If never fired yet, use startDate if it's in the future,
        // else compute the next occurrence based on the day-of-week.
        let weekday = calendar.component(.weekday, from: anchor)
        let hour = calendar.component(.hour, from: anchor)
        let minute = calendar.component(.minute, from: anchor)

        // Move forward 1 day at a time looking for the right weekday after `date`.
        var candidate = date
        for _ in 0..<8 {  // at most 7 iterations
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            if calendar.component(.weekday, from: candidate) == weekday {
                var components = calendar.dateComponents([.year, .month, .day], from: candidate)
                components.hour = hour
                components.minute = minute
                components.second = 0
                if let withTime = calendar.date(from: components), withTime > date {
                    return withTime
                }
            }
        }
        return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
    }

    /// Monthly: fires on `dayOfMonth` (clamped for Feb / 30-day months).
    private static func nextMonthly(
        strictlyAfter date: Date,
        dayOfMonth: Int,
        calendar: Calendar
    ) -> Date {
        // Try this month at dayOfMonth (clamped to month length).
        var components = calendar.dateComponents([.year, .month], from: date)
        components.hour = 9
        components.minute = 0
        components.second = 0

        if let monthStart = calendar.date(from: components),
           let range = calendar.range(of: .day, in: .month, for: monthStart) {
            let clampedDay = min(dayOfMonth, range.count)
            components.day = clampedDay
            if let candidate = calendar.date(from: components), candidate > date {
                return candidate
            }
        }

        // Otherwise, next month at dayOfMonth (clamped).
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: date) ?? date
        var nextComponents = calendar.dateComponents([.year, .month], from: nextMonth)
        nextComponents.hour = 9
        nextComponents.minute = 0
        nextComponents.second = 0
        if let nextMonthStart = calendar.date(from: nextComponents),
           let range = calendar.range(of: .day, in: .month, for: nextMonthStart) {
            nextComponents.day = min(dayOfMonth, range.count)
            return calendar.date(from: nextComponents) ?? nextMonth
        }
        return nextMonth
    }

    /// Yearly: fires on the same month + day as the anchor (start date),
    /// every year. Falls back to clamped end-of-month for Feb 29 anchors.
    private static func nextYearly(
        strictlyAfter date: Date,
        anchoredTo anchor: Date,
        calendar: Calendar
    ) -> Date {
        let anchorComponents = calendar.dateComponents([.month, .day, .hour, .minute], from: anchor)
        var components = calendar.dateComponents([.year], from: date)
        components.month = anchorComponents.month
        components.day = anchorComponents.day
        components.hour = anchorComponents.hour ?? 9
        components.minute = anchorComponents.minute ?? 0
        components.second = 0

        // Try this year first.
        if let candidate = calendar.date(from: components), candidate > date {
            return candidate
        }

        // Otherwise, next year.
        if let year = components.year {
            components.year = year + 1
            if let candidate = calendar.date(from: components) {
                return candidate
            }
        }
        return calendar.date(byAdding: .year, value: 1, to: date) ?? date
    }

    // MARK: - Transaction creation

    private static func createTransaction(rule: RecurringRule, date: Date, in context: ModelContext) {
        switch rule.kind {
        case .expense:
            let expense = Expense(
                amount: rule.amount,
                date: date,
                merchant: rule.name,
                note: rule.note,
                source: .recurring,
                category: rule.category,
                account: rule.account
            )
            expense.recurringRule = rule
            context.insert(expense)

        case .transfer, .cardPayment:
            let transferKind: TransferKind = (rule.kind == .cardPayment) ? .cardBillPayment : .generic
            let transfer = Transfer(
                amount: rule.amount,
                fromAccount: rule.fromAccount,
                toAccount: rule.toAccount,
                date: date,
                kind: transferKind,
                note: rule.note
            )
            transfer.recurringRule = rule
            context.insert(transfer)
        }
    }

    // MARK: - Public helpers

    /// Computes the next upcoming due date for a rule. Used by the UI to
    /// display "Next: 5 Jun".
    static func nextDueDate(for rule: RecurringRule) -> Date? {
        if rule.isPaused { return nil }
        if let endDate = rule.endDate, endDate < .now { return nil }
        let calendar = Calendar.current
        let from = rule.lastGeneratedDate ?? rule.startDate
        let next = nextOccurrence(strictlyAfter: from, rule: rule, calendar: calendar)
        if let endDate = rule.endDate, next > endDate { return nil }
        return next
    }
}
