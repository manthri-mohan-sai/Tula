import Foundation
import SwiftData

// MARK: - Budget

/// A spending cap for a category (or all categories) over a fixed time window.
///
/// Spent amount is computed dynamically from `Expense` records — no rollover,
/// no envelope mechanics. The window slides automatically: a "monthly" budget
/// resets at the start of each calendar month, etc.
///
/// `category == nil` means an **Overall** budget — caps total spending across
/// all categories. Used for "₹50,000/month total" style caps.
@Model
final class Budget {
    var id: UUID = UUID()
    var amount: Double = 0

    /// Stored as String for SwiftData compatibility — use `period` for typed access.
    var periodRaw: String = BudgetPeriod.monthly.rawValue

    /// When the budget was first created. Used as the historical anchor;
    /// the *current* period window is computed from `Date.now`.
    var startDate: Date = Date()

    /// Soft-disable — preserves history but excludes from active calculations.
    /// Useful when the user wants to pause a budget without deleting it.
    var isActive: Bool = true

    var createdAt: Date = Date()

    /// Nil = Overall budget (all spending counts). Otherwise scoped to one category.
    var category: Category?

    init(amount: Double, category: Category? = nil,
         period: BudgetPeriod = .monthly, startDate: Date = .now) {
        self.amount = amount
        self.category = category
        self.periodRaw = period.rawValue
        // Normalize to start-of-day so equality comparisons work cleanly.
        self.startDate = Calendar.current.startOfDay(for: startDate)
    }

    var period: BudgetPeriod {
        get { BudgetPeriod(rawValue: periodRaw) ?? .monthly }
        set { periodRaw = newValue.rawValue }
    }

    /// User-visible name: category name if scoped, "Overall" otherwise.
    var displayName: String {
        category?.name ?? "Overall"
    }
}

// MARK: - Period

/// How often a budget resets. Window boundaries follow the user's calendar
/// (week starts per locale, month/year follow Gregorian).
enum BudgetPeriod: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    /// Short descriptive label for inline use ("this month", etc.).
    var shortLabel: String {
        switch self {
        case .weekly:  return "this week"
        case .monthly: return "this month"
        case .yearly:  return "this year"
        }
    }

    /// Calendar component used to compute the current period interval.
    var calendarComponent: Calendar.Component {
        switch self {
        case .weekly:  return .weekOfYear
        case .monthly: return .month
        case .yearly:  return .year
        }
    }
}

// MARK: - Period Window

extension Budget {
    /// (start, end) of the current period containing `now`. End is exclusive.
    func currentPeriodWindow(now: Date = .now,
                             calendar: Calendar = .current) -> (start: Date, end: Date) {
        let interval = calendar.dateInterval(of: period.calendarComponent, for: now)
            ?? DateInterval(start: now, duration: 0)
        return (interval.start, interval.end)
    }

    /// Days remaining in the current period (inclusive of today).
    /// Returns 0 if the period has ended.
    func daysRemaining(now: Date = .now, calendar: Calendar = .current) -> Int {
        let window = currentPeriodWindow(now: now, calendar: calendar)
        let comps = calendar.dateComponents([.day], from: now, to: window.end)
        return max(0, comps.day ?? 0)
    }
}

// MARK: - Progress Computation

extension Budget {
    /// Spent in the current period, filtered by category (or all if Overall).
    /// Pass in the full expenses array — we filter here to keep callers simple.
    func spent(in expenses: [Expense], now: Date = .now) -> Double {
        let window = currentPeriodWindow(now: now)
        return expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .filter { exp in
                guard let cat = category else { return true }  // Overall: all expenses count
                return exp.category?.id == cat.id
            }
            .reduce(0) { $0 + $1.amount }
    }

    /// Progress ratio (0...n). Can exceed 1.0 when over budget.
    func progress(in expenses: [Expense], now: Date = .now) -> Double {
        guard amount > 0 else { return 0 }
        return spent(in: expenses, now: now) / amount
    }

    /// Remaining headroom. Negative when over budget.
    func remaining(in expenses: [Expense], now: Date = .now) -> Double {
        amount - spent(in: expenses, now: now)
    }

    /// High-level health label used by the UI (color + copy).
    enum Status {
        case healthy       // < 75% used
        case warning       // 75-100% used
        case overBudget    // > 100% used
    }

    func status(in expenses: [Expense], now: Date = .now) -> Status {
        let p = progress(in: expenses, now: now)
        if p > 1.0 { return .overBudget }
        if p >= 0.75 { return .warning }
        return .healthy
    }
}

// MARK: - Chart Data

/// One data point on a budget's cumulative-spend chart.
/// `date` is the day, `cumulative` is total spent from period start through that day.
struct BudgetDailyPoint: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let cumulative: Double
}

extension Budget {
    /// Daily cumulative spend over the current period. One point per day
    /// from period start through today (inclusive). Days with no spending
    /// carry forward the previous total — gives a smooth non-decreasing line.
    func dailyCumulativeSpend(in expenses: [Expense],
                              now: Date = .now,
                              calendar: Calendar = .current) -> [BudgetDailyPoint] {
        let window = currentPeriodWindow(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        // Filter expenses to this period and scope (category or all).
        let relevant = expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .filter { exp in
                guard let cat = category else { return true }
                return exp.category?.id == cat.id
            }

        // Group totals by start-of-day.
        var byDay: [Date: Double] = [:]
        for exp in relevant {
            let day = calendar.startOfDay(for: exp.date)
            byDay[day, default: 0] += exp.amount
        }

        // Walk day-by-day from period start to today, accumulating.
        var points: [BudgetDailyPoint] = []
        var cumulative: Double = 0
        var cursor = calendar.startOfDay(for: window.start)
        while cursor <= today {
            cumulative += byDay[cursor, default: 0]
            points.append(BudgetDailyPoint(date: cursor, cumulative: cumulative))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }
}

// MARK: - Pace

/// Whether the user is on track within the current period. Compares
/// percentage spent vs percentage of time elapsed — diverges from `Status`,
/// which only cares about absolute consumption, not pace.
enum BudgetPace {
    case underPace      // Spending slower than time elapsed — good
    case onTrack        // Within 10pp of expected pace
    case overPace       // Spending faster than time elapsed — risky
    case overBudget     // Already crossed the cap

    var label: String {
        switch self {
        case .underPace:  return "Under pace"
        case .onTrack:    return "On track"
        case .overPace:   return "Spending fast"
        case .overBudget: return "Over budget"
        }
    }
}

extension Budget {
    /// What fraction of the period has elapsed (0...1).
    func elapsedFraction(now: Date = .now, calendar: Calendar = .current) -> Double {
        let window = currentPeriodWindow(now: now, calendar: calendar)
        let total = window.end.timeIntervalSince(window.start)
        guard total > 0 else { return 0 }
        let used = now.timeIntervalSince(window.start)
        return min(max(used / total, 0), 1)
    }

    func pace(in expenses: [Expense], now: Date = .now) -> BudgetPace {
        let spentFrac = progress(in: expenses, now: now)
        if spentFrac > 1.0 { return .overBudget }
        let elapsed = elapsedFraction(now: now)
        let delta = spentFrac - elapsed
        if delta > 0.1 { return .overPace }
        if delta < -0.1 { return .underPace }
        return .onTrack
    }
}
