import Foundation
import SwiftUI

// MARK: - Models

/// One actionable observation about the user's spending. Insights are
/// generated fresh on each view render based on the current data — no
/// caching, no stale state.
struct Insight: Identifiable {
    let id: String
    let kind: InsightKind
    let title: String
    let detail: String
    let icon: String
    let color: Color
    let priority: Int   // higher = more important; engine sorts by this
}

enum InsightKind {
    case streak
    case cardDue
    case categoryAlert
    case biggestToday
    case todayTotal
    case monthPace
    case quietToday
    case bigSpender
}

// MARK: - Engine

enum InsightEngine {

    /// Returns insights ordered by priority (highest first). The view layer
    /// usually shows just the top one or a small carousel.
    static func generate(
        expenses: [Expense],
        accounts: [Account],
        currencyCode: String
    ) -> [Insight] {
        var insights: [Insight] = []
        let calendar = Calendar.current
        let now = Date.now

        // MARK: Today insights

        let todayStart = calendar.startOfDay(for: now)
        let todayExpenses = expenses.filter { $0.date >= todayStart }
        let todayTotal = todayExpenses.reduce(0) { $0 + $1.amount }

        if todayExpenses.isEmpty {
            // Quiet day prompt — encourages logging habit
            insights.append(Insight(
                id: "quietToday",
                kind: .quietToday,
                title: "Quiet day so far",
                detail: "Tap Quick Log to capture today's spends.",
                icon: "leaf.fill",
                color: .green,
                priority: 2
            ))
        } else {
            // Today total
            insights.append(Insight(
                id: "todayTotal",
                kind: .todayTotal,
                title: Currency.format(todayTotal, code: currencyCode),
                detail: "Spent today across \(todayExpenses.count) transaction\(todayExpenses.count == 1 ? "" : "s").",
                icon: "sun.max.fill",
                color: .orange,
                priority: 3
            ))

            // Biggest single expense today
            if let biggest = todayExpenses.max(by: { $0.amount < $1.amount }),
               biggest.amount >= todayTotal * 0.4,
               todayExpenses.count > 1 {
                let label = biggest.merchant ?? biggest.category?.name ?? "Top spend"
                insights.append(Insight(
                    id: "biggestToday",
                    kind: .biggestToday,
                    title: Currency.format(biggest.amount, code: currencyCode),
                    detail: "Biggest today — \(label).",
                    icon: "flame.fill",
                    color: .red,
                    priority: 3
                ))
            }
        }

        // MARK: Logging streak

        let streak = computeStreak(expenses: expenses, calendar: calendar, now: now)
        if streak >= 3 {
            insights.append(Insight(
                id: "streak",
                kind: .streak,
                title: "\(streak)-day streak",
                detail: streakMessage(for: streak),
                icon: "flame.fill",
                color: .orange,
                priority: streak >= 7 ? 5 : 4
            ))
        }

        // MARK: Card outstandings

        let creditCards = accounts.filter { $0.kind == .creditCard && !$0.isArchived }
        let highestCC = creditCards
            .filter { $0.derivedBalance > 0.01 }
            .max(by: { $0.derivedBalance < $1.derivedBalance })

        if let cc = highestCC, cc.derivedBalance > 1000 {
            insights.append(Insight(
                id: "cardDue-\(cc.id)",
                kind: .cardDue,
                title: Currency.format(cc.derivedBalance, code: currencyCode),
                detail: "Outstanding on \(cc.name).",
                icon: "creditcard.fill",
                color: Color(hex: cc.colorHex),
                priority: 4
            ))
        }

        // MARK: Monthly pace

        if let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
           let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) {

            let thisMonth = expenses.filter { $0.date >= monthStart }
            let thisTotal = thisMonth.reduce(0) { $0 + $1.amount }

            // Fair comparison: same number of days elapsed.
            let day = calendar.component(.day, from: now)
            if let cap = calendar.date(byAdding: .day, value: day, to: lastMonthStart) {
                let lastWindow = expenses
                    .filter { $0.date >= lastMonthStart && $0.date < cap }
                    .reduce(0) { $0 + $1.amount }

                if lastWindow > 0 && thisTotal > 0 {
                    let change = (thisTotal - lastWindow) / lastWindow
                    let percent = Int(abs(change * 100).rounded())

                    // Only show if meaningfully different
                    if percent >= 20 {
                        let isUp = change > 0
                        insights.append(Insight(
                            id: "monthPace",
                            kind: .monthPace,
                            title: "\(percent)% \(isUp ? "above" : "below") last month",
                            detail: "At this point in \(now.formatted(.dateTime.month(.wide))).",
                            icon: isUp ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill",
                            color: isUp ? .red : .green,
                            priority: percent >= 50 ? 4 : 2
                        ))
                    }
                }
            }
        }

        // MARK: Category spike (vs trailing-30-day baseline)

        if let monthStart = calendar.dateInterval(of: .month, for: now)?.start {
            let thisMonth = expenses.filter { $0.date >= monthStart }
            let categoryTotals = Dictionary(grouping: thisMonth) { $0.category?.id }
                .compactMapValues { exps -> (Category, Double)? in
                    guard let cat = exps.first?.category else { return nil }
                    return (cat, exps.reduce(0) { $0 + $1.amount })
                }

            guard let trailingStart = calendar.date(byAdding: .day, value: -90, to: now) else {
                return prioritized(insights)
            }
            let trailing90 = expenses.filter { $0.date >= trailingStart && $0.date < monthStart }
            let trailingTotals = Dictionary(grouping: trailing90) { $0.category?.id }
                .mapValues { exps in exps.reduce(0) { $0 + $1.amount } }

            // For each category, compute trailing-3-month monthly average
            for (catID, value) in categoryTotals {
                guard let catID else { continue }
                let (cat, amount) = value
                guard let trailing = trailingTotals[catID], trailing > 0 else { continue }

                let monthlyAvg = trailing / 3.0
                guard monthlyAvg >= 500 else { continue }    // ignore noise

                let ratio = amount / monthlyAvg
                if ratio >= 1.5 {
                    let percent = Int(((ratio - 1) * 100).rounded())
                    insights.append(Insight(
                        id: "catAlert-\(cat.id)",
                        kind: .categoryAlert,
                        title: "\(cat.name) +\(percent)%",
                        detail: "Above your typical monthly \(cat.name.lowercased()) spend.",
                        icon: cat.iconKey,
                        color: Color(hex: cat.colorHex),
                        priority: percent >= 100 ? 5 : 3
                    ))
                }
            }
        }

        return prioritized(insights)
    }

    // MARK: - Helpers

    private static func prioritized(_ insights: [Insight]) -> [Insight] {
        // Sort highest-priority first; cap at 5 for the carousel.
        Array(insights.sorted { $0.priority > $1.priority }.prefix(5))
    }

    /// Public-facing wrapper around the streak computation. Used by Home
    /// to render the streak chip in the hero card. Same algorithm as the
    /// internal insight engine — exposed so the chip and the insight
    /// stay perfectly in sync (no divergent "5-day streak" vs "6-day
    /// streak" between two surfaces).
    static func loggingStreak(expenses: [Expense]) -> Int {
        computeStreak(expenses: expenses, calendar: .current, now: .now)
    }

    /// Count consecutive days (including today) with at least one expense.
    /// "Today might not yet have a log" handling: streak = streak through
    /// yesterday if today is empty (so the user can see "5-day streak —
    /// don't break it").
    private static func computeStreak(expenses: [Expense], calendar: Calendar, now: Date) -> Int {
        guard !expenses.isEmpty else { return 0 }

        let daysWithExpenses = Set(expenses.map { calendar.startOfDay(for: $0.date) })

        var streak = 0
        var cursor = calendar.startOfDay(for: now)
        let todayHasExpenses = daysWithExpenses.contains(cursor)

        // If today has nothing yet, start the count from yesterday so
        // morning users still see the streak.
        if !todayHasExpenses {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        while daysWithExpenses.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        return streak
    }

    private static func streakMessage(for streak: Int) -> String {
        switch streak {
        case 3...6: return "Keep it up — \(streak) days strong."
        case 7...13: return "A full week of logging."
        case 14...29: return "Two weeks of consistent tracking."
        case 30...: return "A month-long habit. Impressive."
        default: return "Building the habit."
        }
    }
}

// MARK: - Insights Carousel View

/// Horizontally-paged carousel of insights with a custom dot indicator
/// rendered *below* the cards (not overlaid). The system `TabView` page
/// dots overlap card content at our compact height, so we hide them
/// (`indexDisplayMode: .never`) and draw our own row underneath.
///
/// Auto-rotates every 7 seconds. Manual swipes reset the timer so it
/// doesn't jump immediately after the user interacts. Single-insight
/// case skips the dot row entirely.
struct InsightsCarousel: View {
    let insights: [Insight]

    @State private var index: Int = 0
    @State private var autoRotateTask: Task<Void, Never>?

    /// Tappable target on a dot — taps animate the page change.
    private func go(to i: Int) {
        Haptics.selection()
        withAnimation(AppAnimation.gentle) { index = i }
    }

    var body: some View {
        if insights.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: Spacing.sm) {
                TabView(selection: $index) {
                    ForEach(Array(insights.enumerated()), id: \.element.id) { i, insight in
                        InsightCard(insight: insight)
                            .tag(i)
                    }
                }
                // Native page swipe with system dots disabled — we draw
                // our own below.
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 88)

                if insights.count > 1 {
                    dotIndicator
                }
            }
            .onAppear { startAutoRotate() }
            .onDisappear { stopAutoRotate() }
            .onChange(of: index) { _, _ in
                // Restart timer on swipe/tap — user wants a beat to read.
                stopAutoRotate()
                startAutoRotate()
            }
        }
    }

    /// Custom dot row. Active dot is wider (capsule), inactive dots are
    /// circles — the iOS-stock "scrollable indicator" pattern. Brand
    /// amber on the active dot anchors the carousel to Tula's palette
    /// without being loud.
    private var dotIndicator: some View {
        HStack(spacing: 6) {
            ForEach(insights.indices, id: \.self) { i in
                let isActive = i == index
                Capsule()
                    .fill(isActive ? Color.tulaBrandFallback : Color.gray.opacity(0.25))
                    .frame(width: isActive ? 16 : 6, height: 6)
                    .onTapGesture { go(to: i) }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: index)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private func startAutoRotate() {
        guard insights.count > 1 else { return }
        autoRotateTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(AppAnimation.gentle) {
                    index = (index + 1) % insights.count
                }
            }
        }
    }

    private func stopAutoRotate() {
        autoRotateTask?.cancel()
        autoRotateTask = nil
    }
}

// MARK: - Single Card

/// Single insight card. Layout:
/// - Color-tinted circular icon on the left
/// - Title + detail stacked, left-aligned
/// - Subtle "chip" badge in the top-right (when relevant) for context
private struct InsightCard: View {
    let insight: Insight

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(insight.color.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: insight.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(insight.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(insight.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .tulaGlass(cornerRadius: CornerRadius.medium)
    }
}
