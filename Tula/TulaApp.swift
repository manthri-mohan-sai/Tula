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
                        // Idempotent: adds any default rules that don't
                        // exist yet. For new users this is a no-op since
                        // installIfNeeded just ran. For existing users it
                        // backfills hundreds of new patterns shipped in
                        // updates. Cheap — one fetch + a set diff.
                        SeedData.installMissingDefaultMerchantRules(into: context)
                        RecurringEngine.generateMissing(in: context)
                        WidgetRefresh.refresh(using: context)
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
            // The save-site calls (WidgetRefresh.refresh after each expense
            // save) handle in-session freshness; this catches the case
            // where the user opens the app fresh after a long absence.
            if newPhase == .active {
                let context = ModelContext(sharedContainer)
                WidgetRefresh.refresh(using: context)
                // Import any expenses shared via the Share Extension
                SharedExpenseImporter.importPending(into: context)
            }
        }
    }
}

// MARK: - Shared Expense Importer

/// Imports pending expenses created by the Share Extension into SwiftData.
enum SharedExpenseImporter {

    /// Check for pending expenses from the Share Extension and import them.
    static func importPending(into context: ModelContext) {
        let manager = PendingExpenseManager()
        let pending = manager.loadPendingExpenses()
        guard !pending.isEmpty else { return }

        for item in pending {
            let expense = Expense(
                amount: item.amount,
                date: item.date,
                merchant: item.merchant,
                note: item.note,
                source: .share
            )

            // Attach receipt image if available
            if let filename = item.receiptImageFilename,
               let imageData = manager.loadReceiptImage(filename: filename) {
                expense.receiptImageData = imageData
                manager.deleteReceiptImage(filename: filename)
            }

            // Try to match category by name
            if let categoryName = item.category {
                let descriptor = FetchDescriptor<Category>()
                if let categories = try? context.fetch(descriptor) {
                    expense.category = categories.first { $0.name.lowercased() == categoryName.lowercased() }
                }
            }

            context.insert(expense)
        }

        try? context.save()
        manager.clearAll()
        WidgetRefresh.refresh(using: context)
    }
}

// MARK: - Widget Snapshot Refresh

/// Centralized widget-snapshot refresh logic. Called on app foreground,
/// after every expense/transfer save, and as part of recurring-rule
/// state changes. Was previously a private instance method on `TulaApp`
/// that only ran on foreground — now any save site can trigger it.
///
/// **Why a separate type?** Save sites need a single line they can drop
/// in (`WidgetRefresh.refresh(using: context)`) without depending on the
/// app struct or environment. Static method on an enum keeps it stateless
/// and importable from anywhere.
enum WidgetRefresh {

    /// Rebuilds the widget snapshot from current data and writes it to the
    /// App Group. Cheap enough to call after every save — ~milliseconds
    /// for typical expense counts. Triggers a `WidgetCenter` reload at
    /// the end so iOS pulls a fresh timeline immediately.
    static func refresh(using context: ModelContext) {
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

        // Active budgets — only monthly ones for the snapshot.
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate { $0.isActive == true }
        )
        let allBudgets = (try? context.fetch(budgetFetch)) ?? []
        let monthlyBudgets = allBudgets.filter { $0.period == .monthly }

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

        // Total cap across all monthly budgets — what the user committed to.
        let totalCap = monthlyBudgets.reduce(0) { $0 + $1.amount }

        // 7-day sparkline (oldest-first).
        var dailyTotals: [Double] = Array(repeating: 0, count: 7)
        for daysAgo in 0..<7 {
            guard let start = calendar.date(byAdding: .day, value: -daysAgo, to: dayStart),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let total = monthExpenses
                .filter { $0.date >= start && $0.date < end }
                .reduce(0) { $0 + $1.amount }
            dailyTotals[6 - daysAgo] = total
        }

        let upcomingRecurrings = buildUpcomingRecurrings(in: context)

        let primaryCurrencyCode = UserDefaults.standard
            .string(forKey: "primaryCurrencyCode") ?? "INR"

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
    private static func buildUpcomingRecurrings(in context: ModelContext) -> [WidgetSnapshot.UpcomingRecurring] {
        let rulesFetch = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.isPaused == false }
        )
        let rules = (try? context.fetch(rulesFetch)) ?? []
        let upcoming = rules.compactMap { rule -> WidgetSnapshot.UpcomingRecurring? in
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
