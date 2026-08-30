import Foundation

/// Derives `CatchUpState` from stored data.
///
/// Pure by design — no `ModelContext`, injected `now` and `calendar`. `HomeView`
/// already holds `allExpenses` via `@Query`, so this costs no extra fetch, and
/// the whole thing is unit-testable without a container.
enum CatchUpDetector {

    /// Maximum days surfaced. A forty-day gap is demoralising and
    /// unactionable; past this the UI offers "dismiss older" instead of chips.
    static let maxLookbackDays = 7

    /// - Parameters:
    ///   - expenses: any order; only `date` and `amount` are read.
    ///   - noSpendDays: day keys the user explicitly closed.
    ///   - recurringRules: all rules; filtered internally (see below).
    ///   - overdueDates: per-rule overdue occurrences, normally
    ///     `HomeView.cachedOverdueDates` populated from
    ///     `RecurringEngine.overdueDates(for:)`.
    ///   - expectedAmount: resolves the amount to show for an occurrence.
    ///     Injected so the detector stays free of `SmartAmountPredictor`;
    ///     defaults to the rule's configured amount.
    ///   - notBefore: user-set floor. Dismissing the "older days" row moves
    ///     this forward so those days stop being counted, without fabricating
    ///     no-spend markers for days the user never actually accounted for.
    static func state(
        expenses: [Expense],
        noSpendDays: Set<String>,
        recurringRules: [RecurringRule],
        overdueDates: [UUID: [Date]],
        expectedAmount: (RecurringRule, Date) -> Double = { rule, _ in rule.amount },
        notBefore: Date? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CatchUpState {

        let today = calendar.startOfDay(for: now)

        // The window never begins before the user's first expense. Without
        // this clamp a day-two user is told they missed seven days.
        // `.lazy` so finding the earliest date does not allocate a parallel
        // array of every expense date on each refresh.
        guard let firstExpenseDate = expenses.lazy.map(\.date).min() else {
            return CatchUpState(
                days: [],
                pendingRecurring: pendingOccurrences(
                    rules: recurringRules, overdueDates: overdueDates,
                    expectedAmount: expectedAmount, calendar: calendar
                ),
                truncatedOlderDays: 0
            )
        }
        // The floor is whichever is later: the user's first expense, or the
        // horizon they explicitly dismissed to.
        var firstDay = calendar.startOfDay(for: firstExpenseDate)
        if let notBefore {
            firstDay = max(firstDay, calendar.startOfDay(for: notBefore))
        }

        // Yesterday is the newest day that can be "missed"; today is still
        // in progress.
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              yesterday >= firstDay
        else {
            return CatchUpState(
                days: [],
                pendingRecurring: pendingOccurrences(
                    rules: recurringRules, overdueDates: overdueDates,
                    expectedAmount: expectedAmount, calendar: calendar
                ),
                truncatedOlderDays: 0
            )
        }

        let windowStart = calendar.date(
            byAdding: .day, value: -(maxLookbackDays - 1), to: yesterday
        ) ?? yesterday
        let effectiveStart = max(windowStart, firstDay)

        // Aggregate once, keyed by day. One pass, order-independent — the
        // caller's @Query sort is not assumed.
        var totalsByDay: [String: (count: Int, total: Double)] = [:]
        for expense in expenses where expense.date >= effectiveStart {
            let key = DayKey.string(from: expense.date, calendar: calendar)
            let existing = totalsByDay[key] ?? (0, 0)
            totalsByDay[key] = (existing.count + 1, existing.total + expense.amount)
        }

        var days: [CatchUpState.Day] = []
        var cursor = effectiveStart
        while cursor <= yesterday {
            let key = DayKey.string(from: cursor, calendar: calendar)
            let status: CatchUpState.DayStatus
            if let hit = totalsByDay[key] {
                // An expense on the day always wins over a no-spend marker:
                // derivation is one-directional, so a stale marker can never
                // hide real data.
                status = .logged(count: hit.count, total: hit.total)
            } else if noSpendDays.contains(key) {
                status = .noSpend
            } else {
                status = .unlogged
            }
            days.append(CatchUpState.Day(date: cursor, status: status))

            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor)
            else { break }
            cursor = next
        }

        return CatchUpState(
            days: days,
            pendingRecurring: pendingOccurrences(
                rules: recurringRules, overdueDates: overdueDates,
                expectedAmount: expectedAmount, calendar: calendar
            ),
            truncatedOlderDays: truncatedCount(
                windowStart: effectiveStart, firstDay: firstDay,
                noSpendDays: noSpendDays, expenses: expenses, calendar: calendar
            )
        )
    }

    // MARK: - Recurring

    /// Occurrences that genuinely need a decision.
    ///
    /// **Critical filter.** `RecurringEngine.generateMissing` already
    /// materialises every rule with `confirmationRequired == false` at launch
    /// (`TulaApp`, `TulaAppDelegate`, `HomeView`). Including those here would
    /// offer to create expenses that already exist. Only rules that opted into
    /// confirmation, or bills the user pays manually, are left pending.
    private static func pendingOccurrences(
        rules: [RecurringRule],
        overdueDates: [UUID: [Date]],
        expectedAmount: (RecurringRule, Date) -> Double,
        calendar: Calendar
    ) -> [PendingOccurrence] {
        var results: [PendingOccurrence] = []

        for rule in rules {
            guard !rule.isPaused,
                  rule.confirmationRequired || rule.isBill,
                  let dates = overdueDates[rule.id], !dates.isEmpty
            else { continue }

            for date in dates {
                // A bill already marked paid on or after this occurrence
                // needs no further action.
                if rule.isBill, let paid = rule.lastPaidDate,
                   calendar.startOfDay(for: paid) >= calendar.startOfDay(for: date) {
                    continue
                }
                results.append(PendingOccurrence(
                    ruleID: rule.id,
                    ruleName: rule.merchant ?? rule.name,
                    dueDate: date,
                    expectedAmount: expectedAmount(rule, date),
                    isBill: rule.isBill
                ))
            }
        }

        return results.sorted { $0.dueDate < $1.dueDate }
    }

    // MARK: - Truncation

    /// Unlogged days between the user's first expense and the lookback window.
    /// Counted, not enumerated — the UI only needs a number for the
    /// "dismiss older" row.
    private static func truncatedCount(
        windowStart: Date,
        firstDay: Date,
        noSpendDays: Set<String>,
        expenses: [Expense],
        calendar: Calendar
    ) -> Int {
        guard windowStart > firstDay else { return 0 }

        var loggedKeys: Set<String> = []
        for expense in expenses where expense.date < windowStart {
            loggedKeys.insert(DayKey.string(from: expense.date, calendar: calendar))
        }

        var count = 0
        var cursor = firstDay
        // Bounded so a years-old first expense cannot spin the loop.
        var guardrail = 0
        while cursor < windowStart, guardrail < 3650 {
            let key = DayKey.string(from: cursor, calendar: calendar)
            if !loggedKeys.contains(key) && !noSpendDays.contains(key) {
                count += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor)
            else { break }
            cursor = next
            guardrail += 1
        }
        return count
    }
}
