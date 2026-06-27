import SwiftUI
import SwiftData

/// Triage screen for expenses that came in without a category — typically
/// from Quick Log voice when the parser couldn't infer one. Shows each
/// review-needed expense as a card with inline category chips for one-tap
/// categorization. Optionally creates a MerchantRule so the same merchant
/// auto-categorizes next time.
struct ReviewQueueView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(
        filter: #Predicate<Expense> { $0.category == nil },
        sort: \Expense.date, order: .reverse
    )
    private var pending: [Expense]

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query private var allMerchantRules: [MerchantRule]

    /// State for the "create rule?" confirmation dialog after assignment.
    @State private var ruleSuggestion: RuleSuggestion?

    /// Tracks which expense is currently showing the full picker sheet.
    @State private var pickingFor: Expense?

    /// Categories to show as inline chips (above the "More" overflow).
    /// Picks the 4 most-used active categories so the common cases are
    /// one tap away.
    private var topCategories: [Category] {
        let active = allCategories.filter { !$0.isArchived }
        return Array(
            active
                .sorted { $0.expenses.count > $1.expenses.count }
                .prefix(4)
        )
    }

    // MARK: - Body

    var body: some View {
        Group {
            if pending.isEmpty {
                allCaughtUp
            } else {
                list
            }
        }
        .background(Color.tulaBackground)
        .navigationTitle("Review")
        .tulaNavigationSubtitle(subtitleText)
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $pickingFor) { expense in
            CategoryPickerSheet(
                categories: allCategories.filter { !$0.isArchived },
                onPick: { cat in
                    pickingFor = nil
                    apply(category: cat, to: expense)
                }
            )
        }
    }

    private var subtitleText: String {
        guard !pending.isEmpty else { return "All caught up" }
        return pending.count == 1
            ? "1 expense to review"
            : "\(pending.count) expenses to review"
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(pending) { expense in
                    ReviewCard(
                        expense: expense,
                        suggestions: topCategories,
                        currencyCode: currencyCode,
                        onPick: { cat in apply(category: cat, to: expense) },
                        onMore: { pickingFor = expense }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .confirmationDialog(
            ruleSuggestion?.title ?? "",
            isPresented: Binding(
                get: { ruleSuggestion != nil },
                set: { if !$0 { ruleSuggestion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let s = ruleSuggestion {
                Button("Yes, always") {
                    createMerchantRule(merchant: s.merchant, category: s.category)
                    ruleSuggestion = nil
                }
                Button("Just this one", role: .cancel) {
                    ruleSuggestion = nil
                }
            }
        } message: {
            if let s = ruleSuggestion {
                Text("Should future \(s.merchant) expenses always be \(s.category.name)?")
            }
        }
    }

    // MARK: - All Caught Up

    private var allCaughtUp: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.green.opacity(0.85))
            Text("All caught up")
                .font(.title3.weight(.semibold))
            Text("Every expense is categorized.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    // MARK: - Assignment

    private func apply(category: Category, to expense: Expense) {
        Haptics.success()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            expense.category = category
        }
        try? context.save()

        // Only prompt to create a rule if there's a clean merchant string
        // and no existing rule covers it. Avoids dialog fatigue on common
        // cases (no merchant = nothing to remember).
        if let merchant = expense.merchant?.trimmingCharacters(in: .whitespaces),
           !merchant.isEmpty,
           !hasMerchantRule(for: merchant) {
            ruleSuggestion = RuleSuggestion(
                merchant: merchant,
                category: category,
                title: "Apply to future \(merchant) expenses?"
            )
        }
    }

    private func hasMerchantRule(for merchant: String) -> Bool {
        let lower = merchant.lowercased()
        return allMerchantRules.contains { lower.contains($0.pattern) }
    }

    private func createMerchantRule(merchant: String, category: Category) {
        let rule = MerchantRule(
            pattern: merchant,
            category: category,
            isUserDefined: true
        )
        context.insert(rule)
        try? context.save()
        Haptics.success()
    }
}

// MARK: - Rule Suggestion

private struct RuleSuggestion {
    let merchant: String
    let category: Category
    let title: String
}

// MARK: - Review Card

/// Single pending-review expense rendered as a tall card with merchant,
/// amount, account, and inline category-suggestion chips.
private struct ReviewCard: View {
    let expense: Expense
    let suggestions: [Category]
    let currencyCode: String
    let onPick: (Category) -> Void
    let onMore: () -> Void

    private var primaryLabel: String {
        if let merchant = expense.merchant?.trimmingCharacters(in: .whitespaces),
           !merchant.isEmpty {
            return merchant
        }
        return "Untagged spend"
    }

    private var secondaryLabel: String {
        var parts: [String] = []
        if let acct = expense.account { parts.append(acct.name) }
        parts.append(relativeDate(expense.date))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — merchant + amount
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(secondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Currency.format(expense.amount, code: currencyCode))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            // Chips
            chipRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }

    /// Wraps suggested category chips + a "More" overflow. Uses a FlowLayout-
    /// style approach via wrapping HStacks — kept simple since 4 chips + More
    /// always fits in two lines on iPhone widths.
    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions) { cat in
                    Button {
                        onPick(cat)
                    } label: {
                        chipLabel(name: cat.name,
                                  icon: cat.iconKey,
                                  color: Color(hex: cat.colorHex))
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onMore) {
                    chipLabel(name: "More", icon: "ellipsis", color: .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chipLabel(name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(name)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.18), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
        )
    }

    private func relativeDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}

// MARK: - Category Picker Sheet (overflow)

/// Grid-style picker used when "More" is tapped from a review chip row.
/// Surfaces every active category, not just the suggested four.
struct CategoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let categories: [Category]
    let onPick: (Category) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 200), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(categories) { cat in
                        Button {
                            Haptics.tap()
                            onPick(cat)
                        } label: {
                            categoryTile(cat)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.tulaBackground)
            .navigationTitle("Choose Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func categoryTile(_ cat: Category) -> some View {
        let color = Color(hex: cat.colorHex)
        return VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: cat.iconKey)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(color)
            }
            Text(cat.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }
}
