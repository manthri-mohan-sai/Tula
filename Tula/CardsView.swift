import SwiftUI
import SwiftData

/// Dedicated cards page. Pushed onto Home's navigation stack from the
/// wallet icon in Home's toolbar.
///
/// **Mobile-first redesign.** Cards are presented as a horizontal,
/// page-snapping carousel — the iOS-native pattern for browsing through
/// a collection on a phone (App Store, Music album art, Wallet). The
/// horizontal swipe axis is **orthogonal** to the page's vertical scroll
/// axis, so they never compete for gestures.
///
/// **Layout (top → bottom):**
/// 1. Horizontal carousel of cards (the centered card is the "active" one)
/// 2. Page indicator dots showing position in the carousel
/// 3. Active card section — header (card name + this-month spend) plus
///    the active card's most recent transactions
///
/// **Interactions:**
/// - Swipe carousel horizontally → active card changes; section below updates.
/// - Tap any card → opens its detail screen.
/// - Tap a transaction → edit that expense.
/// - Swipe a transaction left → edit/delete.
struct CardsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    @Namespace private var cardNamespace
    @State private var navigateAccount: Account?
    @State private var editingExpense: Expense?
    @State private var isAddingAccount: Bool = false
    @State private var showingTransfer: Bool = false
    /// Account currently being edited via the context menu's "Edit"
    /// action. Drives the edit sheet presentation.
    @State private var editingAccount: Account?
    /// Account the user has chosen to archive. Drives the confirmation
    /// alert — set to non-nil to show the alert, cleared after the
    /// user confirms or cancels.
    @State private var accountPendingArchive: Account?
    @State private var expensePendingDelete: Expense?

    /// UUID of the card currently centered in the horizontal carousel.
    /// Bound to the carousel's `scrollPosition`; updating it programmatically
    /// scrolls the carousel; the user swiping updates it from the system.
    @State private var activeCardID: UUID?

    /// The color of the currently active card, used for the gradient
    /// backdrop. Tracked separately so the gradient animates smoothly
    /// as the carousel snaps between cards.
    private var activeCardColor: Color {
        guard let id = activeCardID,
              let account = displayAccounts.first(where: { $0.id == id }) else {
            return displayAccounts.first.map { Color(hex: $0.colorHex).cardified() }
                ?? Color.tulaBrandFallback
        }
        return Color(hex: account.colorHex).cardified()
    }

    // MARK: - Sorting

    /// Most-recently-used first so the carousel opens on the user's most
    /// active card. Never-used accounts sink to the end.
    private var displayAccounts: [Account] {
        let active = allAccounts.filter { !$0.isArchived }
        return active.sorted { lhs, rhs in
            let l = lastUsedDate(for: lhs)
            let r = lastUsedDate(for: rhs)
            switch (l, r) {
            case let (.some(a), .some(b)): return a > b
            case (.some, .none): return true
            case (.none, .some): return false
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

    /// The currently focused card — whichever the carousel has centered.
    /// Falls back to the first display account if `activeCardID` is nil
    /// (which happens for one render on first appearance).
    private var activeAccount: Account? {
        if let id = activeCardID,
           let account = displayAccounts.first(where: { $0.id == id }) {
            return account
        }
        return displayAccounts.first
    }

    // MARK: - Aggregates

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

    private func recentExpenses(for account: Account, limit: Int = 5) -> [Expense] {
        Array(allExpenses
            .filter { $0.account?.id == account.id }
            .prefix(limit))
    }

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
            VStack(alignment: .leading, spacing: 0) {
                if displayAccounts.isEmpty {
                    emptyState
                } else {
                    // Carousel is full-width (no horizontal padding) so cards
                    // can use the entire screen for the peek effect.
                    CardsCarousel(
                        accounts: displayAccounts,
                        namespace: cardNamespace,
                        onTap: { account in
                            navigateAccount = account
                        },
                        onEdit: { account in
                            editingAccount = account
                        },
                        onArchive: { account in
                            accountPendingArchive = account
                        },
                        activeID: $activeCardID
                    )
                    .padding(.top, Spacing.sm)

                    pageIndicator
                        .padding(.top, Spacing.xs)
                        .padding(.bottom, Spacing.xxl)
                        .frame(maxWidth: .infinity)

                    if let active = activeAccount {
                        activeCardSection(for: active)
                            .adaptiveContentWidth()
                    }
                }
            }
            .padding(.bottom, Spacing.xxxl)
        }
        .background {
            ZStack {
                Color.tulaBackground
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            activeCardColor.opacity(0.25),
                            activeCardColor.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 420)
                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea()
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: activeCardID)
        }
        .navigationTitle("Accounts")
        .tulaNavigationSubtitle(subtitleText)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingTransfer = true
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.body.weight(.medium))
                }
                .tint(.primary)
                .accessibilityLabel("Transfer")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    isAddingAccount = true
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .tint(.primary)
                .accessibilityLabel("Add account")
            }
        }
        .navigationDestination(item: $navigateAccount) { account in
            AccountDetailView(account: account)
                .navigationTransition(.zoom(sourceID: account.id, in: cardNamespace))
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(existingExpense: expense)
        }
        .sheet(isPresented: $isAddingAccount) {
            NavigationStack {
                AccountFormView()
            }
        }
        .sheet(isPresented: $showingTransfer) {
            TransferFormView(presetFromAccount: activeAccount)
        }
        .sheet(item: $editingAccount) { account in
            NavigationStack {
                AccountFormView(account: account)
            }
        }
        // Archive confirmation — context menu's destructive Archive
        // surfaces here so the user can back out before the card
        // disappears from the carousel. Uses presentation binding tied
        // to `accountPendingArchive` so the alert only renders when
        // a target account is set.
        .alert(
            "Archive this account?",
            isPresented: Binding(
                get: { accountPendingArchive != nil },
                set: { if !$0 { accountPendingArchive = nil } }
            ),
            presenting: accountPendingArchive
        ) { account in
            Button("Archive", role: .destructive) {
                archive(account)
            }
            Button("Cancel", role: .cancel) {
                accountPendingArchive = nil
            }
        } message: { account in
            Text("\(account.name) will be hidden from your active accounts. Existing transactions stay intact and you can unarchive any time from Settings → Accounts.")
        }
        .alert(
            "Delete Expense?",
            isPresented: Binding(
                get: { expensePendingDelete != nil },
                set: { if !$0 { expensePendingDelete = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { expensePendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let expense = expensePendingDelete {
                    delete(expense)
                    expensePendingDelete = nil
                }
            }
        } message: {
            if let expense = expensePendingDelete {
                Text("This will permanently remove \(Currency.format(expense.amount, code: currencyCode)) from \(expense.merchant ?? "this expense").")
            }
        }
        .task {
            // Initialize the carousel to the most-recently-used card on
            // first appearance. Done in .task (not .onAppear) so it runs
            // once after the query loads.
            if activeCardID == nil {
                activeCardID = displayAccounts.first?.id
            }
        }
    }

    // MARK: - Subtitle

    private var subtitleText: String {
        let count = displayAccounts.count
        let unit = count == 1 ? "account" : "accounts"
        return "\(count) \(unit) · \(Currency.format(netSummary, code: currencyCode))"
    }

    // MARK: - Page indicator

    /// iOS-style page-position indicator. Active dot is an elongated capsule
    /// in the brand color; inactive dots are small neutral circles. Spring
    /// animation makes the active dot grow/shrink smoothly as the user swipes.
    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(displayAccounts, id: \.id) { account in
                let isActive = account.id == activeCardID
                Capsule()
                    .fill(isActive
                          ? Color.tulaBrandFallback
                          : Color.secondary.opacity(0.28))
                    .frame(width: isActive ? 22 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: activeCardID)
        .accessibilityElement()
        .accessibilityLabel("Account \(activePageIndex) of \(displayAccounts.count)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var activePageIndex: Int {
        guard let id = activeCardID,
              let idx = displayAccounts.firstIndex(where: { $0.id == id }) else { return 1 }
        return idx + 1
    }

    // MARK: - Active card section

    /// Max number of transactions surfaced inline. Picked so the whole
    /// page fits on a typical iPhone without forcing an awkward inner
    /// scroll. Beyond this, the user taps "See all" to drill into the
    /// account's full detail screen.
    private let maxInlineTransactions = 4

    /// Per-card panel below the carousel. Everything — section header,
    /// transactions, and the "See all" footer — sits inside one rounded
    /// container so they read as a single, coherent surface. As the
    /// carousel swipes to a different card, this whole container
    /// cross-fades to the new card's data.
    private func activeCardSection(for account: Account) -> some View {
        let recents = recentExpenses(for: account, limit: maxInlineTransactions)
        let monthAmount = monthSpend(for: account)
        let cardColor = Color(hex: account.colorHex)

        return VStack(spacing: 0) {
            sectionHeader(account: account, color: cardColor, monthAmount: monthAmount)

            if recents.isEmpty {
                emptyCardActivity(for: account)
            } else {
                inlineTransactions(recents)
                seeAllFooter(for: account)
            }
        }
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        // Cross-fade when the active card changes (carousel swipe).
        .id(account.id)
        .transition(.opacity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: account.id)
    }

    /// Header row inside the unified container — colored dot tying it
    /// visually to the card above, card name, and the this-month spend.
    private func sectionHeader(account: Account, color: Color, monthAmount: Double) -> some View {
        HStack(alignment: .center, spacing: Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            Text(Currency.format(monthAmount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .contentTransition(.numericText(value: monthAmount))
                .animation(.snappy(duration: 0.35), value: monthAmount)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    /// Inline transactions list. Uses native List for swipe actions but
    /// is height-locked and scroll-disabled so it behaves as a static
    /// inline block within the parent ScrollView (no nested scrolling).
    private func inlineTransactions(_ expenses: [Expense]) -> some View {
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
                // Separator BELOW each row except the last. We must target
                // `edges: .bottom` explicitly — the default `.all` would
                // also hide the top edge of the last row, which is shared
                // with the bottom edge of the row before it, accidentally
                // erasing the line between them. iOS's List handles the
                // first row's top edge automatically (no separator above
                // the first row inside a section).
                .listRowSeparator(index == expenses.count - 1 ? .hidden : .visible, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        expensePendingDelete = expense
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
        // 72pt per row matches ExpenseRow's actual rendered height
        // (64pt minHeight + iOS list chrome ≈ ~70pt with a small buffer).
        // Same value HomeView's recent list uses, so they stay
        // consistent and neither leaves dead space at the end.
        .frame(height: CGFloat(expenses.count) * 72)
    }

    /// Footer: tappable row that navigates to the full account detail
    /// screen. Mirrors Apple's "See All" pattern from Mail, Photos, etc.
    private func seeAllFooter(for account: Account) -> some View {
        Button {
            Haptics.tap()
            navigateAccount = account
        } label: {
            HStack {
                Text("See all transactions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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
    }

    private func delete(_ expense: Expense) {
        withAnimation {
            context.delete(expense)
            context.safeSave()
        }
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
        Haptics.warning()
    }

    /// Soft-delete the given account — flips `isArchived` true so it
    /// disappears from the carousel and account pickers throughout the
    /// app. Existing transactions remain attached and visible; the user
    /// can unarchive later from Settings → Accounts. If the archived
    /// account was the currently focused card, we shift focus to
    /// whichever other account remains so the page indicator and
    /// active-card section don't render against a stale ID.
    private func archive(_ account: Account) {
        let wasActive = activeCardID == account.id
        account.isArchived = true
        context.safeSave()
        Haptics.success()

        // Shift focus if we just archived the visible card. Picks the
        // first remaining active account; the carousel resnaps on next
        // layout. If no accounts remain, activeCardID becomes nil and
        // the empty state takes over.
        if wasActive {
            let remaining = allAccounts.filter { !$0.isArchived && $0.id != account.id }
            activeCardID = remaining.first?.id
        }
        accountPendingArchive = nil
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
                Text("No accounts yet")
                    .font(.headline.weight(.semibold))
                Text("Add an account to see it here — bank, cash, credit card, or anything you spend from.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl * 2)
    }
}
