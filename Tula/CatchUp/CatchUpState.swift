import Foundation

/// A recurring occurrence that fell due while the user was away and still
/// needs a decision.
///
/// Deliberately a value type holding only plain scalars rather than a
/// `RecurringRule` reference: `CatchUpState` is held in `@State` and read
/// during view updates, where SwiftData's lazy relationship faulting can
/// otherwise produce stale or nil display values. `ruleID` is enough to
/// re-fetch when the user actually acts. Same reasoning as
/// `LogConfirmationItem` in `HomeView`.
struct PendingOccurrence: Identifiable, Equatable {
    let ruleID: UUID
    let ruleName: String
    let dueDate: Date
    let expectedAmount: Double
    let isBill: Bool

    var id: String { "\(ruleID.uuidString)_\(Int(dueDate.timeIntervalSince1970))" }
}

/// What the user missed while they were away.
///
/// Produced by `CatchUpDetector` as a pure function of stored data, so it can
/// be recomputed freely on foreground without coordinating cached state.
struct CatchUpState: Equatable {

    enum DayStatus: Equatable {
        /// Nothing logged and not explicitly closed — this is what the
        /// catch-up flow exists to resolve.
        case unlogged
        case logged(count: Int, total: Double)
        /// The user explicitly said nothing was spent.
        case noSpend
    }

    struct Day: Identifiable, Equatable {
        /// Always `calendar.startOfDay`.
        let date: Date
        let status: DayStatus

        var id: Date { date }
        var needsAttention: Bool { status == .unlogged }
    }

    /// Oldest → newest. Excludes today: today is not "missed" yet, and
    /// nagging about a day still in progress is exactly the pressure this
    /// feature is designed to avoid.
    let days: [Day]

    /// Overdue occurrences awaiting a decision. Contains only rules that
    /// genuinely need one — see `CatchUpDetector` for why auto-generated
    /// rules are excluded.
    let pendingRecurring: [PendingOccurrence]

    /// Unlogged days that fell outside the lookback window.
    let truncatedOlderDays: Int

    static let clear = CatchUpState(days: [], pendingRecurring: [], truncatedOlderDays: 0)

    var unloggedDays: [Day] { days.filter(\.needsAttention) }
    var unloggedCount: Int { unloggedDays.count }

    var isClear: Bool { unloggedCount == 0 && pendingRecurring.isEmpty }

    /// Newest unlogged day, used as the dismissal watermark so that a *new*
    /// gap re-surfaces the card even after the user dismissed the last one.
    var newestUnloggedDate: Date? { unloggedDays.last?.date }

    // MARK: - Display

    var headline: String {
        switch (unloggedCount, pendingRecurring.count) {
        case (0, let bills) where bills > 0:
            return bills == 1 ? "1 payment due" : "\(bills) payments due"
        case (1, _):
            return "1 day unlogged"
        case (let days, _):
            return "\(days) days unlogged"
        }
    }

    /// Short weekday list plus a recurring hint, e.g. "Thu, Fri, Sat · 2 bills due".
    func detail(calendar: Calendar = .current) -> String {
        var parts: [String] = []

        let names = unloggedDays.suffix(4).map { day -> String in
            let weekday = calendar.component(.weekday, from: day.date)
            return calendar.shortWeekdaySymbols[weekday - 1]
        }
        if !names.isEmpty {
            let more = unloggedCount - names.count
            parts.append(more > 0
                ? names.joined(separator: ", ") + " +\(more)"
                : names.joined(separator: ", "))
        }

        if !pendingRecurring.isEmpty {
            let count = pendingRecurring.count
            parts.append(count == 1 ? "1 bill due" : "\(count) bills due")
        }

        return parts.joined(separator: " · ")
    }
}
