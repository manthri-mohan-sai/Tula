import SwiftUI
import SwiftData

/// Sheet for creating a new budget or editing an existing one.
///
/// Layout follows AccountFormView's pattern: hero amount input at the top,
/// then grouped configuration form below. Brand color reserved for the
/// amount field; everything else is neutral.
struct BudgetFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    /// nil = create mode, non-nil = edit mode.
    let existingBudget: Budget?

    // MARK: - Form state

    @State private var scope: Scope = .category
    @State private var selectedCategory: Category?
    @State private var amount: Double = 0
    @State private var period: BudgetPeriod = .monthly

    @State private var showDeleteConfirm = false

    enum Scope: String, CaseIterable, Identifiable {
        case category = "Category"
        case overall  = "Overall"
        var id: String { rawValue }
    }

    init(existingBudget: Budget? = nil) {
        self.existingBudget = existingBudget
    }

    // MARK: - Validation

    private var canSave: Bool {
        guard amount > 0 else { return false }
        if scope == .category && selectedCategory == nil { return false }
        return true
    }

    private var isEditing: Bool { existingBudget != nil }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // Amount — hero input
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Currency.symbol(for: currencyCode))
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        FormattedAmountField(
                            value: $amount,
                            currencyCode: currencyCode,
                            placeholder: "0",
                            font: .system(size: 34, weight: .semibold),
                            alignment: .leading
                        )
                        .foregroundStyle(Color.tulaBrandFallback)
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Budget")
                } footer: {
                    Text("\(period.displayName) cap. Resets at the start of each period.")
                }

                // Scope: Category vs Overall
                Section("Scope") {
                    Picker("Scope", selection: $scope) {
                        ForEach(Scope.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scope == .category {
                        Picker("Category", selection: $selectedCategory) {
                            Text("Select…").tag(Category?.none)
                            ForEach(categories) { cat in
                                Label {
                                    Text(cat.name)
                                } icon: {
                                    Image(systemName: cat.iconKey)
                                        .foregroundStyle(Color(hex: cat.colorHex))
                                }
                                .tag(Category?.some(cat))
                            }
                        }
                    } else {
                        // Overall — explain the implication
                        Label("All categories count toward this budget", systemImage: "infinity")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }

                // Period
                Section("Resets") {
                    Picker("Period", selection: $period) {
                        ForEach(BudgetPeriod.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Text("Delete Budget")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Budget" : "New Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Haptics.tap()
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: hydrateFromExisting)
            .confirmationDialog("Delete this budget?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteBudget)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This won't delete any expenses — only the cap itself.")
            }
        }
    }

    // MARK: - Hydrate (edit mode)

    private func hydrateFromExisting() {
        guard let b = existingBudget else { return }
        amount = b.amount
        period = b.period
        if let cat = b.category {
            scope = .category
            selectedCategory = cat
        } else {
            scope = .overall
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
