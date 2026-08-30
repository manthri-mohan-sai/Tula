import Foundation
import SwiftData

/// The single commit path for turning `ExpenseDraft` values into persisted
/// `Expense` records.
///
/// **Why this exists.** The insert → learn → save → refresh ritual was
/// hand-rolled at roughly fourteen call sites and had drifted:
/// `AddExpenseView.save()` runs learning, budget evaluation and reminder
/// refresh; `LogExpenseIntent.perform()` runs neither reminder refresh nor
/// budget evaluation. Same DRY-violation-becomes-correctness-violation
/// pattern documented in `PARSING_REWRITE_PLAN.md` §1.
///
/// **Why it matters for batches.** A batch shares one `safeSave()` and one
/// widget refresh. Multi-day catch-up writes a dozen expenses at once; the
/// per-expense pattern would cost a dozen saves and a dozen widget reloads.
///
/// Adoption is incremental — catch-up uses it now, the other call sites can
/// migrate independently.
///
/// Deliberately *not* `@MainActor`. `ModelContext` is not `Sendable`, so
/// callers already have to invoke this on the context's own actor, and every
/// sibling service the app writes through — `RecurringEngine`, `WidgetRefresh`,
/// `NotificationManager`, `UserLearningEngine` — is a plain enum. Adding
/// isolation here would make this the odd one out and force annotations onto
/// the view methods that call it.
enum ExpenseWriter {

    /// Side effects to run after the batch commits.
    struct Options {
        var learn: Bool = true
        var refreshWidgets: Bool = true
        var refreshReminder: Bool = true
        var evaluateBudgets: Bool = true
        var postSavedNotification: Bool = true

        init(
            learn: Bool = true,
            refreshWidgets: Bool = true,
            refreshReminder: Bool = true,
            evaluateBudgets: Bool = true,
            postSavedNotification: Bool = true
        ) {
            self.learn = learn
            self.refreshWidgets = refreshWidgets
            self.refreshReminder = refreshReminder
            self.evaluateBudgets = evaluateBudgets
            self.postSavedNotification = postSavedNotification
        }

        /// Backfill of past days. Budget evaluation is suppressed because
        /// `evaluateBudgetThresholds` would push "you're over budget" for a
        /// period that has already closed. The caller re-evaluates once
        /// afterwards if any backfilled date lands in the current window.
        static let backfill = Options(evaluateBudgets: false)
    }

    /// Inserts every valid draft, then runs the enabled side effects exactly
    /// once for the whole batch.
    ///
    /// Drafts failing `isValid` (no amount, or no account) are skipped rather
    /// than throwing — the callers are UI flows where a partially-filled row
    /// is an ordinary state, not an error.
    ///
    /// - Returns: the inserted expenses, in draft order.
    @discardableResult
    static func commit(
        _ drafts: [ExpenseDraft],
        source: ExpenseSource,
        in context: ModelContext,
        options: Options = Options(),
        budgets: [Budget] = []
    ) -> [Expense] {
        var created: [Expense] = []

        for draft in drafts where draft.isValid {
            guard let account = draft.account else { continue }

            let expense = Expense(
                amount: draft.amount,
                date: draft.date,
                merchant: draft.merchant,
                note: draft.note,
                source: source,
                category: draft.category,
                account: account
            )
            let raw = draft.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            expense.rawInput = raw.isEmpty ? nil : raw
            if !draft.items.isEmpty {
                expense.items = draft.items.map { LineItem(name: $0) }
            }
            context.insert(expense)

            if options.learn {
                UserLearningEngine.learn(
                    merchant: expense.merchant,
                    category: expense.category?.name,
                    amount: expense.amount,
                    hour: Calendar.current.component(.hour, from: expense.date)
                )
            }
            created.append(expense)
        }

        guard !created.isEmpty else { return [] }

        context.safeSave()

        if options.refreshWidgets {
            WidgetRefresh.refresh(using: context)
        }
        if options.refreshReminder {
            NotificationManager.refreshDailyReminder(using: context)
        }
        if options.evaluateBudgets, !budgets.isEmpty {
            let all = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
            NotificationManager.evaluateBudgetThresholds(budgets: budgets, expenses: all)
        }
        if options.postSavedNotification {
            NotificationCenter.default.post(name: .tulaExpenseSaved, object: nil)
        }

        return created
    }

    /// Deletes a previously committed batch and refreshes the same surfaces.
    /// Used by undo affordances so the toast's action mirrors the commit.
    static func revert(_ expenses: [Expense], in context: ModelContext) {
        guard !expenses.isEmpty else { return }
        for expense in expenses {
            context.delete(expense)
        }
        context.safeSave()
        WidgetRefresh.refresh(using: context)
    }
}
