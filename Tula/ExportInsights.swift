//
//  ExportInsights.swift
//  Tula
//
//  Created by Mohan Manthri on 28/05/26.
//


import Foundation

// MARK: - Export Insights

/// Pre-computed summary data used by both the PDF and CSV exporters.
/// Computing this once and passing it to the renderers keeps the two
/// output formats consistent — "total" and "top category" mean the same
/// thing across CSV and PDF.
struct ExportInsights {

    // MARK: - Headline

    let total: Double
    let count: Int

    /// Per-expense average. Zero when there are no expenses.
    let averagePerExpense: Double

    /// Effective daily average — total divided by the number of days the
    /// range spans (or expenses span, whichever is smaller). Gives a
    /// stable rate that doesn't get distorted by "all time" ranges that
    /// include many empty pre-tracking days.
    let averagePerDay: Double

    /// Largest single expense in the period. Helps users spot outliers
    /// without scrolling the full transaction list.
    let largestExpense: ExpenseSummary?

    /// Day with the highest single-day total — answers "what was my
    /// biggest spending day this month?"
    let biggestDay: (day: Date, total: Double)?

    // MARK: - Breakdowns

    /// Sorted by amount desc; full list, not just top N. PDF will cap
    /// for layout; CSV may include all.
    let categoryBreakdown: [CategoryStat]

    /// Sorted by amount desc; full list.
    let merchantBreakdown: [MerchantStat]

    /// Daily totals across the period, in chronological order.
    /// Empty days are included with `total: 0` to keep the daily-spend
    /// chart honest about gaps.
    let dailyTotals: [(day: Date, total: Double)]

    /// Effective start of the data window (max of range start and earliest expense).
    /// Used in headers to show the actual covered period rather than e.g.
    /// "all time" which is meaningless.
    let effectiveStart: Date?
    let effectiveEnd: Date?

    // MARK: - Builder

    static func compute(
        expenses: [Expense],
        rangeStart: Date,
        rangeEnd: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ExportInsights {
        guard !expenses.isEmpty else {
            return ExportInsights(
                total: 0, count: 0,
                averagePerExpense: 0, averagePerDay: 0,
                largestExpense: nil, biggestDay: nil,
                categoryBreakdown: [], merchantBreakdown: [],
                dailyTotals: [],
                effectiveStart: nil, effectiveEnd: nil
            )
        }

        let total = expenses.reduce(0) { $0 + $1.amount }
        let count = expenses.count
        let avgPerExpense = total / Double(count)

        // Effective window — clamp distant-past to earliest expense and
        // distant-future to either now or the latest expense (whichever
        // is later). Without this an "All Time" export would report a
        // ridiculous "0.5 per day" because we'd divide by years.
        let dates = expenses.map { $0.date }
        let earliest = dates.min() ?? rangeStart
        let latest = dates.max() ?? rangeEnd
        let effStart = max(rangeStart, calendar.startOfDay(for: earliest))
        let effEnd = min(rangeEnd, calendar.startOfDay(for: latest).addingTimeInterval(86_400))

        let dayCount = max(1, calendar.dateComponents([.day], from: effStart, to: effEnd).day ?? 1)
        let avgPerDay = total / Double(dayCount)

        // Largest expense
        let largest = expenses.max(by: { $0.amount < $1.amount })
            .map { ExpenseSummary(
                date: $0.date,
                amount: $0.amount,
                label: $0.merchant ?? $0.category?.name ?? "Spend",
                category: $0.category?.name,
                colorHex: $0.category?.colorHex ?? "#D97706"
            ) }

        // Category breakdown — sum + count by category
        var catTotals: [UUID: CategoryStat] = [:]
        for e in expenses {
            guard let cat = e.category else { continue }
            if var existing = catTotals[cat.id] {
                existing.amount += e.amount
                existing.count += 1
                catTotals[cat.id] = existing
            } else {
                catTotals[cat.id] = CategoryStat(
                    name: cat.name,
                    colorHex: cat.colorHex,
                    iconKey: cat.iconKey,
                    amount: e.amount,
                    count: 1
                )
            }
        }
        let uncategorized = expenses.filter { $0.category == nil }
        if !uncategorized.isEmpty {
            catTotals[UUID()] = CategoryStat(
                name: "Uncategorized",
                colorHex: "#9CA3AF",
                iconKey: "questionmark.circle",
                amount: uncategorized.reduce(0) { $0 + $1.amount },
                count: uncategorized.count
            )
        }
        let categoryBreakdown = Array(catTotals.values).sorted { $0.amount > $1.amount }

        // Merchant breakdown
        var merchTotals: [String: MerchantStat] = [:]
        for e in expenses {
            guard let m = e.merchant?.trimmingCharacters(in: .whitespaces), !m.isEmpty else { continue }
            if var existing = merchTotals[m] {
                existing.amount += e.amount
                existing.count += 1
                merchTotals[m] = existing
            } else {
                merchTotals[m] = MerchantStat(
                    name: m,
                    amount: e.amount,
                    count: 1
                )
            }
        }
        let merchantBreakdown = Array(merchTotals.values).sorted { $0.amount > $1.amount }

        // Daily totals — include empty days so the bar chart is honest
        // about gaps in spending. Cap at 60 days of history to keep
        // chart legible; longer ranges roll up to weekly buckets
        // elsewhere (not implemented yet — for now we still produce
        // daily, the chart caps display).
        var daily: [(Date, Double)] = []
        var cursor = calendar.startOfDay(for: effStart)
        let end = calendar.startOfDay(for: effEnd)
        let dailyMap: [Date: Double] = Dictionary(
            grouping: expenses,
            by: { calendar.startOfDay(for: $0.date) }
        ).mapValues { exps in exps.reduce(0) { $0 + $1.amount } }
        while cursor < end {
            daily.append((cursor, dailyMap[cursor] ?? 0))
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? end
        }
        let biggest = daily.max(by: { $0.1 < $1.1 })
            .map { (day: $0.0, total: $0.1) }
            .flatMap { $0.total > 0 ? $0 : nil }

        return ExportInsights(
            total: total,
            count: count,
            averagePerExpense: avgPerExpense,
            averagePerDay: avgPerDay,
            largestExpense: largest,
            biggestDay: biggest,
            categoryBreakdown: categoryBreakdown,
            merchantBreakdown: merchantBreakdown,
            dailyTotals: daily,
            effectiveStart: effStart,
            effectiveEnd: effEnd
        )
    }
}

// MARK: - Supporting types

struct CategoryStat {
    let name: String
    let colorHex: String
    let iconKey: String
    var amount: Double
    var count: Int
}

struct MerchantStat {
    let name: String
    var amount: Double
    var count: Int
}

struct ExpenseSummary {
    let date: Date
    let amount: Double
    let label: String
    let category: String?
    let colorHex: String
}