import SwiftUI
import SwiftData
import Charts

// MARK: - Period

/// Time window for stats. Apple Health convention — three meaningful periods
/// that cover the questions users actually ask of their spending data.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, sixMonths

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .sixMonths: return "6M"
        }
    }
}

// MARK: - View

struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @PrimaryCurrency private var currencyCode

    @State private var period: StatsPeriod = .month

    /// 0 = current period, -1 = previous, etc. Reset to 0 when period changes.
    @State private var periodOffset: Int = 0

    // MARK: - Period Math

    /// Returns the date range for the current period at the current offset.
    private var currentRange: DateInterval {
        rangeFor(period: period, offset: periodOffset)
    }

    private var previousRange: DateInterval {
        rangeFor(period: period, offset: periodOffset - 1)
    }

    private func rangeFor(period: StatsPeriod, offset: Int) -> DateInterval {
        let cal = Calendar.current
        switch period {
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
            let shifted = cal.date(byAdding: .weekOfYear, value: offset, to: start) ?? start
            return cal.dateInterval(of: .weekOfYear, for: shifted) ?? DateInterval(start: shifted, end: shifted)
        case .month:
            let start = cal.dateInterval(of: .month, for: .now)?.start ?? .now
            let shifted = cal.date(byAdding: .month, value: offset, to: start) ?? start
            return cal.dateInterval(of: .month, for: shifted) ?? DateInterval(start: shifted, end: shifted)
        case .sixMonths:
            // Use anchored 6-month window — last full 6 months from current.
            let monthStart = cal.dateInterval(of: .month, for: .now)?.start ?? .now
            let shiftedStart = cal.date(byAdding: .month, value: offset * 6 - 5, to: monthStart) ?? monthStart
            let shiftedEnd = cal.date(byAdding: .month, value: 1, to: cal.date(byAdding: .month, value: offset * 6, to: monthStart) ?? monthStart) ?? monthStart
            return DateInterval(start: shiftedStart, end: shiftedEnd)
        }
    }

    private var rangeLabel: String {
        let start = currentRange.start
        let end = currentRange.end.addingTimeInterval(-1)   // inclusive end
        let cal = Calendar.current
        switch period {
        case .week:
            // "May 13 – 19" or "Apr 28 – May 4"
            let sameMonth = cal.isDate(start, equalTo: end, toGranularity: .month)
            if sameMonth {
                let monthDay = start.formatted(.dateTime.month(.abbreviated).day())
                let endDay = end.formatted(.dateTime.day())
                return "\(monthDay) – \(endDay)"
            } else {
                let startStr = start.formatted(.dateTime.month(.abbreviated).day())
                let endStr = end.formatted(.dateTime.month(.abbreviated).day())
                return "\(startStr) – \(endStr)"
            }
        case .month:
            return start.formatted(.dateTime.month(.wide).year())
        case .sixMonths:
            let startStr = start.formatted(.dateTime.month(.abbreviated))
            let endStr = end.formatted(.dateTime.month(.abbreviated).year())
            return "\(startStr) – \(endStr)"
        }
    }

    private var isCurrentPeriod: Bool { periodOffset == 0 }

    // MARK: - Derived Stats

    private var rangeExpenses: [Expense] {
        let range = currentRange
        return allExpenses.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var previousRangeExpenses: [Expense] {
        let range = previousRange
        return allExpenses.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var totalThisPeriod: Double {
        rangeExpenses.reduce(0) { $0 + $1.amount }
    }

    private var totalPreviousPeriod: Double {
        previousRangeExpenses.reduce(0) { $0 + $1.amount }
    }

    /// Fair like-for-like comparison: only count previous period up to the
    /// same elapsed fraction. Avoids "we're behind!" panic on day 2 of a month.
    private var trendVsPrevious: Double? {
        guard isCurrentPeriod else {
            // For historical periods, full-period comparison is fine.
            guard totalPreviousPeriod > 0 else { return nil }
            return (totalThisPeriod - totalPreviousPeriod) / totalPreviousPeriod
        }
        let elapsed = Date.now.timeIntervalSince(currentRange.start)
        let total = currentRange.end.timeIntervalSince(currentRange.start)
        let fraction = max(0, min(1, elapsed / total))
        let cap = previousRange.start.addingTimeInterval(total * fraction)
        let comparable = previousRangeExpenses.filter { $0.date < cap }.reduce(0) { $0 + $1.amount }
        guard comparable > 0 else { return nil }
        return (totalThisPeriod - comparable) / comparable
    }

    private var transactionCount: Int { rangeExpenses.count }

    private var averagePerDay: Double {
        let cal = Calendar.current
        let days = max(1, cal.dateComponents([.day], from: currentRange.start, to: currentRange.end).day ?? 1)
        let elapsedDays: Int
        if isCurrentPeriod {
            elapsedDays = min(days, max(1, (cal.dateComponents([.day], from: currentRange.start, to: .now).day ?? 0) + 1))
        } else {
            elapsedDays = days
        }
        return totalThisPeriod / Double(elapsedDays)
    }

    private var topCategoryItem: (category: Category, amount: Double)? {
        categoryBreakdown.first
    }

    private var biggestDay: (date: Date, amount: Double)? {
        let grouped = Dictionary(grouping: rangeExpenses) {
            Calendar.current.startOfDay(for: $0.date)
        }
        let totals = grouped.map { (date: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }
        return totals.max(by: { $0.amount < $1.amount })
    }

    private var categoryBreakdown: [(category: Category, amount: Double)] {
        var totals: [UUID: (Category, Double)] = [:]
        for expense in rangeExpenses {
            guard let cat = expense.category else { continue }
            if let existing = totals[cat.id] {
                totals[cat.id] = (cat, existing.1 + expense.amount)
            } else {
                totals[cat.id] = (cat, expense.amount)
            }
        }
        return totals.values
            .sorted { $0.1 > $1.1 }
            .map { (category: $0.0, amount: $0.1) }
    }

    private var topMerchants: [(name: String, count: Int, amount: Double)] {
        let withMerchants = rangeExpenses.compactMap { e -> (String, Double)? in
            guard let m = e.merchant, !m.isEmpty else { return nil }
            return (m, e.amount)
        }
        let grouped = Dictionary(grouping: withMerchants, by: { $0.0 })
        let aggregated = grouped.map { (name: $0.key,
                                        count: $0.value.count,
                                        amount: $0.value.reduce(0) { $0 + $1.1 }) }
        return Array(aggregated.sorted { $0.amount > $1.amount }.prefix(5))
    }

    /// Chart data — granularity adapts to period.
    private var chartData: [(label: Date, total: Double)] {
        let cal = Calendar.current
        let unit: Calendar.Component = (period == .sixMonths) ? .month : .day
        var data: [(Date, Double)] = []
        var current = currentRange.start
        while current < currentRange.end {
            let next = cal.date(byAdding: unit, value: 1, to: current) ?? currentRange.end
            let total = rangeExpenses
                .filter { $0.date >= current && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            data.append((current, total))
            current = next
        }
        return data
    }

    private var hasAnySpend: Bool { totalThisPeriod > 0 }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    periodPicker
                    periodNavigator
                    heroCard
                    if hasAnySpend {
                        insightGrid
                        chartCard
                        if !categoryBreakdown.isEmpty { categoryBreakdownCard }
                        if !topMerchants.isEmpty { topMerchantsCard }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Spacing.xxl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Stats")
            .onChange(of: period) { _, _ in
                Haptics.selection()
                withAnimation(AppAnimation.gentle) {
                    periodOffset = 0
                }
            }
        }
    }

    // MARK: - Period Picker

    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(StatsPeriod.allCases) { p in
                Text(p.shortLabel).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Period Navigator

    private var periodNavigator: some View {
        HStack(spacing: Spacing.md) {
            navButton(icon: "chevron.left", enabled: true) {
                withAnimation(AppAnimation.gentle) {
                    periodOffset -= 1
                }
            }

            VStack(spacing: 2) {
                Text(rangeLabel)
                    .font(.headline)
                    .contentTransition(.numericText())
                if !isCurrentPeriod {
                    Button {
                        Haptics.tap()
                        withAnimation(AppAnimation.gentle) {
                            periodOffset = 0
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.left")
                                .font(.caption2.weight(.bold))
                            Text("Current")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Color.tulaBrandFallback)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            // Reserve space so the navigator doesn't jump when "Current" button appears
            .frame(minHeight: 32)

            navButton(icon: "chevron.right", enabled: !isCurrentPeriod) {
                withAnimation(AppAnimation.gentle) {
                    periodOffset += 1
                }
            }
        }
    }

    private func navButton(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(enabled ? Color.primary : Color(uiColor: .tertiaryLabel))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.tulaCardSurface)
                        .opacity(enabled ? 1 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text("Total spent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let trend = trendVsPrevious {
                    trendBadge(trend)
                }
            }

            Text(Currency.format(totalThisPeriod, code: currencyCode))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText())

            if hasAnySpend {
                HStack(spacing: Spacing.xs) {
                    Text(Currency.format(averagePerDay, code: currencyCode))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("avg / day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.tulaBrandFallback.opacity(0.12),
                            Color.tulaBrandFallback.opacity(0.04)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private func trendBadge(_ trend: Double) -> some View {
        let isUp = trend > 0
        let color: Color = isUp ? .red : .green
        let percent = Int(abs(trend * 100).rounded())
        return HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.bold))
            Text("\(percent)%")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    // MARK: - Insight Grid (2x2)

    private var insightGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.md),
            GridItem(.flexible(), spacing: Spacing.md),
        ]
        return LazyVGrid(columns: columns, spacing: Spacing.md) {
            insightCard(
                label: "Top Category",
                value: topCategoryItem?.category.name ?? "—",
                detail: topCategoryItem.map { Currency.format($0.amount, code: currencyCode) } ?? "",
                icon: topCategoryItem?.category.iconKey ?? "circle.dashed",
                color: topCategoryItem.map { Color(hex: $0.category.colorHex) } ?? .gray
            )
            insightCard(
                label: "Biggest Day",
                value: biggestDay.map { Currency.format($0.amount, code: currencyCode) } ?? "—",
                detail: biggestDay.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) } ?? "",
                icon: "flame.fill",
                color: .orange
            )
            insightCard(
                label: "Per Day",
                value: Currency.format(averagePerDay, code: currencyCode),
                detail: isCurrentPeriod ? "so far" : "average",
                icon: "calendar",
                color: .blue
            )
            insightCard(
                label: "Transactions",
                value: "\(transactionCount)",
                detail: transactionCount == 1 ? "logged" : "logged",
                icon: "list.bullet",
                color: .purple
            )
        }
    }

    private func insightCard(label: String, value: String, detail: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Image(systemName: icon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color)
                    .frame(width: 18, height: 18)
            }

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .frame(minHeight: 96)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: chartSectionTitle)

            Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                if period == .sixMonths {
                    barChart
                } else {
                    areaChart
                }
            }
        }
    }

    private var chartSectionTitle: String {
        switch period {
        case .week: return "Daily Trend"
        case .month: return "Daily Trend"
        case .sixMonths: return "Monthly Trend"
        }
    }

    private var areaChart: some View {
        Chart {
            ForEach(chartData, id: \.label) { item in
                AreaMark(
                    x: .value("Day", item.label, unit: .day),
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
                    x: .value("Day", item.label, unit: .day),
                    y: .value("Spent", item.total)
                )
                .foregroundStyle(Color.tulaBrandFallback)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 4)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Currency.compact(v, code: currencyCode))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 180)
    }

    private var barChart: some View {
        Chart {
            ForEach(chartData, id: \.label) { item in
                BarMark(
                    x: .value("Month", item.label, unit: .month),
                    y: .value("Spent", item.total),
                    width: .ratio(0.6)
                )
                .foregroundStyle(Color.tulaBrandFallback.gradient)
                .cornerRadius(6)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Currency.compact(v, code: currencyCode))
                            .font(.caption2)
                    }
                }
            }
        }
        .frame(height: 180)
    }

    // MARK: - Category Breakdown

    private var categoryBreakdownCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "By Category")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(Array(categoryBreakdown.enumerated()), id: \.element.category.id) { index, item in
                        categoryRow(item.category, amount: item.amount)
                        if index != categoryBreakdown.count - 1 {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    /// Wider, more readable category row — the subtle bar runs as a background
    /// fill on the left fraction of the row, so the proportion is visible
    /// without sacrificing space for the data.
    private func categoryRow(_ category: Category, amount: Double) -> some View {
        let color = Color(hex: category.colorHex)
        let fraction = totalThisPeriod > 0 ? amount / totalThisPeriod : 0
        let percent = Int((fraction * 100).rounded())

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background fill bar representing fraction
                Rectangle()
                    .fill(color.opacity(0.08))
                    .frame(width: geo.size.width * fraction)

                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.18))
                            .frame(width: 36, height: 36)
                        Image(systemName: category.iconKey)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(percent)% of total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(Currency.format(amount, code: currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, Spacing.md)
            }
        }
        .frame(height: 60)
    }

    // MARK: - Top Merchants

    private var topMerchantsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Top Merchants")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(Array(topMerchants.enumerated()), id: \.offset) { index, item in
                        merchantRow(rank: index + 1, name: item.name, count: item.count, amount: item.amount)
                        if index != topMerchants.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func merchantRow(rank: Int, name: String, count: Int, amount: Double) -> some View {
        HStack(spacing: Spacing.md) {
            Text("\(rank)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(count) transaction\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Currency.format(amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: 4) {
                Text("Nothing to show yet")
                    .font(.subheadline.weight(.semibold))
                Text("No expenses logged in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl * 2)
    }
}
