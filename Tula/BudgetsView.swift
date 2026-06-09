import SwiftUI
import SwiftData
import Charts

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
                .sorted { $0.createdAt > $1.createdAt }
            return items.isEmpty ? nil : (p, items)
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
                           categoryAutoTotal: categoryMonthlySum)
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
                    ForEach(sectionedBudgets, id: \.period) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.period.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

                            ForEach(section.budgets) { budget in
                                Button {
                                    Haptics.tap()
                                    editingBudget = budget
                                } label: {
                                    BudgetCard(budget: budget,
                                               expenses: expenses,
                                               currencyCode: currencyCode)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        delete(budget)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
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
    let currencyCode:      String
    let onEdit:            () -> Void

    // MARK: - Pie data

    /// One slice per category budget (monthly-equivalent amount) plus an
    /// optional Uncategorized slice. A single placeholder keeps the chart
    /// from rendering empty when no budgets exist.
    private var pieSlices: [PieSlice] {
        var slices = categoryBudgets
            .map { b in
                PieSlice(
                    name:   b.displayName,
                    period: b.period,
                    amount: monthlyEquivalent(b),
                    color:  Color(hex: b.category?.colorHex ?? "#D97706")
                )
            }
            .sorted { $0.amount > $1.amount }

        if uncategorized > 0 {
            slices.append(PieSlice(
                name:   "Uncategorized",
                period: nil,
                amount: uncategorized,
                color:  Color(uiColor: .tertiarySystemFill)
            ))
        }

        // Guard: if everything is zero (or list is empty), show a placeholder.
        if slices.isEmpty || slices.allSatisfy({ $0.amount == 0 }) {
            return [PieSlice(name: "No budgets yet",
                             period: nil,
                             amount: 1,
                             color: Color(uiColor: .tertiarySystemFill))]
        }
        return slices
    }

    private var progress: Double {
        guard displayTotal > 0 else { return 0 }
        return totalMonthlySpent / displayTotal
    }

    private var isOverBudget: Bool { progress > 1.0 }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            Divider()
            bodyRow
            if categoryBudgets.isEmpty {
                Text("Add category budgets below to start allocating your spending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                legendRows
            }
            if displayTotal > 0 {
                Divider()
                progressSection
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
        HStack(spacing: 10) {
            Image(systemName: "infinity")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.tulaBrandFallback)
                .frame(width: 30, height: 30)
                .background(Color.tulaBrandFallback.opacity(0.15), in: Circle())

            Text("Total Budget")
                .font(.headline)

            Spacer()

            Button {
                Haptics.tap()
                onEdit()
            } label: {
                Text("Edit")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Body row (total budget amount + donut chart)

    private var bodyRow: some View {
        HStack(alignment: .center, spacing: 16) {

            // Left: total budget
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

                if displayTotal == 0 {
                    Text("No budgets set yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Right: donut chart
            Chart(pieSlices) { slice in
                SectorMark(
                    angle:        .value("Amount", slice.amount),
                    innerRadius:  .ratio(0.55),
                    angularInset: 1.5
                )
                .foregroundStyle(slice.color)
                .cornerRadius(3)
            }
            .frame(width: 110, height: 110)
        }
    }

    // MARK: - Legend

    private var legendRows: some View {
        VStack(spacing: 6) {
            ForEach(pieSlices) { slice in
                if slice.name != "No budgets yet" {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(slice.color)
                            .frame(width: 8, height: 8)

                        Text(slice.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        // Period badge for non-monthly budgets
                        if let period = slice.period, period != .monthly {
                            Text(period.rawValue)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Text(Currency.format(slice.amount, code: currencyCode))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            BudgetProgressBar(progress: progress, isOverBudget: isOverBudget)

            HStack {
                if isOverBudget {
                    Text("Over by \(Currency.format(totalMonthlySpent - displayTotal, code: currencyCode)) this month")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                } else {
                    Text("Spent \(Currency.format(totalMonthlySpent, code: currencyCode)) of \(Currency.format(displayTotal, code: currencyCode)) this month")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                let remaining = max(0, displayTotal - totalMonthlySpent)
                if remaining > 0 {
                    Text("\(Currency.format(remaining, code: currencyCode)) left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(progress >= 0.75 ? .orange : .secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Pie Slice

private struct PieSlice: Identifiable {
    let id     = UUID()
    let name:   String
    let period: BudgetPeriod?
    let amount: Double
    let color:  Color
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

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            BudgetProgressBar(progress: progressValue,
                              isOverBudget: status == .overBudget)
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

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: iconKey)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(budget.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(Currency.format(spent, code: currencyCode)) of \(Currency.format(budget.amount, code: currencyCode))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: spent))
                    .animation(.snappy(duration: 0.35), value: spent)
            }

            Spacer()

            paceBadge
        }
    }

    private var paceBadge: some View {
        Text(pace.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(paceColor.opacity(0.15), in: Capsule())
            .foregroundStyle(paceColor)
    }

    // MARK: - Footer

    /// Two compact stats below the progress bar — daily allowance (the
    /// key actionable number) and days left. Swaps to "over by" messaging
    /// when the cap is breached.
    private var footerRow: some View {
        HStack(spacing: 6) {
            if pace == .overBudget {
                Text("Over by \(Currency.format(abs(remaining), code: currencyCode))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .monospacedDigit()
            } else if let allowance = dailyAllowance {
                Text("\(Currency.format(allowance, code: currencyCode))/day")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(daysLeftLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(daysLeftLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
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
struct BudgetProgressBar: View {
    let progress: Double
    let isOverBudget: Bool
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1.0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .tertiarySystemFill))

                Capsule()
                    .fill(fillColor)
                    .frame(width: geo.size.width * clamped)
                    .animation(.easeOut(duration: 0.4), value: clamped)
            }
        }
        .frame(height: height)
    }

    private var fillColor: Color {
        isOverBudget ? .red : Color.tulaBrandFallback
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

// MARK: - String helper

private extension String {
    /// Returns nil if the string is empty after trimming whitespace.
    /// Used to fall back from "" merchant strings to a real "No merchant" label.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
