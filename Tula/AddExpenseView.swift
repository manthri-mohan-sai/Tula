import SwiftUI
import SwiftData

/// New / edit expense form. Designed for speed:
/// - Amount centered prominently at top
/// - Accounts as compact horizontal pills (icon + name, all visible at once)
/// - Categories as a 4-column grid (no scrolling needed to see all defaults)
/// - Merchant / Note / Date collapsed into one card
/// - Save anchored to bottom (always thumb-reachable)
struct AddExpenseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query private var allMerchantRules: [MerchantRule]

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false

    let existingExpense: Expense?

    @State private var amount: Double
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
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
            _categoryManuallySet = State(initialValue: true)
        } else {
            _amount = State(initialValue: 0)
            _selectedCategory = State(initialValue: nil)
            _selectedAccount = State(initialValue: nil)
            _merchant = State(initialValue: "")
            _note = State(initialValue: "")
            _date = State(initialValue: .now)
            _categoryManuallySet = State(initialValue: false)
        }
    }

    private var isEditing: Bool { existingExpense != nil }
    private var activeAccounts: [Account] { allAccounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { allCategories.filter { !$0.isArchived } }
    private var canSave: Bool { amount > 0 && selectedAccount != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    amountHero
                        .padding(.top, Spacing.lg)

                    accountStrip

                    // Category grid — inline, all categories visible.
                    // Tap to select. No header label (the grid is obviously
                    // a category picker; an "Category" header would just
                    // be noise). 4 columns matches the previous design.
                    categoryGrid
                        .padding(.horizontal, Spacing.xl)

                    // Merchant / Item / Date as inline rows with
                    // text fields and date picker right there. No
                    // sheets, no extra taps — same friction as the
                    // original design but inside the new visual frame.
                    detailsCard
                        .padding(.horizontal, Spacing.xl)

                    if isEditing {
                        deleteButton
                            .padding(.horizontal, Spacing.xl)
                    }
                }
                .padding(.bottom, Spacing.xxl)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.tulaBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .principal) {
                    Text(isEditing ? "Edit Expense" : "Expense")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canSave ? Color.tulaBrandFallback : Color.secondary.opacity(0.5))
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                setupDefaults()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    amountFocused = true
                }
            }
            .onChange(of: merchant) { _, newValue in
                applyMerchantRule(for: newValue)
            }
            .confirmationDialog("Delete this expense?",
                                isPresented: $showingDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action can't be undone.")
            }
        }
    }

    // MARK: - Amount Hero
    //
    // Calculator-style display: massive number, no input chrome, currency
    // symbol whispering above. The number IS the screen. Following Apple
    // Cash and Calculator conventions — the value being entered earns the
    // visual real estate proportional to its importance.

    private var amountHero: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.body.weight(.medium))
                .foregroundStyle(.tertiary)

            FormattedAmountField(
                value: $amount,
                currencyCode: currencyCode,
                placeholder: "0",
                // Larger and lighter than the previous 56pt bold. At
                // 64pt the number commands the screen the way Apple Cash
                // does ("$0" on Cash is ~80pt). `.rounded` keeps the
                // numeric feel friendly rather than typographically heavy.
                font: .system(size: 64, weight: .semibold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .foregroundStyle(amount > 0 ? .primary : .tertiary)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: amount)
        }
    }

    // MARK: - Account Strip
    //
    // Horizontal scrollable pills with NO header. The pills are visually
    // self-explanatory (account icon + name) — adding a "Paid with" label
    // above them is redundant noise. Selection auto-applies the user's
    // last-used default, so the form opens with a sensible choice already
    // made; the user typically just confirms with one glance, not a tap.

    private var accountStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(prioritizedAccounts) { account in
                        AccountPill(
                            account: account,
                            isSelected: selectedAccount?.id == account.id
                        )
                        .id(account.id)
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(AppAnimation.bouncy) {
                                selectedAccount = account
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
            }
            .scrollClipDisabled()
            .onChange(of: selectedAccount?.id) { _, newID in
                guard let id = newID else { return }
                withAnimation(.snappy(duration: 0.4)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Category Grid
    //
    // Inline 4-column grid showing every active category at once. No
    // expansion, no "More" tile — categories are the substance of the
    // entry, not a fold-away detail. Scanning a full grid is fastest
    // for the user; hiding categories behind a sheet was the wrong call.

    private var categoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4),
            spacing: Spacing.md
        ) {
            ForEach(prioritizedCategories) { category in
                CategoryGridItem(
                    category: category,
                    isSelected: selectedCategory?.id == category.id
                )
                .onTapGesture {
                    Haptics.selection()
                    withAnimation(AppAnimation.bouncy) {
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
    }

    // MARK: - Details Card (merchant, item, date)
    //
    // Inline text fields stacked in a single rounded card. Each row is
    // the field's icon + label + the live text input. No sheet detour
    // for typing — tap and start typing. This was the right pattern
    // all along; my sheet-based redesign was over-engineering.

    private var detailsCard: some View {
        Card(padding: 0, cornerRadius: CornerRadius.medium) {
            VStack(spacing: 0) {
                detailRow(label: "Merchant", icon: "storefront.fill") {
                    TextField("Ramachandra Restaurant, Swiggy…", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 48)
                detailRow(label: "Item", icon: "text.alignleft") {
                    TextField("Masala Dosa, Chai…", text: $note)
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 48)
                detailRow(label: "Date", icon: "calendar") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
    }

    private func detailRow<Content: View>(
        label: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md - 2)
    }

    // MARK: - Delete (edit mode only)

    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.warning()
            showingDeleteConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete Expense").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md + 2)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    // MARK: - Account Priority

    /// Account display order in the strip:
    /// 1. **Selected first** so the chosen pill is always at the leading edge.
    /// 2. **Most-recently-used next** — recency uses the latest date among
    ///    that account's expenses + incoming + outgoing transfers.
    /// 3. **`sortOrder` fallback** for accounts that have never been used.
    private var prioritizedAccounts: [Account] {
        let active = activeAccounts
        return active.sorted { lhs, rhs in
            if let selectedID = selectedAccount?.id {
                if lhs.id == selectedID && rhs.id != selectedID { return true }
                if rhs.id == selectedID && lhs.id != selectedID { return false }
            }
            let lDate = latestActivityDate(for: lhs)
            let rDate = latestActivityDate(for: rhs)
            switch (lDate, rDate) {
            case let (.some(a), .some(b)): return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                return lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    /// Latest activity date for an account — looks at expenses,
    /// incoming transfers, and outgoing transfers. Returns nil for
    /// accounts that have never been touched.
    private func latestActivityDate(for account: Account) -> Date? {
        let expenseLatest = account.expenses.map(\.date).max()
        let outgoingLatest = account.outgoingTransfers.map(\.date).max()
        let incomingLatest = account.incomingTransfers.map(\.date).max()
        return [expenseLatest, outgoingLatest, incomingLatest]
            .compactMap { $0 }
            .max()
    }

    // MARK: - Category Priority

    /// Sort categories with three tiers:
    /// 1. **"Other" always last** — fallback bucket, shouldn't displace real categories.
    /// 2. **Usage frequency (last 30 days), descending** — most-picked rises.
    /// 3. **Alphabetical** for ties.
    private var prioritizedCategories: [Category] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let useCounts: [UUID: Int] = activeCategories.reduce(into: [:]) { dict, cat in
            dict[cat.id] = cat.expenses.filter { $0.date >= cutoff }.count
        }
        return activeCategories.sorted { lhs, rhs in
            let lIsOther = lhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            let rIsOther = rhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            if lIsOther != rIsOther {
                return !lIsOther
            }
            let l = useCounts[lhs.id] ?? 0
            let r = useCounts[rhs.id] ?? 0
            if l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Logic

    private func setupDefaults() {
        if isEditing { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { amountFocused = true }
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
                withAnimation(AppAnimation.snappy) { selectedCategory = rule.category }
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
                amount: amount, date: date,
                merchant: merchant.isEmpty ? nil : merchant,
                note: note.isEmpty ? nil : note,
                source: .manual,
                category: selectedCategory, account: account
            )
            context.insert(expense)
        }
        // Learn from the user's choice: if they typed a merchant AND picked
        // a category, remember that mapping so the next "icecream" or
        // "office mess" auto-picks the right category. Silent — the user
        // doesn't see anything happen, but the app gets smarter with use.
        learnMerchantCategory()
        try? context.save(); WidgetRefresh.refresh(using: context)
        lastUsedAccountID = account.id.uuidString
        Haptics.success()
        // Evaluate budget thresholds after persisting — fires a
        // notification if this expense pushed any active budget
        // past 75% or 100%. No-op when budget alerts are disabled.
        evaluateBudgetAlerts()
        dismiss()
    }

    /// User-learning hook: upserts a user-defined MerchantRule when the
    /// expense has both a merchant string and a category. Filters out
    /// pollution (very short merchants, merchant equal to category name,
    /// purely numeric merchants).
    ///
    /// Upsert semantics:
    /// - If a user-defined rule exists for this merchant → update its category.
    /// - If only a default rule exists → leave defaults alone; create a
    ///   higher-priority user rule. The parser checks user rules first, so
    ///   the user's choice wins.
    /// - If no rule exists → create one.
    private func learnMerchantCategory() {
        let trimmed = merchant.trimmingCharacters(in: .whitespaces).lowercased()
        guard let category = selectedCategory,
              !trimmed.isEmpty,
              trimmed.count >= 3,
              // Avoid storing pure numbers ("100" → Food) which add no value.
              !trimmed.allSatisfy({ $0.isNumber || $0.isWhitespace }),
              // Avoid storing rules where merchant equals the category name —
              // these add no new information and could collide.
              trimmed != category.name.lowercased()
        else { return }

        // Look up existing user-defined rule for this exact pattern.
        let fetch = FetchDescriptor<MerchantRule>()
        let allRules = (try? context.fetch(fetch)) ?? []
        let existingUserRule = allRules.first {
            $0.isUserDefined && $0.pattern == trimmed
        }

        if let existing = existingUserRule {
            // Update the category if the user picked a different one this time.
            if existing.category?.id != category.id {
                existing.category = category
            }
        } else {
            // Brand new — insert a user-defined rule. Default rules with the
            // same pattern are left untouched; the parser sees user rules
            // first and they win.
            let rule = MerchantRule(pattern: trimmed,
                                    category: category,
                                    isUserDefined: true)
            context.insert(rule)
        }
    }

    /// Walks active budgets and posts threshold notifications for any
    /// that just crossed 75% or 100%. Gated by the user's opt-in
    /// AppStorage flag — won't fire when budget alerts are off.
    private func evaluateBudgetAlerts() {
        guard budgetAlertsEnabled else { return }
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate<Budget> { $0.isActive == true }
        )
        let expenseFetch = FetchDescriptor<Expense>()
        let budgets = (try? context.fetch(budgetFetch)) ?? []
        let expenses = (try? context.fetch(expenseFetch)) ?? []
        NotificationManager.evaluateBudgetThresholds(
            budgets: budgets,
            expenses: expenses
        )
    }

    private func delete() {
        guard let existingExpense else { return }
        context.delete(existingExpense)
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Account Pill (used in this view)

struct AccountPill: View {
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
        .padding(.vertical, 10)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            Capsule().fill(isSelected ? color : Color.tulaCardSurface)
        )
        .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 6, y: 2)
        .scaleEffect(isSelected ? 1.03 : 1.0)
    }
}

// MARK: - Account Chip (used by TransferFormView)
// Kept for backward compatibility — TransferFormView relies on this name.

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
            Capsule().fill(isSelected ? color : Color.tulaCardSurface)
        )
        .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 6, x: 0, y: 2)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(AppAnimation.bouncy, value: isSelected)
    }
}

// MARK: - Category Grid Item

struct CategoryGridItem: View {
    let category: Category
    let isSelected: Bool

    private var color: Color { Color(hex: category.colorHex) }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Circle()
                    .fill(isSelected ? color : color.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: category.iconKey)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isSelected ? .white : color)
                    .symbolEffect(.bounce, value: isSelected)
            }
            .shadow(color: isSelected ? color.opacity(0.4) : .clear, radius: 8, y: 3)

            Text(category.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(isSelected ? color.opacity(0.08) : Color.clear)
        )
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(AppAnimation.bouncy, value: isSelected)
        .contentShape(Rectangle())
    }
}
