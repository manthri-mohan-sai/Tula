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
    var suggestion: RecurringSuggestion? = nil
    var categoryID: UUID? = nil
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
    case recurringSuggestion
}

// MARK: - Recurring Suggestion

struct RecurringSuggestion: Identifiable {
    let id = UUID()
    let merchant: String
    let frequency: RecurringFrequency
    let category: Category?
    let account: Account?
    let isVariable: Bool
    let lastAmount: Double
    let amountRange: (low: Double, high: Double)?
    let dayOfMonth: Int
}

// MARK: - Engine

enum InsightEngine {

    /// Returns insights ordered by priority (highest first). The view layer
    /// usually shows just the top one or a small carousel.
    static func generate(
        expenses: [Expense],
        accounts: [Account],
        currencyCode: String,
        recurringRules: [RecurringRule] = []
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
            let trailingByCategory = Dictionary(grouping: trailing90) { $0.category?.id }

            for (catID, value) in categoryTotals {
                guard let catID else { continue }
                let (cat, amount) = value
                guard let catTrailing = trailingByCategory[catID], !catTrailing.isEmpty else { continue }

                let trailingTotal = catTrailing.reduce(0) { $0 + $1.amount }
                guard trailingTotal > 0 else { continue }

                let activeMonths = Set(catTrailing.map { calendar.component(.month, from: $0.date) }).count
                let divisor = max(Double(activeMonths), 1.0)
                let monthlyAvg = trailingTotal / divisor
                guard monthlyAvg >= 500 else { continue }

                let ratio = amount / monthlyAvg
                if ratio >= 1.5 {
                    let multiplier = ratio
                    let title: String
                    if multiplier >= 5 {
                        title = "\(cat.name) \(Int(multiplier))x higher"
                    } else {
                        let percent = Int(((ratio - 1) * 100).rounded())
                        title = "\(cat.name) +\(percent)%"
                    }
                    insights.append(Insight(
                        id: "catAlert-\(cat.id)",
                        kind: .categoryAlert,
                        title: title,
                        detail: "Above your typical monthly \(cat.name.lowercased()) spend.",
                        icon: cat.iconKey,
                        color: Color(hex: cat.colorHex),
                        priority: multiplier >= 3 ? 5 : 3,
                        categoryID: catID
                    ))
                }
            }
        }

        // MARK: Recurring pattern suggestions

        let suggestions = RecurringPatternDetector.detect(
            expenses: expenses,
            existingRules: recurringRules,
            currencyCode: currencyCode
        )
        for suggestion in suggestions.prefix(2) {
            let freqLabel = suggestion.frequency == .weekly ? "weekly" : "monthly"
            let variableHint = suggestion.isVariable ? " (amount varies)" : ""
            insights.append(Insight(
                id: "recurringSuggestion-\(suggestion.merchant.lowercased())",
                kind: .recurringSuggestion,
                title: "\(suggestion.merchant) looks recurring",
                detail: "Paid \(freqLabel)\(variableHint). Tap to set up auto-tracking.",
                icon: "arrow.clockwise.circle.fill",
                color: Color(hex: suggestion.category?.colorHex ?? "#D97706"),
                priority: 4,
                suggestion: suggestion
            ))
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

// MARK: - Recurring Pattern Detector

enum RecurringPatternDetector {

    struct MerchantGroup {
        let merchant: String
        let expenses: [Expense]
        let category: Category?
        let account: Account?
    }

    static func detect(
        expenses: [Expense],
        existingRules: [RecurringRule],
        currencyCode: String
    ) -> [RecurringSuggestion] {
        let calendar = Calendar.current
        let existingMerchants = Set(
            existingRules.compactMap { $0.merchant?.lowercased().trimmingCharacters(in: .whitespaces) }
            + existingRules.map { $0.name.lowercased().trimmingCharacters(in: .whitespaces) }
        )

        let merchantExpenses = Dictionary(grouping: expenses) { exp -> String? in
            guard let m = exp.merchant?.trimmingCharacters(in: .whitespaces),
                  !m.isEmpty else { return nil }
            return m.lowercased()
        }

        var suggestions: [RecurringSuggestion] = []

        for (key, exps) in merchantExpenses {
            guard let key, !key.isEmpty else { continue }
            if existingMerchants.contains(key) { continue }

            // Need at least 2 occurrences to detect a pattern
            guard exps.count >= 2 else { continue }

            let sorted = exps.sorted { $0.date < $1.date }
            let displayName = sorted.last?.merchant ?? key

            // Compute intervals between consecutive expenses (in days)
            var intervals: [Int] = []
            for i in 1..<sorted.count {
                let days = calendar.dateComponents([.day], from: sorted[i-1].date, to: sorted[i].date).day ?? 0
                intervals.append(days)
            }

            guard !intervals.isEmpty else { continue }

            let avgInterval = Double(intervals.reduce(0, +)) / Double(intervals.count)

            // Detect frequency based on average interval
            let frequency: RecurringFrequency?
            if avgInterval >= 5 && avgInterval <= 10 {
                // Weekly pattern (7 days ± 3)
                let allWeekly = intervals.allSatisfy { $0 >= 4 && $0 <= 11 }
                frequency = allWeekly ? .weekly : nil
            } else if avgInterval >= 25 && avgInterval <= 38 {
                // Monthly pattern (30 days ± 8)
                let allMonthly = intervals.allSatisfy { $0 >= 20 && $0 <= 45 }
                frequency = allMonthly ? .monthly : nil
            } else {
                frequency = nil
            }

            guard let detectedFrequency = frequency else { continue }

            // Determine if fixed or variable amount
            let amounts = sorted.map(\.amount)
            let minAmt = amounts.min() ?? 0
            let maxAmt = amounts.max() ?? 0
            let avgAmt = amounts.reduce(0, +) / Double(amounts.count)
            let spread = avgAmt > 0 ? (maxAmt - minAmt) / avgAmt : 0
            let isVariable = spread > 0.05

            // Most common category and account
            let category = mostCommon(sorted.compactMap(\.category))
            let account = mostCommon(sorted.compactMap(\.account))

            // Best guess for day of month
            let dayOfMonth: Int
            if detectedFrequency == .monthly {
                let days = sorted.map { calendar.component(.day, from: $0.date) }
                dayOfMonth = mostCommonValue(days) ?? calendar.component(.day, from: sorted.last!.date)
            } else {
                dayOfMonth = calendar.component(.day, from: sorted.last!.date)
            }

            let lastAmount = sorted.last?.amount ?? avgAmt

            suggestions.append(RecurringSuggestion(
                merchant: displayName,
                frequency: detectedFrequency,
                category: category,
                account: account,
                isVariable: isVariable,
                lastAmount: lastAmount,
                amountRange: isVariable ? (low: minAmt, high: maxAmt) : nil,
                dayOfMonth: dayOfMonth
            ))
        }

        // Sort by occurrence count (most frequent patterns first)
        return suggestions.sorted {
            merchantExpenses[$0.merchant.lowercased()]?.count ?? 0
            > merchantExpenses[$1.merchant.lowercased()]?.count ?? 0
        }
    }

    private static func mostCommon<T: Identifiable>(_ items: [T]) -> T? {
        let counts = Dictionary(grouping: items, by: { $0.id })
        return counts.max(by: { $0.value.count < $1.value.count })?.value.first
    }

    private static func mostCommonValue(_ values: [Int]) -> Int? {
        let counts = Dictionary(grouping: values, by: { $0 })
        return counts.max(by: { $0.value.count < $1.value.count })?.key
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
