import WidgetKit
import SwiftUI

// MARK: - Setup
//
// Widget Extension target. Required setup:
//   1. File → New → Target → Widget Extension named "TulaWidget"
//   2. Replace generated file with this one
//   3. Add these files to TulaWidget target membership:
//        - WidgetSnapshot.swift
//        - Currency.swift
//        - SharedAppearance.swift
//   4. Both targets need App Group `group.com.app.Tula` (Signing & Capabilities)
//
// Widget gallery (v2):
//   Home screen
//     • Today (small)        — today's spend + sparkline + month progress
//     • Budgets (medium)     — top 3 budgets with progress bars
//     • Upcoming (medium)    — next 3 recurring expenses due
//     • Quick Actions (small) — Add / Voice deep-link buttons
//   Lock screen
//     • Today Inline         — one-line banner
//     • Today Circular       — budget burn ring
//     • Today Rectangular    — today + sparkline + month %
//
// Removed in v2:
//   • Quick Log (medium) — past-3-expenses was not actionable; replaced
//     by Upcoming which surfaces what's coming due (proactive value).

// MARK: - Provider

/// Reads the shared snapshot for every timeline refresh. Schedules a
/// fresh update every 30 minutes. The snapshot itself is refreshed by
/// the main app on foreground transitions; this just makes sure widgets
/// pick up changes if the user hasn't opened the app in a while.
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
        let entry = TulaWidgetEntry(date: .now, snapshot: WidgetStorage.read())
        let next = Calendar.current.date(
            byAdding: .minute,
            value: 30,
            to: .now
        ) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(next))
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
        TulaBudgetsWidget()
        TulaUpcomingWidget()
        TulaQuickActionsWidget()
    }
}

// MARK: - Today Widget
//
// One Widget supporting four families:
//   • .systemSmall    → home screen (sparkline + amount + progress)
//   • .accessoryInline → lockscreen top line
//   • .accessoryCircular → lockscreen circular slot (budget burn ring)
//   • .accessoryRectangular → lockscreen rectangular slot (today + spark)
//
// Each family renders a distinct view but all draw from the same Today
// snapshot data. Consolidating into one Widget keeps the gallery clean:
// the user picks "Tula Today" once, then chooses size per surface.

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

/// Dispatches to the right view based on the active widget family.
/// SwiftUI's `@Environment(\.widgetFamily)` tells us which one we're in.
struct TodayWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    var body: some View {
        switch family {
        case .accessoryInline:      InlineTodayView(snapshot: snapshot)
        case .accessoryCircular:    CircularTodayView(snapshot: snapshot)
        case .accessoryRectangular: RectangularTodayView(snapshot: snapshot)
        default:                    HomeTodayView(
            snapshot: snapshot
        )   // .systemSmall
        }
    }
}

// MARK: - Today: home screen (small)

/// Compact home-screen widget with subtle brand presence and an
/// information-rich trend chart. Layout layers (back to front):
///
///   1. **तु backdrop** — large faded glyph in the top-right corner,
///      bleeding off the edge. Reads as a watermark / brand presence
///      without competing with the data. Same treatment as the home
///      view's hero card.
///   2. Content stack: "Today" label, amount, trend chart with
///      day-of-week labels, month progress bar.
///
/// The trend chart now includes:
///   • Line + faint fill (the sparkline shape)
///   • Small dot at each data point (3pt) — gives "this is real data,
///     not just a decorative curve"
///   • Today's dot is larger and brand-colored — anchors the eye
///   • M T W T F S S day labels along the bottom, relative to today
///     so the chart is *legible* not just decorative
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

    /// Narrow day-of-week initials for the last 7 days, oldest-first,
    /// aligned to `snapshot.dailyTotals`. Computed against the current
    /// date so "today" is always the last column.
    private var dayLabels: [String] {
        let cal = Calendar.current
        let now = Date.now
        let f = DateFormatter()
        f.dateFormat = "EEEEE"  // M, T, W (single-letter narrow form)
        return (0..<7).map { i in
            let date = cal.date(byAdding: .day, value: -(6 - i), to: now) ?? now
            return f.string(from: date)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // तु backdrop — large faded glyph anchored to the top-
            // right, offset partly off-screen so it reads as a
            // watermark rather than a label. Opacity 0.22 (was 0.10)
            // gives the glyph real presence against the widget's
            // tertiary-fill background; 10% disappeared in normal
            // lighting. Size bumped to 130pt and offset reduced so
            // more of the glyph stays in the visible area — earlier
            // version had ~60% of the character clipped off-screen.
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
                // No contentTransition here — widgets render each
                // timeline snapshot as a discrete image, so SwiftUI
                // has no continuous view tree to interpolate against.
                // The modifier appears to do nothing in this context
                // even when the value is a valid Double. Apple's
                // own widgets (Wallet, Stocks, Health) all hard-cut
                // between refresh values for the same reason.

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

/// Single-line banner that sits at the top of the lockscreen, above the
/// clock. Monochrome — system applies tint. Format: "Today: ₹350" or
/// when budgeted, includes the remaining budget percentage to give one
/// pacing signal in the available width.
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

/// Small circle on the lockscreen, used in the per-side accessory slots.
/// Shows budget-burn as an open ring with the percentage in the center.
/// `widgetAccentable()` lets the user-chosen tint color paint the ring.
/// When no budget is set, falls back to today's amount as a stat label.
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
            // No budget cap → show today's amount in a static circle.
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

/// The richest lockscreen surface: today amount + 7-day sparkline + a
/// thin month-progress trail. Roughly 144x72 pt of space, so we keep
/// everything tight. Monochrome / accentable — adapts to the lockscreen
/// tint chosen by the user.
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

// MARK: - Budgets Widget

struct TulaBudgetsWidget: Widget {
    let kind: String = "TulaBudgetsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            BudgetsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budgets")
        .description("Your top monthly budgets at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

/// Medium widget — title row + up to 3 budget rows showing name, spent,
/// and a horizontal progress bar. Most-used budget rises to the top
/// (sorted by % used in the snapshot generation step).
struct BudgetsWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Budgets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !snapshot.topBudgets.isEmpty {
                    Text("This month")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if snapshot.topBudgets.isEmpty {
                emptyView
            } else {
                ForEach(Array(snapshot.topBudgets.prefix(3))) { entry in
                    BudgetWidgetRow(
                        entry: entry,
                        currencyCode: snapshot.currencyCode
                    )
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

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No budgets yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Open Tula to add one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct BudgetWidgetRow: View {
    let entry: WidgetSnapshot.Entry
    let currencyCode: String

    private var color: Color {
        entry.isOverall ? Color.tulaBrandFallback : Color(hex: entry.colorHex)
    }

    private var isOver: Bool { entry.spent > entry.amount }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.iconKey)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color)
                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(
                    "\(Currency.compact(entry.spent, code: currencyCode)) / \(Currency.compact(entry.amount, code: currencyCode))"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(isOver ? .red : .secondary)
                .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(isOver ? Color.red : color)
                        .frame(width: geo.size.width * min(entry.progress, 1.0))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Upcoming Widget (medium)
//
// Replaces the v1 Quick Log widget. Surfaces what's COMING due in the
// next several days — proactive, plan-ahead value. Tap-to-add deep link
// brings the user into Tula's Recurring section.

struct TulaUpcomingWidget: Widget {
    let kind: String = "TulaUpcomingWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: TulaWidgetProvider()
        ) { entry in
            UpcomingWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Upcoming")
        .description("Recurring expenses due soon.")
        .supportedFamilies([.systemMedium])
    }
}

struct UpcomingWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
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
                emptyView
            } else {
                VStack(spacing: 0) {
                    ForEach(
                        Array(
                            snapshot.upcomingRecurrings.prefix(3).enumerated()
                        ),
                        id: \.element.id
                    ) {
 index,
                        item in
                        UpcomingRow(
                            item: item,
                            currencyCode: snapshot.currencyCode
                        )
                        .padding(.vertical, 4)
                        if index < min(snapshot.upcomingRecurrings.count, 3) - 1 {
                            Divider().opacity(0.5)
                        }
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

    /// Total of all upcoming amounts in the snapshot — sits as a small
    /// trailing label in the header. Gives one-glance "how much is
    /// coming." A trailing visual anchor like Apple Calendar uses.
    private var totalLabel: String {
        let total = snapshot.upcomingRecurrings.reduce(0) { $0 + $1.amount }
        return Currency.compact(total, code: snapshot.currencyCode)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing recurring")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Set up rules in Tula → Recurring.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct UpcomingRow: View {
    let item: WidgetSnapshot.UpcomingRecurring
    let currencyCode: String

    /// Human-friendly due-date label. "Tomorrow" and "Today" are
    /// special-cased because they read better than "in 1 day" / "in
    /// 0 days." Beyond a week, we drop the relative phrasing and just
    /// show the absolute date so the user can plan further out.
    private var dueLabel: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now),
                                      to: cal
            .startOfDay(for: item.dueDate)).day ?? 0
        switch days {
        case ..<0:  return "overdue"
        case 0:     return "today"
        case 1:     return "tomorrow"
        case 2...6: return "in \(days) days"
        default:    return item.dueDate
                .formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private var color: Color { Color(hex: item.colorHex) }
    private var isOverdue: Bool { item.dueDate < Date.now }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.iconKey)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(dueLabel)
                    .font(.caption2)
                    .foregroundStyle(isOverdue ? .red : .secondary)
            }

            Spacer(minLength: 4)

            Text(Currency.format(item.amount, code: currencyCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

// MARK: - Quick Actions Widget (small)

/// Two large tap targets stacked horizontally — Add (typed) on the left,
/// Voice on the right. Each is wrapped in a `Link` so taps route to
/// distinct deep links rather than the whole widget opening to the same
/// destination.
struct TulaQuickActionsWidget: Widget {
    let kind: String = "TulaQuickActionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TulaWidgetProvider()) { _ in
            QuickActionsWidgetView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Quick Actions")
        .description("Tap to log by typing or by voice.")
        .supportedFamilies([.systemSmall])
    }
}

struct QuickActionsWidgetView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Log expense")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                Link(destination: URL(string: "tula://add")!) {
                    actionButton(icon: "plus", label: "Add",
                                 tint: Color.tulaBrandFallback)
                }
                Link(destination: URL(string: "tula://voice")!) {
                    actionButton(icon: "mic.fill", label: "Voice", tint: .red)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private func actionButton(icon: String, label: String, tint: Color) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint, in: Circle())
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

// MARK: - Sparkline

/// Minimal line chart for tight surfaces (lockscreen rectangular).
/// Pure SwiftUI `Path` — no Charts framework dependency (lighter at
/// widget refresh). Renders a thin stroked line + a faint fill under it.
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

// MARK: - Trend chart (with day labels)

/// Richer chart for the home-screen Today widget. Same fill + line as
/// SparklineView, plus:
///   • Small dot at every data point (3pt) — communicates "discrete
///     daily data," not a smooth interpolation
///   • Today's dot is bigger (6pt) and brand-filled — anchors the eye
///     to "where you are right now in the week"
///   • Day-of-week labels along the bottom — chart is actually readable
///     ("looks like I spent more Wednesday and Friday") instead of a
///     decorative squiggle
///
/// Separated from `SparklineView` because the lockscreen rectangular
/// surface needs the simpler version (monochrome, very tight space).
struct TrendChartView: View {
    let values: [Double]
    let dayLabels: [String]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let maxValue = values.max() ?? 0
            let safeMax = maxValue > 0 ? maxValue : 1
            let normalized = values.map { $0 / safeMax }
            // Reserve 9pt at the bottom for day labels.
            let labelHeight: CGFloat = 9
            let chartHeight = max(0, geo.size.height - labelHeight - 2)
            let stepX = values.count > 1
            ? geo.size.width / CGFloat(values.count - 1)
            : 0

            ZStack(alignment: .topLeading) {
                // Soft fill under the line.
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

                // Connecting line.
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

                // Dots at each data point. Today's (last index) gets
                // emphasis: brand-filled, 6pt; the rest are 3pt with a
                // muted fill so the eye reads them as supporting marks.
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

                // Day-of-week labels along the bottom.
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
