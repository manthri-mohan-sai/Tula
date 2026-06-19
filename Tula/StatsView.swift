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
        case .sixMonths: return "6 Months"
        }
    }
}

// MARK: - View

struct StatsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @PrimaryCurrency private var currencyCode
    @AppStorage("themePresetID") private var themePresetID: String = "saffron"

    @State private var period: StatsPeriod = .month

    /// 0 = current period, -1 = previous, etc. Reset to 0 when period changes.
    @State private var periodOffset: Int = 0

    /// Date the user is dragging on the chart (nil when not interacting).
    @State private var chartSelectedDate: Date?
    @State private var selectedWeekday: String?
    @State private var selectedCalendarDay: Date?

    /// Namespace for the period picker's animated selection pill.
    @Namespace private var pickerNamespace

    // MARK: - Drill-down state
    //
    // Stats cards (Top Category, Biggest Day, etc.) are tappable and
    // push to AllExpensesView with a preset filter applied. The two
    // navigation states map 1:1 to the two cards that have a meaningful
    // drill-down destination — others (Per Day, Transactions) push
    // unfiltered or are informational.
    @State private var navPath = NavigationPath()

    /// Last chart point the user inspected — persists after finger lift so
    /// the user can tap the drill-down pill below the chart.
    @State private var pinnedChartDate: Date?

    /// Drives the staggered fill animation for category proportion bars.
    @State private var categoryBarsAppeared: Bool = false

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

    /// Single most interesting pattern from the data — shown as a pill
    /// between the insight grid and the chart. Returns nil when nothing
    /// noteworthy is detected (avoids a "meh" callout).
    private var insightCallout: String? {
        guard hasAnySpend else { return nil }

        // 1. No-spend streak (day-level periods only, past days only)
        if period != .sixMonths {
            let today = Calendar.current.startOfDay(for: .now)
            let cutoff = Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
            let zeroCount = chartData.filter { $0.total == 0 && $0.label < cutoff }.count
            let periodWord = period == .week ? "week" : "month"
            if zeroCount >= 3 {
                return "\(zeroCount) no-spend days this \(periodWord)"
            }
        }

        // 2. Weekend vs weekday ratio
        if !weekdayData.isEmpty {
            let weekendIDs: Set<Int> = [1, 7]  // Sun=1, Sat=7
            let weekendTotal = weekdayData.filter { weekendIDs.contains($0.weekday) }.reduce(0.0) { $0 + $1.total }
            let weekdayTotal = weekdayData.filter { !weekendIDs.contains($0.weekday) }.reduce(0.0) { $0 + $1.total }
            if weekdayTotal > 0 {
                let ratio = (weekendTotal / 2) / (weekdayTotal / 5)
                if ratio >= 1.8 {
                    return "Weekends cost \(String(format: "%.1f", ratio))x more per day"
                } else if ratio <= 0.5 {
                    return "Weekdays cost \(String(format: "%.1f", 1 / ratio))x more per day"
                }
            }
        }

        // 3. Spending pace vs previous period
        if let trend = trendVsPrevious, isCurrentPeriod {
            let label = formatDeltaPercent(trend)
            let periodWord = period == .week ? "week" : "month"
            if trend > 0.15 {
                return "Spending \(label) faster than last \(periodWord)"
            } else if trend < -0.15 {
                return "\(label) under last \(periodWord)'s pace"
            }
        }

        return nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(spacing: Spacing.lg) {
                    periodPicker
                    heroCard
                    if hasAnySpend {
                        insightGrid
                        if period != .month { insightCalloutPill }
                        if period != .month { chartCard }
                        if period == .month { spendingCalendarCard }
                        if period != .month && !weekdayData.isEmpty { weekdayChartCard }
                        if !categoryBreakdown.isEmpty { categoryBreakdownCard }
                        if !topMerchants.isEmpty { topMerchantsCard }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, Spacing.md)
                .padding(.top, Spacing.md)
                .padding(.bottom, Spacing.lg)
            }
            .background {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.tulaBrandFallback.opacity(0.12), Color.tulaBrandFallback.opacity(0.05), Color.tulaBackground],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 400)
                    Color.tulaBackground
                }
                .ignoresSafeArea()
            }
            .navigationTitle("Stats")
            // Stats is a data-dense screen — the large-title bar (iOS 26
            // makes this ~100pt tall) eats real estate the period picker
            // and hero card should own. Inline keeps "Stats" visible as
            // a header chip at the top while the content gets the prime
            // visual space.
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ExpenseFilter.self) { filter in
                AllExpensesView(presetFilter: filter)
            }
            .onChange(of: period) { _, _ in
                Haptics.selection()
                withAnimation(AppAnimation.gentle) {
                    periodOffset = 0
                    pinnedChartDate = nil
                    selectedCalendarDay = nil
                }
            }
            .onChange(of: periodOffset) { _, _ in
                // Reset chart/category state whenever the period window
                // moves — keeps stale data from lingering across windows.
                // Wrapped in withAnimation so removals are smooth.
                withAnimation(AppAnimation.snappy) {
                    pinnedChartDate = nil
                    selectedCalendarDay = nil
                }
            }
            .onChange(of: chartSelectedDate) { old, new in
                // When the user lifts their finger, persist the last
                // selected point so the drill-down pill stays visible.
                if new == nil, let old {
                    withAnimation(AppAnimation.snappy) {
                        pinnedChartDate = old
                    }
                }
            }
        }
    }

    // MARK: - Period Picker

    /// Native segmented Picker. The hand-rolled glass-on-solid pill
    /// version had a visual clash — `.glassEffect` on the container with
    /// an opaque `systemBackground` pill inside read as two competing
    /// materials. Apple's stock segmented picker handles iOS 26's
    /// material treatment correctly without custom layering.
    private var periodPicker: some View {
        Picker("Period", selection: $period) {
            ForEach(StatsPeriod.allCases) { p in
                Text(p.shortLabel).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityHint("Switch between weekly, monthly, and six-month views")
    }

    // MARK: - Hero

    /// Hero card. Lays out the period date navigator at the top (was a
    /// separate row in the header), then the spent total + per-day
    /// average. The date is the period's context, the amount is the
    /// answer — pairing them in one card removes redundant vertical
    /// chrome and lets the amount land harder.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            heroDateNav

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(Currency.format(totalThisPeriod, code: currencyCode))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: totalThisPeriod))
                    .animation(.snappy(duration: 0.35), value: totalThisPeriod)

                if hasAnySpend {
                    HStack(spacing: Spacing.xs) {
                        Text(Currency.format(averagePerDay, code: currencyCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText(value: averagePerDay))
                            .animation(.snappy(duration: 0.35), value: averagePerDay)
                        Text("avg / day")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.lg)
        .compositingGroup()
        .tulaHeroSurface(cornerRadius: CornerRadius.large)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 1.5 else { return }
                    if h < 0 {
                        guard !isCurrentPeriod else { return }
                        Haptics.tap()
                        withAnimation(AppAnimation.gentle) {
                            periodOffset += 1
                            pinnedChartDate = nil
                            categoryBarsAppeared = false
                        }
                    } else {
                        Haptics.tap()
                        withAnimation(AppAnimation.gentle) {
                            periodOffset -= 1
                            pinnedChartDate = nil
                            categoryBarsAppeared = false
                        }
                    }
                }
        )
    }

    /// Date navigator inline at the top of the hero. Lightweight chevrons
    /// flanking the date label, with the trend badge floated right. No
    /// heavy circle backgrounds like the old standalone navigator had —
    /// inside the hero card those felt over-styled.
    private var heroDateNav: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap()
                withAnimation(AppAnimation.gentle) {
                    periodOffset -= 1
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(rangeLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)

            Button {
                guard !isCurrentPeriod else { return }
                Haptics.tap()
                withAnimation(AppAnimation.gentle) {
                    periodOffset += 1
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrentPeriod ? Color(uiColor: .tertiaryLabel) : .primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCurrentPeriod)

            if let trend = trendVsPrevious {
                trendBadge(trend)
            } else if !isCurrentPeriod {
                Button {
                    Haptics.tap()
                    withAnimation(AppAnimation.gentle) {
                        periodOffset = 0
                    }
                } label: {
                    Image(systemName: "arrow.uturn.left")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.tulaBrandFallback)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset to current period")
            }
        }
    }

    private func trendBadge(_ trend: Double) -> some View {
        let isUp = trend > 0
        let color: Color = isUp ? .red : .green
        let label = formatDeltaPercent(trend)
        return HStack(spacing: 2) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    // MARK: - Insight Grid (2x2)
    //
    // Three of the four cards drill down to AllExpensesView with the
    // matching filter preset. "Per Day" is informational only — no
    // deep-link since "all expenses across an average day" isn't a
    // meaningful subset to scroll through.

    private var insightGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: Spacing.md),
            GridItem(.flexible(), spacing: Spacing.md),
        ]
        return LazyVGrid(columns: columns, spacing: Spacing.md) {
            insightCardButton(
                label: "Top Category",
                value: topCategoryItem?.category.name ?? "—",
                detail: topCategoryItem.map { Currency.format($0.amount, code: currencyCode) } ?? "",
                icon: topCategoryItem?.category.iconKey ?? "circle.dashed",
                color: topCategoryItem.map { Color(hex: $0.category.colorHex) } ?? .gray,
                drillDown: topCategoryItem.map { topCategoryFilter(for: $0.category) }
            )
            insightCardButton(
                label: "Biggest Day",
                value: biggestDay.map { Currency.format($0.amount, code: currencyCode) } ?? "—",
                detail: biggestDay.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) } ?? "",
                icon: "flame.fill",
                color: .orange,
                drillDown: biggestDay.map { biggestDayFilter(for: $0.date) }
            )
            insightCardButton(
                label: "Per Day",
                value: Currency.format(averagePerDay, code: currencyCode),
                detail: isCurrentPeriod ? "so far" : "average",
                icon: "calendar",
                color: .blue,
                drillDown: periodRangeFilter
            )
            insightCardButton(
                label: "Transactions",
                value: "\(transactionCount)",
                detail: transactionCount == 1 ? "logged" : "logged",
                icon: "list.bullet",
                color: .purple,
                drillDown: periodRangeFilter
            )
        }
    }

    /// Tappable wrapper around `insightCard`. When `drillDown` is non-nil,
    /// the whole card becomes a Button that pushes AllExpensesView via
    /// `navPath`. When nil, the card renders as a plain (non-interactive)
    /// surface — visually distinct via reduced opacity on the trailing
    /// chevron (absent for non-interactive, present for interactive).
    @ViewBuilder
    private func insightCardButton(label: String, value: String, detail: String,
                                     icon: String, color: Color,
                                     drillDown: ExpenseFilter?) -> some View {
        let isInteractive = drillDown != nil
        if let filter = drillDown {
            Button {
                Haptics.tap()
                navPath.append(filter)
            } label: {
                insightCard(label: label, value: value, detail: detail,
                            icon: icon, color: color,
                            isInteractive: isInteractive)
            }
            .buttonStyle(InsightCardButtonStyle())
            .contextMenu {
                insightContextMenuItems(for: filter)
            }
        } else {
            insightCard(label: label, value: value, detail: detail,
                        icon: icon, color: color,
                        isInteractive: isInteractive)
        }
    }

    // MARK: - Drill-down filter builders

    /// Filter for "Top Category" — single category, current period.
    private func topCategoryFilter(for category: Category) -> ExpenseFilter {
        var f = periodRangeFilter
        f.categoryIDs = [category.id]
        return f
    }

    /// Filter for "Biggest Day" — narrow the range to that single calendar day.
    private func biggestDayFilter(for date: Date) -> ExpenseFilter {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        var f = ExpenseFilter.empty
        f.dateRange = .custom(start: start, end: end)
        return f
    }

    /// Filter for a chart data point — day for week/month, or full month
    /// for 6M view.
    private func chartDateFilter(for date: Date) -> ExpenseFilter {
        let cal = Calendar.current
        if period == .sixMonths {
            let monthStart = cal.dateInterval(of: .month, for: date)?.start ?? date
            let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            var f = ExpenseFilter.empty
            f.dateRange = .custom(start: monthStart, end: monthEnd)
            return f
        } else {
            return biggestDayFilter(for: date)
        }
    }

    /// Human-readable label for a chart data point date.
    private func chartDateLabel(_ date: Date) -> String {
        if period == .sixMonths {
            return date.formatted(.dateTime.month(.abbreviated))
        } else {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// Top expenses matching a filter — used for context menu previews on
    /// insight tiles so the user can peek before committing to drill-down.
    private func topExpenses(for filter: ExpenseFilter, limit: Int = 3) -> [Expense] {
        Array(
            rangeExpenses
                .filter { filter.matches($0) }
                .sorted { $0.amount > $1.amount }
                .prefix(limit)
        )
    }

    /// Context menu content for insight tiles — shows top expenses as a
    /// quick preview, plus a "View all" action.
    @ViewBuilder
    private func insightContextMenuItems(for filter: ExpenseFilter) -> some View {
        let top = topExpenses(for: filter, limit: 3)
        if !top.isEmpty {
            Section {
                ForEach(Array(top.enumerated()), id: \.offset) { _, expense in
                    let title = expense.merchant ?? expense.note ?? "—"
                    let amount = Currency.format(expense.amount, code: currencyCode)
                    let icon = expense.category?.iconKey ?? "circle"
                    Label("\(title) · \(amount)", systemImage: icon)
                }
            }
        }
        Button {
            navPath.append(filter)
        } label: {
            Label("View all expenses", systemImage: "list.bullet")
        }
    }

    /// Filter matching the currently-selected stats period — used as the
    /// base for category/merchant drill-downs and for the "Transactions"
    /// card so tapping it shows the same expenses the stats summarize.
    private var periodRangeFilter: ExpenseFilter {
        var f = ExpenseFilter.empty
        f.dateRange = .custom(start: currentRange.start, end: currentRange.end)
        return f
    }

    private func insightCard(label: String, value: String, detail: String,
                             icon: String, color: Color,
                             isInteractive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
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
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.35), value: value)

            HStack(spacing: 4) {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.35), value: detail)
                Spacer()
                // Tappable cue: small chevron in the detail row. Shows
                // only on interactive cards. .tertiary keeps it quiet —
                // it should signal "yes you can tap" without competing
                // with the value or category color above.
                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .frame(minHeight: 84)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value), \(detail)")
        .accessibilityAddTraits(isInteractive ? .isButton : [])
    }

    // MARK: - Insight Callout

    @ViewBuilder
    private var insightCalloutPill: some View {
        if let insight = insightCallout {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.yellow)
                Text(insight)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                    .fill(Color.yellow.opacity(0.08))
            )
        }
    }

    // MARK: - Chart

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: chartSectionTitle)

            Card(padding: Spacing.md, cornerRadius: CornerRadius.medium) {
                VStack(spacing: Spacing.sm) {
                    if period == .sixMonths {
                        barChart
                    } else {
                        areaChart
                    }

                    // Persistent drill-down pill — appears after the user
                    // inspects a chart point and lifts their finger.
                    if let pinned = pinnedChartDate,
                       let point = nearestPoint(to: pinned) {
                        Button {
                            Haptics.tap()
                            navPath.append(chartDateFilter(for: point.label))
                            pinnedChartDate = nil
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .font(.caption)
                                Text("View \(chartDateLabel(point.label)) expenses")
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(Currency.format(point.total, code: currencyCode))
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Color.tulaBrandFallback)
                            .padding(.horizontal, Spacing.sm)
                            .padding(.vertical, Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                                    .fill(Color.tulaBrandFallback.opacity(0.08))
                            )
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Spending chart")
            .accessibilityValue({
                let total = chartData.reduce(0) { $0 + $1.total }
                let peak = chartData.max(by: { $0.total < $1.total })
                let avg = chartData.isEmpty ? 0 : total / Double(chartData.count)
                var summary = "Total \(Currency.format(total, code: currencyCode)), average \(Currency.format(avg, code: currencyCode))"
                if let peak {
                    summary += ", peak \(Currency.format(peak.total, code: currencyCode))"
                }
                return summary
            }())
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
                        colors: [Color.tulaBrandFallback.opacity(0.45),
                                 Color.tulaBrandFallback.opacity(0.04)],
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

                // Zero-spend day marker — small dot on the axis so
                // "no data" and "zero spend" are visually distinct.
                // Only show for past/today — future days aren't "no-spend."
                if item.total == 0 && item.label <= Date.now {
                    PointMark(
                        x: .value("Day", item.label, unit: .day),
                        y: .value("Spent", 0)
                    )
                    .foregroundStyle(Color.gray.opacity(0.35))
                    .symbolSize(18)
                }
            }

            // Selection indicators — only when user is actively touching.
            if let selected = chartSelectedDate,
               let point = nearestPoint(to: selected) {
                RuleMark(x: .value("Day", point.label, unit: .day))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(
                    x: .value("Day", point.label, unit: .day),
                    y: .value("Spent", point.total)
                )
                .foregroundStyle(Color.tulaBrandFallback)
                .symbolSize(90)
                .annotation(
                    position: .top,
                    alignment: .center,
                    spacing: 8,
                    overflowResolution: .init(x: .fit, y: .disabled)
                ) {
                    chartAnnotation(date: point.label, amount: point.total)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: period == .week ? 7 : 4)) { _ in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.12))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.12))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Currency.compact(v, code: currencyCode))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Native iOS 17+ selection — no custom DragGesture. iOS handles
        // gesture priority correctly with the parent ScrollView, so the
        // chart never blocks vertical scrolling.
        .chartXSelection(value: $chartSelectedDate)
        // Clamp Y range to actual data + 15% headroom. Without this,
        // Charts auto-picks a "nice" max (often ₹10K when data peaks at
        // ₹5K) and we burn half the chart on empty space.
        .chartYScale(domain: 0...chartYMax)
        .frame(height: 220)
    }

    /// Y-axis upper bound. 15% headroom above the data peak so the line
    /// has room to breathe; minimum of 100 so an empty/sparse period
    /// doesn't render a degenerate 0-range axis.
    private var chartYMax: Double {
        let peak = chartData.map(\.total).max() ?? 0
        return max(peak * 1.15, 100)
    }

    /// Annotation popover. Uses a solid system-background surface (not
    /// `.regularMaterial`) so it never picks up tint from the colored
    /// area fill below it — translucent backgrounds were rendering
    /// amber-washed on top of the amber chart fill, which made the
    /// numbers hard to read against. Solid background + subtle stroke +
    /// stronger shadow gives a card that always reads as "on top of."
    private func chartAnnotation(date: Date, amount: Double) -> some View {
        let isMonthly = period == .sixMonths
        let label = isMonthly ? "MONTHLY TOTAL" : "DAILY SPENDING"
        let dateFormat: Date.FormatStyle = isMonthly
            ? .dateTime.month(.wide).year()
            : .dateTime.weekday(.abbreviated).day().month(.abbreviated)

        return VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.3)

            Text(Currency.format(amount, code: currencyCode))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.tulaBrandFallback)

            Text(date, format: dateFormat)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.tulaBrandFallback)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    private func pointForDate(_ date: Date) -> (label: Date, total: Double)? {
        chartData.first { Calendar.current.isDate($0.label, equalTo: date, toGranularity: .day) }
    }

    private func nearestPoint(to date: Date) -> (label: Date, total: Double)? {
        guard !chartData.isEmpty else { return nil }
        return chartData.min(by: { abs($0.label.timeIntervalSince(date)) < abs($1.label.timeIntervalSince(date)) })
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

            // Selection indicator on bars too — same pattern, no scroll conflict.
            if let selected = chartSelectedDate,
               let point = nearestPoint(to: selected) {
                RuleMark(x: .value("Month", point.label, unit: .month))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .annotation(
                        position: .top,
                        alignment: .center,
                        spacing: 8,
                        overflowResolution: .init(x: .fit, y: .disabled)
                    ) {
                        chartAnnotation(date: point.label, amount: point.total)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.12))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Currency.compact(v, code: currencyCode))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXSelection(value: $chartSelectedDate)
        .chartYScale(domain: 0...chartYMax)
        .frame(height: 220)
    }

    // MARK: - Spending Calendar

    /// Daily spending totals keyed by start-of-day date. Powers the
    /// calendar heat-map — each cell's fill intensity is proportional
    /// to how much was spent that day.
    private var dailySpending: [Date: Double] {
        let cal = Calendar.current
        var result: [Date: Double] = [:]
        for expense in rangeExpenses {
            let day = cal.startOfDay(for: expense.date)
            result[day, default: 0] += expense.amount
        }
        return result
    }

    /// Maximum single-day spend in the current month. The heat-map
    /// ceiling — days at this amount render at full intensity.
    private var maxDailySpend: Double {
        dailySpending.values.max() ?? 1
    }

    /// Flat list of optional dates for the current month calendar grid.
    /// `nil` entries pad the first/last positions where the month
    /// doesn't fill a complete week.
    private var calendarSlots: [Date?] {
        let cal = Calendar.current
        let monthStart = currentRange.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        let firstWeekday = cal.component(.weekday, from: monthStart)
        var leadingBlanks = firstWeekday - cal.firstWeekday
        if leadingBlanks < 0 { leadingBlanks += 7 }

        var slots: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for dayOffset in 0..<daysInMonth {
            if let date = cal.date(byAdding: .day, value: dayOffset, to: monthStart) {
                slots.append(cal.startOfDay(for: date))
            }
        }
        while slots.count % 7 != 0 { slots.append(nil) }
        return slots
    }

    /// Count of past/current days with zero spending this period.
    private var noSpendDayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let monthStart = currentRange.start
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        var count = 0
        for dayOffset in 0..<daysInMonth {
            guard let date = cal.date(byAdding: .day, value: dayOffset, to: monthStart) else { continue }
            let day = cal.startOfDay(for: date)
            guard day <= today else { break }
            if (dailySpending[day] ?? 0) == 0 { count += 1 }
        }
        return count
    }

    /// 7-column layout for the calendar grid. Defined once, shared by
    /// the weekday headers and the day cells so columns align perfectly.
    private var calendarColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    }

    // MARK: Spending Calendar — Card

    private var spendingCalendarCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Spending Calendar")

            Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                VStack(spacing: Spacing.md) {
                    calendarWeekdayHeaders
                    calendarGridView
                    calendarLegend

                    if let selected = selectedCalendarDay {
                        calendarDayDetail(for: selected)
                    }
                }
            }
        }
    }

    // MARK: Spending Calendar — Headers

    /// S M T W T F S row aligned with the grid via the same column spec.
    private var calendarWeekdayHeaders: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let start = cal.firstWeekday - 1
        let ordered = Array(symbols[start...]) + Array(symbols[..<start])

        return LazyVGrid(columns: calendarColumns, spacing: 4) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, sym in
                Text(sym)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: Spending Calendar — Grid

    private var calendarGridView: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)

        return LazyVGrid(columns: calendarColumns, spacing: 4) {
            ForEach(Array(calendarSlots.enumerated()), id: \.offset) { _, slot in
                if let date = slot {
                    calendarDayCell(date: date, isToday: date == today)
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fill)
                }
            }
        }
    }

    // MARK: Spending Calendar — Day Cell

    private func calendarDayCell(date: Date, isToday: Bool) -> some View {
        let cal = Calendar.current
        let dayNum = cal.component(.day, from: date)
        let spend = dailySpending[date] ?? 0
        let isFuture = date > cal.startOfDay(for: .now)
        let isSelected = selectedCalendarDay.map {
            cal.isDate($0, inSameDayAs: date)
        } ?? false
        // sqrt scale — keeps low-spend days visible instead of washing
        // them out under a linear ramp.
        let intensity = spend > 0 ? sqrt(min(spend / maxDailySpend, 1.0)) : 0

        return ZStack {
            // Heat-map fill — brand color at varying opacity.
            // Selected cells use .primary fill (not brand) so the
            // selection doesn't look like a high-spend indicator.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? Color.primary.opacity(0.85)
                        : (spend > 0 && !isFuture
                            ? Color.tulaBrandFallback.opacity(0.10 + intensity * 0.50)
                            : Color.clear)
                )

            // Today ring (only when not selected — the solid fill
            // already distinguishes the selected state).
            if !isSelected && isToday {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 2)
            }

            Text("\(dayNum)")
                .font(.system(size: 14, weight: isToday || isSelected ? .bold : .medium, design: .rounded))
                .foregroundStyle(
                    isFuture ? Color(uiColor: .quaternaryLabel)
                        : isSelected ? Color(uiColor: .systemBackground)
                        : intensity > 0.5 ? Color.white
                        : spend > 0 ? Color.primary
                        : Color.secondary
                )
        }
        .aspectRatio(1, contentMode: .fill)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .opacity(isFuture ? 0.35 : 1)
        .onTapGesture {
            guard !isFuture else { return }
            Haptics.selection()
            withAnimation(AppAnimation.snappy) {
                selectedCalendarDay = isSelected ? nil : date
            }
        }
        .accessibilityLabel("\(date.formatted(.dateTime.day().month(.abbreviated)))")
        .accessibilityValue(spend > 0 ? Currency.format(spend, code: currencyCode) : "No spending")
        .accessibilityAddTraits(isFuture ? [] : .isButton)
    }

    // MARK: Spending Calendar — Legend

    /// Split legend: stat counts on the left, GitHub-style gradient on the right.
    private var calendarLegend: some View {
        let spendDays = dailySpending.filter { $0.value > 0 }.count
        let steps: [Double] = [0, 0.15, 0.30, 0.45, 0.60]

        return HStack {
            // Left: descriptive stats
            HStack(spacing: Spacing.md) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.tulaBrandFallback.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text("\(spendDays) spent")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                        .frame(width: 6, height: 6)
                    Text("\(noSpendDayCount) no-spend")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Right: GitHub-style gradient
            HStack(spacing: 3) {
                Text("Less")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                ForEach(steps, id: \.self) { opacity in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(opacity > 0
                            ? Color.tulaBrandFallback.opacity(opacity)
                            : Color(uiColor: .tertiarySystemFill))
                        .frame(width: 10, height: 10)
                }
                Text("More")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Spending Calendar — Day Detail

    /// Inline detail for the selected calendar day.
    @ViewBuilder
    private func calendarDayDetail(for date: Date) -> some View {
        let cal = Calendar.current
        let dayExpenses = rangeExpenses
            .filter { cal.isDate($0.date, inSameDayAs: date) }
            .sorted { $0.amount > $1.amount }
        let dayTotal = dayExpenses.reduce(0) { $0 + $1.amount }

        Divider()

        VStack(spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                        .font(.subheadline.weight(.semibold))
                    if dayTotal > 0 {
                        Text(Currency.format(dayTotal, code: currencyCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.tulaBrandFallback)
                            .monospacedDigit()
                    }
                }

                Spacer()

                if dayTotal > 0 {
                    Button {
                        Haptics.tap()
                        navPath.append(biggestDayFilter(for: date))
                    } label: {
                        HStack(spacing: 4) {
                            Text("View all")
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.tulaBrandFallback)
                    }
                    .buttonStyle(.plain)
                }
            }

            if dayExpenses.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill")
                        .font(.caption)
                        .foregroundStyle(.green.opacity(0.6))
                    Text("No expenses — a no-spend day!")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dayExpenses.prefix(4).enumerated()), id: \.element.id) { index, expense in
                        HStack(spacing: Spacing.sm) {
                            if let cat = expense.category {
                                ZStack {
                                    Circle()
                                        .fill(Color(hex: cat.colorHex).opacity(0.15))
                                        .frame(width: 24, height: 24)
                                    Image(systemName: cat.iconKey)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color(hex: cat.colorHex))
                                }
                            } else {
                                ZStack {
                                    Circle()
                                        .fill(Color.gray.opacity(0.15))
                                        .frame(width: 24, height: 24)
                                    Image(systemName: "circle.dashed")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(expense.merchant ?? expense.category?.name ?? "Expense")
                                .font(.caption)
                                .lineLimit(1)

                            Spacer()

                            Text(Currency.format(expense.amount, code: currencyCode))
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)

                        if index < min(dayExpenses.count, 4) - 1 {
                            Divider().padding(.leading, 32)
                        }
                    }

                    if dayExpenses.count > 4 {
                        Text("and \(dayExpenses.count - 4) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .padding(.leading, 32)
                    }
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Weekday Pattern

    /// "When do you spend most?" — a 7-bar chart showing average spend by
    /// day of week across the current period. Surfaces patterns the linear
    /// trend chart hides: people often spend more on weekends, or on a
    /// particular weekday like Friday. Actionable insight in one glance.
    private var weekdayData: [(weekday: Int, name: String, total: Double, count: Int)] {
        let cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols  // ["Sun","Mon",...] for en_US

        var totals: [Int: Double] = [:]
        var counts: [Int: Int] = [:]
        for expense in rangeExpenses {
            let weekday = cal.component(.weekday, from: expense.date)
            totals[weekday, default: 0] += expense.amount
            counts[weekday, default: 0] += 1
        }

        // Only return if there's enough data to reveal a pattern.
        let totalDays = totals.keys.count
        guard totalDays >= 3 else { return [] }

        return (1...7).map { weekday in
            (
                weekday: weekday,
                name: symbols[weekday - 1],
                total: totals[weekday] ?? 0,
                count: counts[weekday] ?? 0
            )
        }
    }

    private var weekdayChartCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "By Weekday")

            Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if let peak = weekdayData.max(by: { $0.total < $1.total }), peak.total > 0 {
                        Text("Peak day: ")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        + Text(peakDayName(peak.weekday))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                        + Text(" · \(Currency.format(peak.total, code: currencyCode))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Chart(weekdayData, id: \.weekday) { item in
                        BarMark(
                            x: .value("Day", item.name),
                            y: .value("Spent", item.total),
                            width: .ratio(0.55)
                        )
                        .foregroundStyle(Color.tulaBrandFallback.gradient)
                        .cornerRadius(4)

                        if let selected = selectedWeekday, selected == item.name {
                            RuleMark(x: .value("Day", item.name))
                                .foregroundStyle(Color.tulaBrandFallback.opacity(0.35))
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .annotation(
                                    position: .top,
                                    alignment: .center,
                                    spacing: 8,
                                    overflowResolution: .init(x: .fit, y: .disabled)
                                ) {
                                    weekdayAnnotation(item: item)
                                }
                        }
                    }
                    .chartXSelection(value: $selectedWeekday)
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYAxis(.hidden)
                    .frame(height: 120)
                }
            }
        }
    }

    private func peakDayName(_ weekday: Int) -> String {
        let cal = Calendar.current
        return cal.weekdaySymbols[weekday - 1]   // full name like "Saturday"
    }

    private func weekdayAnnotation(item: (weekday: Int, name: String, total: Double, count: Int)) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TOTAL SPENT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.3)

            Text(Currency.format(item.total, code: currencyCode))
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color.tulaBrandFallback)

            Text(peakDayName(item.weekday))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.tulaBrandFallback)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    // MARK: - Category Breakdown

    private var categoryBreakdownCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "By Category")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    categoryDonutHeader
                        .padding(.horizontal, Spacing.md)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.md + 4)

                    Divider()

                    ForEach(Array(categoryBreakdown.enumerated()), id: \.element.category.id) { index, item in
                        Button {
                            Haptics.tap()
                            var f = periodRangeFilter
                            f.categoryIDs = [item.category.id]
                            navPath.append(f)
                        } label: {
                            categoryRow(item.category, amount: item.amount, index: index)
                        }
                        .buttonStyle(InsightRowButtonStyle())
                        if index != categoryBreakdown.count - 1 {
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !categoryBarsAppeared else { return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15)) {
                categoryBarsAppeared = true
            }
        }
    }

    // MARK: - Donut

    /// Donut chart of category proportions for the current period, with
    /// the period total in the center. Limits to top 5 distinct slices
    /// + an "Other" bucket so the donut stays readable; the full list
    /// is still visible in the rows below.
    private var categoryDonutHeader: some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            ZStack {
                CategoryDonut(slices: donutSlices)
                    .frame(width: 120, height: 120)

                VStack(spacing: 2) {
                    Text("Total")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                    Text(Currency.compact(totalThisPeriod, code: currencyCode))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.numericText(value: totalThisPeriod))
                        .animation(.snappy(duration: 0.35), value: totalThisPeriod)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(donutSlices.prefix(4)) { slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)
                        Text(slice.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int((slice.fraction * 100).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: slice.fraction))
                            .animation(.snappy(duration: 0.35), value: slice.fraction)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Top 5 categories as donut slices, with "Other" rolling up the rest.
    /// Each slice carries its display name, color, and fractional share.
    private var donutSlices: [DonutSlice] {
        guard totalThisPeriod > 0 else { return [] }
        let sorted = categoryBreakdown
        let topN = 5
        let head = sorted.prefix(topN)
        let tail = sorted.dropFirst(topN)

        var slices: [DonutSlice] = head.map { item in
            DonutSlice(
                name: item.category.name,
                color: Color(hex: item.category.colorHex),
                amount: item.amount,
                fraction: item.amount / totalThisPeriod
            )
        }

        let tailTotal = tail.reduce(0) { $0 + $1.amount }
        if tailTotal > 0 {
            slices.append(DonutSlice(
                name: "Other",
                color: .gray.opacity(0.6),
                amount: tailTotal,
                fraction: tailTotal / totalThisPeriod
            ))
        }

        return slices
    }

    /// Wider, more readable category row — the subtle bar runs as a background
    /// fill on the left fraction of the row, so the proportion is visible
    /// without sacrificing space for the data.
    private func categoryRow(_ category: Category, amount: Double, index: Int = 0) -> some View {
        let color = Color(hex: category.colorHex)
        let fraction = totalThisPeriod > 0 ? amount / totalThisPeriod : 0
        let percent = Int((fraction * 100).rounded())
        let animatedFraction = categoryBarsAppeared ? fraction : 0

        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                UnevenRoundedRectangle()
                    .fill(color.opacity(0.08))
                    .frame(width: geo.size.width * animatedFraction)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.8)
                            .delay(Double(index) * 0.06),
                        value: categoryBarsAppeared
                    )

                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: category.iconKey)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(.subheadline.weight(.semibold))
                        Text("\(percent)% of total")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(Currency.format(amount, code: currencyCode))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.md)
            }
        }
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    // MARK: - Top Merchants

    private var topMerchantsCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Top Merchants")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(Array(topMerchants.enumerated()), id: \.offset) { index, item in
                        Button {
                            Haptics.tap()
                            var f = periodRangeFilter
                            f.merchantSubstring = item.name
                            navPath.append(f)
                        } label: {
                            merchantRow(rank: index + 1, name: item.name,
                                        count: item.count, amount: item.amount)
                        }
                        .buttonStyle(InsightRowButtonStyle())
                        if index != topMerchants.count - 1 {
                            Divider().padding(.leading, 52)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Currency.format(amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .contentShape(Rectangle())
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

// MARK: - Insight Card Button Style

/// Subtle press affordance for tappable insight cards. Scales down 2%
/// and fades 5% on press — same feel Apple uses for icon grids in
/// Settings / Photos. Reads as "this is interactive" without adding
/// a chevron or any visual ornament to the card itself.
private struct InsightCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.95 : 1.0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Press style for full-width tappable rows inside cards (category +
/// merchant rows). Uses an opacity dim on press rather than a scale —
/// rows are wider than tiles and a scale-down looks awkward at row width.
/// The opacity dim mimics Apple's stock list-row tap response.
private struct InsightRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.05)
                    : Color.clear
            )
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Donut Components

/// One slice of the category donut. `fraction` is the proportion of the
/// total (0...1); slices sum to 1.0 if there are any expenses.
struct DonutSlice: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let color: Color
    let amount: Double
    let fraction: Double
}

/// SectorMark-based donut chart matching the style used in BudgetsView/OverallBudgetCard.
/// Slices are expected to sum to 1.0; the "Other" bucket in the caller handles
/// any remainder so no background ring is needed.
struct CategoryDonut: View {
    let slices: [DonutSlice]

    var body: some View {
        Chart(slices) { slice in
            SectorMark(
                angle:        .value("Amount", slice.fraction),
                innerRadius:  .ratio(0.70),
                angularInset: 1.5
            )
            .foregroundStyle(slice.color)
            .cornerRadius(3)
        }
        .chartLegend(.hidden)
    }
}
