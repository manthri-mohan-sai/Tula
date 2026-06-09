import Foundation
import SwiftData
import WidgetKit

// MARK: - Widget Snapshot Refresh

/// Centralized widget-snapshot refresh logic. Called on app foreground,
/// after every expense/transfer save, and from the share extension after
/// it commits an expense. Stateless enum so any save site can call it
/// with a single line — no dependency on the app struct or environment.
///
/// The share extension calls `refresh(using:upcomingRecurrings:)` with
/// the existing snapshot's upcoming list (unchanged by adding an expense)
/// so it never needs to import RecurringEngine.
enum WidgetRefresh {

    /// Rebuilds the widget snapshot from current data and writes it to the
    /// App Group. Cheap enough to call after every save — ~milliseconds
    /// for typical expense counts. Triggers a WidgetCenter reload at the
    /// end so iOS pulls a fresh timeline immediately.
    ///
    /// - Parameters:
    ///   - context: A ModelContext backed by the shared App Group store.
    ///   - upcomingRecurrings: Pre-built upcoming recurrings to embed in the
    ///     snapshot. Defaults to `[]`. Pass the result of
    ///     `buildUpcomingRecurrings(in:)` from the main app when available;
    ///     the share extension passes the existing snapshot's upcoming list
    ///     (unchanged by adding a one-off expense).
    static func refresh(
        using context: ModelContext,
        upcomingRecurrings: [WidgetSnapshot.UpcomingRecurring] = []
    ) {
        let calendar = Calendar.current
        let now = Date.now

        // Pull expenses for this month — sufficient for both today and month totals.
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return }
        let dayStart = calendar.startOfDay(for: now)

        let monthExpenseFetch = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= monthStart }
        )
        let monthExpenses = (try? context.fetch(monthExpenseFetch)) ?? []
        let monthTotal = monthExpenses.reduce(0) { $0 + $1.amount }
        let todayTotal = monthExpenses
            .filter { $0.date >= dayStart }
            .reduce(0) { $0 + $1.amount }

        // Active budgets — all periods, all scopes.
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.isActive == true }
        )
        let allBudgets = (try? context.fetch(budgetFetch)) ?? []

        // Mirror BudgetsView: separate Overall from Category budgets.
        let overallBudget   = allBudgets.first { $0.category == nil }
        let categoryBudgets = allBudgets.filter { $0.category != nil }

        // Same weekly/yearly → monthly conversion as BudgetsView.monthlyEquivalent.
        func monthlyEquiv(_ b: Budget) -> Double {
            switch b.period {
            case .weekly:  return b.amount * (52.0 / 12.0)
            case .monthly: return b.amount
            case .yearly:  return b.amount / 12.0
            }
        }

        let categoryMonthlySum = categoryBudgets.reduce(0) { $0 + monthlyEquiv($1) }

        // displayTotal = max(overall, categorySum) — mirrors BudgetsView.overallDisplayTotal.
        let totalCap = max(overallBudget?.amount ?? 0, categoryMonthlySum)

        // topBudgets: category rows only — Overall is already the aggregate cap.
        let entries: [WidgetSnapshot.Entry] = categoryBudgets
            .map { b -> WidgetSnapshot.Entry in
                let spent = b.spent(in: monthExpenses)
                return WidgetSnapshot.Entry(
                    id: b.id,
                    name: b.displayName,
                    amount: b.amount,
                    spent: spent,
                    colorHex: b.category?.colorHex ?? "#D97706",
                    iconKey: b.category?.iconKey ?? "infinity",
                    isOverall: false
                )
            }
            .sorted { $0.progress > $1.progress }
            .prefix(4)
            .map { $0 }

        // 7-day sparkline (oldest-first).
        var dailyTotals: [Double] = Array(repeating: 0, count: 7)
        for daysAgo in 0..<7 {
            guard let start = calendar.date(byAdding: .day, value: -daysAgo, to: dayStart),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let total = monthExpenses
                .filter { $0.date >= start && $0.date < end }
                .reduce(0) { $0 + $1.amount }
            dailyTotals[6 - daysAgo] = total
        }

        // Category breakdown — group this month's expenses by category.
        let categoryBreakdown: [WidgetSnapshot.CategorySpend] = {
            var totals: [UUID: (category: (name: String, colorHex: String, iconKey: String), amount: Double)] = [:]
            for expense in monthExpenses {
                guard let cat = expense.category else { continue }
                let key = cat.id
                if var existing = totals[key] {
                    existing.amount += expense.amount
                    totals[key] = existing
                } else {
                    totals[key] = (
                        category: (name: cat.name, colorHex: cat.colorHex, iconKey: cat.iconKey),
                        amount: expense.amount
                    )
                }
            }
            return totals
                .map { key, val in
                    WidgetSnapshot.CategorySpend(
                        id: key,
                        name: val.category.name,
                        amount: val.amount,
                        colorHex: val.category.colorHex,
                        iconKey: val.category.iconKey,
                        percentage: monthTotal > 0 ? val.amount / monthTotal : 0
                    )
                }
                .sorted { $0.amount > $1.amount }
                .prefix(5)
                .map { $0 }
        }()

        // Last month's data for comparison widgets.
        let prevMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart)
        let lastMonthExpenses: [Expense] = {
            guard let prevMonthStart else { return [] }
            let fetch = FetchDescriptor<Expense>(
                predicate: #Predicate { $0.date >= prevMonthStart && $0.date < monthStart }
            )
            return (try? context.fetch(fetch)) ?? []
        }()
        let lastMonthTotal = lastMonthExpenses.reduce(0) { $0 + $1.amount }

        // Same calendar day last month.
        let lastMonthSameDayTotal: Double = {
            guard let sameDay = calendar.date(byAdding: .month, value: -1, to: dayStart),
                  let sameDayEnd = calendar.date(byAdding: .day, value: 1, to: sameDay) else { return 0 }
            return lastMonthExpenses
                .filter { $0.date >= sameDay && $0.date < sameDayEnd }
                .reduce(0) { $0 + $1.amount }
        }()

        // Last month from day 1 through today's day number (month-to-date).
        let lastMonthTillDayTotal: Double = {
            guard let prevMonthStart,
                  let cutoff = calendar.date(
                      byAdding: .day,
                      value: calendar.component(.day, from: now),
                      to: prevMonthStart
                  ) else { return 0 }
            return lastMonthExpenses
                .filter { $0.date >= prevMonthStart && $0.date < cutoff }
                .reduce(0) { $0 + $1.amount }
        }()

        let primaryCurrencyCode = UserDefaults.standard
            .string(forKey: "primaryCurrencyCode") ?? "INR"

        let snapshot = WidgetSnapshot(
            currencyCode: primaryCurrencyCode,
            todayTotal: todayTotal,
            monthTotal: monthTotal,
            monthlyBudgetCap: totalCap,
            topBudgets: entries,
            dailyTotals: dailyTotals,
            upcomingRecurrings: upcomingRecurrings,
            categoryBreakdown: categoryBreakdown,
            lastMonthTotal: lastMonthTotal,
            lastMonthSameDayTotal: lastMonthSameDayTotal,
            lastMonthTillDayTotal: lastMonthTillDayTotal,
            generatedAt: now
        )

        WidgetStorage.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
