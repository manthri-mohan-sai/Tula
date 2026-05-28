import Foundation

// MARK: - Widget Snapshot

/// Compact JSON-codable snapshot the main app writes to App Group storage
/// so the widget extension can render without database access. Refreshed
/// on every app foreground transition (see `TulaApp.refreshWidgetSnapshot`).
///
/// Designed to stay small (a few KB at most) — we only include what any
/// active widget surface needs: today total, month total, top monthly
/// budgets with their progress.
struct WidgetSnapshot: Codable, Equatable {
    /// Currency code the user is operating in. Widget formats using this.
    var currencyCode: String

    /// Today's total spend.
    var todayTotal: Double

    /// This month's total spend across everything.
    var monthTotal: Double

    /// Sum of every active monthly budget's cap, when any exist. Used to
    /// render an aggregate progress bar on the small widget. Zero when
    /// the user has no monthly budgets.
    var monthlyBudgetCap: Double

    /// Top monthly budgets (capped at 4). For the medium widget.
    var topBudgets: [Entry]

    /// Most recent expenses for the Quick Log widget. Capped at 4.
    var recentExpenses: [RecentExpense]

    /// When this snapshot was generated. Widget shows "as of N min ago"
    /// if it's stale beyond a threshold (currently only used internally).
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

    /// One recent-expense row for the Quick Log widget. Stripped of
    /// SwiftData ties — just the bits the widget renders.
    struct RecentExpense: Codable, Equatable, Identifiable {
        var id: UUID
        var amount: Double
        var date: Date
        /// Best label: merchant name if present, else category name, else "Spend".
        var label: String
        /// Category color hex (or brand fallback if no category).
        var colorHex: String
        /// Category SF Symbol (or generic icon if no category).
        var iconKey: String
    }

    static let empty = WidgetSnapshot(
        currencyCode: "INR",
        todayTotal: 0,
        monthTotal: 0,
        monthlyBudgetCap: 0,
        topBudgets: [],
        recentExpenses: [],
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
    static func write(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    /// Read the current snapshot, or `.empty` if nothing has been written
    /// (first launch before the main app has had a chance to refresh).
    static func read() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }
}
