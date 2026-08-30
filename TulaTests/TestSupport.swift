import Foundation
@testable import Tula

/// Deterministic calendar for day-boundary logic.
///
/// Fixed to UTC so the suites cannot pass on the author's machine and fail in
/// CI (or in a different half of the year) purely because of the host time
/// zone. Every production type under test takes an injectable `calendar` and
/// `now` for exactly this reason.
enum TestCalendar {

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// A point inside the given day. Defaults to midday so the value is never
    /// sitting on a boundary that a DST rule could move.
    static func day(
        _ year: Int, _ month: Int, _ dayOfMonth: Int,
        hour: Int = 12,
        calendar: Calendar = TestCalendar.utc
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = hour
        return calendar.date(from: components) ?? .distantPast
    }
}

extension Expense {
    /// Minimal expense fixture — only `date` and `amount` are read by the
    /// types these suites cover.
    static func fixture(on date: Date, amount: Double = 100) -> Expense {
        Expense(amount: amount, date: date)
    }
}

extension RecurringRule {
    static func fixture(
        name: String = "Rent",
        amount: Double = 1000,
        confirmationRequired: Bool = false,
        isBill: Bool = false,
        isPaused: Bool = false
    ) -> RecurringRule {
        let rule = RecurringRule(
            name: name, amount: amount, kind: .expense, dayOfMonth: 1
        )
        rule.confirmationRequired = confirmationRequired
        rule.isBill = isBill
        rule.isPaused = isPaused
        return rule
    }
}
