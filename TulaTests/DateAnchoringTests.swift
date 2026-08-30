import Foundation
import Testing
@testable import Tula

/// Covers the `relativeTo:` overload added for backfill, and — just as
/// importantly — that the original signature's behaviour is unchanged for the
/// existing call sites that still use it.
@Suite("Relative date anchoring")
struct DateAnchoringTests {

    private let calendar = Calendar.current

    private func sameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    private func days(_ offset: Int, from date: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: date) ?? date
    }

    // MARK: - Anchored variant

    @Test("plain text resolves to the anchor, not to today")
    func plainTextUsesAnchor() {
        // The user selected a past day in the catch-up sheet; text with no
        // date token belongs to that day.
        let anchor = days(-4, from: .now)

        let result = ExpenseParser.extractRelativeDate(
            from: "chai 30", relativeTo: anchor
        )

        #expect(sameDay(result.date, anchor))
    }

    @Test("'yesterday' resolves relative to the anchor")
    func yesterdayIsAnchorMinusOne() {
        let anchor = days(-4, from: .now)

        let result = ExpenseParser.extractRelativeDate(
            from: "yesterday chai 30", relativeTo: anchor
        )

        #expect(sameDay(result.date, days(-1, from: anchor)))
        #expect(!result.remaining.lowercased().contains("yesterday"))
    }

    @Test("'day before yesterday' resolves relative to the anchor")
    func dayBeforeYesterdayIsAnchorMinusTwo() {
        let anchor = days(-4, from: .now)

        let result = ExpenseParser.extractRelativeDate(
            from: "day before yesterday 200 groceries", relativeTo: anchor
        )

        #expect(sameDay(result.date, days(-2, from: anchor)))
    }

    @Test("'today' resolves to the anchor day")
    func todayMeansTheAnchor() {
        let anchor = days(-4, from: .now)

        let result = ExpenseParser.extractRelativeDate(
            from: "today 150 lunch", relativeTo: anchor
        )

        #expect(sameDay(result.date, anchor))
        #expect(!result.remaining.lowercased().contains("today"))
    }

    @Test("Hindi 'kal' resolves relative to the anchor")
    func hindiKalUsesAnchor() {
        let anchor = days(-4, from: .now)

        let result = ExpenseParser.extractRelativeDate(
            from: "kal 80 auto", relativeTo: anchor
        )

        #expect(sameDay(result.date, days(-1, from: anchor)))
    }

    // MARK: - Source compatibility

    @Test("the original signature still resolves against today")
    func defaultOverloadUnchanged() {
        #expect(
            sameDay(
                ExpenseParser.extractRelativeDate(from: "chai 30").date,
                .now
            )
        )
        #expect(
            sameDay(
                ExpenseParser.extractRelativeDate(from: "yesterday chai 30").date,
                days(-1, from: .now)
            )
        )
    }

    @Test("both overloads agree when the anchor is now")
    func overloadsAgreeAtNow() {
        let inputs = ["chai 30", "yesterday 40", "parso 60", "today 20"]

        for input in inputs {
            let implicit = ExpenseParser.extractRelativeDate(from: input)
            let explicit = ExpenseParser.extractRelativeDate(
                from: input, relativeTo: .now
            )
            #expect(sameDay(implicit.date, explicit.date))
            #expect(implicit.remaining == explicit.remaining)
        }
    }

    // MARK: - Interpreter threading

    @Test("ExpenseInterpreter defaults referenceDate to now")
    func interpreterDefaultsToNow() {
        let interpreter = ExpenseInterpreter(
            accounts: [], categories: [], merchantRules: [], defaultAccount: nil
        )

        #expect(sameDay(interpreter.referenceDate, .now))
    }
}

@Suite("DayKey")
struct DayKeyTests {

    @Test("formats a stable yyyy-MM-dd key")
    func formatsKey() {
        let date = TestCalendar.day(2026, 8, 5)
        #expect(DayKey.string(from: date, calendar: TestCalendar.utc) == "2026-08-05")
    }

    @Test("round-trips through parsing")
    func roundTrips() {
        let calendar = TestCalendar.utc
        let original = TestCalendar.day(2026, 12, 31)
        let key = DayKey.string(from: original, calendar: calendar)

        let parsed = DayKey.date(from: key, calendar: calendar)

        #expect(parsed.map { calendar.isDate($0, inSameDayAs: original) } == true)
    }

    @Test("rejects a malformed key")
    func rejectsMalformed() {
        #expect(DayKey.date(from: "not-a-date") == nil)
        #expect(DayKey.date(from: "2026-08") == nil)
    }
}

@Suite("NoSpendDayStore")
struct NoSpendDayStoreTests {

    private let calendar = TestCalendar.utc

    @Test("marks and unmarks a day")
    func marksAndUnmarks() {
        var store = NoSpendDayStore(raw: "")
        let day = TestCalendar.day(2026, 8, 24)

        store.set(true, for: day, calendar: calendar)
        #expect(store.contains(day, calendar: calendar))

        store.set(false, for: day, calendar: calendar)
        #expect(!store.contains(day, calendar: calendar))
    }

    @Test("round-trips through its raw string")
    func roundTripsRaw() {
        var store = NoSpendDayStore(raw: "")
        store.set(true, for: TestCalendar.day(2026, 8, 24), calendar: calendar)
        store.set(true, for: TestCalendar.day(2026, 8, 23), calendar: calendar)

        let restored = NoSpendDayStore(raw: store.rawValue)

        #expect(restored.keys == store.keys)
        #expect(restored.keys.count == 2)
    }

    @Test("an empty raw string yields no keys")
    func emptyRaw() {
        #expect(NoSpendDayStore(raw: "").keys.isEmpty)
    }

    @Test("prune drops markers past the retention window")
    func prunesOldKeys() {
        let now = TestCalendar.day(2026, 8, 25)
        var store = NoSpendDayStore(raw: "")
        let recent = TestCalendar.day(2026, 8, 20)
        let ancient = calendar.date(
            byAdding: .day, value: -(NoSpendDayStore.retentionDays + 10), to: now
        ) ?? now

        store.set(true, for: recent, calendar: calendar)
        store.set(true, for: ancient, calendar: calendar)
        store.prune(now: now, calendar: calendar)

        #expect(store.contains(recent, calendar: calendar))
        #expect(!store.contains(ancient, calendar: calendar))
    }
}
