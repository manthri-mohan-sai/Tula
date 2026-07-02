import SwiftUI
import SwiftData
import Charts

// MARK: - Navigation

/// Destinations reachable from the Home screen via path-based navigation.
/// Using a single value-based destination (instead of multiple
/// `.navigationDestination(isPresented:)` bool modifiers) avoids a SwiftUI
/// bug where stacked boolean destinations cause the push transition to hang.
enum HomeDestination: Hashable {
    case reviewQueue
    case allExpenses(filter: ExpenseFilter?, searchFocused: Bool)
}

/// Data needed to present the "Log recurring expense" sheet.
/// All display properties are eagerly captured at creation time so
/// SwiftData's lazy relationship faulting cannot produce stale/nil
/// values on the sheet's first render.
struct LogConfirmationItem: Identifiable {
    let id = UUID()
    let rule: RecurringRule
    let date: Date
    // Eagerly captured display data — avoids lazy-load misses
    let ruleName: String
    let iconName: String
    let iconColor: Color
    let cadenceLabel: String
    let amount: Double
    let isVariable: Bool
    let categoryName: String?
    let categoryIcon: String?
    let categoryColor: Color?
    let accountName: String?
    let accountIcon: String?
    let accountColor: Color?
    /// Predicted amount from SmartAmountPredictor (may differ from rule.amount).
    let predictionHint: String

    init(rule: RecurringRule, date: Date, prediction: SmartAmountPredictor.Prediction? = nil) {
        self.rule = rule
        self.date = date
        self.ruleName = rule.name
        self.iconName = rule.category?.iconKey ?? "arrow.clockwise"
        self.iconColor = Color(hex: rule.category?.colorHex ?? "#D97706")
        self.cadenceLabel = rule.cadenceLabel
        self.amount = prediction?.amount ?? rule.amount
        self.isVariable = rule.isVariable
        self.categoryName = rule.category?.name
        self.categoryIcon = rule.category?.iconKey
        self.categoryColor = rule.category.map { Color(hex: $0.colorHex) }
        self.accountName = rule.account?.name
        self.accountIcon = rule.account?.iconKey
        self.accountColor = rule.account.map { Color(hex: $0.colorHex) }
        self.predictionHint = prediction?.hint(ruleAmount: rule.amount) ?? ""
    }
}

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query private var allMerchantRules: [MerchantRule]
    @Query private var allRecurringRules: [RecurringRule]
    @Query(filter: #Predicate<Budget> { $0.isActive == true }) private var activeBudgets: [Budget]
    @PrimaryCurrency private var currencyCode
    @AppStorage("themePresetID") private var themePresetID: String = "saffron"
    @AppStorage("launchAnimationEnabled") private var launchAnimationEnabled: Bool = true

    @State private var editingExpense: Expense?
    @State private var showingVoiceOverlay = false
    @State private var expenseToDelete: Expense?
    @State private var showingSettings = false
    @State private var showingRecurring = false
    @State private var showingOverdueOnly = false
    @State private var logConfirmation: LogConfirmationItem?
    @State private var confirmSkipRule: RecurringRule?
    @State private var confirmSkipDate: Date?
    @State private var showingSkipConfirm = false
    @State private var navPath = NavigationPath()
    @State private var toastMessage: String?
    @State private var toastToken: UUID = UUID()
    @State private var toastUndoAction: (() -> Void)?
    @State private var savePulse: Bool = false
    /// Number of in-flight Foundation Models enrichment calls. When > 0,
    /// the home view shows a subtle "Smart parsing..." pill so the user
    /// sees that on-device AI is doing work. Decrements on completion.
    /// Counter (not bool) handles concurrent multi-entry parses correctly.
    @State private var smartParseInFlight: Int = 0
    @State private var heroTapPulse: Bool = false
    @AppStorage("dismissedInsightIDs") private var dismissedInsightIDsRaw: String = ""
    @State private var dismissedUpcomingKeys: Set<String> = []
    @State private var recurringSuggestionToCreate: RecurringSuggestion?
    @State private var merchantRuleConfirmInsight: Insight?
    @State private var appeared = false
    @State private var showingAPIKeyPrompt = false
    @State private var showingTransfer = false
    @State private var showingReceiptGallery = false
    /// Three independent drift phases at incommensurate periods (8s, 11s, 14s).
    /// Their compound motion creates fluid, organic glow movement that never
    /// visually repeats — similar to Apple Music's ambient background effect.
    @State private var drift1: Bool = false
    @State private var drift2: Bool = false
    @State private var drift3: Bool = false
    /// Explicit state-driven accent color for the glow. Updated via
    /// withAnimation so SwiftUI interpolates the RGB values smoothly.
    @State private var glowColor: Color = .tulaBrandFallback
    /// Brief brightness pulse during color transitions — glow "breathes"
    /// as it shifts, then settles.
    @State private var glowPulse: Bool = false
    /// Time-of-day color temperature — warm mornings, cool evenings.
    @State private var ambientTint: TimeAmbience.Tint = TimeAmbience.current()

    @State private var expandedStacks: Set<String> = []
    /// Caches for RecurringEngine results. `nextDueDate` and `overdueDates`
    /// loop through date sequences (up to 366 iterations per rule). As raw
    /// computed properties they ran on EVERY body evaluation, causing jank
    /// with many rules. These caches hold the engine output; cheap filtering
    /// (isPaused, isRuleFulfilled, dismissedKeys) still runs per-render.
    @State private var cachedNextDueDates: [UUID: Date] = [:]
    @State private var cachedOverdueDates: [UUID: [Date]] = [:]
    @State private var cachedPredictions: [UUID: SmartAmountPredictor.Prediction] = [:]
    private var networkMonitor = NetworkMonitor.shared

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    @AppStorage("smartParsingEnabled") private var smartParsingEnabled: Bool = true
    @AppStorage("lastAPIKeyPromptDate") private var lastAPIKeyPromptDate: Double = 0

    init() { }

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

    /// Drift speed multiplier — heavy spending days feel energetic (faster
    /// glow drift), quiet days feel calmer (slower drift).
    private var driftSpeedMultiplier: Double {
        let dayOfMonth = max(1, Double(Calendar.current.component(.day, from: .now)))
        let avgPerDay = totalThisMonth / dayOfMonth
        return SpendingVelocity.driftMultiplier(todayTotal: totalToday, monthAvgPerDay: avgPerDay)
    }

    /// Accent color for the page gradient — top-spending category this month,
    /// falling back to brand color when there's no spending yet.
    private var pageAccentColor: Color {
        let hex = topCategoryHex
        return hex.isEmpty ? Color.tulaBrandFallback : Color(hex: hex)
    }

    /// Hex string of the top-spending category. Used as an animation value
    /// so SwiftUI can detect color changes and crossfade the glow smoothly.
    /// Filters out uncategorized expenses — they must not dominate the
    /// accent color, otherwise it always falls back to brand amber.
    private var topCategoryHex: String {
        let withCategory = thisMonthExpenses.filter { $0.category != nil }
        // Group by category ID, not colorHex — two categories can share
        // the same color, inflating one group's total incorrectly.
        let grouped = Dictionary(grouping: withCategory, by: { $0.category!.id })
        guard let top = grouped.max(by: {
            $0.value.reduce(0) { $0 + $1.amount } < $1.value.reduce(0) { $0 + $1.amount }
        }) else {
            return ""
        }
        return top.value.first?.category?.colorHex ?? ""
    }

    /// Persisted set of insight IDs the user has dismissed. Stored as a
    /// comma-separated string in @AppStorage so dismissals survive app
    /// restarts. Insight IDs are deterministic (same data → same IDs),
    /// so dismissed insights stay gone until the underlying data changes
    /// and the InsightEngine produces fresh IDs.
    private var dismissedInsightIDs: Set<String> {
        guard !dismissedInsightIDsRaw.isEmpty else { return [] }
        return Set(dismissedInsightIDsRaw.split(separator: ",").map(String.init))
    }

    private func dismissInsight(_ id: String) {
        var ids = dismissedInsightIDs
        ids.insert(id)
        dismissedInsightIDsRaw = ids.joined(separator: ",")
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
        let tomorrow = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now

        return allRecurringRules
            .filter { !$0.isPaused }
            .compactMap { rule -> (RecurringRule, Date)? in
                guard let next = cachedNextDueDates[rule.id],
                      next < tomorrow else { return nil }
                if isRuleFulfilled(rule, forDueDate: next, calendar: calendar) {
                    return nil
                }
                let key = "\(rule.id)_\(Int(next.timeIntervalSince1970))"
                if dismissedUpcomingKeys.contains(key) { return nil }
                return (rule, next)
            }
            .sorted { $0.1 < $1.1 }
    }

    /// Overdue recurring items — past-due occurrences that were never
    /// logged or skipped. Only surfaces items for confirmation-required
    /// rules (auto-generate rules handle themselves). Capped at 5 to
    /// avoid flooding the home screen if a rule was ignored for weeks.
    private var overdueRecurring: [(rule: RecurringRule, date: Date)] {
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: .now)) ?? .now
        var result: [(RecurringRule, Date)] = []
        for rule in allRecurringRules where !rule.isPaused && rule.kind == .expense {
            let dates = cachedOverdueDates[rule.id] ?? []
            for date in dates {
                guard date >= yesterday else { continue }
                if !isRuleFulfilled(rule, forDueDate: date, calendar: calendar) {
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

    /// Daily budget pace from the overall (non-category-scoped) monthly budget.
    /// Returns nil when no overall budget is set.
    private var dailyBudget: Double? {
        guard let overall = activeBudgets.first(where: { $0.category == nil }),
              overall.amount > 0 else { return nil }
        let daysInMonth = Double(Calendar.current.range(of: .day, in: .month, for: .now)?.count ?? 30)
        return overall.amount / daysInMonth
    }

    private var insights: [Insight] {
        var all = InsightEngine.generate(
            expenses: allExpenses,
            accounts: allAccounts,
            currencyCode: currencyCode,
            recurringRules: allRecurringRules,
            dailyBudget: dailyBudget
        )

        // Merge budget pacing insights
        let budgetInsights = InsightEngine.budgetPacingInsights(
            budgets: activeBudgets,
            expenses: allExpenses,
            currencyCode: currencyCode
        )
        all.append(contentsOf: budgetInsights)

        return all.sorted { $0.priority > $1.priority }
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

    /// Top merchant names by frequency, passed to QuickLogBar for speech
    /// recognition vocabulary hints. Computing here avoids giving the bar
    /// a ModelContext dependency. Capped at 50 to leave room in the 100-
    /// phrase contextualStrings budget for accounts, categories, etc.
    private var frequentMerchantNames: [String] {
        var counts: [String: Int] = [:]
        for expense in allExpenses {
            guard let merchant = expense.merchant?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !merchant.isEmpty else { continue }
            counts[merchant, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(50)
            .map(\.key)
    }

    // MARK: - Body

    private var scrollBackground: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height

            ZStack {
                Color.tulaBackground

                // Primary glow — compound drift from three independent phases
                // creates fluid, organic motion. Each drift bool oscillates
                // at a different period, so the combined path never repeats.
                Circle()
                    .fill(glowColor)
                    .frame(width: w * 0.85, height: w * 0.85)
                    .blur(radius: w * 0.32)
                    .opacity((glowPulse ? 0.42 : 0.28) * ambientTint.opacityMultiplier)
                    .scaleEffect(drift3 ? 1.05 : 0.96)
                    .position(
                        x: w * 0.5 + (drift1 ? 16 : -16) + (drift2 ? -7 : 7),
                        y: h * 0.14 + (drift1 ? -8 : 8) + (drift3 ? 5 : -5)
                    )

                // Secondary glow — same three drifts wired differently so the
                // two blobs orbit each other in a lava-lamp style.
                Circle()
                    .fill(glowColor)
                    .frame(width: w * 0.5, height: w * 0.5)
                    .blur(radius: w * 0.2)
                    .opacity((glowPulse ? 0.22 : 0.14) * ambientTint.opacityMultiplier)
                    .scaleEffect(drift1 ? 1.04 : 0.94)
                    .position(
                        x: w * 0.32 + (drift2 ? 10 : -10) + (drift3 ? -5 : 5),
                        y: h * 0.09 + (drift3 ? 7 : -7) + (drift1 ? -4 : 4)
                    )
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onTapGesture { hideKeyboard() }
        .onAppear {
            ambientTint = TimeAmbience.current()
            glowColor = TimeAmbience.apply(ambientTint, to: pageAccentColor)
            let m = driftSpeedMultiplier
            withAnimation(.easeInOut(duration: 8 * m).repeatForever(autoreverses: true)) {
                drift1 = true
            }
            withAnimation(.easeInOut(duration: 11 * m).repeatForever(autoreverses: true)) {
                drift2 = true
            }
            withAnimation(.easeInOut(duration: 14 * m).repeatForever(autoreverses: true)) {
                drift3 = true
            }
        }
        .onChange(of: topCategoryHex) { _, _ in
            // 1. Flash brighter — glow inhales
            withAnimation(.easeOut(duration: 0.4)) {
                glowPulse = true
            }
            // 2. Slowly shift to the new color (with time-of-day tint)
            withAnimation(.spring(duration: 2.5, bounce: 0.05)) {
                glowColor = TimeAmbience.apply(ambientTint, to: pageAccentColor)
            }
            // 3. Settle brightness — glow exhales
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 1.5)) {
                    glowPulse = false
                }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $navPath) {
            mainScrollView
        }
    }

    private var mainScrollView: some View {
        mainScrollViewCore
            .onReceive(NotificationCenter.default.publisher(for: .tulaExpenseSaved)) { _ in
                showToast("Expense saved")
            }
            .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.6), trigger: editingExpense)
            .sheet(item: $editingExpense) { expense in
                AddExpenseView(existingExpense: expense)
            }
            .fullScreenCover(isPresented: $showingVoiceOverlay) {
                VoiceInputOverlay(
                    accounts: allAccounts.filter { !$0.isArchived },
                    categories: allCategories.filter { !$0.isArchived },
                    merchantRules: allMerchantRules,
                    defaultAccount: defaultAccount,
                    currencyCode: currencyCode,
                    topMerchants: frequentMerchantNames,
                    onSave: { expense in
                        context.insert(expense)
                        UserLearningEngine.learn(
                            merchant: expense.merchant,
                            category: expense.category?.name,
                            amount: expense.amount,
                            hour: Calendar.current.component(.hour, from: expense.date)
                        )
                        try? context.save()
                        WidgetRefresh.refresh(using: context)
                        NotificationManager.refreshDailyReminder(using: context)
                        if let acct = expense.account {
                            lastUsedAccountID = acct.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("Expense saved · Voice")
                        evaluateBudgetAlerts()
                    },
                    onEdit: { expense in
                        context.insert(expense)
                        try? context.save()
                        // Slight delay so fullScreenCover dismisses before
                        // the edit sheet appears — avoids SwiftUI sheet
                        // conflicts.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            editingExpense = expense
                        }
                    },
                    onSaveMany: { expenses in
                        guard !expenses.isEmpty else { return }
                        for expense in expenses {
                            context.insert(expense)
                            UserLearningEngine.learn(
                                merchant: expense.merchant,
                                category: expense.category?.name,
                                amount: expense.amount,
                                hour: Calendar.current.component(.hour, from: expense.date)
                            )
                        }
                        try? context.save()
                        WidgetRefresh.refresh(using: context)
                        NotificationManager.refreshDailyReminder(using: context)
                        if let last = expenses.last?.account {
                            lastUsedAccountID = last.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("\(expenses.count) expenses saved · Voice")
                        evaluateBudgetAlerts()
                    },
                    onDismiss: { }
                )
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingRecurring) {
                RecurringRulesView()
            }
            .sheet(item: $recurringSuggestionToCreate) { suggestion in
                RecurringRuleFormView(suggestion: suggestion)
            }
            .sheet(isPresented: $showingOverdueOnly) {
                RecurringRulesView(showOnlyOverdue: true)
            }
            .sheet(isPresented: $showingTransfer) {
                TransferFormView()
            }
            .sheet(isPresented: $showingReceiptGallery) {
                NavigationStack {
                    ReceiptGalleryView()
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                if let image = shareableImage {
                    ShareSheet(items: [image])
                }
            }
            .sheet(item: $logConfirmation) { item in
                LogAmountSheetView(
                    item: item,
                    currencyCode: currencyCode,
                    onLog: { rule, date, amount in
                        logUpcoming(rule: rule, date: date, customAmount: amount)
                    },
                    onMarkPaid: { rule, date in
                        markAlreadyPaid(rule: rule, date: date)
                    }
                )
            }
            .alert("Enhance with AI",
                   isPresented: $showingAPIKeyPrompt) {
                Button("Set Up Now") {
                    showingSettings = true
                }
                Button("Not Now", role: .cancel) { }
            } message: {
                Text("Tula works great without AI. For smarter category suggestions and receipt parsing, add a free Google Gemini API key in Settings.")
            }
            .sheet(item: $merchantRuleConfirmInsight) { insight in
                MerchantRuleConfirmSheet(
                    insight: insight,
                    categories: allCategories,
                    accounts: allAccounts,
                    onConfirm: { applyMerchantAutoRule(insight) },
                    onDismiss: { merchantRuleConfirmInsight = nil }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    Toast(message: toast, onUndo: toastUndoAction != nil ? { performUndo() } : nil)
                        .padding(.top, Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: toastMessage) { _, newValue in
                if let message = newValue {
                    UIAccessibility.post(notification: .announcement, argument: message)
                }
            }
    }

    private var mainScrollViewCore: some View {
        ScrollView {
            scrollContent
        }
        .background { scrollBackground }
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            refreshRecurringCaches()
            try? await Task.sleep(for: .seconds(0.6))
        }
        .onAppear {
            guard !appeared else { return }
            refreshRecurringCaches()
            let delay: Double = launchAnimationEnabled ? 2.0 : 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(AppAnimation.gentle) {
                    appeared = true
                }
            }
            checkAPIKeyPrompt()
        }
        .onChange(of: allRecurringRules.count) { _, _ in
            refreshRecurringCaches()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                refreshRecurringCaches()
                // Refresh ambient tint — warm mornings, cool evenings
                let newTint = TimeAmbience.current()
                withAnimation(.easeInOut(duration: 2.0)) {
                    ambientTint = newTint
                    glowColor = TimeAmbience.apply(newTint, to: pageAccentColor)
                }
            }
        }
        .navigationTitle("Tula")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { toolbarMenu }
        }
        .navigationDestination(for: HomeDestination.self) { dest in
            destinationView(for: dest)
        }
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            heroSection
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
                .shadow(color: pageAccentColor.opacity(0.18), radius: 28, y: 6)
            if !networkMonitor.isConnected {
                offlineBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            quickLogSection
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.05), value: appeared)
            if allExpenses.isEmpty {
                firstExpensePrompt
                    .offset(y: appeared ? 0 : 16)
                    .opacity(appeared ? 1 : 0)
                    .animation(AppAnimation.gentle.delay(0.08), value: appeared)
            }
            if smartParseInFlight > 0 {
                smartParsingPill
                    .transition(.asymmetric(
                        insertion: .move(edge: .top)
                            .combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            contextSections
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.10), value: appeared)
            recentSection
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.15), value: appeared)
        }
        .adaptiveContentWidth()
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
        .animation(AppAnimation.snappy, value: smartParseInFlight)
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
    @State private var showOfflineInfo = false

    private var offlineBanner: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating)
                Text("Offline")
                    .font(.caption.weight(.semibold))
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showOfflineInfo.toggle()
                    }
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Color(.systemGray6))
            )
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )

            if showOfflineInfo {
                Text("Smart parsing uses a cloud connection. Basic receipt scanning and expense entry work offline.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
    }

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

    // MARK: - Navigation Destinations

    @ViewBuilder
    private func destinationView(for dest: HomeDestination) -> some View {
        switch dest {
        case .reviewQueue: ReviewQueueView()
        case .allExpenses(let filter, let searchFocused):
            AllExpensesView(presetFilter: filter, startSearchFocused: searchFocused)
        }
    }

    // MARK: - Toolbar

    /// Trailing toolbar — Transfer and Receipts grouped in a menu,
    /// Settings as a standalone gear icon.
    private var toolbarMenu: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    Haptics.tap()
                    showingTransfer = true
                } label: {
                    Label("Transfer", systemImage: "arrow.left.arrow.right")
                }
                Button {
                    Haptics.tap()
                    showingReceiptGallery = true
                } label: {
                    Label("Receipts", systemImage: "doc.text.viewfinder")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.medium))
            }
            .tint(.primary)
            .accessibilityLabel("More actions")

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
            .compositingGroup()
            .tulaHeroSurface(cornerRadius: CornerRadius.large)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous))
            .scaleEffect(heroTapPulse ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: heroTapPulse)
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Total spent this month")
            .accessibilityValue(Currency.format(totalThisMonth, code: currencyCode))
            .accessibilityHint("Double tap to view stats")
        }
        .buttonStyle(.plain)
    }

    private func tapHero() {
        Haptics.tap()
        heroTapPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { heroTapPulse = false }
        // Navigate to all expenses for this month
        let filter = ExpenseFilter(dateRange: .thisMonth)
        navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
    }

    private func deltaBadge(_ change: Double) -> some View {
        let isUp = change > 0
        let symbol = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green
        let label = formatDeltaPercent(change)
        return HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text(label).font(.caption.weight(.semibold))
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
        .accessibilityElement()
        .accessibilityLabel("7-day spending trend")
        .accessibilityValue({
            let total = last7DaysData.reduce(0) { $0 + $1.total }
            let peak = last7DaysData.max(by: { $0.total < $1.total })?.total ?? 0
            return "Total \(Currency.format(total, code: currencyCode)), peak day \(Currency.format(peak, code: currencyCode))"
        }())
    }

    // MARK: - Quick Log

    private var quickLogSection: some View {
        QuickLogBar(
            accounts: allAccounts,
            categories: allCategories,
            merchantRules: allMerchantRules,
            defaultAccount: defaultAccount,
            currencyCode: currencyCode,
            onSaveDrafts: { expenses in
                guard !expenses.isEmpty else { return }
                for expense in expenses {
                    context.insert(expense)
                    UserLearningEngine.learn(
                        merchant: expense.merchant,
                        category: expense.category?.name,
                        amount: expense.amount,
                        hour: Calendar.current.component(.hour, from: expense.date)
                    )
                }
                try? context.save()
                WidgetRefresh.refresh(using: context)
                NotificationManager.refreshDailyReminder(using: context)
                if let last = expenses.last?.account {
                    lastUsedAccountID = last.id.uuidString
                }
                Haptics.success()
                triggerSavePulse()
                showToast(expenses.count > 1 ? "\(expenses.count) expenses saved" : "Expense saved")
                evaluateBudgetAlerts()
            },
            isSmartParsing: smartParseInFlight > 0,
            onMicTap: { showingVoiceOverlay = true }
        )
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
                date: parsed.date,
                merchant: parsed.merchant,
                note: parsed.note,
                source: .nlp,
                category: parsed.category,
                account: account
            )
            expense.rawInput = parsed.rawInput
            context.insert(expense)
            UserLearningEngine.learn(
                merchant: expense.merchant,
                category: expense.category?.name,
                amount: expense.amount,
                hour: Calendar.current.component(.hour, from: expense.date)
            )
            lastAccount = account
            savedExpenses.append(expense)
        }
        try? context.save(); WidgetRefresh.refresh(using: context)
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        let undoTargets = savedExpenses
        showToast(valid.count == 1 ? "Expense saved" : "\(valid.count) expenses saved") {
            for expense in undoTargets {
                context.delete(expense)
            }
            try? context.save()
            WidgetRefresh.refresh(using: context)
            Haptics.warning()
        }
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

            Task(priority: .userInitiated) { @MainActor in
                for item in workItems {
                    let result = await SmartExpenseParser.parse(
                        item.rawInput,
                        categories: categoryEntries
                    )

                    if let result {
                        // Category: MerchantRuleResolver first (deterministic),
                        // then FM suggestion with fuzzy name resolution.
                        let enrichedCategory = MerchantRuleResolver.category(
                            for: result.merchant ?? item.expense.merchant,
                            in: context
                        ) ?? resolveCategory(named: result.category)
                        if let enrichedCategory {
                            item.expense.category = enrichedCategory
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

                    // Enforce minimum pill visibility before decrementing.
                    // If FM was fast, we wait out the remainder of the
                    // visibility window; if it was slow, this is a no-op.
                    let elapsed = Date().timeIntervalSince(pillStartedAt)
                    let remaining = minPillVisible - elapsed
                    if remaining > 0 {
                        try? await Task.sleep(for: .seconds(remaining))
                    }

                    // Always decrement, whether parse succeeded or
                    // not — otherwise a failed parse would leave the
                    // pill stuck visible forever.
                    smartParseInFlight = max(0, smartParseInFlight - 1)
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
    /// Parses a YYYY-MM-DD date string returned by the FM. Returns nil
    /// for nil input, empty strings, or unparseable formats.
    private static func parseYMD(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: string)
    }

    /// Resolve a category name (e.g. from FM output) to one of the user's
    /// active categories. Two-pass: exact case-insensitive match first,
    /// then substring overlap so "Food" matches "Food & Drinks" and
    /// "Transport" matches "Travel & Transport". Mirrors the same logic
    /// in AddExpenseView.resolveCategory(named:).
    private func resolveCategory(named name: String?) -> Category? {
        guard let name, !name.isEmpty else { return nil }
        let target = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let active = allCategories.filter { !$0.isArchived }

        // Pass 1: exact case-insensitive match
        if let exact = active.first(where: { $0.name.lowercased() == target }) {
            return exact
        }
        // Pass 2: substring overlap — "Food" ↔ "Food & Drinks"
        let overlaps = active
            .filter { cat in
                let catLower = cat.name.lowercased()
                return target.contains(catLower) || catLower.contains(target)
            }
            .sorted { $0.name.count < $1.name.count }
        return overlaps.first
    }

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

    /// Shows a once-per-day prompt when Gemini is selected but API key
    /// isn't configured. Skipped if Apple FM is available (the user has
    /// a working on-device alternative) or if the user has explicitly
    /// disabled smart parsing (they don't want AI — respect that).
    private func checkAPIKeyPrompt() {
        // Skip if the user explicitly turned off smart parsing — they
        // don't want AI features, so nagging about an API key is wrong.
        guard smartParsingEnabled else { return }

        // Skip if Apple FM is available — user has on-device AI.
        if AIProvider.appleFM.isReady { return }

        // Only prompt when Gemini is the selected provider.
        let provider = AIProviderStorage.selected
        guard provider == .gemini else { return }

        // Skip if already configured.
        guard !provider.isReady else { return }

        // Throttle to once per day.
        let lastPrompt = Date(timeIntervalSince1970: lastAPIKeyPromptDate)
        guard !Calendar.current.isDateInToday(lastPrompt) else { return }

        // Show after a short delay so the home screen settles first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            lastAPIKeyPromptDate = Date.now.timeIntervalSince1970
            showingAPIKeyPrompt = true
        }
    }

    private func triggerSavePulse() {
        savePulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { savePulse = false }
    }

    private func showToast(_ message: String, undoAction: (() -> Void)? = nil) {
        let token = UUID()
        toastToken = token
        toastUndoAction = undoAction
        withAnimation(AppAnimation.snappy) { toastMessage = message }
        let duration: Double = undoAction != nil ? 4.0 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard toastToken == token else { return }
            withAnimation(AppAnimation.gentle) {
                toastMessage = nil
                toastUndoAction = nil
            }
        }
    }

    private func performUndo() {
        toastUndoAction?()
        withAnimation(AppAnimation.snappy) {
            toastMessage = nil
            toastUndoAction = nil
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

        var isOverdue: Bool {
            switch self {
            case .overdue, .overdueOverflow: return true
            default: return false
            }
        }
    }

    /// Measures the height a context card needs based on its text content.
    /// Uses UIKit text measurement against the actual available width,
    /// clamped to a minimum of 60 so the card never shrinks below standard.
    private func measuredCardHeight(for context: HomeContext) -> CGFloat {
        let baseH: CGFloat = 64

        // Extract title + detail + max line counts depending on context type.
        let titleText: String
        let detailText: String
        let maxTitleLines: CGFloat
        let maxDetailLines: CGFloat

        switch context {
        case .insight(let insight):
            titleText = insight.title
            detailText = insight.detail
            maxTitleLines = 2
            maxDetailLines = 4
        case .upcoming, .overdue:
            titleText = contextTitle(for: context)
            detailText = contextDetail(for: context)
            maxTitleLines = 1
            maxDetailLines = 2
        default:
            return baseH
        }

        // Available width for text = screen - scroll padding - card padding - icon - spacings - dismiss button
        let screenW = UIScreen.main.bounds.width
        let textWidth = screenW
            - Spacing.xl * 2       // scroll content horizontal padding
            - Spacing.md * 2       // card horizontal padding
            - 38                   // icon circle
            - Spacing.md * 2       // HStack spacings
            - 28                   // dismiss/chevron area
            - Spacing.md           // outer HStack gap

        // Use semibold to match .subheadline.weight(.semibold) in the view
        let baseTitleFont = UIFont.preferredFont(forTextStyle: .subheadline)
        let titleFont = UIFont.systemFont(ofSize: baseTitleFont.pointSize, weight: .semibold)
        let detailFont = UIFont.preferredFont(forTextStyle: .caption1)

        let rawTitleH = ceil((titleText as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: titleFont],
            context: nil
        ).height)
        let titleH = min(rawTitleH, ceil(titleFont.lineHeight * maxTitleLines))

        let rawDetailH = ceil((detailText as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: detailFont],
            context: nil
        ).height)
        let detailH = min(rawDetailH, ceil(detailFont.lineHeight * maxDetailLines))

        // .padding(.vertical, Spacing.md) = Spacing.md * 2, plus buffer
        // for SwiftUI text layout differences vs UIKit boundingRect
        let verticalPadding: CGFloat = Spacing.md * 2 + 8
        let textSpacing: CGFloat = 2
        let needed = titleH + textSpacing + detailH + verticalPadding

        return max(needed, baseH)
    }

    // MARK: - Context Card Stack (Notification Center style)
    //
    // Reimplemented from scratch. Key design decisions:
    //
    // 1. ALL card types go through `contextRowBody` directly — no wrapper
    //    differences (SwipeableContextRow vs Button) that could cause
    //    different view-tree structures and break animation propagation.
    //
    // 2. Card positioning uses `CardSlideEffect` (a GeometryEffect with
    //    explicit `animatableData`) instead of `.offset(y:)`. This
    //    guarantees SwiftUI interpolates the y position during animation.
    //
    // 3. `withAnimation` in the tap handlers is the SOLE animation driver.
    //    No `.animation(value:)` modifier — avoids conflicting animation
    //    sources that can cause partial or skipped animations.

    @ViewBuilder
    private var contextSections: some View {
        let all = overdueContexts + upcomingContexts + otherContexts
        let isExpanded = expandedStacks.contains("contexts")
        let shouldStack = all.count > 1
        let baseH: CGFloat = 64
        let gap: CGFloat = Spacing.md
        let peekGap: CGFloat = 14
        let stackSpring = Animation.spring(response: 0.42, dampingFraction: 0.72)

        let useCompact = shouldStack && !isExpanded
        let heights = all.map { useCompact ? baseH : measuredCardHeight(for: $0) }
        let expandedTotal = heights.reduce(0, +) + CGFloat(max(all.count - 1, 0)) * gap
        let visibleCount = shouldStack ? min(all.count, 3) : (all.isEmpty ? 0 : 1)
        let collapsedHeight: CGFloat = (0..<visibleCount).reduce(0) { result, i in
            let offsetY = CGFloat(min(i, 2)) * peekGap
            return max(result, offsetY + heights[i])
        }
        let cardShape = RoundedRectangle(cornerRadius: 14, style: .continuous)

        if !all.isEmpty {
            VStack(spacing: 0) {
                // Collapse button
                if shouldStack && isExpanded {
                    Button {
                        withAnimation(stackSpring) {
                            _ = expandedStacks.remove("contexts")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.up")
                                .font(.caption2.weight(.bold))
                            Text("Show less")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(.thinMaterial)
                                .background(Capsule().fill(Color(.systemBackground).opacity(0.4)))
                                .overlay {
                                    Capsule()
                                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.75)
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Spacing.md)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Card stack
                ZStack(alignment: .top) {
                    ForEach(Array(all.enumerated()).reversed(), id: \.element.identifier) { index, context in
                        let yExpanded = heights.prefix(index).reduce(0, +) + CGFloat(index) * gap
                        let yCollapsed = CGFloat(min(index, 2)) * peekGap

                        contextRow(for: context, compactMode: useCompact)
                            .frame(height: heights[index], alignment: .top)
                            .clipShape(cardShape)
                            .shadow(color: Color(.label).opacity(isExpanded ? 0 : 0.06),
                                    radius: 4, y: 2)
                            .modifier(CardSlideEffect(yOffset: isExpanded ? yExpanded : yCollapsed))
                            .scaleEffect(isExpanded ? 1.0 : max(1.0 - CGFloat(index) * 0.025, 0.93),
                                         anchor: .top)
                            .opacity(isExpanded ? 1.0 : (index <= 2 ? 1.0 : 0.0))
                            .zIndex(Double(all.count - index))
                            .allowsHitTesting(isExpanded || !shouldStack)
                    }
                }
                // Expanded: extra breathing room absorbs spring overshoot
                // so the last card doesn't get clipped mid-animation.
                .frame(height: isExpanded ? expandedTotal + 8 : collapsedHeight + 2, alignment: .top)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if shouldStack && !isExpanded {
                        Text("\(all.count)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22, alignment: .center)
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 1)
                            .background(
                                Circle()
                                    .fill(all[0].isOverdue ? Color.red : Color.tulaBrandFallback)
                                    .overlay(Circle().strokeBorder(Color.tulaCardSurface, lineWidth: 1))
                                    .shadow(color: (all[0].isOverdue ? Color.red : Color.tulaBrandFallback).opacity(0.2), radius: 2, y: 1)
                            )
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay {
                    if shouldStack && !isExpanded {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                withAnimation(stackSpring) {
                                    _ = expandedStacks.insert("contexts")
                                }
                            }
                    }
                }
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
        if let topInsight = insights.first(where: { !dismissedInsightIDs.contains($0.id) }) {
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
        if let topInsight = insights.first(where: { !dismissedInsightIDs.contains($0.id) }) {
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
    private func contextRow(for context: HomeContext, compactMode: Bool = false) -> some View {
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
                    confirmLog(rule: rule, date: date)
                }
            ) {
                contextRowBody(
                    for: context,
                    showHint: true,
                    compactMode: compactMode,
                    onDismiss: {
                        Haptics.tap()
                        let key = "\(rule.id)_\(Int(date.timeIntervalSince1970))"
                        withAnimation(AppAnimation.snappy) {
                            _ = dismissedUpcomingKeys.insert(key)
                        }
                    }
                )
            }
            .confirmationDialog(
                "Skip \(rule.name)?",
                isPresented: Binding(
                    get: { confirmSkipRule?.id == rule.id && showingSkipConfirm },
                    set: { if !$0 { confirmSkipRule = nil; showingSkipConfirm = false } }
                ),
                titleVisibility: .visible
            ) {
                Button("Skip", role: .destructive) {
                    skipUpcoming(rule: rule, date: date)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This occurrence will be marked as skipped.")
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
                    confirmLog(rule: rule, date: date)
                }
            ) {
                contextRowBody(for: context, showHint: true, compactMode: compactMode)
            }
            .confirmationDialog(
                "Skip \(rule.name)?",
                isPresented: Binding(
                    get: { confirmSkipRule?.id == rule.id && showingSkipConfirm },
                    set: { if !$0 { confirmSkipRule = nil; showingSkipConfirm = false } }
                ),
                titleVisibility: .visible
            ) {
                Button("Skip", role: .destructive) {
                    skipUpcoming(rule: rule, date: date)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This occurrence will be marked as skipped.")
            }
        case .insight(let insight):
            Button {
                Haptics.tap()
                handleContextTap(context)
            } label: {
                contextRowBody(
                    for: context,
                    showHint: false,
                    compactMode: compactMode,
                    onDismiss: {
                        withAnimation(AppAnimation.snappy) {
                            dismissInsight(insight.id)
                        }
                        Haptics.tap()
                    }
                )
            }
            .buttonStyle(PressableScaleStyle(scale: 0.98))
        case .review, .recurringOverflow, .overdueOverflow:
            Button {
                Haptics.tap()
                handleContextTap(context)
            } label: {
                contextRowBody(for: context, showHint: false, compactMode: compactMode)
            }
            .buttonStyle(.plain)
        }
    }

    /// Common visual content for any context row — icon + title + subtitle.
    /// `showHint` adds a faint "swipe" affordance on the trailing edge to
    /// hint that the row is swipeable (since swipe is non-discoverable by
    /// default). For non-swipeable contexts, shows a chevron instead.
    private func contextRowBody(for context: HomeContext, showHint: Bool, compactMode: Bool = false, onDismiss: (() -> Void)? = nil, onTap: (() -> Void)? = nil) -> some View {
        let icon = contextIcon(for: context)
        let color = contextColor(for: context)
        let title = contextTitle(for: context)
        let detail = contextDetail(for: context)
        let isInsight: Bool
        if case .insight = context { isInsight = true } else { isInsight = false }
        let expandedInsight = isInsight && !compactMode

        return HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(expandedInsight ? 2 : 1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(expandedInsight ? 4 : 2)
                }
                .fixedSize(horizontal: false, vertical: expandedInsight)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let onTap else { return }
                onTap()
            }
            .allowsHitTesting(onTap != nil)

            if isInsight {
                // Insights: show chevron (tap affordance) + dismiss button
                // so the card clearly looks interactive, not just dismissable.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.secondary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            } else if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            } else if showHint {
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
        .padding(.vertical, Spacing.md)
        .frame(minHeight: 64, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
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

    /// Recomputes the cached RecurringEngine results. Called once on
    /// appear and again after actions that change rule state (log, skip,
    /// rule add/delete). Cheap filtering (paused, fulfilled, dismissed)
    /// still runs per-render via the computed properties above.
    private func refreshRecurringCaches() {
        var nextDates: [UUID: Date] = [:]
        var overdueDates: [UUID: [Date]] = [:]
        var predictions: [UUID: SmartAmountPredictor.Prediction] = [:]
        for rule in allRecurringRules where !rule.isPaused {
            if let next = RecurringEngine.nextDueDate(for: rule) {
                nextDates[rule.id] = next
                predictions[rule.id] = SmartAmountPredictor.predict(for: rule, on: next)
            }
            if rule.kind == .expense {
                overdueDates[rule.id] = RecurringEngine.overdueDates(for: rule)
            }
        }
        cachedNextDueDates = nextDates
        cachedOverdueDates = overdueDates
        cachedPredictions = predictions
    }

    // Sheet extracted to LogAmountSheetView (standalone struct below)

    private func confirmLog(rule: RecurringRule, date: Date) {
        // Compute prediction for the given date (not the cached next-due
        // prediction) so overdue items get the correct day-of-week amount.
        let prediction = SmartAmountPredictor.predict(for: rule, on: date)
        logConfirmation = LogConfirmationItem(rule: rule, date: date, prediction: prediction)
    }

    /// One-click log at the predicted amount. Used by the swipe-right action
    /// so the user can log without opening the amount sheet.
    private func quickLog(rule: RecurringRule, date: Date) {
        let prediction = cachedPredictions[rule.id]
            ?? SmartAmountPredictor.predict(for: rule, on: date)
        logUpcoming(rule: rule, date: date, customAmount: prediction.amount)
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
            if rule.isBill {
                rule.lastPaidDate = .now
            }
            try? context.save(); WidgetRefresh.refresh(using: context)
        }
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        refreshRecurringCaches()
        showToast("Skipped")
    }

    /// Mark a recurring occurrence as already paid without creating a
    /// duplicate expense. Advances the rule boundary past this date
    /// so the card disappears from the home screen.
    private func markAlreadyPaid(rule: RecurringRule, date: Date) {
        Haptics.success()
        withAnimation(AppAnimation.snappy) {
            RecurringEngine.skipOccurrence(rule: rule, dueDate: date)
            if rule.isBill {
                rule.lastPaidDate = .now
            }
            try? context.save(); WidgetRefresh.refresh(using: context)
        }
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        refreshRecurringCaches()
        showToast("Marked as paid")
    }

    /// Log a single upcoming/overdue occurrence from the home row.
    /// Uses the amount the user entered in the amount sheet. Cancels
    /// any pending notification for this date so the user isn't asked twice.
    private func logUpcoming(rule: RecurringRule, date: Date, customAmount: Double? = nil) {
        Haptics.success()
        withAnimation(AppAnimation.snappy) {
            RecurringEngine.createTransaction(rule: rule, date: date, in: context, customAmount: customAmount)
            // Advance the boundary so the engine treats this occurrence
            // as handled — prevents the overdue card from persisting.
            if rule.lastGeneratedDate == nil || rule.lastGeneratedDate! < date {
                rule.lastGeneratedDate = date
            }
            if rule.isBill {
                rule.lastPaidDate = .now
            }
            try? context.save(); WidgetRefresh.refresh(using: context)
        }
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        refreshRecurringCaches()
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
        case .upcoming(let rule, let date):
            let dueLabel = upcomingRelativeLabel(for: date)
            if let prediction = cachedPredictions[rule.id] {
                let amountStr = Currency.format(prediction.amount, code: currencyCode)
                let isApprox = prediction.basis != .ruleAmount && abs(prediction.amount - rule.amount) >= 0.01
                let prefix = isApprox ? "~" : ""
                let hint = prediction.hint(ruleAmount: rule.amount)
                if hint.isEmpty {
                    return "\(dueLabel) · \(prefix)\(amountStr)"
                }
                return "\(dueLabel) · \(prefix)\(amountStr) · \(hint)"
            }
            return dueLabel
        case .overdue(let rule, let date):
            let dueLabel = overdueRelativeLabel(for: date)
            // Compute prediction for the ACTUAL overdue date, not the
            // cached next-due-date prediction. The cache stores predictions
            // for the next occurrence (e.g. Wednesday), but the overdue
            // card needs the prediction for the missed date (e.g. Tuesday).
            // Day-of-week patterns differ — "Based on your Tuesdays" vs
            // "Based on your Wednesdays".
            let prediction = SmartAmountPredictor.predict(for: rule, on: date)
            let amountStr = Currency.format(prediction.amount, code: currencyCode)
            let isApprox = prediction.basis != .ruleAmount && abs(prediction.amount - rule.amount) >= 0.01
            let prefix = isApprox ? "~" : ""
            let hint = prediction.hint(ruleAmount: rule.amount)
            if hint.isEmpty {
                return "\(dueLabel) · \(prefix)\(amountStr)"
            }
            return "\(dueLabel) · \(prefix)\(amountStr) · \(hint)"
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
            case .recurringSuggestion:
                if let suggestion = insight.suggestion {
                    recurringSuggestionToCreate = suggestion
                }
            case .todayTotal, .biggestToday, .quietToday:
                let cal = Calendar.current
                let start = cal.startOfDay(for: .now)
                let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now
                let filter = ExpenseFilter(dateRange: .custom(start: start, end: end))
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .categoryAlert:
                var filter = ExpenseFilter(dateRange: .thisMonth)
                if let catID = insight.categoryID {
                    filter.categoryIDs = [catID]
                }
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .monthPace, .bigSpender:
                let filter = ExpenseFilter(dateRange: .thisMonth)
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .budgetPacing:
                var filter = ExpenseFilter(dateRange: .thisMonth)
                if let catID = insight.categoryID {
                    filter.categoryIDs = [catID]
                }
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .youSaved:
                let filter = ExpenseFilter(dateRange: .thisMonth)
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .anomaly:
                let cal = Calendar.current
                let start = cal.startOfDay(for: .now)
                let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: .now) ?? .now
                let filter = ExpenseFilter(dateRange: .custom(start: start, end: end))
                navPath.append(HomeDestination.allExpenses(filter: filter, searchFocused: false))
            case .merchantAutoRule:
                merchantRuleConfirmInsight = insight
            default:
                break
            }
        }
    }

    /// Applies the merchant auto-rule after user confirms in the sheet.
    private func applyMerchantAutoRule(_ insight: Insight) {
        let modelCtx = self.context
        guard let catID = insight.categoryID,
              let merchant = insight.merchantName,
              let category = allCategories.first(where: { $0.id == catID }) else { return }
        let account = insight.accountID.flatMap { accID in
            allAccounts.first { $0.id == accID }
        }
        let rule = MerchantRule(pattern: merchant, category: category, account: account, isUserDefined: true)
        modelCtx.insert(rule)
        try? modelCtx.save()
        withAnimation(AppAnimation.snappy) {
            dismissInsight(insight.id)
        }
        Haptics.success()
        showToast("Rule created for \(merchant)") {
            modelCtx.delete(rule)
            try? modelCtx.save()
            Haptics.warning()
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
                trailing: recentExpenses.isEmpty ? nil : AnyView(
                    HStack(spacing: 2) {
                        Button {
                            Haptics.tap()
                            navPath.append(HomeDestination.allExpenses(filter: nil, searchFocused: true))
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.gray)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(Color(.systemGray6))
                                )
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("Search expenses")
                        SeeAllLink {
                            navPath.append(HomeDestination.allExpenses(filter: nil, searchFocused: false))
                        }
                    }
                )
            )

            if recentExpenses.isEmpty {
                emptyActivityState
            } else {
                recentList
            }
        }
    }

    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 70

    private var recentList: some View {
        List {
            ForEach(Array(recentExpenses.enumerated()), id: \.element.id) { index, expense in
                Button {
                    Haptics.tap()
                    editingExpense = expense
                } label: {
                    ExpenseRow(expense: expense)
                        .padding(.horizontal, Spacing.lg)
                        .frame(height: rowHeight)
                }
                .buttonStyle(PressableScaleStyle(scale: 0.97))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                // Separator BELOW each row except the last. We must target
                // `edges: .bottom` explicitly — the default `.all` would
                // also hide the top edge of the last row, which is shared
                // with the bottom edge of the row before it, accidentally
                // erasing the line between them.
                .listRowSeparator(index == recentExpenses.count - 1 ? .hidden : .visible, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        expenseToDelete = expense
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    .labelStyle(.iconOnly)

                    Button {
                        Haptics.impact()
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
                .confirmationDialog(
                    "Delete this expense?",
                    isPresented: Binding(
                        get: { expenseToDelete?.id == expense.id },
                        set: { if !$0 { expenseToDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        delete(expense)
                        expenseToDelete = nil
                    }
                    Button("Cancel", role: .cancel) {
                        expenseToDelete = nil
                    }
                } message: {
                    Text("This action can't be undone.")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(recentExpenses.count) * rowHeight)  // now exact, no scale math
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    @State private var shareableImage: UIImage?
    @State private var showingShareSheet = false

    @ViewBuilder
    private func expenseContextMenu(for expense: Expense) -> some View {
        Button { editingExpense = expense } label: { Label("Edit", systemImage: "pencil") }
        Button { duplicate(expense) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if let merchant = expense.merchant, !merchant.isEmpty {
            Button { logSimilar(to: expense) } label: {
                Label("Log Another \(merchant)", systemImage: "arrow.clockwise")
            }
        }
        Button { shareExpenseCard(expense) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) { expenseToDelete = expense } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func shareExpenseCard(_ expense: Expense) {
        let renderer = ImageRenderer(content: SpendingCardView(expense: expense, currencyCode: currencyCode))
        renderer.scale = UIScreen.main.scale
        if let image = renderer.uiImage {
            shareableImage = image
            showingShareSheet = true
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
        Haptics.warning()
        context.delete(expense)
        try? context.save()
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
        showToast("Deleted")
    }

    /// Contextual nudge for brand-new users. Points to the Quick Log bar
    /// with a hint example. Auto-disappears once the first expense is saved
    /// because `allExpenses.isEmpty` flips to false via @Query.
    private var firstExpensePrompt: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.tulaBrandFallback)
            Text("Type something like \"350 lunch\" above")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
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
                    .lineLimit(2)
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
        content()
            .offset(x: offset)
            .background {
                // Action labels on each side. Only the side being
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
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .gesture(swipeGesture)
            .onTapGesture {
                onTap()
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
        .frame(maxHeight: .infinity, alignment: .center)
        .background(color)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Log Amount Sheet

/// Standalone sheet for logging a recurring expense occurrence.
/// Uses a clean VStack layout inside a NavigationStack with system
/// grouped-style detail rows, a prominent hero amount area, and a
/// pinned bottom button — following Apple HIG patterns.
private struct LogAmountSheetView: View {
    let item: LogConfirmationItem
    let currencyCode: String
    let onLog: (RecurringRule, Date, Double) -> Void
    let onMarkPaid: (RecurringRule, Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountValue: Double

    init(item: LogConfirmationItem, currencyCode: String,
         onLog: @escaping (RecurringRule, Date, Double) -> Void,
         onMarkPaid: @escaping (RecurringRule, Date) -> Void) {
        self.item = item
        self.currencyCode = currencyCode
        self.onLog = onLog
        self.onMarkPaid = onMarkPaid
        _amountValue = State(initialValue: item.amount)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Scrollable content
                ScrollView {
                    VStack(spacing: 24) {
                        amountHero
                        detailSection
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.immediately)
                .scrollBounceBehavior(.basedOnSize)

                // Pinned bottom button
                logButton
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(item.ruleName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Amount hero

    private var amountHero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.iconColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: item.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(item.iconColor)
            }

            FormattedAmountField(
                value: $amountValue,
                currencyCode: currencyCode,
                placeholder: Currency.format(0, code: currencyCode),
                font: .system(size: 48, weight: .bold, design: .rounded),
                alignment: .center
            )
            .frame(maxWidth: .infinity)
            .foregroundStyle(amountValue > 0 ? .primary : .quaternary)

            if !item.predictionHint.isEmpty {
                Text(item.predictionHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if item.amount > 0, item.isVariable {
                Text("Usually \(Currency.format(item.amount, code: currencyCode))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Detail rows (system grouped style)

    private var detailSection: some View {
        VStack(spacing: 0) {
            if let catName = item.categoryName,
               let catIcon = item.categoryIcon,
               let catColor = item.categoryColor {
                detailRow(icon: catIcon, color: catColor, title: "Category", value: catName)
                Divider().padding(.leading, 56)
            }

            if let accName = item.accountName,
               let accIcon = item.accountIcon,
               let accColor = item.accountColor {
                detailRow(icon: accIcon, color: accColor, title: "Account", value: accName)
                Divider().padding(.leading, 56)
            }

            detailRow(
                icon: "calendar",
                color: .blue,
                title: "Date",
                value: item.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            )
            Divider().padding(.leading, 56)

            detailRow(
                icon: "repeat",
                color: .secondary,
                title: "Repeats",
                value: item.cadenceLabel.capitalized
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
    }

    private func detailRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.leading, 16)

            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 11)
    }

    // MARK: - Log button

    private var logButton: some View {
        VStack(spacing: 12) {
            Button {
                onLog(item.rule, item.date, amountValue)
                dismiss()
            } label: {
                Text("Log \(item.ruleName)")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.tulaBrandFallback)
            .disabled(amountValue <= 0)

            Button {
                onMarkPaid(item.rule, item.date)
                dismiss()
            } label: {
                Text("Already logged this")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(.systemGroupedBackground))
    }
}

/// Animatable geometry effect for card stack positioning.
/// Unlike `.offset(y:)`, this declares `yOffset` as explicit `animatableData`,
/// guaranteeing SwiftUI interpolates the value during animation even when
/// the view's structural identity changes through `_ConditionalContent` branches.
private struct CardSlideEffect: GeometryEffect {
    var yOffset: CGFloat

    var animatableData: CGFloat {
        get { yOffset }
        set { yOffset = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 0, y: yOffset))
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
    var onUndo: (() -> Void)?
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline.weight(.medium))
            if onUndo != nil {
                Text("·")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Button {
                    onUndo?()
                } label: {
                    Text("Undo")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.tulaBrandFallback)
                }
                .buttonStyle(.plain)
            }
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
    /// Save callback for typed input — receives the fully-built expenses
    /// produced by the shared `ExpenseInterpreter` (same pipeline as voice).
    let onSaveDrafts: ([Expense]) -> Void
    /// True when Apple Foundation Models is currently enriching a
    /// recent submission. Drives the radiant amber glow around the
    /// input capsule so the user sees that on-device AI is engaged.
    /// Parent passes `smartParseInFlight > 0`.
    let isSmartParsing: Bool
    /// Callback triggered when the user taps the mic button. HomeView
    /// presents the full-screen voice overlay in response.
    let onMicTap: () -> Void

    @State private var input: String = ""
    @FocusState private var focused: Bool
    /// Inline corrections applied to the live single-expense preview without
    /// retyping. Cleared whenever the field is cleared/submitted.
    @State private var categoryOverride: Category?
    @State private var accountOverride: Account?

    /// Interpreter output, cached in state and refreshed on a short debounce
    /// after typing pauses — NOT on every keystroke. The interpreter runs
    /// NLTagger NER + regex, so recomputing it per character (and per view
    /// render) made typing lag. Debouncing keeps the field buttery.
    @State private var parsedDrafts: [ExpenseDraft] = []
    @State private var parseTask: Task<Void, Never>?

    /// The cached drafts with inline chip overrides applied (cheap).
    private var drafts: [ExpenseDraft] {
        guard parsedDrafts.count == 1 else { return parsedDrafts }
        var produced = parsedDrafts
        if let categoryOverride { produced[0].category = categoryOverride }
        if let accountOverride { produced[0].account = accountOverride }
        return produced
    }

    /// Debounced parse. Cancels any in-flight parse and runs once ~180ms after
    /// the last keystroke, on the main actor (the interpreter is synchronous
    /// and cheap once, just not once-per-character).
    private func scheduleParse(for text: String) {
        parseTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { parsedDrafts = []; return }
        parseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            parsedDrafts = ExpenseInterpreter(
                accounts: accounts, categories: categories,
                merchantRules: merchantRules, defaultAccount: defaultAccount
            ).interpret(text)
        }
    }

    private var validDrafts: [ExpenseDraft] { drafts.filter { $0.isValid } }
    private var canSubmit: Bool { !validDrafts.isEmpty }
    private var showPreview: Bool { !validDrafts.isEmpty }

    /// Single-expense preview (nil for multi-expense — those show a summary row).
    private var previewDraft: ExpenseDraft? {
        validDrafts.count == 1 ? validDrafts.first : nil
    }

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { categories.filter { !$0.isArchived } }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            inputCapsule
            if showPreview {
                previewCard
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.bouncy, value: showPreview)
        // Re-parse only after typing pauses — keeps the field responsive.
        .onChange(of: input) { _, newValue in
            scheduleParse(for: newValue)
        }
        // Voice deep-link from the Quick Actions widget — trigger the
        // full-screen voice overlay.
        .onReceive(NotificationCenter.default.publisher(for: .tulaStartVoiceCapture)) { _ in
            onMicTap()
        }
    }

    // MARK: - Input capsule

    /// Text input capsule with a trailing mic/send button. Voice recording
    /// now lives in the full-screen VoiceInputOverlay; this capsule handles
    /// typed input only.
    private var inputCapsule: some View {
        HStack(spacing: Spacing.md) {
            idleMode
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

    /// True when Foundation Models is enriching a submitted expense.
    /// Drives the amber glow halo around the capsule.
    private var aiActive: Bool {
        isSmartParsing
    }

    /// Pulse scale state for the AI glow. Idles at 1.0; while AI is active,
    /// gently breathes between 1.0 and 1.012 — barely perceptible motion
    /// that signals "alive" without distracting from the user's reading.
    @State private var glowPulse: CGFloat = 1.0

    /// Stroke color for the amber glow when smart parsing is active.
    private var capsuleStrokeColor: Color {
        isSmartParsing ? Color.tulaBrandFallback.opacity(0.55) : .clear
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

            if !input.isEmpty {
                Button {
                    Haptics.tap()
                    clearInput()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .accessibilityLabel("Clear")
            }

            trailingActionButton
        }
        .animation(.easeInOut(duration: 0.2), value: input.isEmpty)
    }

    // MARK: - Trailing action button

    /// 44pt circular button that morphs between mic / stop / send.
    /// Brand-amber in idle/send (signaling the primary action), red in
    /// recording (signaling stop). Meets Apple's 44pt minimum touch target.
    private var trailingActionButton: some View {
        Button(action: trailingAction) {
            ZStack {
                Circle()
                    .fill(trailingButtonFill)
                    .frame(width: 44, height: 44)
                    .shadow(color: trailingButtonFill.opacity(0.22), radius: 4, y: 2)

                Image(systemName: trailingIconName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: validDrafts.count)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.92))
        .disabled(trailingDisabled)
        .accessibilityLabel(trailingAccessibilityLabel)
    }

    private var trailingAccessibilityLabel: String {
        if canSubmit { return "Submit expense" }
        return "Record expense"
    }

    private var trailingIconName: String {
        if canSubmit { return "arrow.up" }
        if !input.isEmpty { return "arrow.up" }
        return "mic.fill"
    }

    private var trailingButtonFill: Color {
        if canSubmit { return Color.tulaBrandFallback }
        if !input.isEmpty { return Color(uiColor: .tertiaryLabel) }
        return Color.tulaBrandFallback
    }

    private var trailingDisabled: Bool {
        !input.isEmpty && !canSubmit
    }

    private func trailingAction() {
        if canSubmit {
            submit()
        } else if input.isEmpty {
            onMicTap()
        } else {
            Haptics.error()
        }
    }

    /// Preview of what will be saved. Amount + summary read at a glance;
    /// Category and Account are explicit, labeled, tappable pills so it's
    /// obvious they can be changed; a clear Save button commits. Shimmers
    /// while on-device AI is enriching.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let only = previewDraft {
                HStack(alignment: .top, spacing: Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Currency.format(only.amount, code: currencyCode))
                            .font(.title3.weight(.heavy))
                            .monospacedDigit()
                        let sub = previewSubtitle(only)
                        if !sub.isEmpty {
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    saveButton
                }
                HStack(spacing: Spacing.sm) {
                    categoryPill(only.category)
                    accountPill(only.account)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    multiplePreviewRow
                    Spacer(minLength: 0)
                    saveButton
                }
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .shimmering(active: isSmartParsing, tint: Color.tulaBrandFallback)
    }

    /// Merchant + items summary line under the amount.
    private func previewSubtitle(_ p: ExpenseDraft) -> String {
        var parts: [String] = []
        if let merchant = p.merchant, !merchant.isEmpty { parts.append(merchant) }
        if !p.items.isEmpty {
            parts.append(p.items.map { $0.capitalized }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Tappable, labeled category pill. Amber when the parser didn't resolve one.
    private func categoryPill(_ current: Category?) -> some View {
        Menu {
            ForEach(activeCategories, id: \.id) { category in
                Button {
                    Haptics.selection()
                    categoryOverride = category
                } label: { Label(category.name, systemImage: category.iconKey) }
            }
        } label: {
            pillLabel(icon: current?.iconKey ?? "tag",
                      text: current?.name ?? "Category",
                      tint: current.map { Color(hex: $0.colorHex) } ?? .orange,
                      muted: current == nil)
        }
    }

    /// Tappable, labeled account pill.
    private func accountPill(_ current: Account?) -> some View {
        Menu {
            ForEach(activeAccounts, id: \.id) { account in
                Button {
                    Haptics.selection()
                    accountOverride = account
                } label: { Label(account.name, systemImage: EditableExpenseCard.icon(for: account)) }
            }
        } label: {
            pillLabel(icon: current.map(EditableExpenseCard.icon(for:)) ?? "creditcard",
                      text: current?.name ?? "Account",
                      tint: current.map { Color(hex: $0.colorHex) } ?? .orange,
                      muted: current == nil)
        }
    }

    /// Shared pill look: icon + label + chevron, tinted, soft fill — reads as
    /// an editable control, not static text.
    private func pillLabel(icon: String, text: String, tint: Color, muted: Bool) -> some View {
        let color = muted ? Color.orange : tint
        return HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private var saveButton: some View {
        Button(action: submit) {
            HStack(spacing: 5) {
                Text("Save").font(.subheadline.weight(.bold))
                Image(systemName: "arrow.up").font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Color.tulaBrandFallback))
        }
        .buttonStyle(PressableScaleStyle(scale: 0.96))
        .transition(.scale.combined(with: .opacity))
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
                Text("\(validDrafts.count) expenses")
                    .font(.subheadline.weight(.bold))
                Text(Currency.format(validDrafts.reduce(0) { $0 + $1.amount }, code: currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Actions

    private func submit() {
        // Parse the current text synchronously — the live preview is debounced,
        // so a fast Return/tap could arrive before it refreshed.
        parseTask?.cancel()
        var ds = ExpenseInterpreter(
            accounts: accounts, categories: categories,
            merchantRules: merchantRules, defaultAccount: defaultAccount
        ).interpret(input).filter { $0.isValid }
        if ds.count == 1 {
            if let categoryOverride { ds[0].category = categoryOverride }
            if let accountOverride { ds[0].account = accountOverride }
        }
        guard !ds.isEmpty else { return }
        let rawInput = input
        let expenses = ds.map { d -> Expense in
            let e = Expense(
                amount: d.amount, date: d.date,
                merchant: d.merchant, note: d.note,
                source: .smartParsed, category: d.category, account: d.account
            )
            e.rawInput = rawInput
            e.items = d.items.map { LineItem(name: $0.capitalized) }
            return e
        }
        onSaveDrafts(expenses)
        clearInput()
    }

    /// Clears the field and any inline overrides — serves as both "clear" and
    /// "discard" for the typed path.
    private func clearInput() {
        parseTask?.cancel()
        input = ""
        focused = false
        parsedDrafts = []
        categoryOverride = nil
        accountOverride = nil
    }
}

// MARK: - Shareable Spending Card

/// Renders a visually appealing spending card image for sharing.
/// Used by ImageRenderer to generate a static PNG from an expense.
private struct SpendingCardView: View {
    let expense: Expense
    let currencyCode: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let cat = expense.category {
                    Image(systemName: cat.iconKey)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color(hex: cat.colorHex).opacity(0.9), in: Circle())
                }
                Spacer()
                Text(expense.date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text(Currency.format(expense.amount, code: currencyCode))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if let merchant = expense.merchant, !merchant.isEmpty {
                Text(merchant)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
            }

            if let cat = expense.category {
                Text(cat.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            HStack {
                Spacer()
                Text("तुला")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(
            LinearGradient(
                colors: [Color(hex: expense.category?.colorHex ?? "#D97706"), Color(hex: expense.category?.colorHex ?? "#D97706").opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Merchant Rule Confirmation Sheet

/// Confirmation sheet shown when tapping a "Auto-categorize {merchant}?"
/// insight card. Explains clearly what the rule will do and lets the user
/// confirm or cancel.
private struct MerchantRuleConfirmSheet: View {
    let insight: Insight
    let categories: [Category]
    let accounts: [Account]
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var merchantName: String {
        insight.merchantName ?? "this merchant"
    }

    private var categoryName: String {
        guard let catID = insight.categoryID else { return "—" }
        return categories.first { $0.id == catID }?.name ?? "—"
    }

    private var categoryIcon: String {
        guard let catID = insight.categoryID else { return "folder" }
        return categories.first { $0.id == catID }?.iconKey ?? "folder"
    }

    private var categoryColor: Color {
        guard let catID = insight.categoryID else { return .secondary }
        if let hex = categories.first(where: { $0.id == catID })?.colorHex {
            return Color(hex: hex)
        }
        return .secondary
    }

    private var accountName: String? {
        guard let accID = insight.accountID else { return nil }
        return accounts.first { $0.id == accID }?.name
    }

    private var accountIcon: String? {
        guard let accID = insight.accountID else { return nil }
        return accounts.first { $0.id == accID }?.iconKey
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(categoryColor.opacity(0.15))
                        .frame(width: 56, height: 56)
                    Image(systemName: "wand.and.stars")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(categoryColor)
                }
                .padding(.top, Spacing.xl)

                Text("Auto-categorize \(merchantName)?")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Create a rule so future expenses from **\(merchantName)** are automatically categorized.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
            }

            // Rule details
            VStack(spacing: 0) {
                // Category row
                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(categoryColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: categoryIcon)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(categoryColor)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Category")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(categoryName)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer()
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)

                if let accName = accountName {
                    Divider()
                        .padding(.leading, Spacing.lg + 36 + Spacing.md)

                    // Account row
                    HStack(spacing: Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color.secondary.opacity(0.12))
                                .frame(width: 36, height: 36)
                            Image(systemName: accountIcon ?? "creditcard")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Account")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(accName)
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.xl)

            Spacer()

            // Action buttons
            VStack(spacing: Spacing.sm) {
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Create Rule")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(categoryColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }

                Button {
                    dismiss()
                    onDismiss()
                } label: {
                    Text("Not Now")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
    }
}
