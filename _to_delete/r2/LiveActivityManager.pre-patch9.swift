import ActivityKit
import Foundation
import OSLog
import SwiftData

/// Starts, updates and ends the day's spending Live Activity.
///
/// **Idempotent by design.** There is no "first expense of the day" special
/// case and no start/update/end state machine for callers to get wrong:
/// `refresh(using:)` reads the current day from the store and reconciles
/// whatever is on screen against it. Call it after any write; calling it
/// twice is harmless.
///
/// App-side only. Live Activities can only be *started* from the app, and
/// `WidgetRefresh` — the obvious place to hook this — is compiled into the
/// share extension, where `Activity.request` is unavailable. Keeping this
/// separate avoids breaking that target.
///
/// Not `@MainActor`, for the same reason as `ExpenseWriter`: its main caller
/// is `ExpenseWriter.commit`, which is nonisolated, and a `@MainActor` callee
/// there is a compile error. The `ActivityKit` mutations that genuinely are
/// async are each wrapped in their own `Task`.
enum LiveActivityManager {

    /// User preference key, mirrored by the toggle in Reminders settings.
    static let enabledKey = "liveActivityEnabled"

    /// Defaults to on. Unlike a notification this needs no permission prompt,
    /// appears only *after* the user has logged something today, and clears
    /// itself when the day ends — it reflects work already done rather than
    /// nagging about work outstanding. The toggle exists for anyone who
    /// disagrees.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private static var systemAllows: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private static var running: [Activity<TulaSpendActivityAttributes>] {
        Activity<TulaSpendActivityAttributes>.activities
    }

    // MARK: - Reconcile

    /// Brings the Live Activity in line with today's stored data.
    ///
    /// - No expenses today, or the feature is off → any activity is ended.
    /// - Activity already running for today → updated in place.
    /// - Otherwise → stale activities ended and a fresh one requested.
    static func refresh(
        using context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        guard isEnabled, systemAllows else {
            endAll()
            return
        }

        let dayStart: Date = calendar.startOfDay(for: now)
        guard let state = snapshot(
            using: context, dayStart: dayStart, calendar: calendar
        ) else {
            // Nothing logged today — an empty activity would be clutter.
            endAll()
            return
        }

        // Anything representing a previous day is stale: the date rolls over
        // while the activity is still on the Lock Screen.
        let live: [Activity<TulaSpendActivityAttributes>] = running
        let current = live.first { $0.attributes.dayStart == dayStart }
        for activity in live where activity.attributes.dayStart != dayStart {
            end(activity)
        }

        let staleDate: Date? = calendar.date(byAdding: .day, value: 1, to: dayStart)
        let content = ActivityContent(state: state, staleDate: staleDate)

        if let current {
            Task { await current.update(content) }
            return
        }

        let code: String = UserDefaults.standard
            .string(forKey: "primaryCurrencyCode") ?? "INR"
        let attributes = TulaSpendActivityAttributes(
            currencyCode: code, dayStart: dayStart
        )

        // Failure is not actionable and must never disturb a save that already
        // succeeded — but it must be *visible*. Swallowing the error with
        // `try?` made a silent no-show indistinguishable from a wiring
        // problem, which is exactly the debugging dead end this avoids.
        //
        // The usual cause is `.visibility`: iOS only permits *starting* an
        // activity from the foreground, so calls from the background task or a
        // notification action can update an existing activity but not create
        // one. That resolves itself on the next foreground refresh.
        do {
            _ = try Activity.request(
                attributes: attributes, content: content, pushType: nil
            )
            lastStartFailure = nil
        } catch {
            lastStartFailure = String(describing: error)
            log.error("Live Activity start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Last `Activity.request` failure, for surfacing in diagnostics. Nil once
    /// an activity has started successfully.
    private(set) static var lastStartFailure: String?

    private static let log = Logger(subsystem: "com.app.Tula", category: "LiveActivity")

    /// One-line description of why nothing is on the Lock Screen right now.
    /// Read this before assuming the feature is broken.
    static func diagnosis(using context: ModelContext) -> String {
        if !isEnabled { return "Off in Settings › Notifications › Live Activity." }
        if !systemAllows {
            return "Live Activities are disabled for Tula in iOS Settings."
        }
        let dayStart = Calendar.current.startOfDay(for: .now)
        if snapshot(using: context, dayStart: dayStart, calendar: .current) == nil {
            return "Nothing logged today — the activity only appears once you log an expense."
        }
        if let lastStartFailure {
            return "Last start attempt failed: \(lastStartFailure)"
        }
        return running.isEmpty ? "Ready, but no activity running." : "Running."
    }

    /// Ends every running activity. Used when the feature is switched off and
    /// when the day closes out empty.
    static func endAll() {
        for activity in running {
            end(activity)
        }
    }

    private static func end(_ activity: Activity<TulaSpendActivityAttributes>) {
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - Snapshot

    /// Today's state, or nil when nothing has been logged yet.
    ///
    /// Written as one explicit accumulation pass rather than
    /// `Dictionary(grouping:)` chained through `filter`/`max`/`reduce`. That
    /// chain is what tripped "unable to type-check this expression in
    /// reasonable time": grouping on an optional `Category` key and inferring
    /// two untyped `reduce(0)` literals through closures gives the solver a
    /// large search space. One loop is faster to compile, single-pass at
    /// runtime, and easier to read.
    private static func snapshot(
        using context: ModelContext,
        dayStart: Date,
        calendar: Calendar
    ) -> TulaSpendActivityAttributes.ContentState? {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return nil }

        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        let expenses: [Expense] = (try? context.fetch(descriptor)) ?? []
        guard !expenses.isEmpty else { return nil }

        var total: Double = 0
        var amountByCategory: [UUID: Double] = [:]
        var categoriesByID: [UUID: Category] = [:]

        for expense in expenses {
            total += expense.amount
            guard let category = expense.category else { continue }
            let key: UUID = category.id
            amountByCategory[key, default: 0] += expense.amount
            categoriesByID[key] = category
        }

        let top: Category? = topCategory(
            amountByCategory: amountByCategory,
            categoriesByID: categoriesByID
        )

        let pace: Double? = dailyBudgetPace(
            using: context, on: dayStart, calendar: calendar
        )
        var remaining: Double?
        if let pace {
            remaining = pace - total
        }

        return TulaSpendActivityAttributes.ContentState(
            todayTotal: total,
            expenseCount: expenses.count,
            budgetRemaining: remaining,
            dailyBudget: pace,
            topCategoryName: top?.name,
            topCategoryIcon: top?.iconKey
        )
    }

    /// Highest-spending category of the day, or nil when nothing was
    /// categorised.
    private static func topCategory(
        amountByCategory: [UUID: Double],
        categoriesByID: [UUID: Category]
    ) -> Category? {
        var topID: UUID?
        var topAmount: Double = 0
        for (id, amount) in amountByCategory where amount > topAmount {
            topAmount = amount
            topID = id
        }
        guard let topID else { return nil }
        return categoriesByID[topID]
    }

    /// Daily pace from the overall (non-category-scoped) monthly budget —
    /// the same derivation `HomeView.dailyBudget` uses, so the Lock Screen and
    /// the hero card can never disagree. Nil when no overall budget is set.
    private static func dailyBudgetPace(
        using context: ModelContext,
        on day: Date,
        calendar: Calendar
    ) -> Double? {
        let descriptor = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.isActive == true }
        )
        let budgets: [Budget] = (try? context.fetch(descriptor)) ?? []
        guard let overall = budgets.first(where: { $0.category == nil }) else {
            return nil
        }
        let amount: Double = overall.amount
        guard amount > 0 else { return nil }
        guard let range = calendar.range(of: .day, in: .month, for: day),
              range.count > 0
        else { return nil }
        return amount / Double(range.count)
    }
}
