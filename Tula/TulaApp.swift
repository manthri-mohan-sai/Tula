import SwiftUI
import SwiftData
import WidgetKit

@main
struct TulaApp: App {
    @UIApplicationDelegateAdaptor(TulaAppDelegate.self) var appDelegate
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("seedDataInstalled") private var seedDataInstalled: Bool = false
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false
    /// User opt-out for the launch animation. Defaults true (animation
    /// shown). Users who've seen the तु calligraphy 200 times can flip
    /// this off in Settings → General.
    @AppStorage("launchAnimationEnabled") private var launchAnimationEnabled: Bool = true

    /// In-session flag: true once the launch animation has completed
    /// (or was skipped, or is disabled). Using @State (not @AppStorage)
    /// means the animation replays on every cold launch but not on
    /// foreground returns within the same session.
    @State private var launchAnimationDone: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    let sharedContainer: ModelContainer = {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
        ])
        let primaryConfig = ModelConfiguration("Tula", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [primaryConfig]) {
            return container
        }
        let memoryConfig = ModelConfiguration("Tula", schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [memoryConfig]) {
            return container
        }
        return (try? ModelContainer(for: Schema([]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
            ?? { preconditionFailure("Cannot create any ModelContainer.") }()
    }()

    var body: some Scene {
        WindowGroup {
            // The home view is always rendered, sitting behind the
            // launch overlay. The launch animation's portal grows out
            // of the merged dot at the end, "punching" a circular
            // hole in the amber that reveals the home view through
            // it. So home must be rendered *underneath* the launch
            // overlay throughout the animation — otherwise there'd be
            // nothing for the portal to reveal.
            //
            // Concurrent rendering is safe here because the launch
            // overlay uses `.compositingGroup()` to confine its
            // blend mode (`.destinationOut`) to its own layer —
            // home view's layout below is untouched. And the home
            // view's `onAppear` fires immediately at cold launch,
            // so by the time the portal opens (~3.15s in) the home
            // is fully rendered and ready.
            ZStack {
                RootTabView()
                    .tint(Color.tulaBrandFallback)
                    .onAppear {
                        let context = ModelContext(sharedContainer)
                        if !seedDataInstalled {
                            SeedData.installIfNeeded(into: context)
                            seedDataInstalled = true
                        }
                        RecurringEngine.generateMissing(in: context)
                        refreshWidgetSnapshot(using: context)
                    }
                    .sheet(isPresented: Binding(
                        get: { !onboardingComplete },
                        set: { _ in }
                    )) {
                        OnboardingView()
                    }

                if !launchAnimationDone {
                    LaunchAnimationView {
                        // No animated transition here — the launch
                        // overlay's portal has already exited the
                        // screen by the time onComplete fires, so
                        // removing it is visually a no-op.
                        launchAnimationDone = true
                    }
                    .onAppear {
                        if !launchAnimationEnabled {
                            launchAnimationDone = true
                        }
                    }
                }
            }
        }
        .modelContainer(sharedContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // Refresh the widget snapshot whenever the app becomes active.
            // Cheaper than observing every save — the widget only needs
            // refresh on transitions the user is likely to see (post-edit
            // backgrounding, then re-foregrounding to glance at it).
            if newPhase == .active {
                let context = ModelContext(sharedContainer)
                refreshWidgetSnapshot(using: context)
            }
        }
    }

    // MARK: - Widget Snapshot

    /// Rebuilds the widget snapshot from current data and writes it to the
    /// App Group. Cheap enough to call on every foreground; ~milliseconds
    /// for typical expense counts. Triggers a widget reload at the end.
    private func refreshWidgetSnapshot(using context: ModelContext) {
        let calendar = Calendar.current
        let now = Date.now

        // Pull expenses for this month — sufficient for both today and month totals.
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return }
        let dayStart = calendar.startOfDay(for: now)

        let monthExpenseFetch = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= monthStart }
        )
        let monthExpenses = (try? context.fetch(monthExpenseFetch)) ?? []
        let monthTotal = monthExpenses.reduce(0) { $0 + $1.amount }
        let todayTotal = monthExpenses
            .filter { $0.date >= dayStart }
            .reduce(0) { $0 + $1.amount }

        // Active budgets — only monthly ones for the snapshot. Other periods
        // exist but the widget surface is monthly-focused.
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.isActive == true }
        )
        let allBudgets = (try? context.fetch(budgetFetch)) ?? []
        let monthlyBudgets = allBudgets.filter { $0.period == .monthly }

        // Aggregate cap is informative even when individual budgets are
        // category-scoped: it's "what I've committed to spending this month".
        let totalCap = monthlyBudgets.reduce(0) { $0 + $1.amount }

        // Top 4 monthly budgets by % used (most urgent first), so the
        // widget surfaces what the user most needs to see.
        let entries: [WidgetSnapshot.Entry] = monthlyBudgets
            .map { b -> WidgetSnapshot.Entry in
                let spent = b.spent(in: monthExpenses)
                return WidgetSnapshot.Entry(
                    id: b.id,
                    name: b.displayName,
                    amount: b.amount,
                    spent: spent,
                    colorHex: b.category?.colorHex ?? "#D97706",
                    iconKey: b.category?.iconKey ?? "infinity",
                    isOverall: b.category == nil
                )
            }
            .sorted { $0.progress > $1.progress }
            .prefix(4)
            .map { $0 }

        // 7-day sparkline data — daily totals, oldest-first. For days
        // that fall outside this month's fetched expenses (early in a
        // new month), the corresponding entries are just zero, which
        // is correct: no spend recorded yet.
        var dailyTotals: [Double] = Array(repeating: 0, count: 7)
        for dayOffset in 0..<7 {
            guard let dayDate = calendar.date(byAdding: .day, value: -dayOffset, to: now),
                  let dayInterval = calendar.dateInterval(of: .day, for: dayDate) else {
                continue
            }
            let total = monthExpenses
                .filter { $0.date >= dayInterval.start && $0.date < dayInterval.end }
                .reduce(0) { $0 + $1.amount }
            // Reverse the index: index 0 = oldest (6 days ago),
            // index 6 = today. Sparkline reads naturally left-to-right.
            dailyTotals[6 - dayOffset] = total
        }

        // Upcoming recurrings — surface what's coming due in the next
        // little while. Excludes paused rules. Top 3 by closest due
        // date. RecurringEngine.nextDueDate handles the per-cadence
        // math (daily/weekly/monthly + start-date math).
        let upcomingRecurrings = buildUpcomingRecurrings(in: context)

        let snapshot = WidgetSnapshot(
            currencyCode: primaryCurrencyCode,
            todayTotal: todayTotal,
            monthTotal: monthTotal,
            monthlyBudgetCap: totalCap,
            topBudgets: entries,
            dailyTotals: dailyTotals,
            upcomingRecurrings: upcomingRecurrings,
            generatedAt: now
        )

        WidgetStorage.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Next 3 recurring expenses due, sorted by due date ascending.
    /// Paused rules are excluded. Used by the medium Upcoming widget
    /// which surfaces *what's coming* — more actionable than past
    /// expenses on a home screen.
    private func buildUpcomingRecurrings(in context: ModelContext) -> [WidgetSnapshot.UpcomingRecurring] {
        let rulesFetch = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.isPaused == false }
        )
        let rules = (try? context.fetch(rulesFetch)) ?? []
        let upcoming = rules.compactMap { rule -> WidgetSnapshot.UpcomingRecurring? in
            // Only include expense-type rules (not transfers — those
            // don't have a "due" semantic that fits this widget).
            guard rule.kind == .expense else { return nil }
            guard let due = RecurringEngine.nextDueDate(for: rule) else { return nil }
            return WidgetSnapshot.UpcomingRecurring(
                id: rule.id,
                name: rule.name,
                amount: rule.amount,
                dueDate: due,
                colorHex: rule.category?.colorHex ?? "#D97706",
                iconKey: rule.category?.iconKey ?? "calendar"
            )
        }
        return Array(upcoming.sorted { $0.dueDate < $1.dueDate }.prefix(3))
    }
}

// MARK: - Root Tabs

enum TulaTab: Hashable {
    case home, stats, add
}

/// Native iOS 26 TabView. Three slots: Home, Stats, and Add (rendered as
/// a separate accessory pill via `.search` role). Settings is no longer a
/// tab — it lives in Home's nav toolbar (gear icon, top-right).
///
/// We intercept selection on the .add tab to present the AddExpense sheet
/// instead of navigating, since Add is an *action* not a destination.
struct RootTabView: View {
    @State private var selectedTab: TulaTab = .home
    @State private var showingAddExpense = false

    /// Custom binding that intercepts selection of the .add tab and routes
    /// it to the sheet instead of letting iOS switch tabs. Other tab
    /// selections behave normally.
    private var tabBinding: Binding<TulaTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .add {
                    Haptics.impact()
                    showingAddExpense = true
                } else {
                    selectedTab = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabBinding) {
            Tab("Home", systemImage: "house.fill", value: TulaTab.home) {
                HomeView(onShowStats: {
                    Haptics.tap()
                    withAnimation(AppAnimation.gentle) {
                        selectedTab = .stats
                    }
                })
            }

            Tab("Stats", systemImage: "chart.bar.fill", value: TulaTab.stats) {
                StatsView()
            }

            // Search-role tab — iOS 26 renders it as a separate accessory
            // pill. We use it for "Add" since visually it's exactly the
            // affordance we want; we intercept selection in the binding.
            Tab("Add", systemImage: "plus", value: TulaTab.add, role: .search) {
                // Placeholder — never seen because tab selection is intercepted.
                Color.tulaBackground.ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showingAddExpense) {
            AddExpenseView()
        }
        // Handle deep links from widgets. `tula://add` opens the Add
        // Expense sheet directly. `tula://voice` keeps the user on Home
        // and posts a notification that the QuickLogBar listens to —
        // starting voice capture without manual tap.
        .onOpenURL { url in
            guard url.scheme == "tula" else { return }
            switch url.host {
            case "add":
                Haptics.impact()
                showingAddExpense = true
            case "voice":
                Haptics.impact()
                selectedTab = .home
                // Slight delay lets the view hierarchy settle (especially
                // if the app is launching cold) before the QuickLogBar
                // reads and acts on the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(
                        name: .tulaStartVoiceCapture,
                        object: nil
                    )
                }
            default: break
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user taps the Voice button on the Quick Actions
    /// widget. The QuickLogBar on Home observes this and starts the
    /// microphone automatically.
    static let tulaStartVoiceCapture = Notification.Name("tula.startVoiceCapture")
}
