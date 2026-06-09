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

        var entries: [TulaWidgetEntry] = [
            TulaWidgetEntry(date: now, snapshot: snapshot)
        ]

        // Half-hour entries for the next 2 hours
        for offset in 1...4 {
            if let future = cal.date(byAdding: .minute, value: offset * 30, to: now) {
                entries.append(TulaWidgetEntry(date: future, snapshot: snapshot))
            }
        }

        // Refresh every 30 min so background updates (notification
        // actions) are picked up even if reloadAllTimelines() is throttled.
        var refreshAfter = cal.date(byAdding: .minute, value: 30, to: now) ?? now
        if let nextMidnight = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) {
            var midnightSnapshot = snapshot
            midnightSnapshot.todayTotal = 0
            midnightSnapshot.dailyTotals = Array(midnightSnapshot.dailyTotals.dropFirst()) + [0]
            midnightSnapshot.generatedAt = nextMidnight
            entries.append(TulaWidgetEntry(date: nextMidnight, snapshot: midnightSnapshot))

            // Hourly entries for the morning after midnight (covers overnight)
            for hour in 1...8 {
                if let morning = cal.date(byAdding: .hour, value: hour, to: nextMidnight) {
                    entries.append(TulaWidgetEntry(date: morning, snapshot: midnightSnapshot))
                }
            }

            // Request a fresh timeline shortly after midnight
            if let postMidnight = cal.date(byAdding: .minute, value: 1, to: nextMidnight) {
                refreshAfter = postMidnight
            }
        }

        let timeline = Timeline(entries: entries, policy: .after(refreshAfter))
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
        TulaMonthSpendWidget()
        TulaUpcomingWidget()
        TulaQuickActionsWidget()
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
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
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

    private var dayChangePercent: Double? {
        guard snapshot.lastMonthSameDayTotal > 0 else { return nil }
        return (snapshot.todayTotal - snapshot.lastMonthSameDayTotal) / snapshot.lastMonthSameDayTotal
    }

    private var isSpendingMoreToday: Bool {
        snapshot.todayTotal > snapshot.lastMonthSameDayTotal
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
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.12))
                .offset(x: 40, y: -30)
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

                if let pct = dayChangePercent {
                    HStack(spacing: 2) {
                        Image(systemName: isSpendingMoreToday ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 8, weight: .bold))
                        Text("\(Int(abs(pct * 100)))% vs same day last month")
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(isSpendingMoreToday ? .red : .green)
                }

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
            .padding(16)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
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
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
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
        ZStack(alignment: .topTrailing) {
            Text("तु")
                .font(.system(size: 140, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                .offset(x: 35, y: -25)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
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

                if snapshot.categoryBreakdown.isEmpty {
                    categoryEmptyView
                } else {
                    let categories = Array(snapshot.categoryBreakdown.prefix(3))
                    let maxAmount = categories.first?.amount ?? 1

                    Spacer(minLength: 4)

                    VStack(spacing: 0) {
                        ForEach(Array(categories.enumerated()), id: \.element.id) { index, cat in
                            CategoryWidgetRow(
                                entry: cat,
                                maxAmount: maxAmount,
                                currencyCode: snapshot.currencyCode
                            )
                            .padding(.vertical, 5)
                            if index < categories.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }

                    if snapshot.categoryBreakdown.count > 3 {
                        Spacer(minLength: 2)
                        Text("+\(snapshot.categoryBreakdown.count - 3) more")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        HStack(spacing: 8) {
            Image(systemName: entry.iconKey)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(entry.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(width: 40, height: 3)
                Capsule()
                    .fill(color.opacity(0.7))
                    .frame(width: max(40 * barFraction, 2), height: 3)
            }
            .frame(width: 40)

            Text("\(Int(entry.percentage * 100))%")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)

            Text(Currency.compact(entry.amount, code: currencyCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
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
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
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
        guard snapshot.lastMonthTillDayTotal > 0 else { return nil }
        return (snapshot.monthTotal - snapshot.lastMonthTillDayTotal) / snapshot.lastMonthTillDayTotal
    }

    private var isSpendingMore: Bool {
        snapshot.monthTotal > snapshot.lastMonthTillDayTotal
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("तु")
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                .offset(x: 40, y: -30)
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
                        Text(Currency.compact(snapshot.lastMonthTillDayTotal, code: snapshot.currencyCode))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text("\(lastMonthName) till day \(Calendar.current.component(.day, from: Date.now))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.top, 1)
                } else {
                    Text("No prior month data")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Upcoming Widget (medium)
// ═══════════════════════════════════════════════════════════════════

struct TulaUpcomingWidget: Widget {
    let kind: String = "TulaUpcomingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            UpcomingWidgetView(snapshot: entry.snapshot)
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Upcoming")
        .description("Recurring expenses due soon.")
        .supportedFamilies([.systemMedium])
    }
}

struct UpcomingWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text("तु")
                .font(.system(size: 140, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                .offset(x: 35, y: -25)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Upcoming")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !snapshot.upcomingRecurrings.isEmpty {
                        Text(totalLabel)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                if snapshot.upcomingRecurrings.isEmpty {
                    VStack(spacing: 4) {
                        Text("Nothing upcoming")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Set up rules in Tula → Recurring.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    Spacer()
                    VStack(spacing: 0) {
                        ForEach(
                            Array(snapshot.upcomingRecurrings.prefix(3).enumerated()),
                            id: \.element.id
                        ) { index, item in
                            UpcomingWidgetRow(
                                item: item,
                                currencyCode: snapshot.currencyCode
                            )
                            .padding(.vertical, 6)
                            if index < min(snapshot.upcomingRecurrings.count, 3) - 1 {
                                Divider().opacity(0.3)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                    Spacer()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var totalLabel: String {
        let total = snapshot.upcomingRecurrings.reduce(0) { $0 + $1.amount }
        return Currency.compact(total, code: snapshot.currencyCode)
    }
}

private struct UpcomingWidgetRow: View {
    let item: WidgetSnapshot.UpcomingRecurring
    let currencyCode: String

    private var dueLabel: String {
        let cal = Calendar.current
        let days = cal.dateComponents(
            [.day],
            from: cal.startOfDay(for: .now),
            to: cal.startOfDay(for: item.dueDate)
        ).day ?? 0
        switch days {
        case ..<0:  return "overdue"
        case 0:     return "today"
        case 1:     return "tomorrow"
        case 2...6: return "in \(days) days"
        default:    return item.dueDate.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var color: Color { Color(hex: item.colorHex) }
    private var isOverdue: Bool { item.dueDate < Date.now }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconKey)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(item.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(dueLabel)
                .font(.caption2)
                .foregroundStyle(isOverdue ? .red : .secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(Currency.format(item.amount, code: currencyCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Quick Actions Widget (small + lockscreen circular)
// ═══════════════════════════════════════════════════════════════════

struct TulaQuickActionsWidget: Widget {
    let kind: String = "TulaQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            QuickActionsEntryView(snapshot: entry.snapshot)
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Quick Add")
        .description("Quickly add, scan, or voice-log an expense.")
        .supportedFamilies([
            .systemSmall,
            .accessoryCircular,
        ])
    }
}

struct QuickActionsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryCircular: LockScreenAddButton()
        default:                 HomeQuickActionsView()
        }
    }
}

// MARK: - Quick Actions: home screen (small)

struct HomeQuickActionsView: View {
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Link(destination: URL(string: "tula://scan")!) {
                    ZStack {
                        Circle()
                            .fill(Color.tulaBrandFallback.opacity(0.12))
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.tulaBrandFallback)
                    }
                }
                Link(destination: URL(string: "tula://voice")!) {
                    ZStack {
                        Circle()
                            .fill(Color.tulaBrandFallback.opacity(0.12))
                        Image(systemName: "mic.fill")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.tulaBrandFallback)
                    }
                }
            }
            GridRow {
                Link(destination: URL(string: "tula://add")!) {
                    ZStack {
                        Circle()
                            .fill(Color.tulaBrandFallback.opacity(0.12))
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Color.tulaBrandFallback)
                    }
                }
                Text("तु")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color.tulaBrandFallback)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Quick Actions: lockscreen circular

struct LockScreenAddButton: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 28, weight: .medium))
                .widgetAccentable()
        }
        .widgetURL(URL(string: "tula://add"))
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Month Spend Widget (medium)
// ═══════════════════════════════════════════════════════════════════

struct TulaMonthSpendWidget: Widget {
    let kind: String = "TulaMonthSpendWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            MonthSpendWidgetView(snapshot: entry.snapshot)
                .containerBackground(Color.tulaBrandFallback.opacity(0.08).gradient, for: .widget)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Month Overview")
        .description("Monthly spend, budget progress, and top categories.")
        .supportedFamilies([.systemMedium])
    }
}

struct MonthSpendWidgetView: View {
    let snapshot: WidgetSnapshot

    private var hasBudget: Bool { snapshot.monthlyBudgetCap > 0 }

    private var budgetProgress: Double {
        guard hasBudget else { return 0 }
        return min(snapshot.monthTotal / snapshot.monthlyBudgetCap, 1.0)
    }

    private var isOverBudget: Bool {
        hasBudget && snapshot.monthTotal > snapshot.monthlyBudgetCap
    }

    private var remaining: Double {
        max(snapshot.monthlyBudgetCap - snapshot.monthTotal, 0)
    }

    private var topCategories: [WidgetSnapshot.CategorySpend] {
        Array(snapshot.categoryBreakdown.prefix(3))
    }

    private var monthName: String {
        Date.now.formatted(.dateTime.month(.wide))
    }

    private var dayOfMonth: Int {
        Calendar.current.component(.day, from: .now)
    }

    private var daysInMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: .now)?.count ?? 30
    }

    private var dailyAverage: Double {
        guard dayOfMonth > 0 else { return 0 }
        return snapshot.monthTotal / Double(dayOfMonth)
    }

    private var projectedTotal: Double {
        guard dayOfMonth > 0 else { return snapshot.monthTotal }
        return snapshot.monthTotal / Double(dayOfMonth) * Double(daysInMonth)
    }

    private var hasLastMonthData: Bool {
        snapshot.lastMonthTillDayTotal > 0
    }

    private var donutCenterLabel: (String, String)? {
        if hasBudget {
            return ("\(Int(budgetProgress * 100))%", "used")
        } else if hasLastMonthData {
            return ("~\(Currency.compact(projectedTotal, code: snapshot.currencyCode))", "month end")
        } else {
            return nil
        }
    }

    private var monthChangePercent: Double? {
        guard snapshot.lastMonthTillDayTotal > 0 else { return nil }
        return (snapshot.monthTotal - snapshot.lastMonthTillDayTotal) / snapshot.lastMonthTillDayTotal
    }

    private var isSpendingMore: Bool {
        snapshot.monthTotal > snapshot.lastMonthTillDayTotal
    }

    private var lastMonthName: String {
        let cal = Calendar.current
        let lastMonth = cal.date(byAdding: .month, value: -1, to: .now) ?? .now
        return lastMonth.formatted(.dateTime.month(.abbreviated))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text("तु")
                .font(.system(size: 140, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback.opacity(0.08))
                .offset(x: 35, y: -25)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Spent in \(monthName)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Text(Currency.format(snapshot.monthTotal, code: snapshot.currencyCode))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .padding(.top, 2)

                        Spacer(minLength: 4)

                        if hasBudget {
                            VStack(alignment: .leading, spacing: 3) {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.08))
                                        Capsule()
                                            .fill(isOverBudget ? Color.red : Color.tulaBrandFallback)
                                            .frame(width: geo.size.width * budgetProgress)
                                    }
                                }
                                .frame(height: 6)
                                .clipShape(Capsule())

                                if isOverBudget {
                                    Text("Over by \(Currency.compact(snapshot.monthTotal - snapshot.monthlyBudgetCap, code: snapshot.currencyCode))")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.red)
                                } else {
                                    Text("\(Currency.compact(remaining, code: snapshot.currencyCode)) left of \(Currency.compact(snapshot.monthlyBudgetCap, code: snapshot.currencyCode))")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else if let pct = monthChangePercent {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 4) {
                                    Image(systemName: isSpendingMore ? "arrow.up.right" : "arrow.down.right")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("\(Int(abs(pct * 100)))% vs \(lastMonthName)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                .foregroundStyle(isSpendingMore ? .red : .green)

                                Text("\(Currency.compact(snapshot.lastMonthTillDayTotal, code: snapshot.currencyCode)) by day \(dayOfMonth) last month")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(Currency.compact(dailyAverage, code: snapshot.currencyCode))/day avg")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.tulaBrandFallback)

                                Text("\(daysInMonth - dayOfMonth) days left in \(monthName.prefix(3))")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !topCategories.isEmpty {
                        DonutChartView(
                            categories: topCategories,
                            centerLabel: donutCenterLabel
                        )
                        .frame(width: 100, height: 100)
                        .padding(.leading, 4)
                    }
                }

                // Bottom: horizontal category legend
                if !topCategories.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(topCategories.enumerated()), id: \.element.id) { index, cat in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(hex: cat.colorHex))
                                    .frame(width: 6, height: 6)
                                Text(cat.name)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(Int(cat.percentage * 100))%")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .monospacedDigit()
                            }
                            if index < topCategories.count - 1 {
                                Spacer(minLength: 0)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Donut Chart

private struct DonutChartView: View {
    let categories: [WidgetSnapshot.CategorySpend]
    let centerLabel: (String, String)?

    private var strokeWidth: CGFloat { centerLabel == nil ? 20 : 12 }
    private let gapAngle: Double = 3

    private struct Segment {
        let startAngle: Double
        let endAngle: Double
        let color: Color
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        let totalPercentage = categories.reduce(0.0) { $0 + $1.percentage }
        let otherPercentage = max(1.0 - totalPercentage, 0)
        let totalGap = gapAngle * Double(categories.count + (otherPercentage > 0 ? 1 : 0))
        let available = 360.0 - totalGap

        var angle: Double = -90

        for cat in categories {
            let sweep = available * cat.percentage
            if sweep > 0 {
                result.append(Segment(
                    startAngle: angle,
                    endAngle: angle + sweep,
                    color: Color(hex: cat.colorHex)
                ))
                angle += sweep + gapAngle
            }
        }

        if otherPercentage > 0.01 {
            let sweep = available * otherPercentage
            result.append(Segment(
                startAngle: angle,
                endAngle: angle + sweep,
                color: Color.gray.opacity(0.25)
            ))
        }

        return result
    }

    var body: some View {
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Circle()
                    .trim(
                        from: CGFloat((seg.startAngle + 90) / 360),
                        to: CGFloat((seg.endAngle + 90) / 360)
                    )
                    .stroke(seg.color, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            if let label = centerLabel {
                VStack(spacing: 1) {
                    Text(label.0)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(label.1)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(strokeWidth / 2 + 2)
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


