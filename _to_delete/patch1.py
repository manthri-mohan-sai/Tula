#!/usr/bin/env python3
"""Patch 1: date anchoring (ExpenseParser + ExpenseInterpreter) and the
under-budget streak bug (Insights). Every replacement is anchored on exact
existing text and asserted to match exactly once."""
import sys, pathlib

ROOT = pathlib.Path.home() / "mnt" / "Tula" / "Tula"

def patch(filename, replacements):
    path = ROOT / filename
    text = path.read_text()
    original = text
    for label, old, new in replacements:
        n = text.count(old)
        if n != 1:
            print(f"FAIL [{filename}] {label}: expected 1 match, found {n}")
            sys.exit(1)
        text = text.replace(old, new)
    if text == original:
        print(f"FAIL [{filename}]: no change produced")
        sys.exit(1)
    path.write_text(text)
    print(f"OK   {filename}  ({len(replacements)} edits)")


# ─────────────────────────── ExpenseParser.swift ───────────────────────────

OLD_EXTRACT = '''    static func extractRelativeDate(
        from text: String
    ) -> (date: Date, remaining: String) {
        let calendar = Calendar.current
        let now = Date.now
        var cleaned = text'''

NEW_EXTRACT = '''    static func extractRelativeDate(
        from text: String
    ) -> (date: Date, remaining: String) {
        extractRelativeDate(from: text, relativeTo: .now)
    }

    /// Reference-anchored variant.
    ///
    /// Backfill flows resolve relative tokens against the day the user
    /// selected rather than against today: typing "chai 30" while catching up
    /// on Monday must land on Monday, and "yesterday" typed in that context
    /// means Sunday. The no-reference overload above delegates here with
    /// `.now`, so every existing call site keeps its previous behaviour
    /// exactly.
    static func extractRelativeDate(
        from text: String,
        relativeTo reference: Date
    ) -> (date: Date, remaining: String) {
        let calendar = Calendar.current
        let now = reference
        var cleaned = text'''

patch("ExpenseParser.swift", [("extractRelativeDate overload", OLD_EXTRACT, NEW_EXTRACT)])


# ───────────────────────── ExpenseInterpreter.swift ─────────────────────────

OLD_FIELDS = '''    let merchantRules: [MerchantRule]
    let defaultAccount: Account?

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }'''

NEW_FIELDS = '''    let merchantRules: [MerchantRule]
    let defaultAccount: Account?

    /// Anchor for relative date tokens ("yesterday", "last Tuesday").
    ///
    /// Defaults to `.now`, which is what every live-entry surface wants. The
    /// catch-up backfill sets it to the day the user selected so that text
    /// typed against a past day resolves against that day rather than today.
    /// Defaulted so the memberwise initialiser stays source-compatible with
    /// existing call sites.
    var referenceDate: Date = .now

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }'''

OLD_DATE_CALL = '''        let date = ExpenseParser.extractRelativeDate(from: segment).date'''
NEW_DATE_CALL = '''        let date = ExpenseParser.extractRelativeDate(
            from: segment, relativeTo: referenceDate
        ).date'''

patch("ExpenseInterpreter.swift", [
    ("referenceDate property", OLD_FIELDS, NEW_FIELDS),
    ("referenceDate threading", OLD_DATE_CALL, NEW_DATE_CALL),
])


# ─────────────────────────────── Insights.swift ─────────────────────────────

OLD_GEN_SIG = '''    static func generate(
        expenses: [Expense],
        accounts: [Account],
        currencyCode: String,
        recurringRules: [RecurringRule] = [],
        dailyBudget: Double? = nil
    ) -> [Insight] {'''

NEW_GEN_SIG = '''    static func generate(
        expenses: [Expense],
        accounts: [Account],
        currencyCode: String,
        recurringRules: [RecurringRule] = [],
        dailyBudget: Double? = nil,
        noSpendDays: Set<String> = []
    ) -> [Insight] {'''

OLD_STREAK_CALL = '''        let streak = computeUnderBudgetStreak(expenses: expenses, dailyBudget: dailyBudget, calendar: calendar, now: now)'''
NEW_STREAK_CALL = '''        let streak = computeUnderBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget,
            noSpendDays: noSpendDays, calendar: calendar, now: now
        )'''

OLD_PUBLIC_STREAK = '''    static func underBudgetStreak(expenses: [Expense], dailyBudget: Double?) -> Int {
        guard let dailyBudget, dailyBudget > 0 else { return 0 }
        return computeUnderBudgetStreak(expenses: expenses, dailyBudget: dailyBudget, calendar: .current, now: .now)
    }'''

NEW_PUBLIC_STREAK = '''    static func underBudgetStreak(
        expenses: [Expense],
        dailyBudget: Double?,
        noSpendDays: Set<String> = []
    ) -> Int {
        guard let dailyBudget, dailyBudget > 0 else { return 0 }
        return computeUnderBudgetStreak(
            expenses: expenses, dailyBudget: dailyBudget,
            noSpendDays: noSpendDays, calendar: .current, now: .now
        )
    }'''

OLD_COMPUTE = '''    /// Count consecutive days (including today) where daily spending stayed
    /// at or below the daily budget pace. Zero-spend days always count —
    /// spending nothing is the ultimate win for a mindful spending app.
    private static func computeUnderBudgetStreak(
        expenses: [Expense], dailyBudget: Double?,
        calendar: Calendar, now: Date
    ) -> Int {'''

NEW_COMPUTE = '''    /// Count consecutive days (including today) where daily spending stayed
    /// at or below the daily budget pace.
    ///
    /// **A day the user did not log does not count.** The spend map has no
    /// entry for an unlogged day, so `?? 0` used to make it indistinguishable
    /// from a genuine zero-spend day — and `0 <= dailyBudget` always holds.
    /// The streak therefore grew for every day the user was away, which meant
    /// the one number surfaced to the user rewarded *not logging*. A day now
    /// counts only when we actually know what happened on it: it has
    /// expenses, or the user explicitly closed it as no-spend.
    private static func computeUnderBudgetStreak(
        expenses: [Expense], dailyBudget: Double?,
        noSpendDays: Set<String>,
        calendar: Calendar, now: Date
    ) -> Int {'''

OLD_LOOP = '''        while cursor >= earliest {
            let daySpend = spendByDay[cursor] ?? 0
            guard daySpend <= dailyBudget else { break }
            streak += 1'''

NEW_LOOP = '''        while cursor >= earliest {
            guard let daySpend = knownDaySpend(
                cursor, spendByDay: spendByDay,
                noSpendDays: noSpendDays, calendar: calendar
            ) else { break }
            guard daySpend <= dailyBudget else { break }
            streak += 1'''

OLD_TODAY_GUARD = '''        // Today might not be over yet — if no spending so far, it still counts
        let todaySpend = spendByDay[cursor] ?? 0
        if todaySpend > dailyBudget {'''

NEW_TODAY_GUARD = '''        // Today might not be over yet — if no spending so far, it still counts.
        // Unlike past days, an unlogged today is not treated as a break: the
        // day is still in progress.
        let todaySpend = spendByDay[cursor] ?? 0
        if todaySpend > dailyBudget {'''

OLD_MSG = '''    private static func underBudgetMessage(for streak: Int) -> String {'''
NEW_MSG = '''    /// Spend on a day we have real information about: logged expenses, or an
    /// explicit no-spend marker. Returns nil for a day the user simply never
    /// logged, which breaks the streak rather than silently extending it.
    private static func knownDaySpend(
        _ day: Date,
        spendByDay: [Date: Double],
        noSpendDays: Set<String>,
        calendar: Calendar
    ) -> Double? {
        if let spend = spendByDay[day] { return spend }
        if noSpendDays.contains(DayKey.string(from: day, calendar: calendar)) { return 0 }
        return nil
    }

    private static func underBudgetMessage(for streak: Int) -> String {'''

patch("Insights.swift", [
    ("generate signature", OLD_GEN_SIG, NEW_GEN_SIG),
    ("generate streak call", OLD_STREAK_CALL, NEW_STREAK_CALL),
    ("public underBudgetStreak", OLD_PUBLIC_STREAK, NEW_PUBLIC_STREAK),
    ("computeUnderBudgetStreak signature", OLD_COMPUTE, NEW_COMPUTE),
    ("today guard comment", OLD_TODAY_GUARD, NEW_TODAY_GUARD),
    ("streak loop known-day gate", OLD_LOOP, NEW_LOOP),
    ("knownDaySpend helper", OLD_MSG, NEW_MSG),
])

print("patch1 complete")
