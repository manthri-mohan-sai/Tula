import Foundation
import SwiftData

/// Generates missed transactions for active RecurringRules.
/// Called on app launch from TulaApp. For each rule, walks forward from
/// the last-generated date (or rule's start date) and creates an Expense
/// or Transfer for each missed monthly occurrence up to today.
enum RecurringEngine {

    static func generateMissing(in context: ModelContext) {
        let descriptor = FetchDescriptor<RecurringRule>()
        guard let rules = try? context.fetch(descriptor) else { return }

        let now = Date.now
        let calendar = Calendar.current
        var didGenerateAnything = false

        for rule in rules where !rule.isPaused {
            // Skip rules whose end date has passed
            if let endDate = rule.endDate, now > endDate { continue }

            // Start walking from the last-generated date if any, else
            // from the rule's startDate. We find the next occurrence after
            // this point that matches the rule's dayOfMonth.
            let startFrom = rule.lastGeneratedDate ?? rule.startDate
            var currentTarget = nextOccurrence(
                strictlyAfter: startFrom,
                dayOfMonth: rule.dayOfMonth,
                calendar: calendar
            )

            // Generate every missed occurrence up to today.
            while currentTarget <= now {
                if let endDate = rule.endDate, currentTarget > endDate { break }

                createTransaction(rule: rule, date: currentTarget, in: context)
                rule.lastGeneratedDate = currentTarget
                didGenerateAnything = true

                currentTarget = nextOccurrence(
                    strictlyAfter: currentTarget,
                    dayOfMonth: rule.dayOfMonth,
                    calendar: calendar
                )
            }
        }

        if didGenerateAnything {
            try? context.save()
        }
    }

    /// Computes the next date strictly after `date` that falls on `dayOfMonth`.
    /// Handles month-length overflow (Feb 30 clamps to Feb 28/29).
    private static func nextOccurrence(
        strictlyAfter date: Date,
        dayOfMonth: Int,
        calendar: Calendar
    ) -> Date {
        // First, try this month at dayOfMonth (clamped).
        var components = calendar.dateComponents([.year, .month], from: date)
        components.hour = 9     // morning, arbitrary but stable
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

        // Otherwise, move to next month and clamp.
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

    /// Computes the next upcoming due date for a rule. Used by the UI to
    /// show "Next: 5 Jun".
    static func nextDueDate(for rule: RecurringRule) -> Date? {
        if rule.isPaused { return nil }
        if let endDate = rule.endDate, endDate < .now { return nil }
        let calendar = Calendar.current
        let from = rule.lastGeneratedDate ?? rule.startDate
        let next = nextOccurrence(strictlyAfter: from, dayOfMonth: rule.dayOfMonth, calendar: calendar)
        if let endDate = rule.endDate, next > endDate { return nil }
        return next
    }
}
