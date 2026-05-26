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

    let sharedContainer: ModelContainer = {
        let schema = Schema([
            Account.self,
            Category.self,
            Expense.self,
            Transfer.self,
            RecurringRule.self,
            MerchantRule.self,
        ])

        let primaryConfig = ModelConfiguration("Tula", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [primaryConfig]) {
            return container
        }

        print("⚠️ Persistent container unavailable — falling back to in-memory.")
        let memoryConfig = ModelConfiguration("Tula", schema: schema, isStoredInMemoryOnly: true)
        if let container = try? ModelContainer(for: schema, configurations: [memoryConfig]) {
            return container
        }

        print("❌ All ModelContainer init attempts failed.")
        return (try? ModelContainer(for: Schema([]),
                                     configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
            ?? {
                preconditionFailure("Cannot create any ModelContainer.")
            }()
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
                    // Run recurring rule generation on every launch.
                    // No-op if there are no rules or nothing's due.
                    RecurringEngine.generateMissing(in: context)
                }
        }
        .modelContainer(sharedContainer)
    }
}

// MARK: - Root Tabs

enum TulaTab: Hashable {
    case home, stats, settings
}

struct RootTabView: View {
    @State private var selectedTab: TulaTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(onShowStats: {
                Haptics.tap()
                selectedTab = .stats
            })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(TulaTab.home)

            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.fill") }
                .tag(TulaTab.stats)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(TulaTab.settings)
        }
    }
}
