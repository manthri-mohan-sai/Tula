import Foundation
import Testing
@testable import Tula

@Suite("CatchUpDetector")
struct CatchUpDetectorTests {

    private let calendar = TestCalendar.utc
    private let now = TestCalendar.day(2026, 8, 25)

    private func detect(
        expenses: [Expense],
        noSpendDays: Set<String> = [],
        rules: [RecurringRule] = [],
        overdue: [UUID: [Date]] = [:],
        notBefore: Date? = nil
    ) -> CatchUpState {
        CatchUpDetector.state(
            expenses: expenses,
            noSpendDays: noSpendDays,
            recurringRules: rules,
            overdueDates: overdue,
            notBefore: notBefore,
            now: now,
            calendar: calendar
        )
    }

    // MARK: - Window

    @Test("reports no gap when every day in the window is logged")
    func cleanRunIsClear() {
        let expenses = (0...7).map {
            Expense.fixture(on: TestCalendar.day(2026, 8, 25 - $0))
        }

        let state = detect(expenses: expenses)

        #expect(state.unloggedCount == 0)
        #expect(state.isClear)
    }

    @Test("finds a three-day gap")
    func findsGap() {
        // Logged the 25th (today) and the 21st; 22nd–24th are missing.
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 21)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 20)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 19)),
        ]

        let state = detect(expenses: expenses)

        #expect(state.unloggedCount == 3)
        #expect(state.headline == "3 days unlogged")
    }

    @Test("today is never reported as missed")
    func todayExcluded() {
        // Only yesterday logged; today deliberately empty. Today is still in
        // progress, so nagging about it is exactly the pressure this feature
        // is designed to avoid.
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 8, 24))]

        let state = detect(expenses: expenses)

        #expect(state.days.allSatisfy { $0.date < calendar.startOfDay(for: self.now) })
        #expect(!state.days.contains { calendar.isDate($0.date, inSameDayAs: self.now) })
    }

    @Test("window never begins before the user's first expense")
    func clampedToFirstExpense() {
        // A brand-new user whose only expense is yesterday must not be told
        // they missed the preceding week.
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 8, 24))]

        let state = detect(expenses: expenses)

        #expect(state.unloggedCount == 0)
        #expect(state.days.count == 1)
    }

    @Test("returns no days when the user has never logged anything")
    func noExpensesAtAll() {
        let state = detect(expenses: [])

        #expect(state.days.isEmpty)
        #expect(state.isClear)
    }

    @Test("lookback is capped at maxLookbackDays")
    func lookbackCapped() {
        // First expense 30 days ago, nothing since — only the capped window
        // is enumerated, the rest is counted as truncated.
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 7, 26))]

        let state = detect(expenses: expenses)

        #expect(state.days.count == CatchUpDetector.maxLookbackDays)
        #expect(state.truncatedOlderDays > 0)
    }

    // MARK: - No-spend markers

    @Test("an explicit no-spend day is not counted as missed")
    func noSpendResolvesDay() {
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 23)),
        ]

        let withoutMarker = detect(expenses: expenses)
        #expect(withoutMarker.unloggedCount == 1)

        let withMarker = detect(expenses: expenses, noSpendDays: ["2026-08-24"])
        #expect(withMarker.unloggedCount == 0)
    }

    @Test("a real expense overrides a stale no-spend marker")
    func expenseBeatsMarker() {
        // Derivation is one-directional: a leftover marker can never hide
        // data the user actually logged.
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 24), amount: 250)
        ]

        let state = detect(expenses: expenses, noSpendDays: ["2026-08-24"])

        let day = state.days.first { calendar.isDate($0.date, inSameDayAs: TestCalendar.day(2026, 8, 24)) }
        #expect(day?.status == .logged(count: 1, total: 250))
    }

    // MARK: - Horizon

    @Test("notBefore moves the floor without fabricating no-spend markers")
    func horizonClampsWindow() {
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 8, 1))]

        let unclamped = detect(expenses: expenses)
        #expect(unclamped.days.count == CatchUpDetector.maxLookbackDays)

        let clamped = detect(
            expenses: expenses, notBefore: TestCalendar.day(2026, 8, 23)
        )
        // 23rd and 24th only — today is excluded.
        #expect(clamped.days.count == 2)
        #expect(clamped.truncatedOlderDays == 0)
    }

    // MARK: - Recurring

    @Test("auto-generated rules are excluded from pending recurring")
    func autoGeneratedExcluded() {
        // RecurringEngine.generateMissing already materialises these at
        // launch; offering them again would create duplicate expenses.
        let rule = RecurringRule.fixture(confirmationRequired: false, isBill: false)
        let overdue = [rule.id: [TestCalendar.day(2026, 8, 23)]]

        let state = detect(
            expenses: [Expense.fixture(on: TestCalendar.day(2026, 8, 25))],
            rules: [rule], overdue: overdue
        )

        #expect(state.pendingRecurring.isEmpty)
    }

    @Test("confirmation-required rules are surfaced")
    func confirmationRequiredSurfaced() {
        let rule = RecurringRule.fixture(name: "Gym", confirmationRequired: true)
        let overdue = [rule.id: [TestCalendar.day(2026, 8, 23)]]

        let state = detect(
            expenses: [Expense.fixture(on: TestCalendar.day(2026, 8, 25))],
            rules: [rule], overdue: overdue
        )

        #expect(state.pendingRecurring.count == 1)
        #expect(state.pendingRecurring.first?.ruleName == "Gym")
    }

    @Test("paused rules are never surfaced")
    func pausedExcluded() {
        let rule = RecurringRule.fixture(confirmationRequired: true, isPaused: true)
        let overdue = [rule.id: [TestCalendar.day(2026, 8, 23)]]

        let state = detect(expenses: [], rules: [rule], overdue: overdue)

        #expect(state.pendingRecurring.isEmpty)
    }

    @Test("a bill already paid past the due date is not surfaced")
    func paidBillExcluded() {
        let rule = RecurringRule.fixture(name: "Electricity", isBill: true)
        rule.lastPaidDate = TestCalendar.day(2026, 8, 24)
        let overdue = [rule.id: [TestCalendar.day(2026, 8, 23)]]

        let state = detect(expenses: [], rules: [rule], overdue: overdue)

        #expect(state.pendingRecurring.isEmpty)
    }

    @Test("pending occurrences are sorted oldest first")
    func pendingSorted() {
        let rule = RecurringRule.fixture(confirmationRequired: true)
        let overdue = [rule.id: [
            TestCalendar.day(2026, 8, 24),
            TestCalendar.day(2026, 8, 22),
            TestCalendar.day(2026, 8, 23),
        ]]

        let state = detect(expenses: [], rules: [rule], overdue: overdue)
        let dates = state.pendingRecurring.map(\.dueDate)

        #expect(dates == dates.sorted())
    }

    // MARK: - Dismissal watermark

    @Test("newestUnloggedDate is the most recent missed day")
    func newestUnlogged() {
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 21)),
        ]

        let state = detect(expenses: expenses)

        #expect(
            state.newestUnloggedDate.map {
                calendar.isDate($0, inSameDayAs: TestCalendar.day(2026, 8, 24))
            } == true
        )
    }
}
