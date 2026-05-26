import SwiftUI
import SwiftData

struct AddExpenseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query private var allMerchantRules: [MerchantRule]

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""

    /// When non-nil, the form edits this expense rather than creating a new one.
    /// Lets us reuse one flow for both intents — Apple's standard pattern.
    let existingExpense: Expense?

    @State private var amount: Double
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
    @State private var showingMoreDetails: Bool
    @State private var categoryManuallySet: Bool
    @State private var showingDeleteConfirm = false

    @FocusState private var amountFocused: Bool

    init(existingExpense: Expense? = nil) {
        self.existingExpense = existingExpense
        if let e = existingExpense {
            _amount = State(initialValue: e.amount)
            _selectedCategory = State(initialValue: e.category)
            _selectedAccount = State(initialValue: e.account)
            _merchant = State(initialValue: e.merchant ?? "")
            _note = State(initialValue: e.note ?? "")
            _date = State(initialValue: e.date)
            _showingMoreDetails = State(initialValue: e.merchant != nil || e.note != nil)
            _categoryManuallySet = State(initialValue: true)
        } else {
            _amount = State(initialValue: 0)
            _selectedCategory = State(initialValue: nil)
            _selectedAccount = State(initialValue: nil)
            _merchant = State(initialValue: "")
            _note = State(initialValue: "")
            _date = State(initialValue: .now)
            _showingMoreDetails = State(initialValue: false)
            _categoryManuallySet = State(initialValue: false)
        }
    }

    private var isEditing: Bool { existingExpense != nil }

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var activeCategories: [Category] {
        allCategories.filter { !$0.isArchived }
    }

    private var canSave: Bool {
        amount > 0 && selectedAccount != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xxl) {
                    amountSection
                    accountSection
                    categorySection
                    moreDetailsSection

                    if isEditing {
                        deleteButton
                    }
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(isEditing ? "Edit Expense" : "New Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear(perform: setupDefaults)
            .onChange(of: merchant) { _, newValue in
                applyMerchantRule(for: newValue)
            }
            .confirmationDialog(
                "Delete this expense?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action can't be undone.")
            }
        }
    }

    // MARK: - Sections

    private var amountSection: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)

            FormattedAmountField(
                value: $amount,
                currencyCode: currencyCode,
                placeholder: "0",
                font: .system(size: 56, weight: .bold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .foregroundStyle(amount > 0 ? .primary : .tertiary)
        }
        .padding(.vertical, Spacing.lg)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Paid with")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(activeAccounts) { account in
                        AccountChip(
                            account: account,
                            isSelected: selectedAccount?.id == account.id
                        )
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(AppAnimation.snappy) {
                                selectedAccount = account
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 12)
            }
        }
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Category")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedCategory == nil {
                    Text("Optional")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(activeCategories) { category in
                        CategoryChip(
                            category: category,
                            isSelected: selectedCategory?.id == category.id
                        )
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(AppAnimation.snappy) {
                                if selectedCategory?.id == category.id {
                                    selectedCategory = nil
                                    categoryManuallySet = false
                                } else {
                                    selectedCategory = category
                                    categoryManuallySet = true
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
            }
        }
    }

    private var moreDetailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Button {
                Haptics.tap()
                withAnimation(AppAnimation.gentle) { showingMoreDetails.toggle() }
            } label: {
                HStack {
                    Image(systemName: showingMoreDetails ? "minus.circle" : "plus.circle")
                        .font(.subheadline)
                    Text(showingMoreDetails ? "Hide extras" : "Merchant · Note · Date")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Color.tulaCardSurface)
                )
            }
            .buttonStyle(.plain)

            if showingMoreDetails {
                Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
                    VStack(spacing: Spacing.md) {
                        detailRow(label: "Merchant") {
                            TextField("Swiggy, Uber, etc.", text: $merchant)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        }
                        Divider()
                        detailRow(label: "Note") {
                            TextField("Optional", text: $note)
                        }
                        Divider()
                        detailRow(label: "Date") {
                            DatePicker("", selection: $date, displayedComponents: .date)
                                .labelsHidden()
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.warning()
            showingDeleteConfirm = true
        } label: {
            Label("Delete Expense", systemImage: "trash")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.red.opacity(0.12))
        )
        .padding(.top, Spacing.lg)
    }

    private func detailRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: - Logic

    private func setupDefaults() {
        if isEditing { return }   // Don't auto-focus / auto-fill when editing

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            amountFocused = true
        }

        if selectedAccount == nil {
            if !lastUsedAccountID.isEmpty,
               let uuid = UUID(uuidString: lastUsedAccountID),
               let match = activeAccounts.first(where: { $0.id == uuid }) {
                selectedAccount = match
            } else {
                selectedAccount = activeAccounts.first
            }
        }
    }

    private func applyMerchantRule(for input: String) {
        guard !categoryManuallySet else { return }
        let needle = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            selectedCategory = nil
            return
        }

        let userRules = allMerchantRules.filter { $0.isUserDefined }
        let defaultRules = allMerchantRules.filter { !$0.isUserDefined }

        for rule in userRules + defaultRules {
            if needle.contains(rule.pattern) {
                withAnimation(AppAnimation.snappy) {
                    selectedCategory = rule.category
                }
                return
            }
        }
    }

    private func save() {
        guard let account = selectedAccount, amount > 0 else { return }

        if let existingExpense {
            existingExpense.amount = amount
            existingExpense.date = date
            existingExpense.merchant = merchant.isEmpty ? nil : merchant
            existingExpense.note = note.isEmpty ? nil : note
            existingExpense.category = selectedCategory
            existingExpense.account = account
        } else {
            let expense = Expense(
                amount: amount,
                date: date,
                merchant: merchant.isEmpty ? nil : merchant,
                note: note.isEmpty ? nil : note,
                source: .manual,
                category: selectedCategory,
                account: account
            )
            context.insert(expense)
        }

        try? context.save()
        lastUsedAccountID = account.id.uuidString
        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let existingExpense else { return }
        context.delete(existingExpense)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

// MARK: - Chips

struct AccountChip: View {
    let account: Account
    let isSelected: Bool

    private var color: Color { Color(hex: account.colorHex) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.iconKey)
                .font(.subheadline.weight(.medium))
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 12)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            Capsule().fill(
                isSelected ? color : Color.tulaCardSurface
            )
        )
        .overlay(
            Capsule().stroke(
                isSelected ? color : Color.clear,
                lineWidth: 1
            )
        )
        .shadow(
            color: isSelected ? color.opacity(0.3) : .clear,
            radius: 6, x: 0, y: 2
        )
    }
}

struct CategoryChip: View {
    let category: Category
    let isSelected: Bool

    private var color: Color { Color(hex: category.colorHex) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(isSelected ? color : color.opacity(0.15))
                    .frame(width: 56, height: 56)
                Image(systemName: category.iconKey)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isSelected ? .white : color)
            }
            .shadow(
                color: isSelected ? color.opacity(0.4) : .clear,
                radius: 8, x: 0, y: 3
            )

            Text(category.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .frame(width: 76)
    }
}
