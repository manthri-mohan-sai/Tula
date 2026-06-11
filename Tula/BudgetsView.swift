import SwiftUI
import SwiftData

/// Top-level budgets screen. Always shows the OverallBudgetCard pinned at
/// the top (even when no budgets exist), then individual category budgets
/// grouped by period below.
///
/// The pinned card aggregates ALL category budgets by converting each to a
/// monthly equivalent (weekly × 52/12, yearly ÷ 12, monthly × 1) so the
/// total represents a single comparable monthly picture regardless of how
/// individual budgets reset.
struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(filter: #Predicate<Budget> { $0.isActive == true },
           sort: \Budget.createdAt, order: .reverse)
    private var budgets: [Budget]

    @Query private var expenses: [Expense]

    @State private var showingAddBudget   = false
    @State private var showingOverallEdit = false
    @State private var editingBudget: Budget?
    @State private var selectedTab: BudgetTab = .overall

    private enum BudgetTab { case overall, category }

    // MARK: - Derived

    /// The stored Overall budget record, if the user has set one.
    private var overallBudget: Budget? {
        budgets.first { $0.category == nil }
    }

    /// All active category budgets across any period.
    private var allCategoryBudgets: [Budget] {
        budgets.filter { $0.category != nil }
    }

    /// Converts any budget's amount to a monthly equivalent so the
    /// pinned card can aggregate across periods fairly.
    private func monthlyEquivalent(_ budget: Budget) -> Double {
        switch budget.period {
        case .weekly:  return budget.amount * (52.0 / 12.0)
        case .monthly: return budget.amount
        case .yearly:  return budget.amount / 12.0
        }
    }

    /// Sum of all category budgets expressed as monthly equivalents.
    private var categoryMonthlySum: Double {
        allCategoryBudgets.reduce(0) { $0 + monthlyEquivalent($1) }
    }

    /// The number shown as "total" in the pinned card.
    /// Uses the user-set Overall amount when it exceeds the auto-sum;
    /// otherwise falls back to the auto-sum.
    private var overallDisplayTotal: Double {
        max(overallBudget?.amount ?? 0, categoryMonthlySum)
    }

    /// Portion of the overall total not covered by any category budget.
    private var uncategorizedAmount: Double {
        max(0, overallDisplayTotal - categoryMonthlySum)
    }

    /// Actual spending in the current calendar month across all categories.
    private var totalMonthlySpent: Double {
        let cal = Calendar.current
        guard let window = cal.dateInterval(of: .month, for: .now) else { return 0 }
        return expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Sectioning

    /// Category budgets grouped by period (Monthly → Weekly → Yearly).
    /// Overall budgets are excluded — they live only in the pinned card.
    private var sectionedBudgets: [(period: BudgetPeriod, budgets: [Budget])] {
        let orderedPeriods: [BudgetPeriod] = [.monthly, .weekly, .yearly]
        return orderedPeriods.compactMap { p in
            let items = budgets
                .filter { $0.period == p && $0.category != nil }
                .sorted { a, b in
                    a.progress(in: expenses) > b.progress(in: expenses)
                }
            return items.isEmpty ? nil : (p, items)
        }
    }

    // MARK: - Budget Callout

    private var budgetCallout: some View {
        let overCount = allCategoryBudgets.filter { $0.status(in: expenses) == .overBudget }.count
        let warningCount = allCategoryBudgets.filter { $0.status(in: expenses) == .warning }.count
        let attentionCount = overCount + warningCount

        return Group {
            if attentionCount > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(overCount > 0 ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(attentionCount) budget\(attentionCount == 1 ? "" : "s") need\(attentionCount == 1 ? "s" : "") attention")
                            .font(.subheadline.weight(.semibold))
                        if overCount > 0 && warningCount > 0 {
                            Text("\(overCount) over budget · \(warningCount) near limit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((overCount > 0 ? Color.red : Color.orange).opacity(0.1))
                )
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    Text("All budgets on track")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.green.opacity(0.1))
                )
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Segmented tab picker
            Picker("Budget View", selection: $selectedTab) {
                Text("Overall").tag(BudgetTab.overall)
                Text("Category").tag(BudgetTab.category)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.tulaBackground)

            // Tab content
            if selectedTab == .overall {
                overallTab
            } else {
                categoryTab
            }
        }
        .background(Color.tulaBackground)
        .navigationTitle("Budgets")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingAddBudget = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .tint(.primary)
                .accessibilityLabel("Add Budget")
            }
        }
        .sheet(isPresented: $showingAddBudget) {
            BudgetFormView(categoryAutoTotal: categoryMonthlySum)
        }
        .sheet(isPresented: $showingOverallEdit) {
            BudgetFormView(existingBudget: overallBudget,
                           categoryAutoTotal: categoryMonthlySum,
                           lockedScope: true,
                           initialScope: .overall)
        }
        .sheet(item: $editingBudget) { b in
            BudgetFormView(existingBudget: b,
                           categoryAutoTotal: categoryMonthlySum)
        }
    }

    // MARK: - Overall tab

    private var overallTab: some View {
        ScrollView {
            OverallBudgetCard(
                categoryBudgets:   allCategoryBudgets,
                overallBudget:     overallBudget,
                monthlyEquivalent: monthlyEquivalent,
                displayTotal:      overallDisplayTotal,
                uncategorized:     uncategorizedAmount,
                totalMonthlySpent: totalMonthlySpent,
                expenses:          expenses,
                currencyCode:      currencyCode
            ) {
                showingOverallEdit = true
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Category tab

    private var categoryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sectionedBudgets.isEmpty {
                    categoryEmptyPrompt
                } else {
                    budgetCallout

                    ForEach(sectionedBudgets, id: \.period) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.period.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            ForEach(section.budgets) { budget in
                                NavigationLink {
                                    BudgetTransactionsView(
                                        budget: budget,
                                        expenses: expenses,
                                        currencyCode: currencyCode
                                    )
                                } label: {
                                    BudgetCard(budget: budget,
                                               expenses: expenses,
                                               currencyCode: currencyCode)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Category empty prompt

    private var categoryEmptyPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("No Category Budgets")
                    .font(.subheadline.weight(.semibold))
                Text("Add caps for Groceries, Transport, or any\ncategory — they roll up into the card above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Haptics.tap()
                showingAddBudget = true
            } label: {
                Label("Add Budget", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.tulaBrandFallback, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }

    // MARK: - Delete

    private func delete(_ budget: Budget) {
        Haptics.warning()
        context.delete(budget)
        try? context.save()
    }
}

// MARK: - Overall Budget Card

/// Pinned summary card at the top of BudgetsView.
///
/// Aggregates all category budgets by converting each to a monthly
/// equivalent (weekly × 52/12, yearly ÷ 12, monthly × 1). The donut
/// chart on the right shows how the monthly total is split across
/// categories; the left column shows the portion not allocated to any
/// specific category ("Uncategorized"). A progress bar tracks actual
/// monthly spending vs the total.
struct OverallBudgetCard: View {
    let categoryBudgets:   [Budget]
    let overallBudget:     Budget?
    let monthlyEquivalent: (Budget) -> Double
    let displayTotal:      Double
    let uncategorized:     Double
    let totalMonthlySpent: Double
    let expenses:          [Expense]
    let currencyCode:      String
    let onEdit:            () -> Void

    private var progress: Double {
        guard displayTotal > 0 else { return 0 }
        return totalMonthlySpent / displayTotal
    }

    private var isOverBudget: Bool { progress > 1.0 }

    private var daysElapsedThisMonth: Int {
        let cal = Calendar.current
        guard let start = cal.dateInterval(of: .month, for: .now)?.start else { return 1 }
        let days = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: .now)).day ?? 0
        return max(1, days + 1)
    }

    private var daysRemainingThisMonth: Int {
        let cal = Calendar.current
        guard let end = cal.dateInterval(of: .month, for: .now)?.end else { return 0 }
        return max(0, cal.dateComponents([.day], from: .now, to: end).day ?? 0)
    }

    private var dailyAvgSpend: Double {
        totalMonthlySpent / Double(daysElapsedThisMonth)
    }

    private var dailyAllowance: Double? {
        let remaining = displayTotal - totalMonthlySpent
        guard remaining > 0, daysRemainingThisMonth > 0 else { return nil }
        return remaining / Double(daysRemainingThisMonth)
    }

    private var lastMonthSpent: Double {
        let cal = Calendar.current
        guard let lastMonth = cal.date(byAdding: .month, value: -1, to: .now),
              let window = cal.dateInterval(of: .month, for: lastMonth) else { return 0 }
        return expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .reduce(0) { $0 + $1.amount }
    }

    private var vsLastMonth: (pct: Int, isUp: Bool)? {
        guard lastMonthSpent > 0 else { return nil }
        let change = ((totalMonthlySpent - lastMonthSpent) / lastMonthSpent) * 100
        let pct = Int(abs(change))
        guard pct > 0 else { return nil }
        return (pct, change >= 0)
    }

    private var topCategory: (name: String, amount: Double, color: Color)? {
        let cal = Calendar.current
        guard let window = cal.dateInterval(of: .month, for: .now) else { return nil }
        let monthExpenses = expenses.filter { $0.date >= window.start && $0.date < window.end }
        let grouped = Dictionary(grouping: monthExpenses, by: { $0.category?.name ?? "Uncategorized" })
        guard let top = grouped.max(by: {
            $0.value.reduce(0) { $0 + $1.amount } < $1.value.reduce(0) { $0 + $1.amount }
        }) else { return nil }
        let amount = top.value.reduce(0) { $0 + $1.amount }
        let color = Color(hex: top.value.first?.category?.colorHex ?? "#D97706")
        return (top.key, amount, color)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            Divider()
            amountRow
            if displayTotal > 0 {
                overallStatBoxes
            }
            if categoryBudgets.isEmpty {
                Text("Add category budgets below to start allocating your spending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                legendRows
            }
            if let comparison = vsLastMonth {
                comparisonRow(comparison)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Monthly Overview")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                Haptics.tap()
                onEdit()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.caption2.weight(.bold))
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.tulaBrandFallback.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.tulaBrandFallback)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Amount Row

    private var amountRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Currency.format(displayTotal, code: currencyCode))
                    .font(.title2.bold())
                    .foregroundStyle(displayTotal > 0 ? .primary : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: displayTotal))
                    .animation(.snappy(duration: 0.35), value: displayTotal)

                Text("Total Budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if displayTotal > 0 {
                VStack(alignment: .trailing) {
                    if isOverBudget {
                        Text(Currency.format(totalMonthlySpent - displayTotal, code: currencyCode))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.red)
                            .monospacedDigit()
                        Text("Over budget")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        let remaining = displayTotal - totalMonthlySpent
                        Text(Currency.format(remaining, code: currencyCode))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(progress >= 0.75 ? .orange : .primary)
                            .monospacedDigit()
                        Text("Remaining")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Stat Boxes

    private var overallStatBoxes: some View {
        HStack(spacing: 10) {
            overallStatBox(
                value: Currency.format(dailyAvgSpend, code: currencyCode),
                label: "Daily Avg",
                color: .primary
            )

            if let allowance = dailyAllowance {
                overallStatBox(
                    value: Currency.format(allowance, code: currencyCode),
                    label: "Per Day Left",
                    color: progress >= 0.75 ? .orange : .primary
                )
            } else if isOverBudget {
                overallStatBox(
                    value: "—",
                    label: "Over Budget",
                    color: .red
                )
            }

            overallStatBox(
                value: daysRemainingThisMonth == 0 ? "Last Day" : "\(daysRemainingThisMonth)",
                label: daysRemainingThisMonth == 1 ? "Day Left" : "Days Left",
                color: .primary
            )
        }
    }

    private func overallStatBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(uiColor: .tertiarySystemFill).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Comparison Row

    private func comparisonRow(_ comparison: (pct: Int, isUp: Bool)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: comparison.isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(comparison.isUp ? .red : .green)
            Text("\(comparison.pct)% \(comparison.isUp ? "more" : "less") than last month")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let top = topCategory {
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(top.color)
                        .frame(width: 6, height: 6)
                    Text("Top: \(top.name)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Stacked Bar + Legend (iCloud-style)

    @State private var barAnimated = false

    private var spentSortedBudgets: [Budget] {
        categoryBudgets
            .filter { $0.spent(in: expenses) > 0 }
            .sorted { $0.spent(in: expenses) > $1.spent(in: expenses) }
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Spending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Currency.format(totalMonthlySpent, code: currencyCode)) of \(Currency.format(displayTotal, code: currencyCode))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(spentSortedBudgets) { budget in
                        let spent = budget.spent(in: expenses)
                        let fraction = displayTotal > 0 ? min(spent / displayTotal, 1.0) : 0
                        let catColor = Color(hex: budget.category?.colorHex ?? "#D97706")

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(catColor)
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                // Animate the whole bar with a scale transform instead of
                // animating individual frame widths — pure GPU transform,
                // no layout recalculation per frame = no jitter.
                .scaleEffect(x: barAnimated ? 1 : 0, anchor: .leading)
            }
            .frame(height: 18)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onAppear {
                withAnimation(.spring(response: 0.65, dampingFraction: 0.82).delay(0.15)) {
                    barAnimated = true
                }
            }

            let columns = [GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(spentSortedBudgets) { budget in
                    let spent = budget.spent(in: expenses)
                    let pct = totalMonthlySpent > 0 ? Int(spent / totalMonthlySpent * 100) : 0
                    let catColor = Color(hex: budget.category?.colorHex ?? "#D97706")

                    HStack(spacing: 5) {
                        Circle()
                            .fill(catColor)
                            .frame(width: 8, height: 8)
                        Text("\(budget.displayName) \(pct)%")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            }

        }
    }
}

// MARK: - Budget Card

/// Unified budget card — every budget on the screen renders this. Combines
/// the at-a-glance progress info (icon, name, spent/cap, pace, progress bar,
/// days left) with the "where it went" breakdown that used to be reserved
/// for a single featured budget.
///
/// For Overall budgets the breakdown shows top categories; for category-
/// scoped budgets it shows top merchants. Capped at 3 entries so cards
/// stay compact and stack-friendly when the user has many budgets.
struct BudgetCard: View {
    let budget: Budget
    let expenses: [Expense]
    let currencyCode: String

    private var spent: Double { budget.spent(in: expenses) }
    private var progressValue: Double { budget.progress(in: expenses) }
    private var remaining: Double { budget.remaining(in: expenses) }
    private var status: Budget.Status { budget.status(in: expenses) }
    private var pace: BudgetPace { budget.pace(in: expenses) }
    private var daysLeft: Int { budget.daysRemaining() }

    private var iconColor: Color {
        if let cat = budget.category {
            return Color(hex: cat.colorHex)
        }
        return Color.tulaBrandFallback
    }

    private var iconKey: String {
        budget.category?.iconKey ?? "infinity"
    }

    private var paceColor: Color {
        switch pace {
        case .underPace, .onTrack: return .secondary
        case .overPace:             return Color.tulaBrandFallback
        case .overBudget:           return .red
        }
    }

    private var projectedOvershoot: Double? {
        guard pace == .overPace else { return nil }
        let elapsed = budget.elapsedFraction()
        guard elapsed > 0.05 else { return nil }
        // Lump-sum guard: if budget is nearly used but only 1-2 transactions,
        // the linear projection is meaningless (e.g. a single monthly transfer).
        // Many transactions (shopping, food) = real pattern, keep projecting.
        if progressValue >= 0.9 && periodExpenses.count <= 2 { return nil }
        let projected = spent / elapsed
        let overshoot = projected - budget.amount
        return overshoot > 0 ? overshoot : nil
    }

    /// Expenses inside the current period, filtered to this budget's scope.
    private var periodExpenses: [Expense] {
        let window = budget.currentPeriodWindow()
        return expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .filter { exp in
                guard let cat = budget.category else { return true }
                return exp.category?.id == cat.id
            }
    }

    /// Top 3 buckets where the money went. Categories for Overall budgets,
    /// merchants for category-scoped ones.
    private var breakdown: [BreakdownBucket] {
        let isOverall = (budget.category == nil)
        let grouped: [String: (amount: Double, color: Color, icon: String)] = Dictionary(
            grouping: periodExpenses,
            by: { exp -> String in
                if isOverall {
                    return exp.category?.name ?? "Uncategorized"
                } else {
                    return exp.merchant?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                        ?? "No merchant"
                }
            }
        ).mapValues { exps -> (Double, Color, String) in
            let sum = exps.reduce(0) { $0 + $1.amount }
            let color: Color = {
                if isOverall, let hex = exps.first?.category?.colorHex {
                    return Color(hex: hex)
                }
                return Color.tulaBrandFallback
            }()
            let icon: String = {
                if isOverall {
                    return exps.first?.category?.iconKey ?? "questionmark.circle"
                }
                return "storefront"
            }()
            return (sum, color, icon)
        }

        return grouped
            .map { BreakdownBucket(name: $0.key, amount: $0.value.amount,
                                   color: $0.value.color, icon: $0.value.icon) }
            .sorted { $0.amount > $1.amount }
            .prefix(3)
            .map { $0 }
    }

    private var breakdownMax: Double {
        breakdown.first?.amount ?? 1
    }



    private var percentText: String {
        let pct = Int(min(progressValue, 9.99) * 100)
        return "\(pct)%"
    }

    private var ringColor: Color {
        if status == .overBudget { return .red }
        if status == .warning { return .orange }
        return iconColor
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                // Left: name, percentage, spent/cap
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: iconKey)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(iconColor)
                            .frame(width: 26, height: 26)
                            .background(iconColor.opacity(0.15), in: Circle())
                        Text(budget.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    Text(percentText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(ringColor)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progressValue))
                        .animation(.snappy(duration: 0.35), value: progressValue)

                    Text("\(Currency.format(spent, code: currencyCode))/\(Currency.format(budget.amount, code: currencyCode))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()

                // Right: activity ring
                budgetRing
            }

            footerRow

            if !breakdown.isEmpty {
                Divider().padding(.vertical, 2)
                breakdownSection
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .contentShape(Rectangle())

    }

    // MARK: - Ring

    private var budgetRing: some View {
        ActivityRingView(progress: progressValue, ringColor: ringColor, lineWidth: 12)
            .frame(width: 56, height: 56)
    }

    // MARK: - Footer

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(pace.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(paceColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(paceColor)

                if pace == .overBudget {
                    Text("Over by \(Currency.format(abs(remaining), code: currencyCode))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                } else if remaining <= 0 {
                    Text("· Budget fully used")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else if let allowance = dailyAllowance {
                    Text("· \(Currency.format(allowance, code: currencyCode))/day")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text("· \(daysLeftLabel)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            if let overshoot = projectedOvershoot {
                Text("Projected \(Currency.format(overshoot, code: currencyCode)) over budget")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .monospacedDigit()
            }
        }
    }

    private var dailyAllowance: Double? {
        guard daysLeft > 0, remaining > 0 else { return nil }
        return remaining / Double(daysLeft)
    }

    private var daysLeftLabel: String {
        if daysLeft == 0 { return "Period ending" }
        if daysLeft == 1 { return "1 day left" }
        return "\(daysLeft) days left"
    }

    // MARK: - Breakdown

    private var breakdownTitle: String {
        budget.category == nil ? "Where it went" : "Top merchants"
    }

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(breakdownTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)

            VStack(spacing: 8) {
                ForEach(breakdown) { bucket in
                    BreakdownRow(
                        bucket: bucket,
                        maxAmount: breakdownMax,
                        currencyCode: currencyCode
                    )
                }
            }
        }
    }
}

// MARK: - Progress Bar

/// Thin pill-shaped progress bar. Fill is brand amber by default,
/// switches to red when over budget. Over-budget bars are visually
/// full (the overflow indicator is the red badge in the row above).
struct BudgetProgressBar: UIViewRepresentable {
    let progress: Double
    let isOverBudget: Bool
    var height: CGFloat = 6

    func makeUIView(context: Context) -> BudgetProgressUIView {
        BudgetProgressUIView(barHeight: height)
    }

    func updateUIView(_ view: BudgetProgressUIView, context: Context) {
        view.update(
            progress: min(max(progress, 0), 1.0),
            fillColor: UIColor(isOverBudget ? .red : Color.tulaBrandFallback)
        )
    }
}

final class BudgetProgressUIView: UIView {
    private let trackView = UIView()
    private let fillView = UIView()
    private let barHeight: CGFloat
    private var targetProgress: Double = 0
    private var hasAppeared = false

    init(barHeight: CGFloat) {
        self.barHeight = barHeight
        super.init(frame: .zero)
        trackView.backgroundColor = .tertiarySystemFill
        trackView.clipsToBounds = true
        addSubview(trackView)
        trackView.addSubview(fillView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: barHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        let r = barHeight / 2
        trackView.frame = bounds
        trackView.layer.cornerRadius = r
        fillView.layer.cornerRadius = r

        if !hasAppeared {
            hasAppeared = true
            fillView.frame = CGRect(x: 0, y: 0, width: 0, height: bounds.height)
            UIView.animate(withDuration: 0.4, delay: 0.1, options: .curveEaseOut) {
                self.fillView.frame = CGRect(
                    x: 0, y: 0,
                    width: self.bounds.width * self.targetProgress,
                    height: self.bounds.height
                )
            }
        }
    }

    func update(progress: Double, fillColor: UIColor) {
        let changed = targetProgress != progress
        targetProgress = progress
        fillView.backgroundColor = fillColor

        if hasAppeared && changed {
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
                self.fillView.frame = CGRect(
                    x: 0, y: 0,
                    width: self.bounds.width * progress,
                    height: self.bounds.height
                )
            }
        } else if !hasAppeared {
            setNeedsLayout()
        }
    }
}


// MARK: - Breakdown Bucket & Row

struct BreakdownBucket: Identifiable {
    let id = UUID()
    let name: String
    let amount: Double
    let color: Color
    let icon: String
}

private struct BreakdownRow: View {
    let bucket: BreakdownBucket
    let maxAmount: Double
    let currencyCode: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bucket.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(bucket.color)
                .frame(width: 24, height: 24)
                .background(bucket.color.opacity(0.15), in: Circle())

            Text(bucket.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(Currency.format(bucket.amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

// MARK: - Budget Transactions View

struct BudgetTransactionsView: View {
    let budget: Budget
    let expenses: [Expense]
    let currencyCode: String

    @State private var showingEdit = false


    private var periodExpenses: [Expense] {
        let window = budget.currentPeriodWindow()
        return expenses
            .filter { $0.date >= window.start && $0.date < window.end }
            .filter { exp in
                guard let cat = budget.category else { return true }
                return exp.category?.id == cat.id
            }
            .sorted { $0.date > $1.date }
    }

    private var spent: Double { budget.spent(in: expenses) }
    private var rem: Double { budget.remaining(in: expenses) }
    private var progressValue: Double { budget.progress(in: expenses) }
    private var isOverBudget: Bool { budget.status(in: expenses) == .overBudget }

    private var iconColor: Color {
        if let cat = budget.category {
            return Color(hex: cat.colorHex)
        }
        return Color.tulaBrandFallback
    }

    private var iconKey: String {
        budget.category?.iconKey ?? "infinity"
    }

    private var percentText: String {
        "\(Int(min(progressValue, 9.99) * 100))%"
    }

    private var ringColor: Color { isOverBudget ? .red : iconColor }
    private var daysLeft: Int { budget.daysRemaining() }

    private var dailyAllowance: Double? {
        guard daysLeft > 0, rem > 0 else { return nil }
        return rem / Double(daysLeft)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader
                transactionsSection
                    .padding(.top, 20)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [ringColor.opacity(0.10), ringColor.opacity(0.04), Color.tulaBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 420)
                Color.tulaBackground
            }
            .ignoresSafeArea()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationTitle(budget.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingEdit = true
                } label: {
                    Text("Edit")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .sheet(isPresented: $showingEdit) {
            BudgetFormView(existingBudget: budget)
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        return VStack(spacing: 20) {
            ZStack {
                ActivityRingView(progress: progressValue, ringColor: ringColor,
                                 lineWidth: 18, trackOpacity: 0.15)

                Image(systemName: iconKey)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(ringColor)
            }
            .frame(width: 110, height: 110)

            VStack(spacing: 4) {
                Text(Currency.format(spent, code: currencyCode))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: spent))

                Text("of \(Currency.format(budget.amount, code: currencyCode)) \(budget.period.shortLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            statBoxes

            if isOverBudget {
                Text("Over by \(Currency.format(abs(rem), code: currencyCode))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 6)
        .padding(.horizontal, 16)

    }

    // MARK: - Stat Boxes

    private var statBoxes: some View {
        HStack(spacing: 12) {
            if let allowance = dailyAllowance {
                statBox(
                    title: Currency.format(allowance, code: currencyCode),
                    subtitle: "Per Day Left",
                    color: .primary
                )
            } else if isOverBudget {
                statBox(
                    title: percentText,
                    subtitle: "Budget Used",
                    color: .red
                )
            } else {
                statBox(
                    title: Currency.format(rem, code: currencyCode),
                    subtitle: "Remaining",
                    color: .primary
                )
            }

            statBox(
                title: daysLeft == 0 ? "Last Day" : "\(daysLeft)",
                subtitle: daysLeft == 0 ? "" : daysLeft == 1 ? "Day Left" : "Days Left",
                color: .primary
            )
        }
    }

    private func statBox(title: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Transactions Section

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(periodExpenses.count) transaction\(periodExpenses.count == 1 ? "" : "s") \(budget.period.shortLabel)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.3)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            if periodExpenses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No spending \(budget.period.shortLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(periodExpenses.enumerated()), id: \.element.id) { idx, expense in
                        ExpenseRow(expense: expense)
                            .padding(.horizontal, 14)
                        if idx < periodExpenses.count - 1 {
                            Divider()
                                .padding(.leading, 66)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.tulaCardSurface)
                )
            }
        }
    }
}

// MARK: - String helper

private extension String {
    /// Returns nil if the string is empty after trimming whitespace.
    /// Used to fall back from "" merchant strings to a real "No merchant" label.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

