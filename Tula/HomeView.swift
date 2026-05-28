import SwiftUI
import SwiftData
import Charts

// MARK: - Navigation

/// Destinations reachable from the Home screen via path-based navigation.
/// Using a single value-based destination (instead of multiple
/// `.navigationDestination(isPresented:)` bool modifiers) avoids a SwiftUI
/// bug where stacked boolean destinations cause the push transition to hang.
enum HomeDestination: Hashable {
    case cards
    case budgets
    case reviewQueue
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query private var allMerchantRules: [MerchantRule]
    @Query private var allRecurringRules: [RecurringRule]
    @PrimaryCurrency private var currencyCode

    let onShowStats: () -> Void

    @State private var editingExpense: Expense?
    @State private var showingAllExpenses = false
    @State private var showingSettings = false
    @State private var showingRecurring = false
    @State private var navPath = NavigationPath()
    @State private var toastMessage: String?
    @State private var toastToken: UUID = UUID()
    @State private var savePulse: Bool = false
    @State private var heroTapPulse: Bool = false

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false

    init(onShowStats: @escaping () -> Void = {}) {
        self.onShowStats = onShowStats
    }

    // MARK: - Derived

    private var thisMonthExpenses: [Expense] {
        let cal = Calendar.current
        guard let monthStart = cal.dateInterval(of: .month, for: .now)?.start else { return [] }
        return allExpenses.filter { $0.date >= monthStart }
    }

    private var totalThisMonth: Double {
        thisMonthExpenses.reduce(0) { $0 + $1.amount }
    }

    private var todaysExpenses: [Expense] {
        let start = Calendar.current.startOfDay(for: .now)
        return allExpenses.filter { $0.date >= start }
    }

    private var totalToday: Double {
        todaysExpenses.reduce(0) { $0 + $1.amount }
    }

    /// Count of expenses missing a category — the Quick Log voice flow can
    /// land here when the parser can't infer the category. Surfaced as a
    /// banner above Recent so the user can triage in one tap.
    private var reviewCount: Int {
        allExpenses.lazy.filter { $0.category == nil }.count
    }

    /// Upcoming recurring rules due in the next 7 days. Each row pairs a
    /// rule with its computed next-due date. Capped at 3 in the surface
    /// so the section doesn't dominate Home — the full list lives in
    /// Settings → Recurring.
    private var upcomingRecurring: [(rule: RecurringRule, date: Date)] {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        return allRecurringRules
            .filter { !$0.isPaused }
            .compactMap { rule -> (RecurringRule, Date)? in
                guard let next = RecurringEngine.nextDueDate(for: rule),
                      next <= horizon else { return nil }
                return (rule, next)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
            .map { $0 }
    }

    /// Computed insights for the Home carousel. Regenerated every render
    /// from the current data — the engine is pure and fast enough that
    /// caching adds complexity for no measurable win. Falls back to an
    /// empty array (which hides the carousel) when no observations land.
    private var insights: [Insight] {
        InsightEngine.generate(
            expenses: allExpenses,
            accounts: allAccounts,
            currencyCode: currencyCode
        )
    }

    private var monthOverMonthChange: Double? {
        let cal = Calendar.current
        let dayOfMonth = cal.component(.day, from: .now)
        guard let thisStart = cal.dateInterval(of: .month, for: .now)?.start,
              let lastStart = cal.date(byAdding: .month, value: -1, to: thisStart),
              let comparablePoint = cal.date(byAdding: .day, value: dayOfMonth, to: lastStart) else { return nil }
        let lastSameWindow = allExpenses
            .filter { $0.date >= lastStart && $0.date < comparablePoint }
            .reduce(0) { $0 + $1.amount }
        guard lastSameWindow > 0 else { return nil }
        return (totalThisMonth - lastSameWindow) / lastSameWindow
    }

    private var recentExpenses: [Expense] { Array(allExpenses.prefix(5)) }

    /// Sparkline data: 7 trailing days ending today. When today has zero
    /// spend the rightmost bar is empty, making the chart visually shift
    /// left with awkward whitespace on the right. We drop today in that
    /// case and slide the window back one day so the chart always ends
    /// on a "real" data point.
    private var last7DaysData: [(day: Date, total: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)

        // Build the trailing window. We pull 7 days *including* today.
        let includeToday = totalToday > 0
        let endOffset = includeToday ? 0 : 1
        let startOffset = endOffset + 6
        return (endOffset...startOffset).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let total = allExpenses
                .filter { $0.date >= day && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            return (day, total)
        }
    }

    private var defaultAccount: Account? {
        if !lastUsedAccountID.isEmpty,
           let uuid = UUID(uuidString: lastUsedAccountID),
           let match = allAccounts.first(where: { $0.id == uuid && !$0.isArchived }) {
            return match
        }
        return allAccounts.first(where: { !$0.isArchived })
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $navPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    heroSection
                    quickLogSection
                    if let context = activeContext {
                        contextRow(for: context)
                    }
                    recentSection
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.lg)
            }
            .background(Color.tulaBackground)
            // Dismiss keyboard the instant the user starts scrolling — same
            // pattern as AddExpense and Apple's stock forms. Was previously
            // `.interactively` which required dragging past a threshold.
            .scrollDismissesKeyboard(.immediately)
            // Tap anywhere on the background also dismisses keyboard.
            .background(
                Color.tulaBackground
                    .onTapGesture { hideKeyboard() }
            )
            .navigationTitle("Tula")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        navPath.append(HomeDestination.cards)
                    } label: {
                        Image(systemName: "creditcard")
                            .font(.body.weight(.medium))
                    }
                    // Neutral tint — these are utility navigations, not
                    // affirmative actions. Brand amber on a navigation
                    // button reads as "primary action" and visually
                    // competes with the hero amount below.
                    .tint(.primary)
                    .accessibilityLabel("Accounts")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        navPath.append(HomeDestination.budgets)
                    } label: {
                        Image(systemName: "chart.pie")
                            .font(.body.weight(.medium))
                    }
                    .tint(.primary)
                    .accessibilityLabel("Budgets")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.medium))
                    }
                    .tint(.primary)
                    .accessibilityLabel("Settings")
                }
            }
            // Single navigation destination handler — Apple's recommended
            // pattern. Multiple `.navigationDestination(isPresented:)`
            // modifiers on the same view cause the push transition to hang
            // because SwiftUI can't reliably disambiguate them.
            .navigationDestination(for: HomeDestination.self) { dest in
                switch dest {
                case .cards:       CardsView()
                case .budgets:     BudgetsView()
                case .reviewQueue: ReviewQueueView()
                }
            }
            .sheet(item: $editingExpense) { expense in
                AddExpenseView(existingExpense: expense)
            }
            .sheet(isPresented: $showingAllExpenses) {
                NavigationStack {
                    AllExpensesView()
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingRecurring) {
                RecurringRulesView()
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    Toast(message: toast)
                        .padding(.top, Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Hero

    /// Hero card with full gradient and the prominent Devanagari watermark
    /// to the right side. The amber sparkline lives at the bottom. Tappable
    /// to drill into Stats — pulses on tap as a visual handshake before
    /// the tab transition.
    private var heroSection: some View {
        Button(action: tapHero) {
            ZStack(alignment: .topTrailing) {
                Text("तुला")
                    .font(.system(size: 130, weight: .bold))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                    .offset(x: 20, y: -26)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Date.now, format: .dateTime.month(.wide).year())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let change = monthOverMonthChange {
                            deltaBadge(change)
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Spent this month")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HeroAmountText(
                            amount: totalThisMonth,
                            currencyCode: currencyCode,
                            size: 36
                        )
                        .scaleEffect(savePulse ? 1.04 : 1.0)
                        .animation(AppAnimation.bouncy, value: savePulse)
                    }

                    if totalToday > 0 {
                        todayInline
                    }

                    if !last7DaysData.allSatisfy({ $0.total == 0 }) {
                        sparkline
                            .frame(height: 32)
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md - 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.tulaBrandFallback.opacity(0.14),
                                Color.tulaBrandFallback.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous))
            .scaleEffect(heroTapPulse ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: heroTapPulse)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func tapHero() {
        Haptics.tap()
        heroTapPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onShowStats() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { heroTapPulse = false }
    }

    private func deltaBadge(_ change: Double) -> some View {
        let isUp = change > 0
        let symbol = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green
        let percent = Int(abs(change * 100).rounded())
        return HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text("\(percent)%").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    /// Inline "today" summary that sits below the month total. A small
    /// amber dot anchors the row visually (replaces the previous sun
    /// icon — semantic "this is your active/current data" rather than
    /// weather imagery). The text "·" separator was a typography hack;
    /// a proper 3pt Circle reads as a deliberate separator dot rather
    /// than a stray character, and aligns better with the amber anchor.
    private var todayInline: some View {
        HStack(spacing: 0) {
            // Brand-color anchor — small enough to be a visual cue, not
            // an icon. Same pattern Apple Music uses for the "Now
            // Playing" row indicator and Reminders' completed dots.
            Circle()
                .fill(Color.tulaBrandFallback)
                .frame(width: 6, height: 6)
                .padding(.trailing, 8)

            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.trailing, 8)

            Text(Currency.format(totalToday, code: currencyCode))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: totalToday))
                .animation(.snappy(duration: 0.35), value: totalToday)
                .padding(.trailing, 10)

            // Refined separator — 3pt circle reads as a deliberate
            // typographic mark, not a leftover character.
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3, height: 3)
                .padding(.trailing, 8)

            Text("\(todaysExpenses.count) tx")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: Double(todaysExpenses.count)))
                .animation(.snappy(duration: 0.35), value: todaysExpenses.count)
        }
    }

    /// Amber sparkline — primary brand color back on this since the user
    /// specifically called out wanting amber here.
    private var sparkline: some View {
        Chart {
            ForEach(last7DaysData, id: \.day) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Spent", item.total),
                    width: .ratio(0.55)
                )
                .foregroundStyle(Color.tulaBrandFallback.gradient)
                .cornerRadius(3)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    // MARK: - Quick Log

    private var quickLogSection: some View {
        QuickLogBar(
            accounts: allAccounts,
            categories: allCategories,
            merchantRules: allMerchantRules,
            defaultAccount: defaultAccount,
            currencyCode: currencyCode,
            onSubmit: handleQuickLog
        )
    }

    private func handleQuickLog(_ parsedExpenses: [ParsedExpense]) {
        let valid = parsedExpenses.filter { $0.isValid }
        guard !valid.isEmpty else { return }
        var lastAccount: Account?
        for parsed in valid {
            guard let account = parsed.account else { continue }
            let expense = Expense(
                amount: parsed.amount,
                merchant: parsed.merchant,
                note: nil,
                source: .nlp,
                category: parsed.category,
                account: account
            )
            expense.rawInput = parsed.rawInput
            context.insert(expense)
            lastAccount = account
        }
        try? context.save()
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        showToast(valid.count == 1 ? "Expense saved" : "\(valid.count) expenses saved")
        evaluateBudgetAlerts()
    }

    /// Evaluates whether any budget crossed a notification threshold after
    /// the most recent save. Cheap — just walks budgets + summed expenses
    /// and posts a notification per crossing. No-op when the user has
    /// disabled budget alerts.
    private func evaluateBudgetAlerts() {
        guard budgetAlertsEnabled else { return }
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate<Budget> { $0.isActive == true }
        )
        let budgets = (try? context.fetch(budgetFetch)) ?? []
        NotificationManager.evaluateBudgetThresholds(
            budgets: budgets,
            expenses: allExpenses
        )
    }

    private func triggerSavePulse() {
        savePulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { savePulse = false }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(AppAnimation.snappy) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard toastToken == token else { return }
            withAnimation(AppAnimation.gentle) { toastMessage = nil }
        }
    }

    // MARK: - Context Row
    //
    // Single, compact row that surfaces whatever needs attention right
    // now — review queue, an imminent recurring bill, or the top
    // insight. Only one shows at a time (highest priority wins) so the
    // home screen doesn't pile three different banners on top of each
    // other competing for the eye.

    /// Possible attention items in priority order. Reviews come first
    /// because they're an explicit user task. Imminent recurring bills
    /// next — they need acknowledgement before they fire. Insights last,
    /// since they're nice-to-have observations.
    private enum HomeContext {
        case review(count: Int)
        case upcoming(rule: RecurringRule, date: Date)
        case insight(Insight)
    }

    /// Returns the single most important context item to show, or nil
    /// when nothing urgent applies. The order here defines the priority:
    /// reviews → upcoming bills → insights → nothing.
    private var activeContext: HomeContext? {
        if reviewCount > 0 {
            return .review(count: reviewCount)
        }
        if let next = upcomingRecurring.first {
            return .upcoming(rule: next.rule, date: next.date)
        }
        if let topInsight = insights.first {
            return .insight(topInsight)
        }
        return nil
    }

    /// Renders the active context as a single tappable row. Pattern
    /// follows iOS Wallet/Health "callout" cells — icon disc on left,
    /// title + subtitle stacked, chevron on the right. Glass surface
    /// so it reads as a notice rather than a primary card.
    private func contextRow(for context: HomeContext) -> some View {
        let icon = contextIcon(for: context)
        let color = contextColor(for: context)
        let title = contextTitle(for: context)
        let detail = contextDetail(for: context)

        return Button {
            Haptics.tap()
            handleContextTap(context)
        } label: {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
        .buttonStyle(.plain)
    }

    private func contextIcon(for context: HomeContext) -> String {
        switch context {
        case .review:               return "tag.slash"
        case .upcoming(let rule, _): return rule.category?.iconKey ?? "arrow.clockwise.circle.fill"
        case .insight(let i):       return i.icon
        }
    }

    private func contextColor(for context: HomeContext) -> Color {
        switch context {
        case .review:               return Color.tulaBrandFallback
        case .upcoming(let rule, _): return Color(hex: rule.category?.colorHex ?? "#D97706")
        case .insight(let i):       return i.color
        }
    }

    private func contextTitle(for context: HomeContext) -> String {
        switch context {
        case .review(let count):
            return count == 1 ? "1 expense to review" : "\(count) expenses to review"
        case .upcoming(let rule, _):
            return rule.name
        case .insight(let i):
            return i.title
        }
    }

    private func contextDetail(for context: HomeContext) -> String {
        switch context {
        case .review:
            return "Tap to categorize"
        case .upcoming(_, let date):
            return upcomingRelativeLabel(for: date)
        case .insight(let i):
            return i.detail
        }
    }

    /// "Today", "Tomorrow", "in 3 days" — keeps the upcoming context row
    /// human-readable without exposing raw dates in the compact subtitle.
    private func upcomingRelativeLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Due today" }
        if cal.isDateInTomorrow(date) { return "Due tomorrow" }
        let days = cal.dateComponents([.day], from: .now, to: date).day ?? 0
        if days <= 7 { return "Due in \(days) days" }
        return "Due \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func handleContextTap(_ context: HomeContext) {
        switch context {
        case .review:
            navPath.append(HomeDestination.reviewQueue)
        case .upcoming:
            showingRecurring = true
        case .insight:
            // No destination for insights — they're informational. Tapping
            // is a no-op but the haptic acknowledges the gesture.
            break
        }
    }

    // MARK: - Legacy banners (kept for reference / future use)
    //
    // The standalone reviewBanner and upcomingSection are no longer
    // wired into the body — replaced by the unified contextRow above.
    // Kept defined so future flows (e.g. a dedicated Activity tab) can
    // re-surface them without rebuilding from scratch.

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                title: "Upcoming",
                trailing: AnyView(SeeAllLink {
                    Haptics.tap()
                    showingRecurring = true
                })
            )

            VStack(spacing: 0) {
                ForEach(Array(upcomingRecurring.enumerated()), id: \.element.rule.id) { idx, entry in
                    Button {
                        Haptics.tap()
                        showingRecurring = true
                    } label: {
                        UpcomingRecurringRow(
                            rule: entry.rule,
                            dueDate: entry.date,
                            currencyCode: currencyCode
                        )
                        .padding(.horizontal, Spacing.lg)
                        .padding(.vertical, Spacing.sm + 2)
                    }
                    .buttonStyle(.plain)

                    if idx < upcomingRecurring.count - 1 {
                        Divider().padding(.leading, Spacing.lg + 38 + Spacing.md)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
    }

    // MARK: - Review Banner

    /// Compact callout above Recent when there are uncategorized expenses
    /// pending triage. Subtle amber styling — it's a nudge, not an alarm.
    private var reviewBanner: some View {
        Button {
            Haptics.tap()
            navPath.append(HomeDestination.reviewQueue)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "tag.slash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .frame(width: 36, height: 36)
                    .background(Color.tulaBrandFallback.opacity(0.15), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(reviewCount == 1
                         ? "1 expense to review"
                         : "\(reviewCount) expenses to review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to categorize")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent

    /// Recent expenses use a native `List` with `.scrollDisabled(true)` so we
    /// get real `.swipeActions` (same as AllExpensesView) while the list
    /// behaves as a static block inside the parent scroll view. The fixed
    /// height matches `rowHeight × count` so there's no internal scroll
    /// area for the user to hit.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                title: "Recent",
                trailing: recentExpenses.isEmpty ? nil : AnyView(SeeAllLink {
                    showingAllExpenses = true
                })
            )

            if recentExpenses.isEmpty {
                emptyActivityState
            } else {
                recentList
            }
        }
    }

    /// Approximate per-row height used to size the static List. Set slightly
    /// above the ExpenseRow's minHeight (56pt) to account for separator
    /// space and rounding. If this drifts, only visible symptom is small
    /// extra/missing whitespace at the bottom of the section.
    /// Per-row height for the recent activity list. Matches the actual
    /// rendered height of ExpenseRow (64pt minHeight + 24pt vertical
    /// padding clamped by minHeight = 64pt content + iOS list chrome
    /// ≈ ~70pt). A 72pt buffer gives a few points of safety without
    /// leaving large empty space at the end of the list frame.
    private var rowHeight: CGFloat { 72 }

    private var recentList: some View {
        List {
            ForEach(Array(recentExpenses.enumerated()), id: \.element.id) { index, expense in
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
                // erasing the line between them.
                .listRowSeparator(index == recentExpenses.count - 1 ? .hidden : .visible, edges: .bottom)
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
                .contextMenu {
                    expenseContextMenu(for: expense)
                } preview: {
                    ExpenseContextPreview(expense: expense)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(recentExpenses.count) * rowHeight)
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    @ViewBuilder
    private func expenseContextMenu(for expense: Expense) -> some View {
        Button { editingExpense = expense } label: { Label("Edit", systemImage: "pencil") }
        Button { duplicate(expense) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if let merchant = expense.merchant, !merchant.isEmpty {
            Button { logSimilar(to: expense) } label: {
                Label("Log Another \(merchant)", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button(role: .destructive) { delete(expense) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func duplicate(_ expense: Expense) {
        let copy = Expense(
            amount: expense.amount, date: .now,
            merchant: expense.merchant, note: expense.note,
            source: .manual, category: expense.category, account: expense.account
        )
        context.insert(copy)
        try? context.save()
        Haptics.success()
        showToast("Duplicated")
        triggerSavePulse()
    }

    private func logSimilar(to expense: Expense) {
        let template = Expense(
            amount: 0, date: .now,
            merchant: expense.merchant, note: nil,
            source: .manual, category: expense.category, account: expense.account
        )
        context.insert(template)
        try? context.save()
        editingExpense = template
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        Haptics.warning()
        showToast("Deleted")
    }

    private var emptyActivityState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "tray").font(.title2).foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: Spacing.xs) {
                Text("Nothing logged yet").font(.subheadline.weight(.semibold))
                Text("Use the + button or Quick Log above")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }
}

// MARK: - Upcoming Recurring Row

/// One row in Home's "Upcoming" section. Compact tile showing the rule's
/// icon, name, and the relative due-date string. Amount on the right.
private struct UpcomingRecurringRow: View {
    let rule: RecurringRule
    let dueDate: Date
    let currencyCode: String

    private var color: Color {
        if rule.kind == .expense, let cat = rule.category {
            return Color(hex: cat.colorHex)
        }
        return Color.tulaBrandFallback
    }

    private var iconKey: String {
        switch rule.kind {
        case .expense:     return rule.category?.iconKey ?? "arrow.triangle.2.circlepath"
        case .transfer:    return "arrow.left.arrow.right"
        case .cardPayment: return "creditcard"
        }
    }

    private var relativeDue: String {
        let cal = Calendar.current
        if cal.isDateInToday(dueDate) { return "Today" }
        if cal.isDateInTomorrow(dueDate) { return "Tomorrow" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now),
                                       to: cal.startOfDay(for: dueDate)).day ?? 0
        if days <= 7 { return "In \(days) days" }
        return dueDate.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: iconKey)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(relativeDue) · \(rule.cadenceLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.xs)

            Text(Currency.format(rule.amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

// MARK: - Keyboard dismissal helper

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }
}

// MARK: - Plain Row Button Style

struct PlainRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Toast

private struct Toast: View {
    let message: String
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }
}

// MARK: - Quick Log Bar

/// After voice stops, the preview card grows in prominence and we DON'T
/// auto-focus the text field — so the parsed expense and submit button
/// are unmistakably visible. Tapping the preview card also submits, in
/// addition to the trailing arrow button.
private struct QuickLogBar: View {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    let currencyCode: String
    let onSubmit: ([ParsedExpense]) -> Void

    @State private var input: String = ""
    @FocusState private var focused: Bool
    @StateObject private var speech = SpeechRecognizer()
    @State private var showingPermissionDenied = false
    /// Tracks whether we just finished a voice session — used to give the
    /// preview card extra prominence and tappable confirm behavior.
    @State private var justFinishedVoice = false

    private var parsed: [ParsedExpense] {
        ExpenseParser.parse(
            input: input,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
    }

    private var validParsed: [ParsedExpense] { parsed.filter { $0.isValid } }
    private var canSubmit: Bool { !validParsed.isEmpty && !speech.isRecording }
    private var showPreview: Bool { !validParsed.isEmpty }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            inputCapsule
            if showPreview {
                previewCard
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.bouncy, value: showPreview)
        .animation(AppAnimation.snappy, value: speech.isRecording)
        .onChange(of: speech.transcript) { _, newValue in
            input = newValue
        }
        // Voice deep-link from the Quick Actions widget posts this
        // notification — auto-start the mic so the user goes straight
        // from widget tap to speaking.
        .onReceive(NotificationCenter.default.publisher(for: .tulaStartVoiceCapture)) { _ in
            if !speech.isRecording {
                startVoice()
            }
        }
        .alert("Voice access needed", isPresented: $showingPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enable Microphone and Speech Recognition in iOS Settings to dictate expenses.")
        }
    }

    // MARK: - Input capsule

    /// Two visual modes:
    /// 1. Idle/typing — text field with a prominent mic button on the right.
    ///    The mic is brand-amber and 44pt so it reads as the primary action;
    ///    typing is supported as the secondary path.
    /// 2. Recording — the entire capsule transforms: a live waveform replaces
    ///    the text field, the background tints red, and the trailing button
    ///    becomes a clear stop control.
    private var inputCapsule: some View {
        HStack(spacing: Spacing.md) {
            if speech.isRecording {
                recordingMode
            } else {
                idleMode
            }
        }
        .padding(.leading, Spacing.lg)
        .padding(.trailing, Spacing.xs + 2)
        .padding(.vertical, Spacing.xs + 2)
        .frame(minHeight: 56)
        .background(
            Capsule().fill(
                speech.isRecording
                    ? Color.red.opacity(0.10)
                    : Color.tulaCardSurface
            )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    speech.isRecording ? Color.red.opacity(0.30) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    /// Idle / text-entry mode — full-width TextField + a bold trailing action.
    private var idleMode: some View {
        HStack(spacing: Spacing.md) {
            TextField("What did you spend?", text: $input)
                .focused($focused)
                .submitLabel(.send)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { submit() }
                .frame(maxWidth: .infinity)

            trailingActionButton
        }
    }

    /// Recording mode — live waveform visualization with stop button.
    /// The waveform is purely decorative animated bars; the actual transcript
    /// streams in below into the preview card once parseable.
    private var recordingMode: some View {
        HStack(spacing: Spacing.md) {
            WaveformIndicator()
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !input.isEmpty {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(input.split(separator: " ").count) words")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Listening…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            trailingActionButton
        }
    }

    // MARK: - Trailing action button

    /// 40pt circular button that morphs between mic / stop / send.
    /// Brand-amber in idle/send (signaling the primary action), red in
    /// recording (signaling stop). Smaller and with a subtler shadow than
    /// before — the previous 44pt with a strong colored glow read as
    /// disproportionate against the quiet input capsule.
    private var trailingActionButton: some View {
        Button(action: trailingAction) {
            ZStack {
                Circle()
                    .fill(trailingButtonFill)
                    .frame(width: 40, height: 40)
                    .shadow(color: trailingButtonFill.opacity(0.22), radius: 4, y: 2)

                Image(systemName: trailingIconName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: validParsed.count)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.92))
        .disabled(trailingDisabled)
    }

    private var trailingIconName: String {
        if speech.isRecording { return "stop.fill" }
        if canSubmit { return "arrow.up" }
        if !input.isEmpty { return "arrow.up" }
        return "mic.fill"
    }

    private var trailingButtonFill: Color {
        if speech.isRecording { return .red }
        if canSubmit { return Color.tulaBrandFallback }
        if !input.isEmpty { return Color(uiColor: .tertiaryLabel) }
        return Color.tulaBrandFallback
    }

    private var trailingDisabled: Bool {
        if speech.isRecording { return false }
        if canSubmit { return false }
        if !input.isEmpty { return true }
        return false
    }

    private func trailingAction() {
        if speech.isRecording {
            stopVoice()
        } else if canSubmit {
            submit()
        } else if input.isEmpty {
            startVoice()
        } else {
            Haptics.error()
        }
    }

    /// Compact summary of what will be saved. After voice ends, this card
    /// becomes the primary "save here" target — bigger, with a clear CTA
    /// button at the right. Tapping anywhere on the card submits.
    private var previewCard: some View {
        Button(action: submit) {
            HStack(spacing: Spacing.sm) {
                if validParsed.count == 1, let only = validParsed.first {
                    singlePreviewRow(only)
                } else {
                    multiplePreviewRow
                }
                Spacer(minLength: 0)
                saveBadge
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 4)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(justFinishedVoice
                          ? Color.tulaBrandFallback.opacity(0.12)
                          : Color.tulaCardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .strokeBorder(
                        justFinishedVoice
                            ? Color.tulaBrandFallback.opacity(0.35)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    private var saveBadge: some View {
        HStack(spacing: 4) {
            Text("Save")
                .font(.caption.weight(.bold))
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.tulaBrandFallback)
        )
        .foregroundStyle(.white)
    }

    private func singlePreviewRow(_ p: ParsedExpense) -> some View {
        HStack(spacing: Spacing.sm) {
            if let category = p.category {
                let color = Color(hex: category.colorHex)
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 28, height: 28)
                    Image(systemName: category.iconKey)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Currency.format(p.amount, code: currencyCode))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    if let merchant = p.merchant {
                        Text(merchant)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let account = p.account {
                        if p.merchant != nil { Text("·").foregroundStyle(.tertiary).font(.caption2) }
                        Text(account.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var multiplePreviewRow: some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                Circle().fill(Color.tulaBrandFallback.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "checklist")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(validParsed.count) expenses")
                    .font(.subheadline.weight(.bold))
                Text(Currency.format(validParsed.reduce(0) { $0 + $1.amount }, code: currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Voice actions

    private func startVoice() {
        Task {
            let ok = await speech.requestAuthorization()
            if ok {
                Haptics.impact()
                speech.start()
                justFinishedVoice = false
            } else {
                Haptics.error()
                showingPermissionDenied = true
            }
        }
    }

    /// Stops recording WITHOUT auto-focusing the text field. The preview
    /// card stays visible with an obvious "Save" CTA. User reads, taps to
    /// save — they don't see a keyboard slide up and cover the preview.
    private func stopVoice() {
        Haptics.tap()
        speech.stop()
        justFinishedVoice = !validParsed.isEmpty
        // Bouncier emphasis on the parsed preview
        if !validParsed.isEmpty {
            withAnimation(AppAnimation.bouncy) {
                justFinishedVoice = true
            }
        }
    }

    private func submit() {
        let valid = validParsed
        guard !valid.isEmpty else { return }
        if speech.isRecording { speech.stop() }
        onSubmit(valid)
        input = ""
        focused = false
        justFinishedVoice = false
    }
}

// MARK: - Waveform Indicator

/// Animated bars that pulse during voice recording. Purely decorative — the
/// bars don't represent actual audio amplitude, but their continuous motion
/// communicates "I'm actively listening" more reliably than a static icon.
///
/// Eight bars in brand-amber, each with its own randomized animation delay
/// and duration so the pattern feels organic, not mechanical.
private struct WaveformIndicator: View {
    @State private var animate: Bool = false

    private let barCount = 8
    private let baseHeights: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.5, 0.7]
    private let delays: [Double] = [0, 0.15, 0.3, 0.05, 0.2, 0.35, 0.1, 0.25]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: 3)
                    .scaleEffect(
                        y: animate ? baseHeights[i] : 0.2,
                        anchor: .center
                    )
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
