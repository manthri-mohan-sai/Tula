import Foundation

/// Consecutive days, ending today, on which the user closed the books —
/// either by logging at least one expense or by explicitly marking the day
/// as no-spend.
///
/// **Why this and not `InsightEngine.underBudgetStreak`.** The under-budget
/// streak measures *underspending*, which breaks on a legitimately expensive
/// day and so teaches the user the number is arbitrary. This measures
/// *logging*, which is the habit the app actually depends on.
///
/// **Repair needs no machinery.** The streak is derived from expense dates,
/// so a backfilled expense carrying a past date recomputes the streak upward
/// on the next render. Filling a gap restores the streak as a direct
/// consequence of correct derivation — there is deliberately no separate
/// "repair" state to keep in sync.
enum LoggingStreak {

    /// Hard bound on the backwards walk. Also bounds the size of the
    /// day-key set built below.
    static let maxLookbackDays = 400

    /// - Parameters:
    ///   - expenses: any order; only `date` is read.
    ///   - noSpendDays: day keys the user explicitly closed as no-spend.
    /// - Returns: streak length in days, counting today.
    static func current(
        expenses: [Expense],
        noSpendDays: Set<String>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        let today = calendar.startOfDay(for: now)
        guard let horizon = calendar.date(
            byAdding: .day, value: -maxLookbackDays, to: today
        ) else { return 0 }

        // One O(n) pass with a cheap Date comparison, rather than assuming the
        // caller's sort order. `HomeView.allExpenses` happens to be reverse-
        // sorted today, but depending on that would make this silently
        // under-report if the @Query sort ever changed.
        var loggedDays: Set<String> = []
        for expense in expenses where expense.date >= horizon {
            loggedDays.insert(DayKey.string(from: expense.date, calendar: calendar))
        }

        func isClosed(_ day: Date) -> Bool {
            let key = DayKey.string(from: day, calendar: calendar)
            return loggedDays.contains(key) || noSpendDays.contains(key)
        }

        // Today is still in progress, so not having logged it *yet* is not a
        // miss — it is simply not a contribution. Opening the app at 9am after
        // a fortnight of daily logging must not read "0-day streak"; that is
        // precisely the arbitrary-feeling number this type replaces. Today
        // therefore extends the streak once closed, and is skipped otherwise.
        var cursor = today
        var streak = 0
        if isClosed(today) {
            streak = 1
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        else { return streak }
        cursor = yesterday

        // Bound starts at 1 because today, when closed, already contributed —
        // so `maxLookbackDays` is the exact ceiling on the reported streak
        // rather than one less than it.
        for _ in 1..<maxLookbackDays {
            guard isClosed(cursor) else { break }
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor)
            else { break }
            cursor = previous
        }
        return streak
    }
}
