import ActivityKit
import Foundation

/// Live Activity contract for the day's spending.
///
/// Compiled into **both** the app and the widget extension — the app calls
/// `Activity.request` with these attributes, the widget renders them. That
/// dual membership is why this file deliberately imports nothing from the app:
/// no SwiftData models, no `Theme`, no `Budget`. Every value is a plain
/// `Codable` scalar resolved on the app side before the update is pushed.
///
/// Adding a stored property to `ContentState` is a breaking change for any
/// activity already running on a user's device — ActivityKit decodes state
/// pushed by an older build. Add new fields as optionals.
struct TulaSpendActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        /// Total spent today, in `currencyCode`.
        var todayTotal: Double
        var expenseCount: Int
        /// Remaining daily budget pace. Nil when no overall budget is set —
        /// the view then hides the budget line entirely rather than showing
        /// a meaningless zero.
        var budgetRemaining: Double?
        /// Daily budget pace, for the progress bar's denominator.
        var dailyBudget: Double?
        var topCategoryName: String?
        /// SF Symbol name, taken from the category's `iconKey`.
        var topCategoryIcon: String?

        /// What the daily budget says should have been spent by *now*.
        ///
        /// This is what makes the activity worth glancing at. A bare running
        /// total is near-useless in the morning (always ~0) and unactionable
        /// in the evening (is ₹1,240 good or bad?). Compared against expected
        /// pace, the same number becomes a verdict at every hour of the day.
        ///
        /// Resolved app-side on each refresh — see
        /// `LiveActivityManager.expectedSpend(by:)`. Optional so an activity
        /// started by an older build still decodes.
        var expectedByNow: Double?

        // MARK: - Derived

        /// Fraction of the daily pace consumed, clamped to 0...1 for the bar.
        /// Values above 1 are reported by `isOverBudget` instead, so the bar
        /// never overflows its track.
        var budgetFraction: Double {
            guard let dailyBudget, dailyBudget > 0 else { return 0 }
            return clampedFraction(todayTotal / dailyBudget)
        }

        /// Where the pace marker sits on the same track.
        var expectedFraction: Double? {
            guard let dailyBudget, dailyBudget > 0, let expectedByNow
            else { return nil }
            return clampedFraction(expectedByNow / dailyBudget)
        }

        var isOverBudget: Bool {
            guard let dailyBudget, dailyBudget > 0 else { return false }
            return todayTotal > dailyBudget
        }

        /// Positive when spending is ahead of where it should be by now.
        var paceDelta: Double? {
            guard let expectedByNow else { return nil }
            return todayTotal - expectedByNow
        }

        /// True once spending has run meaningfully ahead of the day's pace.
        ///
        /// The 5% deadband stops the verdict flickering between "on track" and
        /// "ahead" on every small expense, which would make the colour change
        /// read as noise rather than signal.
        var isAheadOfPace: Bool {
            guard let paceDelta, let dailyBudget, dailyBudget > 0 else { return false }
            return paceDelta > dailyBudget * 0.05
        }

        private func clampedFraction(_ value: Double) -> Double {
            if value < 0 { return 0 }
            if value > 1 { return 1 }
            return value
        }
    }

    /// ISO currency code, captured once when the activity starts.
    var currencyCode: String
    /// Start of the day this activity represents. The manager ends and
    /// restarts the activity when the date rolls over rather than mutating
    /// this, so a stale activity is always detectable.
    var dayStart: Date
}
