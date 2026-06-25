import Foundation
import SwiftData

/// Re-anchors an account's balance to a user-supplied real value by
/// recording a `BalanceAdjustment`. The arithmetic (`delta`) is a pure
/// function so it can be reasoned about and verified without SwiftData.
enum BalanceReconciler {

    /// The signed correction needed to move `current` to `target`.
    static func delta(target: Double, current: Double) -> Double {
        target - current
    }

    /// Reconcile `account` to `target`. Creates and inserts a
    /// `BalanceAdjustment` for the gap, unless the balance already matches
    /// (within a cent), in which case it is a no-op and returns nil.
    ///
    /// The caller is responsible for saving the context and refreshing
    /// widgets — keeping side effects at the call site mirrors how the
    /// app's other write paths (TransferFormView, HomeView) work.
    @discardableResult
    static func reconcile(account: Account,
                          to target: Double,
                          source: AdjustmentSource,
                          date: Date = .now,
                          note: String? = nil,
                          in context: ModelContext) -> BalanceAdjustment? {
        let d = delta(target: target, current: account.derivedBalance)
        guard abs(d) >= 0.01 else { return nil }

        let adjustment = BalanceAdjustment(
            delta: d,
            resultingBalance: target,
            account: account,
            date: date,
            source: source,
            note: note
        )
        context.insert(adjustment)
        return adjustment
    }
}
