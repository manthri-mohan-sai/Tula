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
    @State private var allExpensesFilter: ExpenseFilter?
    @State private var showingSettings = false
    @State private var showingRecurring = false
    @State private var showingOverdueOnly = false
    @State private var confirmLogRule: RecurringRule?
    @State private var confirmLogDate: Date?
    @State private var showingLogConfirm = false
    @State private var confirmSkipRule: RecurringRule?
    @State private var confirmSkipDate: Date?
    @State private var showingSkipConfirm = false
    @State private var navPath = NavigationPath()
    @State private var toastMessage: String?
    @State private var toastToken: UUID = UUID()
    @State private var savePulse: Bool = false
    /// Number of in-flight Foundation Models enrichment calls. When > 0,
    /// the home view shows a subtle "Smart parsing..." pill so the user
    /// sees that on-device AI is doing work. Decrements on completion.
    /// Counter (not bool) handles concurrent multi-entry parses correctly.
    @State private var smartParseInFlight: Int = 0
    @State private var heroTapPulse: Bool = false

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    @AppStorage("smartParsingEnabled") private var smartParsingEnabled: Bool = true

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
    /// Pairs each non-paused, non-yet-handled recurring rule with its next
    /// due date. "Not yet handled" means: not already logged today (by the
    /// auto-detect rules below), not skipped, not auto-logged. The window
    /// is capped at 7 days from now.
    ///
    /// **Already-logged detection** is best-effort matching, not strict
    /// equality. A rule is considered fulfilled for today when an
    /// expense exists with same calendar day AND same category AND same
    /// account AND title/merchant contains the rule's name (case-insensitive).
    /// User manually logging "lunch at office canteen" with the canteen's
    /// food category fulfills the "Lunch" recurring rule even though the
    /// expense was manual. Conservative — any one mismatch (different
    /// category, different account, or rule name not in merchant string)
    /// leaves the rule visible so the user isn't accidentally dropped.
    ///
    /// Returns ALL matches in the window (no cap here); the consuming view
    /// applies its own grouping/cap (see `groupedUpcoming`).
    private var upcomingRecurring: [(rule: RecurringRule, date: Date)] {
        let calendar = Calendar.current
        let now = Date.now
        let horizon = calendar.date(byAdding: .day, value: 7, to: now) ?? now

        return allRecurringRules
            .filter { !$0.isPaused }
            .compactMap { rule -> (RecurringRule, Date)? in
                guard let next = RecurringEngine.nextDueDate(for: rule),
                      next <= horizon else { return nil }
                // Suppress if user already logged this rule's expense today
                // (or for the due date — supports rules due tomorrow that
                // the user pre-paid).
                if isRuleFulfilled(rule, forDueDate: next, calendar: calendar) {
                    return nil
                }
                return (rule, next)
            }
            .sorted { $0.1 < $1.1 }
    }

    /// Overdue recurring items — past-due occurrences that were never
    /// logged or skipped. Only surfaces items for confirmation-required
    /// rules (auto-generate rules handle themselves). Capped at 5 to
    /// avoid flooding the home screen if a rule was ignored for weeks.
    private var overdueRecurring: [(rule: RecurringRule, date: Date)] {
        var result: [(RecurringRule, Date)] = []
        for rule in allRecurringRules where !rule.isPaused && rule.kind == .expense {
            let dates = RecurringEngine.overdueDates(for: rule)
            for date in dates {
                if !isRuleFulfilled(rule, forDueDate: date, calendar: Calendar.current) {
                    result.append((rule, date))
                }
            }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    /// Checks whether the user has already logged an expense that fulfills
    /// this recurring rule for the given due date. Match criteria (ALL must
    /// be true):
    /// - Same calendar day
    /// - Same category
    /// - Same account
    /// - Expense merchant/note contains the rule's name (case-insensitive)
    ///
    /// The last criterion is the soft heuristic — matches "Mess Breakfast"
    /// against rule named "Breakfast", or "Office Lunch" against "Lunch".
    /// Conservative: better to leave an item visible (annoying nudge) than
    /// hide a real upcoming (missed expense).
    private func isRuleFulfilled(_ rule: RecurringRule,
                                  forDueDate dueDate: Date,
                                  calendar: Calendar) -> Bool {
        guard let dayInterval = calendar.dateInterval(of: .day, for: dueDate) else {
            return false
        }
        let ruleName = rule.name.lowercased()
        let ruleCategoryID = rule.category?.id
        let ruleAccountID = rule.account?.id

        return allExpenses.contains { expense in
            // Same day
            guard expense.date >= dayInterval.start,
                  expense.date < dayInterval.end else { return false }
            // Same category
            guard expense.category?.id == ruleCategoryID else { return false }
            // Same account
            guard expense.account?.id == ruleAccountID else { return false }
            // Rule name appears in merchant or note
            let merchantMatch = (expense.merchant ?? "")
                .lowercased().contains(ruleName)
            let noteMatch = (expense.note ?? "")
                .lowercased().contains(ruleName)
            return merchantMatch || noteMatch
        }
    }

    /// Grouped upcoming items ready for the home screen.
    ///
    /// **Grouping logic** matches user intent:
    /// - Time-scheduled items (rule.hasSpecificTime == true) are sorted
    ///   by their actual time; only the NEAREST one is surfaced. The
    ///   others stay queued — they'll show up after the nearest is
    ///   logged/skipped (which removes it from `upcomingRecurring`).
    /// - General items (hasSpecificTime == false) all show, stacked
    ///   below the scheduled one. There's no inherent ordering — they're
    ///   sorted by their notion of "due date" but visually grouped.
    ///
    /// **Cap**: total at 3 rows so the home screen doesn't get crowded.
    /// One scheduled (the nearest), up to 2 general. If there are 5
    /// general all due today, we show 2 and note in the UI that there
    /// are more (via a "+N more" pill at the bottom).
    private var groupedUpcoming: GroupedUpcoming {
        let all = upcomingRecurring
        let scheduled = all.filter { $0.rule.hasSpecificTime }
        let general = all.filter { !$0.rule.hasSpecificTime }

        // Nearest scheduled = first after sort by date (the sort already
        // happened in upcomingRecurring).
        let nearestScheduled = scheduled.first

        // General items: take up to 2 for display, count rest as overflow.
        let visibleGeneral = Array(general.prefix(2))
        let overflowCount = max(0, general.count - visibleGeneral.count)

        return GroupedUpcoming(
            scheduled: nearestScheduled,
            general: visibleGeneral,
            overflowCount: overflowCount
        )
    }

    /// Display structure for the home upcoming section. One nearest
    /// time-scheduled item, plus a stack of general items, plus an
    /// optional overflow count for the "+N more" affordance.
    struct GroupedUpcoming {
        let scheduled: (rule: RecurringRule, date: Date)?
        let general: [(rule: RecurringRule, date: Date)]
        let overflowCount: Int

        /// True when there's nothing to render — saves the view layer
        /// from having to check three fields.
        var isEmpty: Bool {
            scheduled == nil && general.isEmpty
        }
    }

    /// Computed insights for the Home context callouts. Regenerated every
    /// render from the current data — the engine is pure and fast enough
    /// that caching adds complexity for no measurable win.
    ///
    /// **Streak filtered out** because the streak chip lives in the hero
    /// card now (see `loggingStreak`). Showing it twice would be noise.
    private var insights: [Insight] {
        InsightEngine.generate(
            expenses: allExpenses,
            accounts: allAccounts,
            currencyCode: currencyCode
        )
        .filter { $0.kind != .streak }
    }

    /// Current consecutive-day logging streak — used by the hero card's
    /// streak chip. Same algorithm InsightEngine uses internally; the
    /// public helper keeps the two surfaces in sync.
    private var loggingStreak: Int {
        InsightEngine.loggingStreak(expenses: allExpenses)
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
                    if smartParseInFlight > 0 {
                        smartParsingPill
                            .transition(.asymmetric(
                                insertion: .move(edge: .top)
                                    .combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                    contextSections
                    recentSection
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.lg)
                .animation(AppAnimation.snappy, value: smartParseInFlight)
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
                    AllExpensesView(presetFilter: allExpensesFilter)
                }
                .onDisappear { allExpensesFilter = nil }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingRecurring) {
                RecurringRulesView()
            }
            .sheet(isPresented: $showingOverdueOnly) {
                RecurringRulesView(showOnlyOverdue: true)
            }
            .confirmationDialog(
                "Log \(confirmLogRule?.name ?? "expense")?",
                isPresented: $showingLogConfirm,
                titleVisibility: .visible
            ) {
                Button("Log") {
                    if let rule = confirmLogRule, let date = confirmLogDate {
                        logUpcoming(rule: rule, date: date)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if let rule = confirmLogRule {
                    Text("This will record \(Currency.format(rule.amount, code: currencyCode)) as an expense.")
                }
            }
            .confirmationDialog(
                "Skip \(confirmSkipRule?.name ?? "expense")?",
                isPresented: $showingSkipConfirm,
                titleVisibility: .visible
            ) {
                Button("Skip", role: .destructive) {
                    if let rule = confirmSkipRule, let date = confirmSkipDate {
                        skipUpcoming(rule: rule, date: date)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This occurrence will be marked as skipped.")
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

    // MARK: - Smart parsing pill

    /// In-flight indicator for Foundation Models enrichment. Appears
    /// only when at least one FM parse is running, sits between the
    /// Quick Log row and the rest of the home view, fades out the
    /// moment all parses complete.
    ///
    /// **Why it's here.** Users submit "spent 350 on lunch with team",
    /// the rules parser doesn't categorize it, FM kicks in async. Without
    /// this pill, the user sees nothing happen for 200-500ms and then
    /// suddenly the category appears in the list. The pill makes it
    /// visible: "yes, on-device AI is working on this."
    private var smartParsingPill: some View {
        HStack(spacing: 8) {
            // The official SF Symbol for Apple Intelligence on iOS 26.
            // Falls back to `sparkles` if running on a pre-26 build —
            // shouldn't happen given our deployment target, but defensive.
            Image(systemName: SFSymbols.appleIntelligence)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.tulaBrandFallback)
                .symbolEffect(.pulse, options: .repeating)

            Text(smartParseInFlight == 1
                 ? "Smart parsing…"
                 : "Smart parsing \(smartParseInFlight) entries…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer()

            // Small spinner for the "something is computing" cue. A
            // pulsing icon alone reads as decorative; the ProgressView
            // confirms work is genuinely happening.
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs + 2)
        .background(
            Capsule()
                .fill(Color.tulaBrandFallback.opacity(0.10))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    Color.tulaBrandFallback.opacity(0.22),
                    lineWidth: 0.5
                )
        )
        .accessibilityLabel("Apple Intelligence is parsing your entry")
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
                    HStack(spacing: 6) {
                        Text(Date.now, format: .dateTime.month(.wide).year())
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        // Streak chip beside the month label — when the
                        // user has a logging streak going, a small flame
                        // glyph with the day count appears here. This used
                        // to be its own insight callout below the hero,
                        // but it's better integrated into the hero itself:
                        // streaks are about *consistency* with the headline
                        // number, not a separate piece of information.
                        // Threshold (3 days) matches the insight engine's.
                        if loggingStreak >= 3 {
                            HStack(spacing: 3) {
                                Image(systemName: "flame.fill")
                                Text("\(loggingStreak)")
                            }
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.orange.opacity(0.15))
                            )
                            .accessibilityLabel("\(loggingStreak) day logging streak")
                        }
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
            onSubmit: handleQuickLog,
            isSmartParsing: smartParseInFlight > 0
        )
    }

    /// Routes the submission. Typed input takes the fast rule-based path;
    /// single-expense voice input gets re-parsed by Foundation Models so
    /// transcription noise (homophones like "waffle" → "rahul", split
    /// digits "1 20") gets corrected with full context.
    ///
    /// **Multi-expense input bypasses FM.** Foundation Models returns a
    /// single structured result — it has no concept of "this string
    /// represents two expenses". Routing "350 food and 400 groceries"
    /// through FM would silently lose one of them. The rule parser is
    /// purpose-built for splitting on conjunctions and commas, so when
    /// rules already detected 2+ expenses, we trust that decomposition
    /// and skip FM entirely.
    private func handleQuickLog(_ parsedExpenses: [ParsedExpense],
                                rawInput: String,
                                isVoice: Bool) {
        let isMultiExpense = parsedExpenses.count >= 2

        if isVoice, !isMultiExpense, SmartExpenseParser.isAvailable {
            handleVoiceQuickLog(rawInput: rawInput, ruleFallback: parsedExpenses)
            return
        }
        // Typed input, multi-expense voice, or no-FM device: rule path.
        saveParsedExpenses(parsedExpenses)
    }

    /// FM-first voice path. Sends the raw speech transcript to Foundation
    /// Models with the user's category and account lists as anchors, then
    /// constructs and saves an Expense from the structured result. Falls
    /// back to the rule-parsed expenses if FM is unavailable, returns
    /// garbage, or times out.
    private func handleVoiceQuickLog(rawInput: String,
                                     ruleFallback: [ParsedExpense]) {
        let usableCategories = allCategories.filter { !$0.isArchived }
        let usableAccounts = allAccounts.filter { !$0.isArchived }
        let categoryEntries = usableCategories.map {
            CategoryEntry(name: $0.name, iconKey: $0.iconKey)
        }
        let accountNames = usableAccounts.map { $0.name }
        let categoryByName = Dictionary(uniqueKeysWithValues:
            usableCategories.map { ($0.name.lowercased(), $0) })
        let accountByName = Dictionary(uniqueKeysWithValues:
            usableAccounts.map { ($0.name.lowercased(), $0) })

        // Show the AI pill for the duration of the FM call. Floor ensures
        // it stays visible long enough to register (FM can be fast on
        // iPhone 17 — 100-200ms wouldn't otherwise be seen).
        smartParseInFlight += 1
        let startedAt = Date()
        let minPillVisible: TimeInterval = 0.8
        let timeout: TimeInterval = 6.0

        // Build the situational + DB context block BEFORE the detached
        // task so MainActor access to ModelContext works. The string is
        // Sendable and crosses the actor boundary safely.
        let contextBlock = FMContextBuilder.build(modelContext: context)

        Task.detached(priority: .userInitiated) {
            // Race the FM call against a timeout so a hung model doesn't
            // freeze the save flow indefinitely.
            let result = await withTaskGroup(of: SmartParseResult?.self) { group in
                group.addTask {
                    await SmartExpenseParser.parseVoice(
                        rawInput,
                        categories: categoryEntries,
                        accountNames: accountNames,
                        contextBlock: contextBlock
                    )
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            // Enforce minimum pill visibility.
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < minPillVisible {
                try? await Task.sleep(for: .seconds(minPillVisible - elapsed))
            }

            await MainActor.run {
                smartParseInFlight = max(0, smartParseInFlight - 1)

                // Build and save from FM result if it produced a usable
                // amount + account; otherwise fall back to rule output.
                if let result, result.amount > 0 {
                    // Amount sanity check: if FM's amount is significantly
                    // smaller than what the rule parser extracted from the
                    // same raw input, FM probably dropped a digit during
                    // its interpretation. Fall back to rules in that case.
                    //
                    // The rule parser handles number-word normalization
                    // (e.g. "three fifty" → 350) and split-digit collapse
                    // ("3 50" → 350) before extracting the amount. So if
                    // rule says 350 and FM says 50, FM is wrong.
                    let ruleAmount = ruleFallback.first?.amount ?? 0
                    if ruleAmount > 0, result.amount < ruleAmount / 2 {
                        saveParsedExpenses(ruleFallback)
                        return
                    }

                    let category = result.category
                        .flatMap { categoryByName[$0.lowercased()] }
                    let account = result.account
                        .flatMap { accountByName[$0.lowercased()] }
                        ?? defaultAccount
                    guard let account else {
                        // No account possible — couldn't save. Fall back.
                        saveParsedExpenses(ruleFallback)
                        return
                    }

                    let expense = Expense(
                        amount: result.amount,
                        merchant: result.merchant,
                        note: result.item,
                        source: .smartParsed,
                        category: category,
                        account: account
                    )
                    expense.rawInput = rawInput
                    context.insert(expense)
                    try? context.save(); WidgetRefresh.refresh(using: context)
                    NotificationManager.refreshDailyReminder(using: context)
                    lastUsedAccountID = account.id.uuidString
                    Haptics.success()
                    triggerSavePulse()
                    showToast("Expense saved")
                    evaluateBudgetAlerts()
                } else {
                    // FM unavailable / failed / no usable result. Use rule output.
                    saveParsedExpenses(ruleFallback)
                }
            }
        }
    }

    /// Original rule-based save path, extracted so both the typed flow
    /// and the voice fallback share one code path. Saves the parsed
    /// expenses and kicks off background FM enrichment for any that
    /// rules couldn't categorize.
    private func saveParsedExpenses(_ parsedExpenses: [ParsedExpense]) {
        let valid = parsedExpenses.filter { $0.isValid }
        guard !valid.isEmpty else { return }
        var lastAccount: Account?
        var savedExpenses: [Expense] = []
        for parsed in valid {
            guard let account = parsed.account else { continue }
            let expense = Expense(
                amount: parsed.amount,
                merchant: parsed.merchant,
                note: parsed.note,
                source: .nlp,
                category: parsed.category,
                account: account
            )
            expense.rawInput = parsed.rawInput
            context.insert(expense)
            lastAccount = account
            savedExpenses.append(expense)
        }
        try? context.save(); WidgetRefresh.refresh(using: context)
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        showToast(valid.count == 1 ? "Expense saved" : "\(valid.count) expenses saved")
        evaluateBudgetAlerts()

        // ─── Smart enrichment ───────────────────────────────────────
        // For any expense that rules couldn't categorize, fire Apple
        // Foundation Models in the background. The expense is already
        // saved — the user sees instant feedback. When FM returns
        // (typically 100-500ms later), we update the category in place.
        //
        // Gates: only runs on devices where FM is available, when the
        // user has the feature on (default), and only for inputs that
        // actually need help (no category yet AND complex enough to
        // benefit from LLM understanding).
        enrichWithSmartParser(savedExpenses)
    }

    /// Fires Foundation Models in the background to fill in categories
    /// the rule-based parser missed. No-op on unsupported devices, when
    /// the toggle is off, or when nothing needs enrichment. Updates
    /// happen silently — no toast, no spinner. The user just sees the
    /// category appear a beat later.
    private func enrichWithSmartParser(_ expenses: [Expense]) {
        guard smartParsingEnabled,
              SmartExpenseParser.isAvailable else { return }

            // Only enrich expenses where category is missing AND raw input
            // looks complex enough to benefit (rules already handled the
            // simple cases). "Complex enough" is a soft heuristic: more
            // than two whitespace-separated tokens, or longer than 18 chars.
            // For "ola 250" we skip — rules clearly saw it and decided.
            let candidates = expenses.filter { expense in
                expense.category == nil
                    && (expense.rawInput?.count ?? 0) > 8
                    && shouldAskLLM(expense.rawInput ?? "")
            }
            guard !candidates.isEmpty else { return }

            let usableCategories = allCategories.filter { !$0.isArchived }
            let categoryEntries = usableCategories.map {
                CategoryEntry(name: $0.name, iconKey: $0.iconKey)
            }
            let categoryMap = Dictionary(uniqueKeysWithValues:
                usableCategories.map { ($0.name.lowercased(), $0) })

            // Capture the data we need from the SwiftData models on the
            // main actor BEFORE spawning the detached task. Reading model
            // properties from off-main can trigger SwiftData warnings;
            // pairing each id with its raw input lets us do the async
            // FM work cleanly and apply results back on main.
            let workItems: [(expense: Expense, rawInput: String)] = candidates
                .compactMap { exp in
                    guard let input = exp.rawInput else { return nil }
                    return (exp, input)
                }

            // Bump the in-flight counter so the "Smart parsing..." pill
            // appears. We bump by workItems.count up-front (one for each
            // expense being enriched) and decrement individually as each
            // FM call completes — so the pill shows during the entire
            // batch and disappears the moment the last one resolves.
            smartParseInFlight += workItems.count
            // Record the start time so each decrement can enforce a
            // minimum-visibility window. A bare FM call can complete in
            // 100-200ms, which is faster than the human eye reliably
            // registers — without this floor, the pill would flicker
            // and the user wouldn't know AI ran at all.
            let pillStartedAt = Date()
            let minPillVisible: TimeInterval = 1.2

            Task.detached(priority: .userInitiated) {
                for item in workItems {
                    let result = await SmartExpenseParser.parse(
                        item.rawInput,
                        categories: categoryEntries
                    )

                    await MainActor.run {
                        if let result {
                            // Re-find the category by name (FM returns a string).
                            if let catName = result.category?.lowercased(),
                               let category = categoryMap[catName] {
                                item.expense.category = category
                            }
                            // Improve merchant if rules left it nil and FM
                            // identified one (don't overwrite — rules might
                            // have caught the precise merchant the user typed).
                            if item.expense.merchant == nil,
                               let m = result.merchant,
                               !m.isEmpty {
                                item.expense.merchant = m
                            }
                            try? context.save(); WidgetRefresh.refresh(using: context)
                        }
                    }

                    // Enforce minimum pill visibility before decrementing.
                    // If FM was fast, we wait out the remainder of the
                    // visibility window; if it was slow, this is a no-op.
                    let elapsed = Date().timeIntervalSince(pillStartedAt)
                    let remaining = minPillVisible - elapsed
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }

                    await MainActor.run {
                        // Always decrement, whether parse succeeded or
                        // not — otherwise a failed parse would leave the
                        // pill stuck visible forever.
                        smartParseInFlight = max(0, smartParseInFlight - 1)
                    }
                }
            }
    }

    /// Soft heuristic for whether an input is "complex" enough to warrant
    /// LLM invocation. Avoids firing FM for inputs the rules clearly
    /// understood; saves battery and latency. Returns true when:
    /// - The text contains 3+ tokens, OR
    /// - It contains a verb-like word ("spent", "paid", "bought", etc.)
    private func shouldAskLLM(_ input: String) -> Bool {
        let lower = input.lowercased()
        let tokens = lower
            .split(whereSeparator: { $0.isWhitespace })
            .count
        if tokens >= 3 { return true }
        let verbs = ["spent", "paid", "bought", "got", "ate", "had",
                     "ordered", "rode", "took", "drank", "purchased"]
        return verbs.contains { lower.contains($0) }
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
        case overdue(rule: RecurringRule, date: Date)
        /// "+N more recurring due today" — compact summary line shown
        /// when the user has more than 2 general recurring items due,
        /// so we don't clutter the home with every one. Tap to expand
        /// (drills into the recurring rules sheet).
        case recurringOverflow(count: Int)
        case overdueOverflow(count: Int)
        case insight(Insight)

        var identifier: String {
            switch self {
            case .review(let count):
                return "review-\(count)"
            case .upcoming(let rule, let date):
                return "upcoming-\(rule.id.uuidString)-\(Int(date.timeIntervalSince1970))"
            case .overdue(let rule, let date):
                return "overdue-\(rule.id.uuidString)-\(Int(date.timeIntervalSince1970))"
            case .recurringOverflow(let count):
                return "overflow-\(count)"
            case .overdueOverflow(let count):
                return "overdue-overflow-\(count)"
            case .insight(let insight):
                return "insight-\(insight.id)"
            }
        }
    }

    /// Returns the single most important context item to show, or nil
    /// when nothing urgent applies. The order here defines the priority:
    /// reviews → upcoming bills → insights → nothing.
    @ViewBuilder
    private var contextSections: some View {
        let overdue = overdueContexts
        let upcoming = upcomingContexts
        let other = otherContexts

        if !overdue.isEmpty {
            contextGroup(title: "Overdue", contexts: overdue)
        }
        if !upcoming.isEmpty {
            contextGroup(title: "Upcoming", contexts: upcoming)
        }
        ForEach(other, id: \.identifier) { context in
            contextRow(for: context)
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
    }

    private func contextGroup(title: String, contexts: [HomeContext]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(contexts, id: \.identifier) { context in
                contextRow(for: context)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
    }

    private var overdueContexts: [HomeContext] {
        let overdue = overdueRecurring
        var contexts: [HomeContext] = []
        for item in overdue.prefix(3) {
            contexts.append(.overdue(rule: item.rule, date: item.date))
        }
        if overdue.count > 3 {
            contexts.append(.overdueOverflow(count: overdue.count - 3))
        }
        return contexts
    }

    private var upcomingContexts: [HomeContext] {
        let grouped = groupedUpcoming
        var contexts: [HomeContext] = []
        if let scheduled = grouped.scheduled {
            contexts.append(.upcoming(rule: scheduled.rule, date: scheduled.date))
        }
        for item in grouped.general {
            contexts.append(.upcoming(rule: item.rule, date: item.date))
        }
        if grouped.overflowCount > 0 {
            contexts.append(.recurringOverflow(count: grouped.overflowCount))
        }
        return contexts
    }

    private var otherContexts: [HomeContext] {
        var contexts: [HomeContext] = []
        if reviewCount > 0 {
            contexts.append(.review(count: reviewCount))
        }
        if let topInsight = insights.first {
            contexts.append(.insight(topInsight))
        }
        return contexts
    }

    /// Ordered list of context callouts to render above the Recent section.
    ///
    /// **Ordering** matches user attention: one nearest time-scheduled
    /// recurring item first (because time-scheduled items have urgency),
    /// then general (all-day) recurring items stacked below, then at most
    /// one review-queue callout, then at most one insight.
    ///
    /// Already-logged items are filtered out upstream by `upcomingRecurring`
    /// so they never appear here. When the user logs/skips an item, the
    /// SwiftData query re-emits and the ForEach animates the removal —
    /// the next item slides up to take its place.
    private var activeContexts: [HomeContext] {
        var contexts: [HomeContext] = []

        // 1. Overdue items first — highest priority.
        let overdue = overdueRecurring
        let visibleOverdue = overdue.prefix(3)
        for item in visibleOverdue {
            contexts.append(.overdue(rule: item.rule, date: item.date))
        }
        if overdue.count > visibleOverdue.count {
            contexts.append(.overdueOverflow(count: overdue.count - visibleOverdue.count))
        }

        // 2. Upcoming items.
        let grouped = groupedUpcoming
        if let scheduled = grouped.scheduled {
            contexts.append(.upcoming(rule: scheduled.rule, date: scheduled.date))
        }
        for item in grouped.general {
            contexts.append(.upcoming(rule: item.rule, date: item.date))
        }
        if grouped.overflowCount > 0 {
            contexts.append(.recurringOverflow(count: grouped.overflowCount))
        }

        // 3. Review and insight stay at the bottom.
        if reviewCount > 0 {
            contexts.append(.review(count: reviewCount))
        }
        if let topInsight = insights.first {
            contexts.append(.insight(topInsight))
        }
        return contexts
    }

    /// Legacy single-context accessor. Kept for any call sites that might
    /// still reference it; the home body itself now uses `activeContexts`
    /// (plural) to render multiple callouts.
    private var activeContext: HomeContext? {
        activeContexts.first
    }

    /// Renders the active context as a row. Pattern follows iOS Wallet/
    /// Health "callout" cells — icon disc on left, title + subtitle
    /// stacked.
    ///
    /// **Layout variants** by context type:
    /// - `.upcoming`: wrapped in `SwipeableContextRow` for native-feeling
    ///   swipe gestures — swipe right to log (brand amber), swipe left to
    ///   skip (secondary gray). Same pattern as iOS Mail / Reminders.
    ///   A long swipe past threshold fires the action immediately; a
    ///   short swipe just reveals the button under the moving card.
    ///   Tapping the row body still drills into the recurring sheet.
    /// - `.review` / `.insight`: a single tap target with chevron. No
    ///   swipe actions because there isn't a one-click resolution.
    @ViewBuilder
    private func contextRow(for context: HomeContext) -> some View {
        switch context {
        case .upcoming(let rule, let date):
            SwipeableContextRow(
                leadingLabel: "Log",
                leadingIcon: "checkmark.circle.fill",
                leadingColor: Color.tulaBrandFallback,
                leadingAction: { confirmLog(rule: rule, date: date) },
                trailingLabel: "Skip",
                trailingIcon: "forward.fill",
                trailingColor: Color.secondary,
                trailingAction: { confirmSkip(rule: rule, date: date) },
                onTap: {
                    Haptics.tap()
                    handleContextTap(context)
                }
            ) {
                contextRowBody(for: context, showHint: true)
            }
        case .overdue(let rule, let date):
            SwipeableContextRow(
                leadingLabel: "Log",
                leadingIcon: "checkmark.circle.fill",
                leadingColor: Color.tulaBrandFallback,
                leadingAction: { confirmLog(rule: rule, date: date) },
                trailingLabel: "Skip",
                trailingIcon: "forward.fill",
                trailingColor: Color.secondary,
                trailingAction: { confirmSkip(rule: rule, date: date) },
                onTap: {
                    Haptics.tap()
                    handleContextTap(context)
                }
            ) {
                contextRowBody(for: context, showHint: true)
            }
        case .review, .insight, .recurringOverflow, .overdueOverflow:
            Button {
                Haptics.tap()
                handleContextTap(context)
            } label: {
                contextRowBody(for: context, showHint: false)
            }
            .buttonStyle(.plain)
        }
    }

    /// Common visual content for any context row — icon + title + subtitle.
    /// `showHint` adds a faint "swipe" affordance on the trailing edge to
    /// hint that the row is swipeable (since swipe is non-discoverable by
    /// default). For non-swipeable contexts, shows a chevron instead.
    private func contextRowBody(for context: HomeContext, showHint: Bool) -> some View {
        let icon = contextIcon(for: context)
        let color = contextColor(for: context)
        let title = contextTitle(for: context)
        let detail = contextDetail(for: context)

        return HStack(spacing: Spacing.md) {
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

            // Trailing affordance: chevron for tap-only rows, a subtle
            // "swipe arrows" hint for swipeable rows. The hint is two
            // tiny chevrons in opposite directions — universally readable
            // as "you can swipe this either way" without taking up
            // significant space.
            if showHint {
                HStack(spacing: 1) {
                    Image(systemName: "chevron.left")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .contentShape(Rectangle())
    }

    /// Right-side action area for non-swipeable contexts (review/insight).
    /// Kept around for backward reference but currently unused — the new
    /// `contextRowBody` handles the chevron directly. Will be removed in
    /// a future cleanup pass once we're sure no callers reference it.
    @ViewBuilder
    private func contextTrailingActions(for context: HomeContext) -> some View {
        switch context {
        case .upcoming, .review, .insight, .recurringOverflow, .overdue, .overdueOverflow:
            EmptyView()
        }
    }

    private func confirmLog(rule: RecurringRule, date: Date) {
        confirmLogRule = rule
        confirmLogDate = date
        showingLogConfirm = true
    }

    private func confirmSkip(rule: RecurringRule, date: Date) {
        confirmSkipRule = rule
        confirmSkipDate = date
        showingSkipConfirm = true
    }

    private func skipUpcoming(rule: RecurringRule, date: Date) {
        Haptics.tap()
        withAnimation(AppAnimation.snappy) {
            RecurringEngine.skipOccurrence(rule: rule, dueDate: date)
            try? context.save(); WidgetRefresh.refresh(using: context)
        }
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        showToast("Skipped")
    }

    /// Log a single upcoming occurrence from the home row. Creates the
    /// expense immediately using the rule's saved fields, same path as
    /// the notification "Log it" action. Cancels any pending notification
    /// for this date so the user isn't asked twice.
    private func logUpcoming(rule: RecurringRule, date: Date) {
        Haptics.success()
        withAnimation(AppAnimation.snappy) {
            RecurringEngine.createTransaction(rule: rule, date: date, in: context)
            try? context.save(); WidgetRefresh.refresh(using: context)
        }
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        triggerSavePulse()
        showToast("Logged \(rule.name)")
    }

    private func contextIcon(for context: HomeContext) -> String {
        switch context {
        case .review:                return "tag.slash"
        case .upcoming(let rule, _): return rule.category?.iconKey ?? "arrow.clockwise.circle.fill"
        case .overdue(let rule, _):  return rule.category?.iconKey ?? "exclamationmark.circle.fill"
        case .recurringOverflow:     return "ellipsis.circle.fill"
        case .overdueOverflow:       return "exclamationmark.circle.fill"
        case .insight(let i):        return i.icon
        }
    }

    private func contextColor(for context: HomeContext) -> Color {
        switch context {
        case .review:                return Color.tulaBrandFallback
        case .upcoming(let rule, _): return Color(hex: rule.category?.colorHex ?? "#D97706")
        case .overdue:               return .red
        case .recurringOverflow:     return .secondary
        case .overdueOverflow:       return .red
        case .insight(let i):        return i.color
        }
    }

    private func contextTitle(for context: HomeContext) -> String {
        switch context {
        case .review(let count):
            return count == 1 ? "1 expense to review" : "\(count) expenses to review"
        case .upcoming(let rule, _):
            return rule.name
        case .overdue(let rule, _):
            return rule.name
        case .recurringOverflow(let count):
            return count == 1 ? "1 more recurring due" : "\(count) more recurring due"
        case .overdueOverflow(let count):
            return count == 1 ? "1 more overdue" : "\(count) more overdue"
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
        case .overdue(_, let date):
            return overdueRelativeLabel(for: date)
        case .recurringOverflow:
            return "Tap to see all"
        case .overdueOverflow:
            return "Tap to see all"
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

    private func overdueRelativeLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "Overdue · yesterday" }
        if cal.isDateInToday(date) { return "Overdue · earlier today" }
        let days = cal.dateComponents([.day], from: date, to: .now).day ?? 0
        if days <= 7 { return "Overdue · \(days) days ago" }
        return "Overdue · \(date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private func handleContextTap(_ context: HomeContext) {
        switch context {
        case .review:
            navPath.append(HomeDestination.reviewQueue)
        case .upcoming, .recurringOverflow, .overdue:
            showingRecurring = true
        case .overdueOverflow:
            showingOverdueOnly = true
        case .insight(let insight):
            switch insight.kind {
            case .todayTotal, .biggestToday, .quietToday:
                let cal = Calendar.current
                let start = cal.startOfDay(for: .now)
                let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now
                allExpensesFilter = ExpenseFilter(dateRange: .custom(start: start, end: end))
                showingAllExpenses = true
            case .monthPace, .bigSpender, .categoryAlert:
                allExpensesFilter = ExpenseFilter(dateRange: .thisMonth)
                showingAllExpenses = true
            default:
                break
            }
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
        try? context.save(); WidgetRefresh.refresh(using: context)
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
        try? context.save(); WidgetRefresh.refresh(using: context)
        editingExpense = template
    }

    private func delete(_ expense: Expense) {
        withAnimation {
            context.delete(expense)
            try? context.save()
        }
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
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

// MARK: - Swipeable Context Row

/// Custom swipe-to-act wrapper for the home upcoming context row.
///
/// **Why custom?** SwiftUI's `swipeActions(edge:)` only works inside a
/// `List`. The home view uses a `ScrollView` + `VStack` layout where
/// that modifier is silently ignored. This view provides equivalent
/// behavior outside of a List — drag the foreground content left or
/// right to reveal action backgrounds; release past the threshold to
/// fire the action.
///
/// **Behavior modeled on iOS Mail / Reminders:**
/// - Swipe RIGHT reveals the leading (primary positive) action.
/// - Swipe LEFT reveals the trailing (secondary / deferring) action.
/// - A *long* swipe past `commitThreshold` auto-fires the action.
/// - A *short* swipe (or release before the threshold) snaps back.
/// - Past the rubber-band threshold, drag resistance increases so the
///   user feels they're stretching against something — communicates the
///   commit boundary tactically.
/// - Haptic feedback fires once when the drag crosses the threshold,
///   giving a tactile "this will commit if released" cue.
private struct SwipeableContextRow<Content: View>: View {
    let leadingLabel: String
    let leadingIcon: String
    let leadingColor: Color
    let leadingAction: () -> Void

    let trailingLabel: String
    let trailingIcon: String
    let trailingColor: Color
    let trailingAction: () -> Void

    let onTap: () -> Void

    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var hapticArmed = true

    /// Drag distance required to commit the action on release. ~25% of a
    /// typical iPhone width — same feel as Apple Mail's swipe threshold.
    private let commitThreshold: CGFloat = 90
    /// Where rubber-band resistance kicks in. Set generously past the
    /// commit threshold so the user gets clear visual feedback that
    /// they've passed the trigger point.
    private let resistanceStart: CGFloat = 130

    var body: some View {
        ZStack {
            // Background: action labels on each side. Only the side being
            // swiped toward is visible (opacity gated by offset sign).
            HStack(spacing: 0) {
                actionBackground(
                    label: leadingLabel,
                    icon: leadingIcon,
                    color: leadingColor,
                    alignment: .leading
                )
                .opacity(offset > 1 ? 1 : 0)

                Spacer(minLength: 0)

                actionBackground(
                    label: trailingLabel,
                    icon: trailingIcon,
                    color: trailingColor,
                    alignment: .trailing
                )
                .opacity(offset < -1 ? 1 : 0)
            }

            // Foreground: the actual content, shifted by drag amount.
            content()
                .offset(x: offset)
                .gesture(swipeGesture)
                .onTapGesture {
                    onTap()
                }
        }
    }

    private var swipeGesture: some Gesture {
        // minimumDistance: 12 prevents tap gesture from being eaten by
        // tiny drags. Anything below 12pt is treated as a tap.
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let raw = value.translation.width
                // Apply rubber-band past resistanceStart so the user
                // feels increasing pushback — Apple's standard pattern.
                if abs(raw) > resistanceStart {
                    let excess = abs(raw) - resistanceStart
                    let resisted = resistanceStart + excess * 0.3
                    offset = (raw < 0 ? -1 : 1) * resisted
                } else {
                    offset = raw
                }

                // Haptic feedback exactly once when crossing the commit
                // threshold. `hapticArmed` flips off after firing and
                // re-arms only when the user pulls back below threshold.
                let crossed = abs(raw) > commitThreshold
                if crossed && hapticArmed {
                    Haptics.impact()
                    hapticArmed = false
                } else if !crossed {
                    hapticArmed = true
                }
            }
            .onEnded { value in
                let raw = value.translation.width
                if raw > commitThreshold {
                    // Right-swipe past threshold — fire leading action.
                    withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                    leadingAction()
                } else if raw < -commitThreshold {
                    // Left-swipe past threshold — fire trailing action.
                    withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                    trailingAction()
                } else {
                    // Short swipe — snap back without firing.
                    withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                }
                hapticArmed = true
            }
    }

    private func actionBackground(label: String, icon: String,
                                   color: Color, alignment: Alignment) -> some View {
        HStack(spacing: 8) {
            if alignment == .trailing { Spacer(minLength: 0) }

            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            if alignment == .leading { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Spacing.md + 4)
        // Width chosen so the background extends well past the commit
        // threshold — the user sees the colored region before they've
        // dragged enough to fire the action, so the affordance is clear.
        .frame(width: 130)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color)
        )
    }
}



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
    /// Submit callback. Carries the rule-parsed expenses, the raw input
    /// string, and a flag indicating whether the input came from voice
    /// dictation. The host (HomeView) uses these to decide whether to
    /// save the rule-parsed result directly (typed input) or send the
    /// raw transcript through Foundation Models for re-parse (voice
    /// input, where rules can't reliably handle transcription noise).
    let onSubmit: ([ParsedExpense], String, Bool) -> Void
    /// True when Apple Foundation Models is currently enriching a
    /// recent submission. Drives the radiant amber glow around the
    /// input capsule so the user sees that on-device AI is engaged.
    /// Parent passes `smartParseInFlight > 0`.
    let isSmartParsing: Bool

    @State private var input: String = ""
    @FocusState private var focused: Bool
    @StateObject private var speech = SpeechRecognizer()
    @State private var showingPermissionDenied = false
    /// Tracks whether we just finished a voice session — used to give the
    /// preview card extra prominence and tappable confirm behavior.
    @State private var justFinishedVoice = false

    /// Tracks whether the CURRENT input text originated from voice
    /// dictation vs typing. Set to true whenever a speech transcript
    /// update overwrites `input`; reset to false whenever the user
    /// edits via keyboard. Used at submit time to decide whether to
    /// route through Foundation Models (voice path, more forgiving of
    /// transcription noise) or the rule parser (typed path, faster).
    ///
    /// More reliable than `justFinishedVoice` for routing decisions —
    /// that flag depends on the rule parser successfully extracting an
    /// amount AT the moment the user taps stop, which can be wrong when
    /// transcription is noisy enough to break rule parsing.
    @State private var inputCameFromVoice: Bool = false

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
            // Speech recognizer updated the transcript — adopt it AND
            // mark the input as voice-sourced so submit can route via FM.
            // Track separately from the text content itself (which the
            // user may then edit by hand) to avoid losing the voice
            // routing decision if a small typo is corrected manually.
            input = newValue
            if !newValue.isEmpty {
                inputCameFromVoice = true
            }
        }
        .onChange(of: input) { oldValue, newValue in
            // If the user changes the text without speech being involved
            // (e.g. typing in the field), flip back to typed source.
            // We compare against speech.transcript: if they diverge AND
            // speech isn't currently producing this update, the user typed.
            if newValue != speech.transcript && !speech.isRecording {
                // But: speech.transcript may still hold the prior voice
                // text after stop. Only switch to typed if the new value
                // is meaningfully different (not just a small edit of the
                // voice transcript). Conservative: keep voice flag unless
                // input becomes empty (clean slate) or markedly different.
                if newValue.isEmpty {
                    inputCameFromVoice = false
                }
            }
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
            // Background stays the same regardless of state. The AI signal
            // (amber halo) is carried by the shadow + stroke; the recording
            // signal (red) is in the stroke + the recordingMode subview's
            // own iconography (waveform, red stop button). Doubling up the
            // red on the background made the capsule feel alarmed; calmer
            // base + sharper ring reads as "engaged" without "warning".
            Capsule().fill(Color.tulaCardSurface)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    capsuleStrokeColor,
                    lineWidth: aiActive ? 1.5 : 1
                )
        )
        // Radiant glow signals "on-device AI is engaged" — covers both
        // states: speech recognition is transcribing your voice (which
        // IS on-device AI), or Foundation Models is enriching a recent
        // entry. Visually it's one cohesive signal: "AI is helping you
        // right now". Honest framing — both stages are AI, both deserve
        // the same indicator.
        //
        // Layered shadows (inner + outer) at brand amber give the capsule
        // a soft halo. Recording adds a red outer ring on top of the amber
        // (via the stroke), so red+amber together = "voice mode" and amber
        // alone = "smart parsing" — same vocabulary, different inflection.
        .shadow(
            color: glowColor,
            radius: aiActive ? 14 : 0,
            x: 0,
            y: 0
        )
        .shadow(
            color: glowColor.opacity(0.55),
            radius: aiActive ? 6 : 0,
            x: 0,
            y: 0
        )
        .scaleEffect(aiActive ? glowPulse : 1.0)
        .onAppear {
            // Drive the breathing pulse with a repeating animation
            // that ticks the scale and shadow alpha between two values.
            // .easeInOut with autoreverses makes it feel like a slow
            // exhale rather than a heartbeat — calm, not anxious.
            withAnimation(
                .easeInOut(duration: 1.3).repeatForever(autoreverses: true)
            ) {
                glowPulse = 1.012
            }
        }
        .animation(.easeInOut(duration: 0.35), value: aiActive)
    }

    /// Unified "AI is engaged" state — true when any of:
    /// - On-device speech recognition is recording
    /// - Foundation Models is enriching a submitted expense
    /// - Foundation Models is doing parallel transcript correction during
    ///   a dictation pause (the user paused to think; we use that idle
    ///   time to clean up homophones in the segment they just finished)
    /// All three are forms of on-device AI helping the user; the glow
    /// treats them as a single visual signal so the user sees one
    /// coherent "AI is here" indicator rather than three separate cues.
    private var aiActive: Bool {
        speech.isRecording || isSmartParsing || speech.isCorrecting
    }

    /// Pulse scale state for the AI glow. Idles at 1.0; while AI is active,
    /// gently breathes between 1.0 and 1.012 — barely perceptible motion
    /// that signals "alive" without distracting from the user's reading.
    @State private var glowPulse: CGFloat = 1.0

    /// Stroke color layered with the amber glow. Voice recording adds a
    /// red ring on top of the amber halo, so red+amber together read as
    /// "voice mode" (still AI, just a stronger signal because the mic is
    /// hot). Amber alone reads as "smart parsing in progress".
    private var capsuleStrokeColor: Color {
        if speech.isRecording { return Color.red.opacity(0.40) }
        if isSmartParsing { return Color.tulaBrandFallback.opacity(0.55) }
        return .clear
    }

    /// Glow color for the shadow ring. Always amber when AI is active —
    /// the recording state's red lives in the stroke, not the shadow, so
    /// the halo color stays consistent. Zero when idle so the shadow
    /// modifier collapses to no-op (no perf cost when nothing is happening).
    private var glowColor: Color {
        aiActive
            ? Color.tulaBrandFallback.opacity(0.65)
            : .clear
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
        let rawInput = input
        let wasVoice = inputCameFromVoice
        guard !valid.isEmpty else { return }
        if speech.isRecording { speech.stop() }
        onSubmit(valid, rawInput, wasVoice)
        input = ""
        focused = false
        justFinishedVoice = false
        inputCameFromVoice = false
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
