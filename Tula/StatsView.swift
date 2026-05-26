import SwiftUI
import SwiftData
import Charts

/// Monthly statistics — total spent, category breakdown, daily trend.
/// Swipe left/right to navigate between months.
struct StatsView: View {
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    /// First day of the currently-displayed month.
    @State private var monthAnchor: Date = {
        Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
    }()

    // MARK: - Derived

    private var monthExpenses: [Expense] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        return allExpenses.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    private var totalThisPeriod: Double {
        monthExpenses.reduce(0) { $0 + $1.amount }
    }

    private var categoryBreakdown: [(category: Category, total: Double)] {
        var totals: [UUID: (Category, Double)] = [:]
        for expense in monthExpenses {
            guard let cat = expense.category else { continue }
            if let existing = totals[cat.id] {
                totals[cat.id] = (cat, existing.1 + expense.amount)
            } else {
                totals[cat.id] = (cat, expense.amount)
            }
        }
        return totals.values
            .sorted { $0.1 > $1.1 }
            .map { (category: $0.0, total: $0.1) }
    }

    private var dailyTrend: [(day: Date, total: Double)] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        var data: [(Date, Double)] = []
        var current = interval.start
        while current < interval.end {
            let next = cal.date(byAdding: .day, value: 1, to: current) ?? interval.end
            let total = monthExpenses
                .filter { $0.date >= current && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            data.append((current, total))
            current = next
        }
        return data
    }

    private var isCurrentMonth: Bool {
        let cal = Calendar.current
        return cal.isDate(monthAnchor, equalTo: .now, toGranularity: .month)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    monthSelector
                    summaryCard
                    if !dailyTrend.isEmpty {
                        dailyTrendCard
                    }
                    if !categoryBreakdown.isEmpty {
                        categoryBreakdownCard
                    } else if monthExpenses.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Spacing.xxl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Stats")
        }
    }

    // MARK: - Month Selector

    private var monthSelector: some View {
        HStack(spacing: Spacing.lg) {
            Button {
                Haptics.tap()
                withAnimation(AppAnimation.gentle) {
                    monthAnchor = Calendar.current.date(byAdding: .month, value: -1, to: monthAnchor) ?? monthAnchor
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.tulaCardSurface))
            }
            .buttonStyle(.plain)

            VStack(spacing: 2) {
                Text(monthAnchor, format: .dateTime.month(.wide).year())
                    .font(.headline)
                if !isCurrentMonth {
                    Button("Jump to current") {
                        Haptics.tap()
                        withAnimation(AppAnimation.gentle) {
                            monthAnchor = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now
                        }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.tulaBrandFallback)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                Haptics.tap()
                withAnimation(AppAnimation.gentle) {
                    monthAnchor = Calendar.current.date(byAdding: .month, value: 1, to: monthAnchor) ?? monthAnchor
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.tulaCardSurface))
                    .opacity(isCurrentMonth ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentMonth)
        }
    }

    // MARK: - Summary Card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Total Spent")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Currency.format(totalThisPeriod, code: currencyCode))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("\(monthExpenses.count) transaction\(monthExpenses.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.tulaBrandFallback.opacity(0.10),
                            Color.tulaBrandFallback.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    // MARK: - Daily Trend

    private var dailyTrendCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Daily Trend")

            Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                Chart {
                    ForEach(dailyTrend, id: \.day) { item in
                        AreaMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Spent", item.total)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.tulaBrandFallback.opacity(0.5),
                                         Color.tulaBrandFallback.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Day", item.day, unit: .day),
                            y: .value("Spent", item.total)
                        )
                        .foregroundStyle(Color.tulaBrandFallback)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                        AxisValueLabel(format: .dateTime.day())
                            .font(.caption2)
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.tertiary.opacity(0.3))
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Currency.compact(v, code: currencyCode))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
    }

    // MARK: - Category Breakdown

    private var categoryBreakdownCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "By Category")

            Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                VStack(spacing: Spacing.lg) {
                    ForEach(Array(categoryBreakdown.enumerated()), id: \.element.category.id) { _, item in
                        categoryBar(category: item.category, amount: item.total)
                    }
                }
            }
        }
    }

    private func categoryBar(category: Category, amount: Double) -> some View {
        let color = Color(hex: category.colorHex)
        let fraction = totalThisPeriod > 0 ? amount / totalThisPeriod : 0
        let percent = Int((fraction * 100).rounded())

        return VStack(spacing: 6) {
            HStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: category.iconKey)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
                Text(category.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Currency.format(amount, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("\(percent)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.12))
                        .frame(height: 6)
                    Capsule()
                        .fill(color)
                        .frame(width: max(4, geo.size.width * fraction), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "chart.pie")
                    .font(.title)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: 4) {
                Text("No data for this month")
                    .font(.subheadline.weight(.semibold))
                Text("Log expenses to see them appear here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }
}
