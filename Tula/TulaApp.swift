//
//  TulaApp.swift
//  Tula
//
//  Created by Mohan Manthri on 26/05/26.

import SwiftUI
import SwiftData

@main
struct TulaApp: App {
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("seedDataInstalled") private var seedDataInstalled: Bool = false
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    let sharedContainer: ModelContainer = {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self,
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
            RootTabView()
                .tint(Color.tulaBrandFallback)
                .onAppear {
                    let context = ModelContext(sharedContainer)
                    if !seedDataInstalled {
                        SeedData.installIfNeeded(into: context)
                        seedDataInstalled = true
                    }
                    RecurringEngine.generateMissing(in: context)
                }
                .sheet(isPresented: Binding(
                    get: { !onboardingComplete },
                    set: { _ in }
                )) {
                    OnboardingView()
                }
        }
        .modelContainer(sharedContainer)
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
    }
}
