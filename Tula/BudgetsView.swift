import SwiftUI
import SwiftData

/// Top-level list of all budgets. Reached from Home toolbar.
///
/// Layout: grouped by period (Monthly / Weekly / Yearly) so the user sees
/// what resets when. Each row shows the category, spent/total, progress bar,
/// remaining headroom, and days left in the period.
struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(filter: #Predicate<Budget> { $0.isActive == true },
           sort: \Budget.createdAt, order: .reverse)
    private var budgets: [Budget]

    @Query private var expenses: [Expense]

    @State private var showingAddBudget = false
    @State private var editingBudget: Budget?

    // MARK: - Sectioning

    /// Groups budgets by period so all monthly budgets appear together,
    /// then weekly, then yearly. Within a period: Overall first (special),
    /// then by createdAt (newest first, matching @Query order).
    private var sectionedBudgets: [(period: BudgetPeriod, budgets: [Budget])] {
        // Use a fixed period order — monthly is the dominant case, show first.
        let orderedPeriods: [BudgetPeriod] = [.monthly, .weekly, .yearly]
        return orderedPeriods.compactMap { p in
            let items = budgets
                .filter { $0.period == p }
                .sorted { lhs, rhs in
                    // Overall always sorts first within a period
                    if lhs.category == nil && rhs.category != nil { return true }
                    if lhs.category != nil && rhs.category == nil { return false }
                    return lhs.createdAt > rhs.createdAt
                }
            return items.isEmpty ? nil : (p, items)
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if budgets.isEmpty {
                emptyState
            } else {
                budgetsList
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
            BudgetFormView()
        }
        .sheet(item: $editingBudget) { b in
            BudgetFormView(existingBudget: b)
        }
    }

    // MARK: - List

    private var budgetsList: some View {
        List {
            ForEach(sectionedBudgets, id: \.period) { section in
                Section {
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
                        .listRowInsets(EdgeInsets(top: 6, leading: 16,
                                                  bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .onDelete { offsets in
                        delete(from: section.budgets, at: offsets)
                    }
                } header: {
                    Text(section.period.displayName)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.pie")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No Budgets Yet")
                .font(.title3.weight(.semibold))
            Text("Set spending caps for categories\nor an overall monthly limit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                showingAddBudget = true
            } label: {
                Label("Create Budget", systemImage: "plus")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.tulaBrandFallback, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Delete

    private func delete(from list: [Budget], at offsets: IndexSet) {
        Haptics.warning()
        for index in offsets {
            context.delete(list[index])
        }
        try? context.save()
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
