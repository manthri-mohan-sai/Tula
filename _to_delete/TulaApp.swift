import SwiftUI
import SwiftData
import WidgetKit
import AppIntents

@main
struct TulaApp: App {
    @UIApplicationDelegateAdaptor(TulaAppDelegate.self) var appDelegate
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("themePresetID") private var themePresetID: String = "saffron"
    @AppStorage("seedDataInstalled") private var seedDataInstalled: Bool = false
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    /// Install the VisionKit recognizer hook into ReceiptStorage. The
    /// main app has VisionKit available (via VisionKitRecognizer.swift),
    /// but the share extension intentionally doesn't compile that file
    /// to avoid the framework's launch-time memory cost. ReceiptStorage
    /// holds an optional closure that, when set, routes OCR through
    /// VisionKit; when nil (share extension) it falls through to Vision.
    init() {
        TulaShortcuts.updateAppShortcutParameters()
        ReceiptStorage.visionKitRecognizer = { image in
            await recognizeTextWithVisionKit(image)
        }
    }
    /// User opt-out for the launch animation. Defaults true (animation
    /// shown). Users who've seen the तु calligraphy 200 times can flip
    /// this off in Settings → General.
    @AppStorage("launchAnimationEnabled") private var launchAnimationEnabled: Bool = true

    /// In-session flag: true once the launch animation has completed
    /// (or was skipped, or is disabled). Using @State (not @AppStorage)
    /// means the animation replays on every cold launch but not on
    /// foreground returns within the same session.
    /// Holds a reference to the Darwin notification observer for the
    /// share-extension "did save" signal. The observer is created on
    /// first scene appearance and lives for the app's lifetime; the
    /// @State binding keeps SwiftUI from deallocating it across view
    /// rebuilds.
    @State private var shareExtensionObserver: DarwinNotificationObserver? = nil

    /// Set to true when the share extension posts a Darwin notification
    /// indicating it saved an expense. The main app reads this flag on
    /// the next ScenePhase change (or via the @Query system noticing
    /// the new SQLite rows) to re-fetch and refresh UI.
    @State private var shareExtensionDidSaveTick: Int = 0

    @State private var launchAnimationDone: Bool = false
    @AppStorage("appLockEnabled") private var appLockEnabled: Bool = false
    @AppStorage("appLockDelay") private var appLockDelay: Int = 0
    /// Reads UserDefaults directly so the lock is active on cold launch.
    @State private var isLocked: Bool = UserDefaults.standard.bool(forKey: "appLockEnabled")
    /// Timestamp when the app last entered background. Used with
    /// `appLockDelay` to implement a grace period — if the user returns
    /// within the configured window, the lock screen auto-dismisses
    /// without requiring biometric auth.
    @State private var backgroundedAt: Date?

    @Environment(\.scenePhase) private var scenePhase

    let sharedContainer: ModelContainer = {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
            BalanceAdjustment.self, LineItem.self,
        ])

        // **Primary path**: shared App Group container. This is the
        // location both the main app AND the TulaShare extension open
        // so they see the same expense list. On iOS 18+, SwiftData
        // relies on SQLite's built-in locking for cross-process safety;
        // sufficient for the share-extension write-and-die pattern.
        if let storeURL = SharedStorage.sharedStoreURL {
            let sharedConfig = ModelConfiguration("Tula",
                                                   schema: schema,
                                                   url: storeURL)
            if let container = try? ModelContainer(for: schema,
                                                    configurations: [sharedConfig]) {
                return container
            }
        }

        // **Fallback 1**: if the App Group entitlement is missing or
        // broken, fall back to a local store. The share extension
        // won't be able to write here (it'd be sandboxed elsewhere),
        // but the main app continues to function normally. User
        // notices the share feature doesn't work; everything else does.
        let primaryConfig = ModelConfiguration("Tula", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [primaryConfig]) {
            return container
        }

        // **Fallback 2**: in-memory store. Only reached when the
        // disk-backed store is corrupt or sandbox permissions are
        // misconfigured. Lets the app launch (with empty data) so the
        // user can at least see the UI and report the issue.
        let memoryConfig = ModelConfiguration("Tula", schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [memoryConfig]) {
            return container
        }

        // **Fallback 3**: empty-schema in-memory container. Last resort
        // before crashing — guarantees we can construct *something*
        // even if everything above failed.
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
                let _ = themePresetID
                RootTabView(appDelegate: appDelegate, launchAnimationDone: $launchAnimationDone)
                    .tint(Color.tulaBrandFallback)
                    .onAppear {
                        let context = ModelContext(sharedContainer)
                        if !seedDataInstalled {
                            SeedData.installIfNeeded(into: context)
                            seedDataInstalled = true
                        }
                        // Heavy work runs on a background thread with its
                        // own ModelContext. RecurringEngine.generateMissing
                        // loops through every rule doing repeated SwiftData
                        // property accesses — easily >5s with cold caches.
                        // Running on @MainActor (even in a Task) still
                        // starves the launch animation's asyncAfter callbacks.
                        // Task.detached moves the work entirely off the main
                        // thread; @Query views pick up changes via SQLite
                        // notifications once the background context saves.
                        let container = sharedContainer
                        Task.detached {
                            let bgContext = ModelContext(container)
                            SeedData.installMissingDefaultMerchantRules(into: bgContext)
                            RecurringEngine.generateMissing(in: bgContext)
                            cleanupOldReceipts(in: bgContext)
                            await MainActor.run {
                                let ctx = ModelContext(container)
                                WidgetRefresh.refresh(using: ctx)
                            }
                        }

                        // Install the Darwin notification observer if it
                        // isn't already running. Listens for the share
                        // extension's "did save" signal so the main app
                        // can refresh its @Query views without waiting
                        // for the next foreground. Cross-process pings —
                        // in-process NotificationCenter wouldn't see
                        // changes from a separate process.
                        if shareExtensionObserver == nil {
                            shareExtensionObserver = DarwinNotificationObserver(
                                name: SharedNotifications.didSaveExpense
                            ) {
                                // Bump the tick counter to force SwiftUI
                                // to re-evaluate any views that key off
                                // it, and refresh the widget snapshot
                                // since totals may have changed.
                                shareExtensionDidSaveTick &+= 1
                                let ctx = ModelContext(sharedContainer)
                                WidgetRefresh.refresh(
                                    using: ctx,
                                    upcomingRecurrings: buildUpcomingRecurrings(in: ctx)
                                )
                            }
                        }
                    }
                    .sheet(isPresented: Binding(
                        get: { !onboardingComplete },
                        set: { if !$0 { onboardingComplete = true } }
                    )) {
                        OnboardingView()
                    }

                // Lock screen sits behind the splash animation so it's
                // already rendered when the splash finishes — no flash.
                // FaceID triggers silently during the splash via onAppear;
                // if it succeeds, the lock clears before splash ends and
                // the user goes straight to home.
                if isLocked {
                    AppLockView {
                        withAnimation(AppAnimation.gentle) {
                            isLocked = false
                        }
                    }
                    .zIndex(2)
                }

                if !launchAnimationDone {
                    LaunchAnimationView {
                        launchAnimationDone = true
                    }
                    .onAppear {
                        if !launchAnimationEnabled || appDelegate.pendingShortcutURL != nil || appDelegate.launchedFromDeepLink {
                            launchAnimationDone = true
                        }
                    }
                    .zIndex(3)
                }
            }
        }
        .modelContainer(sharedContainer)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Grace period: if the user returns within the configured
                // delay, auto-unlock without requiring biometric auth.
                // The lock screen was shown on background to hide content
                // from the app switcher; this just lifts it silently.
                if appLockEnabled && isLocked && appLockDelay > 0,
                   let bg = backgroundedAt,
                   Date.now.timeIntervalSince(bg) < Double(appLockDelay) {
                    withAnimation(AppAnimation.gentle) {
                        isLocked = false
                    }
                }

                // Auto-trigger FaceID when returning from background
                // while still locked (beyond grace period). AppLockView's
                // onAppear only fires once; this covers subsequent returns.
                if appLockEnabled && isLocked && launchAnimationDone {
                    Task {
                        let success = await AppLockManager.authenticate()
                        if success {
                            withAnimation(AppAnimation.gentle) {
                                isLocked = false
                            }
                        }
                    }
                }

                let activeContainer = sharedContainer
                Task.detached {
                    let ctx = ModelContext(activeContainer)

                    let upcomingRecurrings = buildUpcomingRecurrings(in: ctx)
                    await MainActor.run {
                        let mainCtx = ModelContext(activeContainer)
                        WidgetRefresh.refresh(
                            using: mainCtx,
                            upcomingRecurrings: upcomingRecurrings
                        )
                        NotificationManager.refreshDailyReminder(using: mainCtx)
                        TulaShortcuts.updateAppShortcutParameters()
                    }
                }
            } else if newPhase == .background {
                if appLockEnabled {
                    isLocked = true
                    backgroundedAt = .now
                }
                appDelegate.scheduleWidgetRefresh()
                let ctx = ModelContext(sharedContainer)
                BackupManager.autoBackupIfNeeded(context: ctx)
            }
        }
    }
}


// MARK: - Receipt Auto-Delete

/// Strips receipt images from expenses older than the configured threshold.
/// Only removes the image data — the expense record itself is preserved.
/// Called on app launch in a background context so it never blocks UI.
nonisolated func cleanupOldReceipts(in context: ModelContext) {
    let days = UserDefaults.standard.integer(forKey: "receiptAutoDeleteDays")
    guard days > 0 else { return }

    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
    var descriptor = FetchDescriptor<Expense>(
        predicate: #Predicate { $0.date < cutoff && $0.receiptImageData != nil }
    )
    descriptor.fetchLimit = 500  // batch to avoid memory spikes

    guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
    for expense in stale {
        expense.receiptImageData = nil
    }
    context.safeSave()
}

// MARK: - Upcoming Recurrings Builder

/// Builds the next 3 recurring expenses due for embedding in the widget snapshot.
/// Kept separate from WidgetRefresh (which lives in a shared file) because it
/// depends on RecurringEngine, which is not compiled into the share extension.
nonisolated func buildUpcomingRecurrings(in context: ModelContext) -> [WidgetSnapshot.UpcomingRecurring] {
    let rulesFetch = FetchDescriptor<RecurringRule>(
        predicate: #Predicate { $0.isPaused == false }
    )
    let rules = (try? context.fetch(rulesFetch)) ?? []
    let upcoming = rules.compactMap { rule -> WidgetSnapshot.UpcomingRecurring? in
        guard rule.kind == .expense else { return nil }
        // Zero-amount rules are hidden from the widget too — a "₹0 ·
        // overdue" row is noise, not a reminder.
        guard rule.amount > 0 else { return nil }
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

// MARK: - Root Tabs

enum TulaTab: Hashable {
    case home, stats, budgets, accounts, add
}

/// Four navigation tabs (Home, Stats, Budgets, Accounts) plus a separate
/// Add accessory rendered via the `.search` role — iOS 26 shows it as a
/// distinct pill/button in the tab bar, visually separated from the
/// navigation tabs. Settings lives in Home's toolbar (gear icon).
struct RootTabView: View {
    let appDelegate: TulaAppDelegate
    @Binding var launchAnimationDone: Bool
    @State private var selectedTab: TulaTab = .home
    /// Single atomic state for the Add Expense sheet. Using one `item:`
    /// binding instead of two separate bools (`showingAddExpense` +
    /// `pendingScanOnAdd`) eliminates the race where SwiftUI's sheet
    /// content closure captured `pendingScanOnAdd` before it was updated,
    /// making `openCameraOnAppear` always `false` on scan launches.
    @State private var addExpenseMode: AddExpenseMode?

    enum AddExpenseMode: Identifiable {
        case normal
        case scan
        var id: Int { self == .scan ? 1 : 0 }
    }

    /// Intercepts selection of the `.add` tab to present the sheet
    /// instead of switching tabs. All other tabs behave normally.
    private var tabBinding: Binding<TulaTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == .add {
                    Haptics.impact()
                    addExpenseMode = .normal
                } else {
                    selectedTab = newValue
                }
            }
        )
    }

    var body: some View {
        TabView(selection: tabBinding) {
            Tab("Home", systemImage: "house.fill", value: TulaTab.home) {
                HomeView()
            }

            Tab("Stats", systemImage: "chart.bar.fill", value: TulaTab.stats) {
                StatsView()
            }

            Tab("Budgets", systemImage: "chart.pie.fill", value: TulaTab.budgets) {
                NavigationStack {
                    BudgetsView()
                }
            }

            Tab("Accounts", systemImage: "creditcard.fill", value: TulaTab.accounts) {
                NavigationStack {
                    CardsView()
                }
            }

            Tab("Add", systemImage: "plus", value: TulaTab.add, role: .search) {
                Color.tulaBackground.ignoresSafeArea()
            }
        }
        .sheet(item: $addExpenseMode) { mode in
            AddExpenseView(openCameraOnAppear: mode == .scan)
                .presentationSizing(.page)
        }
        // Handle deep links from widgets. `tula://add` opens the Add
        // Expense sheet directly. `tula://voice` keeps the user on Home
        // and posts a notification that the QuickLogBar listens to —
        // starting voice capture without manual tap.
        .onOpenURL { url in
            if !launchAnimationDone { launchAnimationDone = true }
            handleDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tulaQuickAction)) { note in
            if let url = note.object as? URL {
                appDelegate.pendingShortcutURL = nil
                if !launchAnimationDone { launchAnimationDone = true }
                handleDeepLink(url)
            }
        }
        .task {
            guard let url = appDelegate.pendingShortcutURL else { return }
            appDelegate.pendingShortcutURL = nil
            if !launchAnimationDone { launchAnimationDone = true }
            try? await Task.sleep(for: .seconds(0.5))
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "tula" else { return }
        switch url.host {
        case "add":
            Haptics.impact()
            addExpenseMode = .normal
        case "voice":
            Haptics.impact()
            selectedTab = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(
                    name: .tulaStartVoiceCapture,
                    object: nil
                )
            }
        case "scan":
            Haptics.impact()
            addExpenseMode = .scan
        default: break
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the user taps the Voice button on the Quick Actions
    /// widget. The QuickLogBar on Home observes this and starts the
    /// microphone automatically.
    static let tulaStartVoiceCapture = Notification.Name("tula.startVoiceCapture")
    static let tulaStartReceiptScan = Notification.Name("tula.startReceiptScan")
    static let tulaQuickAction = Notification.Name("tula.quickAction")
    static let tulaExpenseSaved = Notification.Name("tula.expenseSaved")
}
