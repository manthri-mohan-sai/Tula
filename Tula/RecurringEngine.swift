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

        for rule in rules {
            // Auto-resume: if rule is paused but its `pausedUntil` has
            // elapsed, clear both flags here so downstream logic treats
            // the rule as active again. Done before the isPaused check
            // so the same launch that detects the expiry also picks up
            // any past-due occurrences.
            if rule.isPaused, let until = rule.pausedUntil, until <= now {
                rule.isPaused = false
                rule.pausedUntil = nil
            }
            if rule.isPaused { continue }

            if let endDate = rule.endDate, now > endDate { continue }

            // Pause-until: if a future date is set, skip this run. If
            // the date has passed, clear it (the rule auto-resumes).
            if let until = rule.pausedUntil {
                if until > now {
                    continue
                } else {
                    rule.pausedUntil = nil
                    didGenerateAnything = true   // ensure save fires
                }
            }

            // Rules requiring confirmation don't auto-log. Schedule
            // notifications for upcoming due dates instead — user
            // taps Log/Skip on the notification banner. We pre-queue
            // the next 14 occurrences so iOS can fire them even when
            // the app is closed.
            if rule.confirmationRequired {
                scheduleUpcomingConfirmations(for: rule, calendar: calendar)
                continue
            }

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

    /// For confirmation-required rules, schedules the next N occurrences
    /// as interactive notifications. iOS dedupes by request identifier,
    /// so re-running on every app launch is safe — already-scheduled
    /// notifications are simply replaced in place.
    ///
    /// We cap at 14 occurrences because iOS limits a single app to ~64
    /// pending notifications total; daily rules would otherwise saturate
    /// the budget within two months.
    private static func scheduleUpcomingConfirmations(
        for rule: RecurringRule,
        calendar: Calendar
    ) {
        // Need a sensible account+currency to format the body line.
        // For expense rules we use the linked account; for transfers
        // (which also support recurrence) we use the fromAccount.
        let code = rule.account?.currencyCode
            ?? rule.fromAccount?.currencyCode
            ?? UserDefaults.standard.string(forKey: "primaryCurrencyCode")
            ?? "INR"

        let now = Date.now

        // Anchor: start walking from start-of-today, not from `now`.
        //
        // Why this matters: `nextOccurrence(strictlyAfter:)` finds the
        // first calendar-aware occurrence after the given date. If the
        // user creates a "Lunch 1pm daily" rule at 3pm, anchoring on
        // `now` would skip today's 1pm (already past) and queue
        // tomorrow's 1pm as the first notification. From the user's
        // perspective: "I set up lunch, nothing happened."
        //
        // Starting from start-of-today means nextOccurrence first
        // surfaces today's 1pm. We then drop any candidate whose
        // fire-time is already in the past via the `nextDate > now`
        // filter inside the loop — iOS can't deliver retroactive
        // notifications. Net effect: today's notification fires IF the
        // user set up the rule before its scheduled time, and is
        // silently skipped IF after — but the rule is still correctly
        // queued for tomorrow onward.
        let anchor = calendar.startOfDay(for: now)
        var nextDate = nextOccurrence(strictlyAfter: anchor, rule: rule, calendar: calendar)

        var scheduled = 0
        let cap = 14
        while scheduled < cap {
            if let endDate = rule.endDate, nextDate > endDate { break }

            // Skip past-due occurrences (today's 1pm at 3pm). iOS would
            // either drop them or fire them immediately as a stale alert,
            // both undesirable.
            if nextDate > now {
                NotificationManager.scheduleConfirmation(
                    ruleID: rule.id,
                    ruleName: rule.name,
                    amount: rule.amount,
                    currencyCode: code,
                    dueDate: nextDate
                )
                scheduled += 1
            }

            nextDate = nextOccurrence(
                strictlyAfter: nextDate,
                rule: rule,
                calendar: calendar
            )
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
            return nextWeekly(
                strictlyAfter: date,
                anchoredTo: rule.startDate,
                weekdaysMask: rule.weekdaysMask,
                calendar: calendar
            )
        case .monthly:
            return nextMonthly(
                strictlyAfter: date,
                dayOfMonth: rule.dayOfMonth,
                anchoredTo: rule.startDate,
                calendar: calendar
            )
        case .yearly:
            return nextYearly(strictlyAfter: date, anchoredTo: rule.startDate, calendar: calendar)
        case .custom:
            return nextCustom(
                strictlyAfter: date,
                anchoredTo: rule.startDate,
                interval: max(1, rule.customInterval),
                unit: rule.customUnit,
                calendar: calendar
            )
        }
    }

    // MARK: - Per-frequency next-occurrence logic

    /// Weekly: anchored to startDate's time of day. Fires on every weekday
    /// whose bit is set in `weekdaysMask`. If `weekdaysMask == 0`, falls
    /// back to firing on startDate's weekday only (legacy single-day mode).
    private static func nextWeekly(
        strictlyAfter date: Date,
        anchoredTo anchor: Date,
        weekdaysMask: Int,
        calendar: Calendar
    ) -> Date {
        let hour = calendar.component(.hour, from: anchor)
        let minute = calendar.component(.minute, from: anchor)

        // Build the set of allowed weekdays. Mask 0 means "use anchor's
        // weekday only" — preserves legacy behavior. Otherwise expand
        // the bitmask into a set (bit 0 = Sunday = weekday 1, etc).
        let allowedWeekdays: Set<Int>
        if weekdaysMask == 0 {
            allowedWeekdays = [calendar.component(.weekday, from: anchor)]
        } else {
            var set: Set<Int> = []
            for i in 0..<7 where (weekdaysMask & (1 << i)) != 0 {
                set.insert(i + 1)
            }
            // Safety: if mask was somehow only bits 7+ (shouldn't happen),
            // fall back to anchor's weekday rather than infinite-looping.
            if set.isEmpty {
                allowedWeekdays = [calendar.component(.weekday, from: anchor)]
            } else {
                allowedWeekdays = set
            }
        }

        // Walk forward day-by-day looking for an allowed weekday. Check
        // today FIRST (then tomorrow, then day-after, etc) — previously
        // this loop incremented BEFORE checking, which silently skipped
        // today's slot when called with `date = startOfToday`. Combined
        // with the scheduler anchoring on start-of-today, that made every
        // rule with a specific time queue from tomorrow onward, never
        // today. The `withTime > date` clause inside still filters out
        // candidates whose time-of-day has already passed when `date`
        // includes a non-zero time component, so we don't accidentally
        // schedule past-due notifications.
        var candidate = date
        for _ in 0..<8 {
            if allowedWeekdays.contains(calendar.component(.weekday, from: candidate)) {
                var components = calendar.dateComponents([.year, .month, .day], from: candidate)
                components.hour = hour
                components.minute = minute
                components.second = 0
                if let withTime = calendar.date(from: components), withTime > date {
                    return withTime
                }
            }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return calendar.date(byAdding: .weekOfYear, value: 1, to: date) ?? date
    }

    /// Monthly: fires on `dayOfMonth` (clamped for Feb / 30-day months)
    /// at the time-of-day of `anchor`. Previously hard-coded to 9am
    /// regardless of the rule's specified time — meaning a "1st of the
    /// month at 6pm rent reminder" would fire at 9am, ignoring user
    /// intent. Now respects the anchor's hour/minute.
    private static func nextMonthly(
        strictlyAfter date: Date,
        dayOfMonth: Int,
        anchoredTo anchor: Date,
        calendar: Calendar
    ) -> Date {
        let hour = calendar.component(.hour, from: anchor)
        let minute = calendar.component(.minute, from: anchor)

        // Try this month at dayOfMonth (clamped to month length).
        var components = calendar.dateComponents([.year, .month], from: date)
        components.hour = hour
        components.minute = minute
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
        nextComponents.hour = hour
        nextComponents.minute = minute
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

    /// Custom: stride forward from the anchor in fixed-unit jumps until
    /// landing strictly after `date`. Time-of-day is preserved from the
    /// anchor so "every 2 weeks" fires at the same hour each occurrence.
    ///
    /// Walks forward via the calendar component rather than naive seconds
    /// so DST/calendar-month boundaries are handled correctly (months
    /// have varying lengths; date arithmetic on raw intervals would
    /// drift over the year).
    private static func nextCustom(
        strictlyAfter date: Date,
        anchoredTo anchor: Date,
        interval: Int,
        unit: CustomIntervalUnit,
        calendar: Calendar
    ) -> Date {
        var candidate = anchor
        // Stride forward in `interval` × unit jumps until we pass `date`.
        // Capped at 10,000 iterations as a safety guard against pathological
        // intervals (e.g. interval=0 would loop forever; we already clamp
        // at the call site but defense-in-depth is cheap).
        var iterations = 0
        while candidate <= date && iterations < 10_000 {
            guard let next = calendar.date(
                byAdding: unit.calendarComponent,
                value: interval,
                to: candidate
            ) else { break }
            candidate = next
            iterations += 1
        }
        return candidate
    }

    // MARK: - Transaction creation

    /// Creates the rule's payload (expense or transfer) and inserts it
    /// into the given context. Marked `internal` (no access level) so the
    /// notification-response handler can call it when the user taps
    /// "Log it" on a confirmation notification.
    static func createTransaction(rule: RecurringRule, date: Date, in context: ModelContext) {
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
    /// Returns the next due date strictly in the future relative to `now`.
    /// For the home screen this means: today's 1pm lunch won't appear as
    /// "upcoming" at 8pm — we step forward to tomorrow's 1pm instead.
    ///
    /// **Why the loop**: `nextOccurrence` returns the next slot after
    /// `lastGeneratedDate ?? startDate`, which may be in the past if the
    /// rule fires daily and today's slot already passed. We need to walk
    /// forward through occurrences until we find one that hasn't fired
    /// yet. Capped at 366 iterations (one year of daily slots) as a safety
    /// guard — a misconfigured rule shouldn't be able to spin forever.
    static func nextDueDate(for rule: RecurringRule) -> Date? {
        if rule.isPaused { return nil }
        if let endDate = rule.endDate, endDate < .now { return nil }
        let calendar = Calendar.current
        let now = Date.now
        var from = rule.lastGeneratedDate ?? rule.startDate
        var iterations = 0
        while iterations < 366 {
            let next = nextOccurrence(strictlyAfter: from, rule: rule, calendar: calendar)
            if let endDate = rule.endDate, next > endDate { return nil }
            // Future occurrence found — return it.
            if next > now { return next }
            // Past-due — advance and try again. For daily rules this
            // converges in one or two iterations; for weekly the worst
            // case is 7 (today's slot already passed, next week's is
            // what we want); for monthly worst case is ~31.
            from = next
            iterations += 1
        }
        return nil
    }

    /// Mark a specific occurrence of a rule as "handled" without creating
    /// an expense. Used when the user taps Skip on a confirmation
    /// notification or the Skip button in the home upcoming row.
    ///
    /// **Semantics.** `lastGeneratedDate` is the field that the engine
    /// uses as the boundary between "already processed" and "still to do."
    /// `nextDueDate` returns the first occurrence strictly after this
    /// field. So bumping it to the skipped date makes the engine treat
    /// the skipped occurrence as resolved — the home screen indicator
    /// disappears, and the next occurrence (tomorrow / next week / etc.)
    /// surfaces in its place.
    ///
    /// The field name says "generated" for backward-compat; the meaning is
    /// closer to "last handled" once skip is taken into account. No new
    /// data column was added — skip uses the same boundary as log.
    static func skipOccurrence(rule: RecurringRule, dueDate: Date) {
        // Only advance the marker; don't go backward. Multiple skip taps
        // for the same date should be idempotent, and we should never
        // backtrack a previously-logged date.
        if let last = rule.lastGeneratedDate, last >= dueDate { return }
        rule.lastGeneratedDate = dueDate
    }
}
