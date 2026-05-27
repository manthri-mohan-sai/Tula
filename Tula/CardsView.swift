import SwiftUI
import SwiftData

/// Dedicated cards page. Pushed onto Home's navigation stack from the
/// wallet icon in Home's toolbar.
///
/// **Layout (top → bottom):**
/// 1. Summary header — N accounts + Net amount + month spend
/// 2. Cards stack (Wallet-style) — collapsed or expanded
/// 3. **Active card section** — shows the bottom (active) card's recent
///    activity + a small spend-this-month stat. Updates as the user lifts
///    a different card to the bottom. Hidden when the stack is expanded
///    (every card is fully visible, so per-card detail is redundant).
///
/// Note: general "Recent" lives on Home — this page intentionally shows
/// per-card detail rather than duplicating that.
struct CardsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    @Namespace private var cardNamespace
    @State private var navigateAccount: Account?
    @State private var editingExpense: Expense?
    @State private var isExpanded: Bool = false

    /// User-induced ordering of cards. Empty until the user taps or drags;
    /// the last UUID in this array is the **active** card (bottom of the
    /// stack). Owned here so the active-card section below can react.
    @State private var cardOrder: [UUID] = []

    // MARK: - Sorting

    /// Sort: oldest-used first so the most-recently-used card ends up at
    /// the END of the array — which corresponds to the BOTTOM of the
    /// vertical stack (the "active" position in Wallet-style layouts).
    /// Accounts that have never been used sink to the top of the stack.
    private var displayAccounts: [Account] {
        let active = allAccounts.filter { !$0.isArchived }
        return active.sorted { lhs, rhs in
            let l = lastUsedDate(for: lhs)
            let r = lastUsedDate(for: rhs)
            switch (l, r) {
            // Oldest first — least-recent date sorts before more-recent.
            case let (.some(a), .some(b)): return a < b
            // Never-used accounts sort above ever-used ones (top of stack).
            case (.some, .none): return false
            case (.none, .some): return true
            case (.none, .none): return lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    private func lastUsedDate(for account: Account) -> Date? {
        var dates: [Date] = []
        dates.append(contentsOf: account.expenses.map(\.date))
        dates.append(contentsOf: account.outgoingTransfers.map(\.date))
        dates.append(contentsOf: account.incomingTransfers.map(\.date))
        return dates.max()
    }

    // MARK: - Active card derivation

    /// The card currently at the bottom of the stack. Derived from
    /// `cardOrder` if the user has reordered, otherwise from the natural
    /// `displayAccounts` order's last element.
    private var activeAccount: Account? {
        if let lastID = cardOrder.last,
           let account = displayAccounts.first(where: { $0.id == lastID }) {
            return account
        }
        return displayAccounts.last
    }

    // MARK: - Aggregates

    /// Liquid balances minus credit-card outstanding.
    private var netSummary: Double {
        var liquid: Double = 0
        var outstanding: Double = 0
        for account in displayAccounts {
            switch account.kind {
            case .bank, .cash, .wallet: liquid += account.derivedBalance
            case .creditCard:           outstanding += account.derivedBalance
            }
        }
        return liquid - outstanding
    }

    /// Returns recent expenses for a specific account, drawing from the
    /// query results (already sorted by date descending).
    private func recentExpenses(for account: Account, limit: Int = 5) -> [Expense] {
        Array(allExpenses
            .filter { $0.account?.id == account.id }
            .prefix(limit))
    }

    /// Sum spent on a specific account this calendar month.
    private func monthSpend(for account: Account) -> Double {
        let cal = Calendar.current
        guard let monthStart = cal.dateInterval(of: .month, for: .now)?.start else { return 0 }
        return allExpenses
            .filter { $0.account?.id == account.id && $0.date >= monthStart }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                if displayAccounts.isEmpty {
                    emptyState
                } else {
                    // Cards stack leads — no header above it. Apple Wallet
                    // discipline: this screen is for looking at cards, so
                    // cards are the hero. Net worth / monthly totals live
                    // on Home and Stats, not duplicated here.
                    CardsCarousel(
                        accounts: displayAccounts,
                        namespace: cardNamespace,
                        onTap: { account in
                            navigateAccount = account
                        },
                        isExpanded: $isExpanded,
                        orderedIDs: $cardOrder
                    )

                    if !isExpanded, let active = activeAccount {
                        activeCardSection(for: active)
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.xxxl)
        }
        .background(Color.tulaBackground)
        .navigationTitle("Cards")
        .navigationSubtitle(subtitleText)
        .navigationBarTitleDisplayMode(.large)
        // Cards is a pushed detail screen, not a root tab — hide the tab
        // bar so the view feels like its own dedicated context (matches
        // how iOS hides the tab bar when pushing into AccountDetail etc.).
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !displayAccounts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded
                              ? "rectangle.stack.fill"
                              : "rectangle.expand.vertical")
                            .font(.body.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    // Neutral tint — this is a view-mode toggle, not an
                    // affirmative or destructive action. Brand amber here
                    // (inherited from the app's root tint) was reading
                    // as "primary action" when it's really just a switch.
                    .tint(.primary)
                    .accessibilityLabel(isExpanded ? "Stack cards" : "Expand cards")
                }
            }
        }
        .navigationDestination(item: $navigateAccount) { account in
            AccountDetailView(account: account)
                .navigationTransition(.zoom(sourceID: account.id, in: cardNamespace))
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(existingExpense: expense)
        }
    }

    // MARK: - Subtitle

    /// Compact subtitle rendered inside the navigation bar via
    /// `.navigationSubtitle` (iOS 26+). Sits under the large title with
    /// the same restraint as Mail's folder counts. We deliberately keep
    /// this to one line of dense info instead of a multi-line summary —
    /// the cards themselves are the hero of the screen.
    private var subtitleText: String {
        let count = displayAccounts.count
        let unit = count == 1 ? "account" : "accounts"
        return "\(count) \(unit) · \(Currency.format(netSummary, code: currencyCode))"
    }

    // MARK: - Active card section

    /// Per-card detail panel that lives below the stack in collapsed mode.
    /// Shows a stat header (this-month spend on the active card) plus its
    /// last few transactions. Updates with a smooth transition whenever
    /// the active card changes (because `activeAccount` changes).
    private func activeCardSection(for account: Account) -> some View {
        let recents = recentExpenses(for: account)
        let monthAmount = monthSpend(for: account)
        let cardColor = Color(hex: account.colorHex)

        return VStack(alignment: .leading, spacing: Spacing.md) {
            // Header: card name + this-month stat. The colored dot ties
            // the section to the card's visual identity.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Circle()
                    .fill(cardColor)
                    .frame(width: 8, height: 8)
                Text("On \(account.name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                Text(Currency.format(monthAmount, code: currencyCode))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            if recents.isEmpty {
                emptyCardActivity(for: account)
            } else {
                transactionsList(recents)
            }
        }
        // Identify the view by account so SwiftUI cross-fades content when
        // the active card changes (rather than mutating in place).
        .id(account.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func transactionsList(_ expenses: [Expense]) -> some View {
        List {
            ForEach(Array(expenses.enumerated()), id: \.element.id) { index, expense in
                Button {
                    Haptics.tap()
                    editingExpense = expense
                } label: {
                    ExpenseRow(expense: expense)
                        .padding(.horizontal, Spacing.lg)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(index == expenses.count - 1 ? .hidden : .visible)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(expense)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)

                    Button {
                        editingExpense = expense
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                    .labelStyle(.iconOnly)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(expenses.count) * 62)
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    /// Shown when the active card has no expenses logged yet.
    private func emptyCardActivity(for account: Account) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("No activity yet")
                    .font(.subheadline.weight(.semibold))
                Text("Expenses logged to \(account.name) will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        Haptics.warning()
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "creditcard")
                    .font(.title)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: Spacing.xs) {
                Text("No cards yet")
                    .font(.headline.weight(.semibold))
                Text("Add accounts in Settings to see them here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl * 2)
    }
}
