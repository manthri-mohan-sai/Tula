import Foundation

// MARK: - Widget Snapshot

/// Compact JSON-codable snapshot the main app writes to App Group storage
/// so the widget extension can render without database access. Refreshed
/// on every app foreground transition (see `WidgetRefresh.refresh`).
///
/// Designed to stay small (a few KB at most). Includes only what active
/// widget surfaces need: today's spend, month total, top monthly budgets,
/// a 7-day sparkline trail, and upcoming recurring expenses.
///
/// **v2 changes:** Removed `recentExpenses` (past-data feed was not
/// actionable on a home screen). Added `dailyTotals` for sparklines on
/// the Today widget and lockscreen rectangular surface. Added
/// `upcomingRecurrings` for the new Upcoming widget — surfaces what's
/// *coming due* rather than what's already happened, which is the
/// proactive value finance apps should offer at a glance.
struct WidgetSnapshot: Codable, Equatable {
    /// Currency code the user is operating in. Widget formats using this.
    var currencyCode: String

    /// Today's total spend.
    var todayTotal: Double

    /// This month's total spend across everything.
    var monthTotal: Double

    /// Sum of every active monthly budget's cap. Zero when the user has
    /// no monthly budgets. Used for an aggregate progress bar.
    var monthlyBudgetCap: Double

    /// Top monthly budgets (capped at 4). For the medium Budgets widget.
    var topBudgets: [Entry]

    /// Last 7 days of daily totals, oldest-first (so index 0 is six days
    /// ago, index 6 is today). Always exactly 7 values, zero-padded for
    /// days with no spend. Drives the sparkline on Today (small) and the
    /// lockscreen rectangular surface.
    var dailyTotals: [Double]

    /// Next recurring expenses due, sorted by due date ascending. Capped
    /// at 3 — the medium Upcoming widget renders 3 rows max. Paused
    /// rules are excluded.
    var upcomingRecurrings: [UpcomingRecurring]

    /// Top spending categories this month, sorted by amount descending.
    /// Capped at 5 — the medium Category Breakdown widget shows 4 rows.
    var categoryBreakdown: [CategorySpend]

    /// Last month's total spend. Used by the Monthly Comparison widget
    /// to show change vs current month.
    var lastMonthTotal: Double

    /// Last month's spend on the same calendar day as today. Used by
    /// the Today widget to show day-over-day comparison.
    var lastMonthSameDayTotal: Double

    /// Last month's spend from day 1 through today's day number. Used
    /// by the Monthly Comparison widget for a fair month-to-date comparison.
    var lastMonthTillDayTotal: Double

    /// When this snapshot was generated.
    var generatedAt: Date

    /// One budget summary row for the widget UI.
    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var amount: Double
        var spent: Double
        /// Hex color string; widget renders Color(hex: ...).
        var colorHex: String
        /// SF Symbol name.
        var iconKey: String
        /// True for Overall budgets — widget may render differently.
        var isOverall: Bool

        var progress: Double {
            guard amount > 0 else { return 0 }
            return spent / amount
        }
    }

    /// One upcoming recurring rule. Stripped of SwiftData ties — pure
    /// codable payload the widget extension can render without DB access.
    struct UpcomingRecurring: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var amount: Double
        var dueDate: Date
        var colorHex: String
        var iconKey: String
    }

    /// One category's spend for the month. Drives the Category Breakdown
    /// widget. Percentage is pre-computed relative to monthTotal.
    struct CategorySpend: Codable, Equatable, Identifiable {
        var id: UUID
        var name: String
        var amount: Double
        var colorHex: String
        var iconKey: String
        var percentage: Double
    }



    init(currencyCode: String, todayTotal: Double, monthTotal: Double,
         monthlyBudgetCap: Double, topBudgets: [Entry], dailyTotals: [Double],
         upcomingRecurrings: [UpcomingRecurring], categoryBreakdown: [CategorySpend],
         lastMonthTotal: Double, lastMonthSameDayTotal: Double = 0,
         lastMonthTillDayTotal: Double = 0,
         generatedAt: Date) {
        self.currencyCode = currencyCode
        self.todayTotal = todayTotal
        self.monthTotal = monthTotal
        self.monthlyBudgetCap = monthlyBudgetCap
        self.topBudgets = topBudgets
        self.dailyTotals = dailyTotals
        self.upcomingRecurrings = upcomingRecurrings
        self.categoryBreakdown = categoryBreakdown
        self.lastMonthTotal = lastMonthTotal
        self.lastMonthSameDayTotal = lastMonthSameDayTotal
        self.lastMonthTillDayTotal = lastMonthTillDayTotal
        self.generatedAt = generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currencyCode = try c.decode(String.self, forKey: .currencyCode)
        todayTotal = try c.decode(Double.self, forKey: .todayTotal)
        monthTotal = try c.decode(Double.self, forKey: .monthTotal)
        monthlyBudgetCap = try c.decode(Double.self, forKey: .monthlyBudgetCap)
        topBudgets = try c.decode([Entry].self, forKey: .topBudgets)
        dailyTotals = try c.decode([Double].self, forKey: .dailyTotals)
        upcomingRecurrings = try c.decode([UpcomingRecurring].self, forKey: .upcomingRecurrings)
        categoryBreakdown = (try? c.decode([CategorySpend].self, forKey: .categoryBreakdown)) ?? []
        lastMonthTotal = (try? c.decode(Double.self, forKey: .lastMonthTotal)) ?? 0
        lastMonthSameDayTotal = (try? c.decode(Double.self, forKey: .lastMonthSameDayTotal)) ?? 0
        lastMonthTillDayTotal = (try? c.decode(Double.self, forKey: .lastMonthTillDayTotal)) ?? 0
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
    }

    static let empty = WidgetSnapshot(
        currencyCode: "INR",
        todayTotal: 0,
        monthTotal: 0,
        monthlyBudgetCap: 0,
        topBudgets: [],
        dailyTotals: Array(repeating: 0, count: 7),
        upcomingRecurrings: [],
        categoryBreakdown: [],
        lastMonthTotal: 0,
        lastMonthSameDayTotal: 0,
        lastMonthTillDayTotal: 0,
        generatedAt: .distantPast
    )
}

// MARK: - Storage

/// Shared UserDefaults bridge between the main app and the widget extension.
///
/// Setup checklist (must be done in Xcode):
/// 1. In Signing & Capabilities for BOTH targets (main app + widget), add
///    an App Group with id `group.com.app.Tula` (must match `appGroupID`).
/// 2. Add this file's target membership to the Widget Extension target.
/// 3. Add `WidgetCenter.shared.reloadAllTimelines()` calls wherever data
///    that the widget shows is mutated (already done in `TulaApp`).
enum WidgetStorage {

    /// Must match the App Group entitlement on both targets. Update in one
    /// place when the bundle id changes.
    static let appGroupID = "group.com.app.Tula"

    /// Key under which the snapshot JSON is stored.
    private static let snapshotKey = "widget_snapshot_v1"

    /// Shared defaults backed by the App Group. Falls back to standard
    /// defaults if the group isn't configured — widget will then render
    /// the empty snapshot, which is harmless.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    /// Persist the snapshot for the widget. Safe to call frequently.
    /// Calls `synchronize()` to flush the write to disk immediately —
    /// without this, the widget extension's process may read a stale
    /// cached copy of the App Group defaults when iOS calls `getTimeline`.
    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
        defaults.synchronize()
    }

    /// Read the current snapshot, or `.empty` if nothing has been written
    /// (first launch before the main app has had a chance to refresh).
    /// Calls `synchronize()` so the widget extension process picks up
    /// writes the main app made via a different process.
    static func read() -> WidgetSnapshot {
        defaults.synchronize()
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}

