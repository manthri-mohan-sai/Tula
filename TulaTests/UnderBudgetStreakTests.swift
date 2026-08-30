import Foundation
import Testing
@testable import Tula

/// Regression cover for the bug this work fixed: an unlogged day used to be
/// indistinguishable from a genuine zero-spend day, so `0 <= dailyBudget`
/// always held and the streak grew for every day the user was away. The only
/// number surfaced to the user therefore rewarded *not logging*.
///
/// `InsightEngine.underBudgetStreak` reads `Calendar.current` and `Date.now`
/// internally, so these cases build their dates the same way. The one
/// theoretical flake is a run that straddles local midnight.
@Suite("Under-budget streak")
struct UnderBudgetStreakTests {

    private let calendar = Calendar.current
    private let dailyBudget: Double = 500

    private func daysAgo(_ offset: Int) -> Date {
        let start = calendar.startOfDay(for: .now)
        let shifted = calendar.date(byAdding: .day, value: -offset, to: start) ?? start
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: shifted) ?? shifted
    }

    private func key(_ offset: Int) -> String {
        DayKey.string(from: daysAgo(offset), calendar: calendar)
    }

    // MARK: - The regression

    @Test("an unlogged day breaks the streak instead of extending it")
    func unloggedDayBreaksStreak() {
        // Today and yesterday under budget, the day before never logged,
        // then three more under-budget days. The streak must stop at the
        // hole rather than counting straight through it.
        let expenses = [
            Expense.fixture(on: daysAgo(0), amount: 100),
            Expense.fixture(on: daysAgo(1), amount: 100),
            Expense.fixture(on: daysAgo(3), amount: 100),
            Expense.fixture(on: daysAgo(4), amount: 100),
            Expense.fixture(on: daysAgo(5), amount: 100),
        ]

        let streak = InsightEngine.underBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget
        )

        #expect(streak == 2)
    }

    @Test("a long absence does not inflate the streak")
    func absenceDoesNotInflate() {
        // The exact shape of the reported problem: one expense a week ago and
        // nothing since. The old implementation counted every silent day.
        let expenses = [Expense.fixture(on: daysAgo(7), amount: 100)]

        let streak = InsightEngine.underBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget
        )

        #expect(streak <= 1)
    }

    // MARK: - Preserved behaviour

    @Test("consecutive under-budget days still count")
    func consecutiveUnderBudget() {
        let expenses = (0...3).map {
            Expense.fixture(on: daysAgo($0), amount: 100)
        }

        #expect(
            InsightEngine.underBudgetStreak(
                expenses: expenses, dailyBudget: dailyBudget
            ) == 4
        )
    }

    @Test("an over-budget day breaks the streak")
    func overBudgetBreaks() {
        let expenses = [
            Expense.fixture(on: daysAgo(0), amount: 100),
            Expense.fixture(on: daysAgo(1), amount: 100),
            Expense.fixture(on: daysAgo(2), amount: 9_000),
            Expense.fixture(on: daysAgo(3), amount: 100),
        ]

        #expect(
            InsightEngine.underBudgetStreak(
                expenses: expenses, dailyBudget: dailyBudget
            ) == 2
        )
    }

    @Test("returns zero when no daily budget is set")
    func noBudgetIsZero() {
        let expenses = [Expense.fixture(on: daysAgo(0), amount: 100)]

        #expect(
            InsightEngine.underBudgetStreak(
                expenses: expenses, dailyBudget: nil
            ) == 0
        )
    }

    // MARK: - No-spend markers

    @Test("an explicitly closed no-spend day extends the streak")
    func noSpendDayCounts() {
        // A day the user actively said was empty is a day we know about, so
        // it legitimately continues the streak — unlike a silent day.
        let expenses = [
            Expense.fixture(on: daysAgo(0), amount: 100),
            Expense.fixture(on: daysAgo(2), amount: 100),
            Expense.fixture(on: daysAgo(3), amount: 100),
        ]

        let without = InsightEngine.underBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget
        )
        #expect(without == 1)

        let with = InsightEngine.underBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget,
            noSpendDays: [key(1)]
        )
        #expect(with == 4)
    }
}
