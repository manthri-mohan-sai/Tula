import Foundation
import AppIntents
import SwiftData

// MARK: - LogExpenseIntent

/// The main App Intent: parse a natural-language expense description and
/// save it. Works from Siri, the Shortcuts app, the Action button (iPhone 15
/// Pro+), Spotlight, and Lock Screen widgets.
///
/// Notes on why this is structured this way:
/// - `openAppWhenRun = false` so the user stays in Siri / their current
///   context after logging. Faster, less disruptive.
/// - `@MainActor` on perform() because SwiftData ModelContext touches Core
///   Data internals that prefer the main actor.
/// - Container is opened identically to the app's primary container so
///   data is shared transparently with the app.
struct LogExpenseIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Expense"

    static var description = IntentDescription(
        """
        Log an expense in Tula using natural language, like \"450 swiggy hdfc cc\" \
        or \"350 food and 400 groceries\". Multi-expense input creates one entry \
        per amount.
        """,
        categoryName: "Logging"
    )

    /// Don't open the app for this — Siri / Shortcuts should be able to log
    /// silently and return a confirmation dialog.
    static var openAppWhenRun: Bool = false

    /// Make the intent surface in Spotlight, Siri suggestions, and the
    /// Action button picker.
    static var isDiscoverable: Bool = true

    @Parameter(
        title: "Expense",
        description: "Natural language expense description.",
        requestValueDialog: IntentDialog("What did you spend?")
    )
    var expenseDescription: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$expenseDescription)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try sharedModelContext()

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let merchantRules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []

        let defaultAccount = resolveDefaultAccount(from: accounts)

        // Same pipeline as voice and quick-log: the deterministic, user-data-
        // driven interpreter. Handles multi-expense, marker-precedence account
        // matching, number compounds, and line items — no bespoke Siri parser.
        let interpreter = ExpenseInterpreter(
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
        let drafts = interpreter.interpret(expenseDescription).filter { $0.isValid }

        guard !drafts.isEmpty else {
            return .result(dialog: IntentDialog("I couldn't understand that. Try something like \"450 at Swiggy\"."))
        }

        var totalAmount: Double = 0
        var currencyCode = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        var lastAccountID: UUID?
        var descriptors: [String] = []

        for d in drafts {
            guard let account = d.account else { continue }
            let expense = Expense(
                amount: d.amount,
                date: d.date,
                merchant: d.merchant,
                note: d.note,
                source: .siri,
                category: d.category,
                account: account
            )
            expense.rawInput = expenseDescription
            expense.items = d.items.map { LineItem(name: $0.capitalized) }
            context.insert(expense)
            UserLearningEngine.learn(
                merchant: expense.merchant,
                category: expense.category?.name,
                amount: expense.amount,
                hour: Calendar.current.component(.hour, from: expense.date)
            )
            totalAmount += d.amount
            currencyCode = account.currencyCode
            lastAccountID = account.id
            if let descriptor = d.category?.name ?? d.merchant { descriptors.append(descriptor) }
        }

        try? context.save(); WidgetRefresh.refresh(using: context)
        postDarwinNotification(SharedNotifications.didSaveExpense)

        // Remember the last used account so subsequent Quick Log defaults work.
        if let id = lastAccountID {
            UserDefaults.standard.set(id.uuidString, forKey: "lastUsedAccountID")
        }

        // Build a friendly confirmation dialog.
        let totalFormatted = Currency.format(totalAmount, code: currencyCode)
        if drafts.count == 1 {
            if let descriptor = descriptors.first, !descriptor.isEmpty {
                return .result(dialog: IntentDialog("Logged \(totalFormatted) for \(descriptor)."))
            }
            return .result(dialog: IntentDialog("Logged \(totalFormatted)."))
        } else {
            return .result(dialog: IntentDialog("Logged \(drafts.count) expenses totaling \(totalFormatted)."))
        }
    }
}

// MARK: - ShowTodaySpendIntent

/// Reports today's spend. Pairs with the Live Activity / Lock Screen so
/// the user can also voice-query it ("How much did I spend today in Tula?")
/// instead of glancing at the screen.
struct ShowTodaySpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Today's Spend"

    static var description = IntentDescription(
        "Show how much you've spent in Tula today.",
        categoryName: "Insights"
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try sharedModelContext()

        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= todayStart }
        )
        let expenses = (try? context.fetch(descriptor)) ?? []
        let total = expenses.reduce(0) { $0 + $1.amount }
        let count = expenses.count
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"

        if count == 0 {
            return .result(dialog: IntentDialog("You haven't logged any expenses today."))
        }
        let totalFormatted = Currency.format(total, code: code)
        if count == 1 {
            return .result(dialog: IntentDialog("Today you've spent \(totalFormatted)."))
        }
        return .result(dialog: IntentDialog("Today you've spent \(totalFormatted) across \(count) transactions."))
    }
}

// MARK: - ShowMonthlySpendIntent

/// Reports total monthly spend. Simple, no parameters.
struct ShowMonthlySpendIntent: AppIntent {
    static var title: LocalizedStringResource = "Monthly Spend"

    static var description = IntentDescription(
        "Show how much you've spent in Tula this month.",
        categoryName: "Insights"
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try sharedModelContext()

        let calendar = Calendar.current
        guard let monthStart = calendar.dateInterval(of: .month, for: .now)?.start else {
            return .result(dialog: IntentDialog("Couldn't calculate this month."))
        }

        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= monthStart }
        )
        let expenses = (try? context.fetch(descriptor)) ?? []
        let total = expenses.reduce(0) { $0 + $1.amount }
        let count = expenses.count
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        let totalFormatted = Currency.format(total, code: code)

        let month = Date.now.formatted(.dateTime.month(.wide))
        if count == 0 {
            return .result(dialog: IntentDialog("You haven't logged any expenses in \(month) yet."))
        } else {
            return .result(dialog: IntentDialog("In \(month) you've spent \(totalFormatted) across \(count) transactions."))
        }
    }
}

// MARK: - Shared Helpers

/// Builds (or rebuilds) a ModelContext pointing at the same database the app uses.
/// Used by every App Intent.
@MainActor
private func sharedModelContext() throws -> ModelContext {
    let schema = Schema([
        Account.self,
        Category.self,
        Expense.self,
        Transfer.self,
        RecurringRule.self,
        MerchantRule.self,
        Budget.self,
        BalanceAdjustment.self,
        LineItem.self,
    ])
    if let storeURL = SharedStorage.sharedStoreURL {
        let config = ModelConfiguration("Tula", schema: schema, url: storeURL)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return ModelContext(container)
        }
    }
    let config = ModelConfiguration("Tula", schema: schema)
    guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
        throw IntentError.containerUnavailable
    }
    return ModelContext(container)
}

private func resolveDefaultAccount(from accounts: [Account]) -> Account? {
    let active = accounts.filter { !$0.isArchived }
    let lastUsedID = UserDefaults.standard.string(forKey: "lastUsedAccountID") ?? ""
    if !lastUsedID.isEmpty,
       let uuid = UUID(uuidString: lastUsedID),
       let match = active.first(where: { $0.id == uuid }) {
        return match
    }
    return active.first
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case containerUnavailable
    case parseFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .containerUnavailable: return "Couldn't open Tula's database."
        case .parseFailed: return "Couldn't parse the expense."
        }
    }
}

// MARK: - App Shortcuts Provider

/// Surfaces the intents in Spotlight, Siri suggestions, and the Shortcuts
/// app. The first phrase listed becomes the default Siri voice trigger.
///
/// Note: Apple requires `\(.applicationName)` somewhere in every phrase —
/// without it the phrase won't be recognized. The app's display name from
/// Info.plist becomes the substitution. Users must therefore say "in Tula"
/// (or similar) as part of the question; bare "how much did I spend on milk"
/// can never route here.
///
/// **IMPORTANT — call `TulaShortcuts.updateAppShortcutParameters()`:**
/// 1. Once on app launch (e.g. in `TulaApp.init` or first `onAppear`), and
/// 2. After any create/rename/archive of a Category or Account.
/// Siri caches `\(\.$topic)` values from `suggestedEntities()` at index
/// time; without this call, new categories/accounts won't be recognized
/// in spoken phrases until iOS reindexes on its own schedule.
struct TulaShortcuts: AppShortcutsProvider {

    /// Bright accent for the Shortcuts app tile.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "Log expense in \(.applicationName)",
                "Add expense in \(.applicationName)",
                "Spent in \(.applicationName)",
                "\(.applicationName) log expense",
                "\(.applicationName) add expense",
                "\(.applicationName) spent",
                "Track expense in \(.applicationName)",
                "Record expense in \(.applicationName)",
                "\(.applicationName) expense",
                "\(.applicationName) new expense"
            ],
            shortTitle: "Log Expense",
            systemImageName: "indianrupeesign.circle.fill"
        )

        AppShortcut(
            intent: ShowTodaySpendIntent(),
            phrases: [
                "How much have I spent today in \(.applicationName)",
                "Show today's spend in \(.applicationName)",
                "\(.applicationName) today",
                "\(.applicationName) how much today",
                "What did I spend today in \(.applicationName)"
            ],
            shortTitle: "Today's Spend",
            systemImageName: "sun.max.fill"
        )

        AppShortcut(
            intent: ShowMonthlySpendIntent(),
            phrases: [
                "How much have I spent this month in \(.applicationName)",
                "How much did I spend this month in \(.applicationName)",
                "Show my monthly spend in \(.applicationName)",
                "\(.applicationName) monthly spend",
                "\(.applicationName) this month"
            ],
            shortTitle: "Monthly Spend",
            systemImageName: "chart.bar.fill"
        )

    }
}
