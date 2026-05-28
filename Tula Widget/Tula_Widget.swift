import WidgetKit
import SwiftUI

// MARK: - Setup instructions
//
// This file belongs to a separate Widget Extension target. To set it up:
//
// 1. In Xcode: File → New → Target → Widget Extension. Name it "TulaWidget".
//    Uncheck "Include Configuration App Intent" (we use a fixed widget,
//    not user-configurable for v1).
//
// 2. Replace the generated TulaWidget.swift with this file.
//
// 3. Add target membership to the Widget Extension for these files from the
//    main app:
//      - WidgetSnapshot.swift  (shared data model)
//      - Currency.swift        (formatting helpers, no Haptics dependency)
//      - SharedAppearance.swift (Color(hex:) + brand color)
//    For each file: select it, open File Inspector (⌥⌘1), and check the
//    TulaWidget target under "Target Membership". Tula must remain checked.
//
// 4. In Signing & Capabilities for BOTH targets (main app + TulaWidget):
//    + Capability → App Groups → add `group.com.app.Tula`.
//
// 5. Build & run on a real device or simulator. Long-press home screen →
//    + → search "Tula" → add a small or medium widget.

// MARK: - Provider

/// Reads the shared snapshot for every timeline refresh. We schedule a
/// fresh update every 30 minutes — the snapshot itself is refreshed by
/// the main app on foreground, so this just makes sure widgets pick up
/// changes if the user hasn't opened the app in a while.
struct TulaWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> TulaWidgetEntry {
        TulaWidgetEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (TulaWidgetEntry) -> Void) {
        completion(TulaWidgetEntry(date: .now, snapshot: WidgetStorage.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TulaWidgetEntry>) -> Void) {
        let entry = TulaWidgetEntry(date: .now, snapshot: WidgetStorage.read())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(next))
        completion(timeline)
    }
}

struct TulaWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

// MARK: - Widget Bundle (entry point)

/// The widget extension entry point. Exposes three distinct widgets in
/// iOS's widget gallery so the user can pick which one fits their home
/// screen: Today (small), Budgets (medium), Quick Log (medium).
@main
struct TulaWidgetBundle: WidgetBundle {
    var body: some Widget {
        TulaTodayWidget()
        TulaBudgetsWidget()
        TulaQuickLogWidget()
        TulaQuickActionsWidget()
    }
}

// MARK: - Today Widget (small)

struct TulaTodayWidget: Widget {
    let kind: String = "TulaTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TulaWidgetProvider()) { entry in
            TodayWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Today's spend and monthly budget pace.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Budgets Widget (medium)

struct TulaBudgetsWidget: Widget {
    let kind: String = "TulaBudgetsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TulaWidgetProvider()) { entry in
            BudgetsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Budgets")
        .description("Your top monthly budgets at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Quick Actions Widget (small)

/// Small widget with two big tap targets: + (type to add) and 🎤 (voice
/// add). Each target deep-links to a different entry path in the main
/// app — tula://add for typed entry, tula://voice for voice. Both routes
/// surface the Add Expense flow; voice additionally auto-starts the mic.
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

// MARK: - Quick Log Widget (medium)

/// Combined log + quick-add. Shows the last few expenses with the whole
/// widget acting as a tap target that opens the app to the Add Expense
/// sheet via the `tula://add` deep link.
struct TulaQuickLogWidget: Widget {
    let kind: String = "TulaQuickLogWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TulaWidgetProvider()) { entry in
            QuickLogWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                // The entire widget is a single tap surface — taps open
                // the main app and route to AddExpense.
                .widgetURL(URL(string: "tula://add"))
        }
        .configurationDisplayName("Quick Log")
        .description("Tap to log; see your recent expenses.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Small: Today

/// Small widget — hero number is today's total, with a thin month-cap
/// progress bar at the bottom for context. If no monthly budgets, the
/// bar is hidden and the spend stands alone.
struct TodayWidgetView: View {
    let snapshot: WidgetSnapshot

    private var monthProgress: Double {
        guard snapshot.monthlyBudgetCap > 0 else { return 0 }
        return min(snapshot.monthTotal / snapshot.monthlyBudgetCap, 1.0)
    }

    private var isOverMonthBudget: Bool {
        snapshot.monthlyBudgetCap > 0
            && snapshot.monthTotal > snapshot.monthlyBudgetCap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Today")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(Currency.format(snapshot.todayTotal, code: snapshot.currencyCode))
                .font(.system(size: 26, weight: .semibold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if snapshot.monthlyBudgetCap > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                            Capsule()
                                .fill(isOverMonthBudget
                                      ? .red
                                      : Color.tulaBrandFallback)
                                .frame(width: geo.size.width * monthProgress)
                        }
                    }
                    .frame(height: 4)
                    Text("\(Currency.compact(snapshot.monthTotal, code: snapshot.currencyCode)) of \(Currency.compact(snapshot.monthlyBudgetCap, code: snapshot.currencyCode)) this month")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium: Budgets

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
                Text("This month")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if snapshot.topBudgets.isEmpty {
                emptyView
            } else {
                VStack(spacing: 7) {
                    ForEach(snapshot.topBudgets.prefix(3)) { entry in
                        BudgetWidgetRow(
                            entry: entry,
                            currencyCode: snapshot.currencyCode
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                Text("\(Currency.compact(entry.spent, code: currencyCode)) / \(Currency.compact(entry.amount, code: currencyCode))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isOver ? .red : .secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(isOver ? .red : color)
                        .frame(width: geo.size.width * min(entry.progress, 1.0))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Quick Log Widget View

/// Header with brand "+" cue plus a tight list of the last 3 expenses.
/// Entire widget is a tap target (via `.widgetURL` on the configuration)
/// that opens the app to AddExpense — no buttons needed inside.
struct QuickLogWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — title + amber "+" hint communicates tap-to-add
            HStack {
                Text("Quick Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color.tulaBrandFallback)
                        .frame(width: 22, height: 22)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
            }

            if snapshot.recentExpenses.isEmpty {
                emptyView
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.recentExpenses.prefix(3).enumerated()),
                            id: \.element.id) { index, exp in
                        QuickLogRow(expense: exp, currencyCode: snapshot.currencyCode)
                            .padding(.vertical, 5)
                        if index < min(snapshot.recentExpenses.count, 3) - 1 {
                            Divider()
                                .opacity(0.5)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Nothing logged yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Tap to add your first expense.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct QuickLogRow: View {
    let expense: WidgetSnapshot.RecentExpense
    let currencyCode: String

    private var color: Color { Color(hex: expense.colorHex) }

    private var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(expense.date) { return "Today" }
        if cal.isDateInYesterday(expense.date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: expense.date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: expense.iconKey)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.15), in: Circle())

            Text(expense.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(Currency.format(expense.amount, code: currencyCode))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Text(relativeDate)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Quick Actions Widget View

/// Two large tap targets stacked horizontally — Add (typed) on the left,
/// Voice on the right. Each is wrapped in a `Link` so taps route to
/// distinct deep links rather than the whole widget opening to the same
/// destination. The small widget is just big enough to fit two prominent
/// buttons; we make them as tall and tappable as possible.
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
                    actionButton(
                        icon: "plus",
                        label: "Add",
                        tint: Color.tulaBrandFallback
                    )
                }

                Link(destination: URL(string: "tula://voice")!) {
                    actionButton(
                        icon: "mic.fill",
                        label: "Voice",
                        tint: .red
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
