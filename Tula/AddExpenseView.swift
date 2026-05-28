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
    /// When true, the category grid shows all categories; when false, only
    /// the first 7 are shown (with a "More" tile as the 8th cell). Tapping
    /// "More" expands. This keeps the form compact by default.
    @State private var showingAllCategories = false

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
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: Spacing.xxl) {
                        amountSection
                        accountSection
                        categorySection
                        detailsSection
                        if isEditing { deleteButton }
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.xxl)
                }
                .background(Color.tulaBackground)
                .scrollDismissesKeyboard(.immediately)

                stickyBottomBar
            }
            .navigationTitle(isEditing ? "Edit Expense" : "New Expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: setupDefaults)
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

    // MARK: - Amount

    private var amountSection: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.title3.weight(.medium))
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
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Account

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Paid with")

            // ScrollViewReader gives us programmatic scroll-to-id. Used
            // below to keep the selected account pill visible: if the
            // user taps an account off-screen, the scroller animates it
            // into view so the selection is always confirmed visually.
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
                            // Slide-in from leading + fade so freshly-
                            // visible chips have a moment of motion
                            // rather than popping in. Identifies the
                            // surface as "alive" without being loud.
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .leading)),
                                removal: .opacity
                            ))
                        }
                    }
                    .padding(.vertical, Spacing.sm)
                    .padding(.horizontal, 2)
                }
                // Let chip shadows render outside the horizontal scroll
                // bounds — without this, the selected pill's amber drop
                // shadow gets clipped at the top/bottom edges.
                .scrollClipDisabled()
                // Negate parent padding so the scroll extends edge-to-edge.
                .padding(.horizontal, -Spacing.xl)
                .padding(.horizontal, Spacing.xl)
                // Auto-scroll the selected pill into view whenever the
                // selection changes — covers both initial appearance
                // (lastUsedAccountID gets selected during setupDefaults)
                // and explicit user taps that hit an off-screen pill.
                .onChange(of: selectedAccount?.id) { _, newID in
                    guard let id = newID else { return }
                    withAnimation(.snappy(duration: 0.4)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    /// Account display order in the "Paid with" pills row:
    /// 1. **Selected account first** (when editing or after a tap) — keeps the
    ///    chosen pill anchored at the leading edge instead of forcing a scroll.
    /// 2. **Most-recently-used next** — recency uses the latest date among
    ///    that account's expenses + incoming + outgoing transfers.
    /// 3. **`sortOrder` fallback** for accounts that have never been used.
    private var prioritizedAccounts: [Account] {
        let active = activeAccounts
        return active.sorted { lhs, rhs in
            // Tier 1: selected pinned first.
            if let selectedID = selectedAccount?.id {
                if lhs.id == selectedID && rhs.id != selectedID { return true }
                if rhs.id == selectedID && lhs.id != selectedID { return false }
            }

            // Tier 2: most-recent activity.
            let lDate = latestActivityDate(for: lhs)
            let rDate = latestActivityDate(for: rhs)
            switch (lDate, rDate) {
            case let (.some(a), .some(b)): return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                // Tier 3: stable sortOrder fallback.
                return lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    private func latestActivityDate(for account: Account) -> Date? {
        var dates: [Date] = []
        dates.append(contentsOf: account.expenses.map(\.date))
        dates.append(contentsOf: account.outgoingTransfers.map(\.date))
        dates.append(contentsOf: account.incomingTransfers.map(\.date))
        return dates.max()
    }

    // MARK: - Category

    /// 4-column grid with a compact default of 7 categories + a "More"
    /// tile. Tapping More expands to show every category. Categories are
    /// sorted by recent usage (last 30 days) so the user's most-used appear
    /// first — a real workflow optimization.
    private var categorySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Category".uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedCategory == nil {
                    Text("Optional")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4),
                spacing: Spacing.md
            ) {
                ForEach(displayedCategories) { category in
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

                if shouldShowMoreTile {
                    moreTile
                }
            }
        }
    }

    /// Categories actually shown in the grid — either prioritized first 7
    /// (when collapsed) or all categories (when expanded).
    private var displayedCategories: [Category] {
        let sorted = prioritizedCategories
        return showingAllCategories ? sorted : Array(sorted.prefix(7))
    }

    /// Sort categories with three tiers:
    /// 1. **"Other" always last** regardless of usage — by design, it's the
    ///    fallback bucket and shouldn't displace real categories.
    /// 2. **Usage frequency (last 30 days), descending** — what the user
    ///    actually picks most often rises to the top.
    /// 3. **Alphabetical** for ties (including the common "zero usage" case
    ///    for new installs).
    private var prioritizedCategories: [Category] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let useCounts: [UUID: Int] = activeCategories.reduce(into: [:]) { dict, cat in
            dict[cat.id] = cat.expenses.filter { $0.date >= cutoff }.count
        }
        return activeCategories.sorted { lhs, rhs in
            // Tier 1: "Other" sinks to the bottom.
            let lIsOther = lhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            let rIsOther = rhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            if lIsOther != rIsOther {
                return !lIsOther   // the non-Other one comes first
            }

            // Tier 2: usage frequency, descending.
            let l = useCounts[lhs.id] ?? 0
            let r = useCounts[rhs.id] ?? 0
            if l != r { return l > r }

            // Tier 3: alphabetical for ties.
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var shouldShowMoreTile: Bool {
        !showingAllCategories && activeCategories.count > 7
    }

    /// "More" tile that lives as the 8th cell when categories are collapsed.
    /// Expands the grid in place with a smooth spring.
    private var moreTile: some View {
        Button {
            Haptics.tap()
            withAnimation(AppAnimation.gentle) {
                showingAllCategories = true
            }
        } label: {
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 50, height: 50)
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("More")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(PressableScaleStyle(scale: 0.95))
    }

    // MARK: - Details (merchant, note, date)
    //
    // These three fields used to live behind a "+ Add details" toggle —
    // a friction tax that hid the most-edited optional field (Note)
    // behind an extra tap. Now they sit inline as a single card with
    // three rows so the user can see what they're skipping and fill any
    // of them in without expanding anything. Date defaults to today, so
    // most quick logs still skip past these without typing.

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Details")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    detailRow(label: "Merchant", icon: "storefront.fill") {
                        TextField("Swiggy, Uber…", text: $merchant)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    Divider().padding(.leading, 48)
                    detailRow(label: "Note", icon: "text.alignleft") {
                        TextField("Optional", text: $note)
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
        .padding(.top, Spacing.lg)
    }

    // MARK: - Sticky Bottom Bar

    private var stickyBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                save()
            } label: {
                Text(isEditing ? "Save Changes" : "Save Expense")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md + 2)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .fill(canSave ? Color.tulaBrandFallback : Color.gray.opacity(0.3))
                    )
                    .shadow(
                        color: canSave ? Color.tulaBrandFallback.opacity(0.3) : .clear,
                        radius: 12, y: 4
                    )
            }
            .buttonStyle(PressableScaleStyle(scale: 0.97))
            .disabled(!canSave)
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
        .background(.regularMaterial)
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
        try? context.save()
        lastUsedAccountID = account.id.uuidString
        Haptics.success()
        // Evaluate budget thresholds after persisting — fires a
        // notification if this expense pushed any active budget
        // past 75% or 100%. No-op when budget alerts are disabled.
        evaluateBudgetAlerts()
        dismiss()
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
        try? context.save()
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
