import SwiftUI
import SwiftData

struct BudgetFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    let existingBudget: Budget?
    var categoryAutoTotal: Double = 0
    var lockedScope: Bool = false
    var initialScope: Scope = .category

    // MARK: - Form state

    @State private var scope: Scope = .category
    @State private var selectedCategory: Category?
    @State private var amount: Double = 0
    @State private var period: BudgetPeriod = .monthly
    @State private var showDeleteConfirm = false
    @FocusState private var amountFocused: Bool

    enum Scope: String, CaseIterable, Identifiable {
        case category = "Category"
        case overall  = "Overall"
        var id: String { rawValue }
    }

    init(existingBudget: Budget? = nil,
         categoryAutoTotal: Double = 0,
         lockedScope: Bool = false,
         initialScope: Scope = .category) {
        self.existingBudget    = existingBudget
        self.categoryAutoTotal = categoryAutoTotal
        self.lockedScope       = lockedScope
        self.initialScope      = initialScope
    }

    // MARK: - Validation

    private var canSave: Bool {
        guard amount > 0 else { return false }
        if scope == .category && selectedCategory == nil { return false }
        return true
    }

    private var isEditing: Bool { existingBudget != nil }

    private var activeCategories: [Category] {
        categories.filter { !$0.isArchived }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    amountSection
                    scopeSection
                    if scope == .category {
                        categoryChips
                    } else {
                        overallHint
                    }
                    periodSection
                    if isEditing {
                        deleteButton
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xxxl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(isEditing ? "Edit Budget" : "New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.tap()
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear {
                hydrateFromExisting()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if amount == 0 { amountFocused = true }
                }
            }
        }
    }

    // MARK: - Amount Section

    private var amountSection: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)

            FormattedAmountField(
                value: $amount,
                currencyCode: currencyCode,
                placeholder: "0",
                font: .system(size: 52, weight: .bold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Budget amount")
            .foregroundStyle(amount > 0 ? Color.tulaBrandFallback : Color.secondary.opacity(0.4))

            Text("\(period.displayName) budget cap")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Scope Section

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Scope")

            if lockedScope {
                HStack(spacing: 10) {
                    Image(systemName: scope == .overall ? "infinity" : "tag.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.tulaBrandFallback)
                    Text(scope == .overall ? "Overall Budget" : "Category Budget")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("Locked")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
            } else {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Choose between category or overall budget")
            }
        }
    }

    // MARK: - Category Chips

    private var categoryChips: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Category")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(activeCategories) { cat in
                        let isSelected = selectedCategory?.id == cat.id
                        let catColor = Color(hex: cat.colorHex)

                        Button {
                            Haptics.selection()
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                selectedCategory = isSelected ? nil : cat
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: isSelected ? cat.iconKey : cat.iconKey)
                                    .font(.system(size: 14, weight: .semibold))
                                    .symbolEffect(.bounce, value: isSelected)
                                Text(cat.name)
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background {
                                Capsule()
                                    .fill(isSelected ? catColor : Color(uiColor: .tertiarySystemFill))
                                    .shadow(color: isSelected ? catColor.opacity(0.35) : .clear,
                                            radius: isSelected ? 8 : 0, y: isSelected ? 3 : 0)
                            }
                            .overlay {
                                Capsule()
                                    .strokeBorder(isSelected ? catColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            }
                            .foregroundStyle(isSelected ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(isSelected ? 1.04 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityLabel(cat.name)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()

            if selectedCategory == nil {
                Text("Select a category for this budget")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Overall Hint

    private var overallHint: some View {
        Card(padding: Spacing.lg, cornerRadius: CornerRadius.small) {
            VStack(alignment: .leading, spacing: 8) {
                Label("All categories count toward this budget", systemImage: "infinity")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                if categoryAutoTotal > 0 {
                    let formatted = Currency.format(categoryAutoTotal, code: currencyCode)
                    Text("Category budgets total \(formatted)/mo. Set a higher amount to track unallocated spending.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Period Section

    private var periodSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Resets Every")

            Picker("Period", selection: $period) {
                ForEach(BudgetPeriod.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Delete

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            HStack {
                Spacer()
                Label("Delete Budget", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.md)
        .confirmationDialog("Delete this budget?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteBudget)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This won't delete any expenses — only the cap itself.")
        }
    }

    // MARK: - Hydrate (edit mode)

    private func hydrateFromExisting() {
        if let b = existingBudget {
            amount = b.amount
            period = b.period
            if let cat = b.category {
                scope = .category
                selectedCategory = cat
            } else {
                scope = .overall
            }
        } else {
            scope = initialScope
        }
    }

    // MARK: - Save / Delete

    private func save() {
        let cat: Category? = (scope == .category) ? selectedCategory : nil

        if let existing = existingBudget {
            existing.amount = amount
            existing.period = period
            existing.category = cat
        } else {
            let new = Budget(
                amount: amount,
                category: cat,
                period: period,
                startDate: .now
            )
            context.insert(new)
        }

        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func deleteBudget() {
        guard let b = existingBudget else { return }
        context.delete(b)
        try? context.save()
        Haptics.warning()
        dismiss()
    }
}
