import WidgetKit
import SwiftUI

// MARK: - Setup
//
// Widget Extension target. Required setup:
//   1. Add these files to Widget target membership:
//        - WidgetSnapshot.swift, Currency.swift, SharedAppearance.swift
//   2. Both targets need App Group `group.com.app.Tula`
//
// Widget gallery:
//   Home screen
//     • Today (small)               — today's spend + sparkline + month progress
//     • Category Breakdown (medium) — top 4 categories with proportional bars
//     • Monthly Comparison (small)  — this month vs last, directional change
//   Lock screen
//     • Today Inline                — one-line banner
//     • Today Circular              — budget burn ring
//     • Today Rectangular           — today + sparkline + month %

// MARK: - Provider

struct TulaWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> TulaWidgetEntry {
        TulaWidgetEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (TulaWidgetEntry) -> Void
    ) {
        completion(TulaWidgetEntry(date: .now, snapshot: WidgetStorage.read()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<TulaWidgetEntry>) -> Void
    ) {
        let snapshot = WidgetStorage.read()
        let now = Date.now
        let cal = Calendar.current
        let nowEntry = TulaWidgetEntry(date: now, snapshot: snapshot)

        var entries: [TulaWidgetEntry] = [nowEntry]

        for offset in 1...8 {
            if let future = cal.date(byAdding: .minute, value: offset * 30, to: now) {
                entries.append(TulaWidgetEntry(date: future, snapshot: snapshot))
            }
        }

        if let nextMidnight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) {
            var midnightSnapshot = snapshot
            midnightSnapshot.todayTotal = 0
            midnightSnapshot.generatedAt = nextMidnight
            entries.append(TulaWidgetEntry(date: nextMidnight,
                                            snapshot: midnightSnapshot))
        }

        let refreshDate = cal.date(byAdding: .minute, value: 30, to: now) ?? now
        let timeline = Timeline(entries: entries, policy: .after(refreshDate))
        completion(timeline)
    }
}

struct TulaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

// MARK: - Bundle

@main
struct TulaWidgetBundle: WidgetBundle {
    var body: some Widget {
        TulaTodayWidget()
        TulaCategoryWidget()
        TulaMonthCompareWidget()
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Today Widget
// ═══════════════════════════════════════════════════════════════════

struct TulaTodayWidget: Widget {
    let kind: String = "TulaTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            TodayWidgetEntryView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's spend with trend and month budget pace.")
        .supportedFamilies([
            .systemSmall,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryInline:      InlineTodayView(snapshot: snapshot)
        case .accessoryCircular:    CircularTodayView(snapshot: snapshot)
        case .accessoryRectangular: RectangularTodayView(snapshot: snapshot)
        default:                    HomeTodayView(snapshot: snapshot)
        }
    }
}

// MARK: - Today: home screen (small)

struct HomeTodayView: View {
    let snapshot: WidgetSnapshot

    private var monthProgress: Double {
        guard snapshot.monthlyBudgetCap > 0 else { return 0 }
        return min(snapshot.monthTotal / snapshot.monthlyBudgetCap, 1.0)
    }

    private var isOverMonthBudget: Bool {
        snapshot.monthlyBudgetCap > 0
        && snapshot.monthTotal > snapshot.monthlyBudgetCap
    }

    private var dayLabels: [String] {
        let cal = Calendar.current
        let now = Date.now
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return (0..<7).map { i in
            let date = cal.date(byAdding: .day, value: -(6 - i), to: now) ?? now
            return f.string(from: date)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("तु")
                .font(.system(size: 130, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.15))
                .offset(x: 25, y: -30)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Text(
                    Currency
                        .format(
                            snapshot.todayTotal,
                            code: snapshot.currencyCode
                        )
                )
                .font(.system(size: 30, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .monospacedDigit()

                Spacer(minLength: 0)

                TrendChartView(
                    values: snapshot.dailyTotals,
                    dayLabels: dayLabels,
                    color: Color.tulaBrandFallback
                )
                .frame(height: 36)

                if snapshot.monthlyBudgetCap > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule()
                                    .fill(
                                        isOverMonthBudget ? Color.red : Color.tulaBrandFallback
                                    )
                                    .frame(
                                        width: geo.size.width * monthProgress
                                    )
                            }
                        }
                        .frame(height: 3)
                        Text(
                            "\(Currency.compact(snapshot.monthTotal, code: snapshot.currencyCode)) of \(Currency.compact(snapshot.monthlyBudgetCap, code: snapshot.currencyCode))"
                        )
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

// MARK: - Today: lockscreen inline

struct InlineTodayView: View {
    let snapshot: WidgetSnapshot

    private var budgetTrail: String? {
        guard snapshot.monthlyBudgetCap > 0 else { return nil }
        let pct = max(0, 1 - (snapshot.monthTotal / snapshot.monthlyBudgetCap))
        return "\(Int(pct * 100))% left"
    }

    var body: some View {
        if let trail = budgetTrail {
            Text(
                "Today \(Currency.format(snapshot.todayTotal, code: snapshot.currencyCode)) · \(trail)"
            )
        } else {
            Text(
                "Today \(Currency.format(snapshot.todayTotal, code: snapshot.currencyCode))"
            )
        }
    }
}

// MARK: - Today: lockscreen circular

struct CircularTodayView: View {
    let snapshot: WidgetSnapshot

    private var progress: Double {
        guard snapshot.monthlyBudgetCap > 0 else { return 0 }
        return min(snapshot.monthTotal / snapshot.monthlyBudgetCap, 1.0)
    }

    var body: some View {
        if snapshot.monthlyBudgetCap > 0 {
            ZStack {
                Circle()
                    .stroke(lineWidth: 4)
                    .opacity(0.25)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        } else {
            VStack(spacing: 0) {
                Text("Today")
                    .font(.system(size: 9, weight: .medium))
                    .opacity(0.7)
                Text(
                    Currency
                        .compact(
                            snapshot.todayTotal,
                            code: snapshot.currencyCode
                        )
                )
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .widgetAccentable()
            }
        }
    }
}

// MARK: - Today: lockscreen rectangular

struct RectangularTodayView: View {
    let snapshot: WidgetSnapshot

    private var monthProgress: Double {
        guard snapshot.monthlyBudgetCap > 0 else { return 0 }
        return min(snapshot.monthTotal / snapshot.monthlyBudgetCap, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Today")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.8)
                Spacer()
            }
            Text(
                Currency
                    .format(snapshot.todayTotal, code: snapshot.currencyCode)
            )
            .font(.system(size: 17, weight: .semibold))
            .monospacedDigit()
            .widgetAccentable()
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            SparklineView(values: snapshot.dailyTotals, color: .primary)
                .frame(height: 14)
                .widgetAccentable()

            if snapshot.monthlyBudgetCap > 0 {
                HStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().opacity(0.25)
                            Capsule()
                                .frame(width: geo.size.width * monthProgress)
                                .widgetAccentable()
                        }
                    }
                    .frame(height: 2)
                    Text("\(Int(monthProgress * 100))%")
                        .font(.system(size: 9, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.85)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Category Breakdown Widget (medium)
// ═══════════════════════════════════════════════════════════════════

struct TulaCategoryWidget: Widget {
    let kind: String = "TulaCategoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            CategoryWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Spending")
        .description("This month's spending by category.")
        .supportedFamilies([.systemMedium])
    }
}

struct CategoryWidgetView: View {
    let snapshot: WidgetSnapshot

    private var monthName: String {
        Date.now.formatted(.dateTime.month(.wide))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Spending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Currency.format(snapshot.monthTotal, code: snapshot.currencyCode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            Spacer(minLength: 6)

            if snapshot.categoryBreakdown.isEmpty {
                categoryEmptyView
            } else {
                let maxAmount = snapshot.categoryBreakdown.first?.amount ?? 1
                VStack(spacing: 6) {
                    ForEach(Array(snapshot.categoryBreakdown.prefix(4))) { cat in
                        CategoryWidgetRow(
                            entry: cat,
                            maxAmount: maxAmount,
                            currencyCode: snapshot.currencyCode
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private var categoryEmptyView: some View {
        VStack(spacing: 4) {
            Text("No expenses yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Start logging in Tula.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct CategoryWidgetRow: View {
    let entry: WidgetSnapshot.CategorySpend
    let maxAmount: Double
    let currencyCode: String

    private var color: Color { Color(hex: entry.colorHex) }

    private var barFraction: Double {
        guard maxAmount > 0 else { return 0 }
        return entry.amount / maxAmount
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: entry.iconKey)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(entry.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(Int(entry.percentage * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Text(Currency.compact(entry.amount, code: currencyCode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(color)
                        .frame(width: max(geo.size.width * barFraction, 2))
                }
            }
            .frame(height: 3)
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Monthly Comparison Widget (small)
// ═══════════════════════════════════════════════════════════════════

struct TulaMonthCompareWidget: Widget {
    let kind: String = "TulaMonthCompareWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            MonthCompareWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Monthly")
        .description("This month vs last month at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

struct MonthCompareWidgetView: View {
    let snapshot: WidgetSnapshot

    private var monthName: String {
        Date.now.formatted(.dateTime.month(.abbreviated))
    }

    private var lastMonthName: String {
        let cal = Calendar.current
        let lastMonth = cal.date(byAdding: .month, value: -1, to: .now) ?? .now
        return lastMonth.formatted(.dateTime.month(.abbreviated))
    }

    private var changePercent: Double? {
        guard snapshot.lastMonthTotal > 0 else { return nil }
        return (snapshot.monthTotal - snapshot.lastMonthTotal) / snapshot.lastMonthTotal
    }

    private var isSpendingMore: Bool {
        snapshot.monthTotal > snapshot.lastMonthTotal
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Brand watermark
            Text("तु")
                .font(.system(size: 110, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                .offset(x: 30, y: -25)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                Text(monthName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                Spacer(minLength: 4)

                // Hero amount
                Text(
                    Currency.format(
                        snapshot.monthTotal,
                        code: snapshot.currencyCode
                    )
                )
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .monospacedDigit()

                Spacer(minLength: 6)

                // Change indicator
                if let pct = changePercent {
                    HStack(spacing: 3) {
                        Image(systemName: isSpendingMore ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text("\(Int(abs(pct * 100)))%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(isSpendingMore ? .red : .green)

                    HStack(spacing: 3) {
                        Text("vs")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        Text(Currency.compact(snapshot.lastMonthTotal, code: snapshot.currencyCode))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(lastMonthName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 1)
                } else {
                    Text("No prior month data")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Sparkline
// ═══════════════════════════════════════════════════════════════════

struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 0
            let safeMax = maxValue > 0 ? maxValue : 1
            let normalized = values.map { $0 / safeMax }
            let stepX = values.count > 1
            ? geo.size.width / CGFloat(values.count - 1)
            : 0

            ZStack {
                Path { path in
                    guard !values.isEmpty else { return }
                    for (i, v) in normalized.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat(v))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: geo.size.height))
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(
                        x: CGFloat(values.count - 1) * stepX,
                        y: geo.size.height
                    ))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.18))

                Path { path in
                    guard !values.isEmpty else { return }
                    for (i, v) in normalized.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat(v))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(
                    lineWidth: 1.5,
                    lineCap: .round,
                    lineJoin: .round
                ))
            }
        }
    }
}

// MARK: - Trend Chart (with day labels)

struct TrendChartView: View {
    let values: [Double]
    let dayLabels: [String]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 0
            let safeMax = maxValue > 0 ? maxValue : 1
            let normalized = values.map { $0 / safeMax }
            let labelHeight: CGFloat = 9
            let chartHeight = max(0, geo.size.height - labelHeight - 2)
            let stepX = values.count > 1
            ? geo.size.width / CGFloat(values.count - 1)
            : 0

            ZStack(alignment: .topLeading) {
                Path { path in
                    guard !values.isEmpty else { return }
                    for (i, v) in normalized.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = chartHeight * (1 - CGFloat(v))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: chartHeight))
                            path.addLine(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    path.addLine(to: CGPoint(
                        x: CGFloat(values.count - 1) * stepX,
                        y: chartHeight
                    ))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.16))

                Path { path in
                    guard !values.isEmpty else { return }
                    for (i, v) in normalized.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = chartHeight * (1 - CGFloat(v))
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(
                    lineWidth: 1.4,
                    lineCap: .round,
                    lineJoin: .round
                ))

                ForEach(0..<values.count, id: \.self) { i in
                    let v = normalized[i]
                    let x = CGFloat(i) * stepX
                    let y = chartHeight * (1 - CGFloat(v))
                    let isToday = (i == values.count - 1)

                    Circle()
                        .fill(isToday ? color : color.opacity(0.45))
                        .frame(
                            width: isToday ? 6 : 3,
                            height: isToday ? 6 : 3
                        )
                        .position(x: x, y: y)
                }

                ForEach(
                    0..<min(dayLabels.count, values.count),
                    id: \.self
                ) { i in
                    let x = CGFloat(i) * stepX
                    let isToday = (i == values.count - 1)
                    Text(dayLabels[i])
                        .font(
                            .system(
                                size: 7.5,
                                weight: isToday ? .semibold : .regular
                            )
                        )
                        .foregroundStyle(isToday ? color : .secondary)
                        .frame(width: 12)
                        .position(x: x, y: geo.size.height - labelHeight / 2)
                }
            }
        }
    }
}
