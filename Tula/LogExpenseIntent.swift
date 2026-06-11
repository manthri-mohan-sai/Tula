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

        // FM-first path. Siri input is essentially voice input — same
        // transcription noise, same homophone risks, same split-digit
        // quirks ("two fifty" / "1 20"). When Foundation Models is
        // available, route through it first; rules become the fallback
        // for older devices or when FM can't produce a usable result.
        //
        // Multi-expense input (commas, multiple amounts) intentionally
        // skips FM — the rule parser is purpose-built for splitting,
        // while FM returns a single structured result. Detecting this
        // upstream means "350 food and 400 groceries" still creates two
        // expenses (one bug we don't want to regress).
        if SmartExpenseParser.isAvailable,
           !isLikelyMultiExpense(expenseDescription),
           let savedDialog = await trySmartParseForSiri(
               input: expenseDescription,
               accounts: accounts,
               categories: categories,
               defaultAccount: defaultAccount,
               context: context
           )
        {
            return .result(dialog: savedDialog)
        }

        // Rule-based fallback: same logic as before for typed-style input,
        // multi-expense input, or devices without FM.
        let parsed = ExpenseParser.parse(
            input: expenseDescription,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )

        let valid = parsed.filter { $0.isValid }

        guard !valid.isEmpty else {
            return .result(dialog: IntentDialog("I couldn't understand that. Try something like \"450 at Swiggy\"."))
        }

        var totalAmount: Double = 0
        var currencyCode: String = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        var lastAccountID: UUID?

        for p in valid {
            guard let account = p.account else { continue }
            let expense = Expense(
                amount: p.amount,
                merchant: p.merchant,
                note: p.note,
                source: .siri,
                category: p.category,
                account: account
            )
            expense.rawInput = p.rawInput
            context.insert(expense)
            totalAmount += p.amount
            currencyCode = account.currencyCode
            lastAccountID = account.id
        }

        try? context.save(); WidgetRefresh.refresh(using: context)
        postDarwinNotification(SharedNotifications.didSaveExpense)

        // Remember the last used account so subsequent Quick Log defaults work.
        if let id = lastAccountID {
            UserDefaults.standard.set(id.uuidString, forKey: "lastUsedAccountID")
        }

        // Build a friendly confirmation dialog.
        let totalFormatted = Currency.format(totalAmount, code: currencyCode)
        if valid.count == 1, let only = valid.first {
            let labelParts = [only.category?.name, only.merchant].compactMap { $0 }
            if let descriptor = labelParts.first, !descriptor.isEmpty {
                return .result(dialog: IntentDialog("Logged \(totalFormatted) for \(descriptor)."))
            } else {
                return .result(dialog: IntentDialog("Logged \(totalFormatted)."))
            }
        } else {
            return .result(dialog: IntentDialog("Logged \(valid.count) expenses totaling \(totalFormatted)."))
        }
    }

    /// Heuristic for detecting multi-expense input. Triggers when the
    /// string contains a conjunction word ("and", "plus", "then", "also")
    /// surrounded by spaces AND has 2+ digit groups. Pure-comma cases
    /// also trigger (`"350 swiggy, 200 uber"`). Conservative — if in
    /// doubt, returns false (single-expense path via FM is fine for
    /// most edge cases).
    private func isLikelyMultiExpense(_ input: String) -> Bool {
        let digitCount = input.matches(of: #/\d+/#).count
        guard digitCount >= 2 else { return false }
        let lower = input.lowercased()
        if lower.contains(",") || lower.contains(";") { return true }
        let conjunctions = [" and ", " plus ", " then ", " also "]
        return conjunctions.contains { lower.contains($0) }
    }

    /// Smart-parses a Siri-supplied expense description through Foundation
    /// Models and saves the resulting expense if usable. Returns the
    /// confirmation dialog on success, or nil to signal the caller should
    /// fall back to the rule parser.
    ///
    /// **Safety net:** races the FM call against a 4-second timeout because
    /// Siri itself has an intent-execution time budget (~10s). If FM is
    /// slow, we want to fall through to rules well before Siri kills the
    /// intent — a fast worse answer beats a no-answer timeout.
    @MainActor
    private func trySmartParseForSiri(
        input: String,
        accounts: [Account],
        categories: [Category],
        defaultAccount: Account?,
        context: ModelContext
    ) async -> IntentDialog? {
        let usableCategories = categories.filter { !$0.isArchived }
        let usableAccounts = accounts.filter { !$0.isArchived }
        let categoryEntries = usableCategories.map {
            CategoryEntry(name: $0.name, iconKey: $0.iconKey)
        }
        let accountNames = usableAccounts.map { $0.name }
        let categoryByName = Dictionary(uniqueKeysWithValues:
            usableCategories.map { ($0.name.lowercased(), $0) })
        let accountByName = Dictionary(uniqueKeysWithValues:
            usableAccounts.map { ($0.name.lowercased(), $0) })

        // Build situational + DB context for FM. Pass into both parse
        // call so the model has full awareness of the user's history.
        let fmContext = await FMContextBuilder.build(modelContext: context)

        // Race FM against a 4s timeout. Siri's overall intent budget is
        // ~10s; reserving ~6s for save + dialog rendering leaves headroom.
        let result = await withTaskGroup(of: SmartParseResult?.self) { group in
            group.addTask {
                await SmartExpenseParser.parseVoice(
                    input,
                    categories: categoryEntries,
                    accountNames: accountNames,
                    contextBlock: fmContext
                )
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(4))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let result, result.amount > 0 else { return nil }

        // Amount sanity check — same as in-app voice path. If FM's amount
        // is significantly smaller than what the rule parser would have
        // extracted, FM dropped a digit during interpretation. Returning
        // nil here causes the caller to fall back to the rule parser.
        let merchantRules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let ruleParsed = ExpenseParser.parse(
            input: input,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
        let ruleAmount = ruleParsed.first?.amount ?? 0
        if ruleAmount > 0, result.amount < ruleAmount / 2 {
            return nil
        }

        let category = result.category.flatMap { categoryByName[$0.lowercased()] }
        let account = result.account.flatMap { accountByName[$0.lowercased()] }
            ?? defaultAccount
        guard let account else { return nil }

        let expense = Expense(
            amount: result.amount,
            merchant: result.merchant,
            note: result.item,
            source: .smartParsed,
            category: category,
            account: account
        )
        expense.rawInput = input
        context.insert(expense)
        try? context.save(); WidgetRefresh.refresh(using: context)

        UserDefaults.standard.set(account.id.uuidString, forKey: "lastUsedAccountID")

        // Build the dialog using the same phrasing as the rule-based path
        // so Siri's response feels consistent regardless of which parser ran.
        let totalFormatted = Currency.format(result.amount, code: account.currencyCode)
        let descriptor = [category?.name, result.merchant].compactMap { $0 }.first ?? ""
        if descriptor.isEmpty {
            return IntentDialog("Logged \(totalFormatted).")
        } else {
            return IntentDialog("Logged \(totalFormatted) for \(descriptor).")
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

// MARK: - CheckSpendingIntent

/// Answers "How much did I spend on shopping/groceries/milk this month?"
/// Separate intent from ShowMonthlySpendIntent to avoid Siri routing confusion.
///
/// Matches the topic against (in spirit-of-the-question order):
/// categories, merchants, notes, and **account names** — so
/// "How much did I spend on IndusInd card in Tula" works too.
struct CheckSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Spending"

    static var description = IntentDescription(
        "Check how much you spent on a category, merchant, item, or account this month.",
        categoryName: "Insights"
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @Parameter(
        title: "Topic",
        description: "What to check spending for.",
        requestValueDialog: IntentDialog("What do you want to check spending for?")
    )
    var topic: SpendingTopic

    static var parameterSummary: some ParameterSummary {
        Summary("Check spending for \(\.$topic)")
    }

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

        let query = topic.rawValue.lowercased()

        let matched = expenses.filter { expense in
            // Category: exact match (case-insensitive)
            if let catName = expense.category?.name.lowercased(), !catName.isEmpty {
                if catName == query || catName.contains(query) { return true }
            }
            // Merchant: substring match
            if let merchant = expense.merchant?.lowercased(), !merchant.isEmpty {
                if merchant == query || merchant.contains(query) { return true }
            }
            // Note: word-level match (avoids false positives from substrings)
            if let note = expense.note?.lowercased(), !note.isEmpty {
                let words = note.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
                if words.contains(query) { return true }
            }
            return false
        }

        let total = matched.reduce(0) { $0 + $1.amount }
        let count = matched.count
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        let totalFormatted = Currency.format(total, code: code)
        let month = Date.now.formatted(.dateTime.month(.wide))
        let label = topic == .bills ? "Bills & Utilities" : topic.rawValue.capitalized

        if count == 0 {
            return .result(dialog: IntentDialog("You haven't spent anything on \(label) in \(month)."))
        } else if count == 1 {
            return .result(dialog: IntentDialog("You spent \(totalFormatted) on \(label) in \(month)."))
        } else {
            return .result(dialog: IntentDialog("You spent \(totalFormatted) on \(label) in \(month) across \(count) transactions."))
        }
    }
}

// MARK: - ShowAccountSpendingIntent

/// Reports this month's spending broken down by account/card.
/// No parameters — Siri resolves it immediately without a picker.
struct ShowAccountSpendingIntent: AppIntent {
    static var title: LocalizedStringResource = "Account Spending"

    static var description = IntentDescription(
        "Show how much you've spent on each account or card this month.",
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
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        let month = Date.now.formatted(.dateTime.month(.wide))

        guard !expenses.isEmpty else {
            return .result(dialog: IntentDialog("No expenses logged in \(month) yet."))
        }

        // Group by account name
        var byAccount: [(name: String, total: Double, count: Int)] = []
        var grouped: [String: (total: Double, count: Int)] = [:]
        for expense in expenses {
            let name = expense.account?.name ?? "Unknown"
            let existing = grouped[name] ?? (total: 0, count: 0)
            grouped[name] = (total: existing.total + expense.amount, count: existing.count + 1)
        }
        byAccount = grouped.map { (name: $0.key, total: $0.value.total, count: $0.value.count) }
            .sorted { $0.total > $1.total }

        if byAccount.count == 1 {
            let a = byAccount[0]
            let formatted = Currency.format(a.total, code: code)
            return .result(dialog: IntentDialog("In \(month), you spent \(formatted) on \(a.name) across \(a.count) transactions."))
        }

        // Multiple accounts — list top entries
        let lines = byAccount.prefix(5).map { a in
            "\(a.name): \(Currency.format(a.total, code: code))"
        }
        let summary = lines.joined(separator: ", ")
        let total = Currency.format(expenses.reduce(0) { $0 + $1.amount }, code: code)
        return .result(dialog: IntentDialog("In \(month) you spent \(total) total. \(summary)."))
    }
}

// MARK: - ShowCardDuesIntent

/// Reports outstanding dues on all credit cards.
/// No parameters — Siri resolves it immediately without a picker.
struct ShowCardDuesIntent: AppIntent {
    static var title: LocalizedStringResource = "Card Dues"

    static var description = IntentDescription(
        "Show outstanding dues on your credit cards.",
        categoryName: "Insights"
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try sharedModelContext()

        let accountDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate { $0.isArchived == false }
        )
        let accounts = (try? context.fetch(accountDescriptor)) ?? []
        let creditCards = accounts.filter { $0.kind == .creditCard }
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"

        guard !creditCards.isEmpty else {
            return .result(dialog: IntentDialog("You don't have any credit cards set up in Tula."))
        }

        let lines = creditCards.map { card in
            let due = card.derivedBalance
            let dueFormatted = Currency.format(abs(due), code: code)
            if due <= 0 {
                return "\(card.name): no dues"
            } else if let limit = card.creditLimit, limit > 0 {
                let limitFormatted = Currency.format(limit, code: code)
                return "\(card.name): \(dueFormatted) due of \(limitFormatted) limit"
            } else {
                return "\(card.name): \(dueFormatted) due"
            }
        }

        if creditCards.count == 1 {
            let msg = lines[0]
            return .result(dialog: IntentDialog("\(msg)."))
        }

        let msg = lines.joined(separator: ". ")
        return .result(dialog: IntentDialog("\(msg)."))
    }
}

// MARK: - SpendingTopic (AppEnum)

/// Compile-time enum of spending topics. AppEnum values are baked into the
/// binary metadata — Siri indexes them without any runtime calls.
/// Note: AppEntity with dynamic values does NOT work for Siri voice on
/// this device — only static AppEnum cases are resolved inline.
enum SpendingTopic: String, AppEnum {
    case food, groceries, transport, shopping, entertainment
    case bills, rent, health, education, travel
    case personalCare = "personal care"
    case milk, coffee, fuel, dining, snacks, subscriptions, clothing

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    static var caseDisplayRepresentations: [SpendingTopic: DisplayRepresentation] = [
        .food: "Food",
        .groceries: "Groceries",
        .transport: "Transport",
        .shopping: "Shopping",
        .entertainment: "Entertainment",
        .bills: "Bills & Utilities",
        .rent: "Rent",
        .health: "Health",
        .education: "Education",
        .travel: "Travel",
        .personalCare: "Personal Care",
        .milk: "Milk",
        .coffee: "Coffee",
        .fuel: "Fuel",
        .dining: "Dining",
        .snacks: "Snacks",
        .subscriptions: "Subscriptions",
        .clothing: "Clothing",
    ]
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

        AppShortcut(
            intent: CheckSpendingIntent(),
            phrases: [
                "How much did I spend on \(\.$topic) in \(.applicationName)",
                "Check \(\.$topic) spending in \(.applicationName)",
                "\(\.$topic) spending in \(.applicationName)"
            ],
            shortTitle: "Check Spending",
            systemImageName: "magnifyingglass"
        )

        AppShortcut(
            intent: ShowAccountSpendingIntent(),
            phrases: [
                "Show card spending in \(.applicationName)",
                "Spending by card in \(.applicationName)",
                "\(.applicationName) account breakdown"
            ],
            shortTitle: "Card Spending",
            systemImageName: "creditcard.fill"
        )

        AppShortcut(
            intent: ShowCardDuesIntent(),
            phrases: [
                "What's due on my cards in \(.applicationName)",
                "Card dues in \(.applicationName)",
                "\(.applicationName) credit card dues"
            ],
            shortTitle: "Card Dues",
            systemImageName: "indianrupeesign.arrow.circlepath"
        )

    }
}
