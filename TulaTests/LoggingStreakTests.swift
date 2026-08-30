import Foundation
import Testing
@testable import Tula

@Suite("LoggingStreak")
struct LoggingStreakTests {

    private let calendar = TestCalendar.utc
    /// Fixed "today" for every case in this suite.
    private let now = TestCalendar.day(2026, 8, 25)

    // MARK: - The regression this type exists to fix

    @Test("counts today, unlike the old NotificationManager implementation")
    func todayCounts() {
        // The replaced `NotificationManager.loggingStreak` started its walk at
        // `-1 day`, so a user who had logged today still saw a streak of zero
        // for their first day. Today must count.
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 8, 25))]

        let streak = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )

        #expect(streak == 1)
    }

    // MARK: - Basic derivation

    @Test("returns zero when nothing has ever been logged")
    func emptyIsZero() {
        #expect(
            LoggingStreak.current(
                expenses: [], noSpendDays: [], now: now, calendar: calendar
            ) == 0
        )
    }

    @Test("counts consecutive logged days ending today")
    func consecutiveDays() {
        let expenses = (0...4).map {
            Expense.fixture(on: TestCalendar.day(2026, 8, 25 - $0))
        }

        let streak = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )

        #expect(streak == 5)
    }

    @Test("multiple expenses on one day count as a single day")
    func multipleSameDay() {
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25, hour: 9)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 25, hour: 14)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 25, hour: 21)),
        ]

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: [], now: now, calendar: calendar
            ) == 1
        )
    }

    @Test("a gap terminates the streak")
    func gapTerminates() {
        // 25th and 24th logged, 23rd missing, 22nd logged — the 22nd must not
        // be reachable through the hole.
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 24)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 22)),
        ]

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: [], now: now, calendar: calendar
            ) == 2
        )
    }

    @Test("an unlogged today does not break the streak")
    func unloggedTodayDoesNotBreak() {
        // Today is still in progress. Opening the app before the day's first
        // spend must not read "0-day streak" after a run of daily logging —
        // that is the arbitrary-feeling number this type exists to replace.
        let expenses = (1...4).map {
            Expense.fixture(on: TestCalendar.day(2026, 8, 25 - $0))
        }

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: [], now: now, calendar: calendar
            ) == 4
        )
    }

    @Test("closing today extends the streak by one")
    func closingTodayExtends() {
        var expenses = (1...4).map {
            Expense.fixture(on: TestCalendar.day(2026, 8, 25 - $0))
        }
        let before = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )

        expenses.append(Expense.fixture(on: TestCalendar.day(2026, 8, 25)))
        let after = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )

        #expect(before == 4)
        #expect(after == 5)
    }

    @Test("a gap ending yesterday still yields zero")
    func yesterdayGapIsZero() {
        // Today unlogged is forgiven; yesterday unlogged is a real miss.
        let expenses = [Expense.fixture(on: TestCalendar.day(2026, 8, 23))]

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: [], now: now, calendar: calendar
            ) == 0
        )
    }

    // MARK: - No-spend days

    @Test("an explicit no-spend day bridges the streak")
    func noSpendBridges() {
        let expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 23)),
        ]
        let noSpend: Set<String> = ["2026-08-24"]

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: noSpend,
                now: now, calendar: calendar
            ) == 3
        )
    }

    @Test("a no-spend day alone closes the day")
    func noSpendOnlyDay() {
        #expect(
            LoggingStreak.current(
                expenses: [], noSpendDays: ["2026-08-25"],
                now: now, calendar: calendar
            ) == 1
        )
    }

    // MARK: - Repair

    @Test("backfilling a gap day restores the full streak")
    func backfillRepairs() {
        // The mechanic the whole catch-up flow depends on: repair is a
        // consequence of deriving the streak from expense dates, with no
        // separate repair state to keep in sync.
        var expenses = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 24)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 22)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 21)),
        ]

        let before = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )
        #expect(before == 2)

        expenses.append(Expense.fixture(on: TestCalendar.day(2026, 8, 23)))

        let after = LoggingStreak.current(
            expenses: expenses, noSpendDays: [], now: now, calendar: calendar
        )
        #expect(after == 5)
    }

    // MARK: - Ordering independence

    @Test("result does not depend on the caller's sort order")
    func orderIndependent() {
        let ascending = [
            Expense.fixture(on: TestCalendar.day(2026, 8, 23)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 24)),
            Expense.fixture(on: TestCalendar.day(2026, 8, 25)),
        ]
        let descending: [Expense] = ascending.reversed()

        let a = LoggingStreak.current(
            expenses: ascending, noSpendDays: [], now: now, calendar: calendar
        )
        let b = LoggingStreak.current(
            expenses: descending, noSpendDays: [], now: now, calendar: calendar
        )

        #expect(a == 3)
        #expect(a == b)
    }

    // MARK: - Bounds

    @Test("walk is bounded by maxLookbackDays")
    func boundedWalk() {
        // Every day for well over the cap — the result must clamp rather than
        // spin.
        let expenses = (0..<(LoggingStreak.maxLookbackDays + 50)).map { offset -> Expense in
            let date = calendar.date(
                byAdding: .day, value: -offset,
                to: TestCalendar.day(2026, 8, 25)
            ) ?? now
            return Expense.fixture(on: date)
        }

        #expect(
            LoggingStreak.current(
                expenses: expenses, noSpendDays: [], now: now, calendar: calendar
            ) == LoggingStreak.maxLookbackDays
        )
    }
}
