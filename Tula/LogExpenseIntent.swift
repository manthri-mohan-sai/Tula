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
    @available(iOS 26.0, *)
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

        // Race FM against a 4s timeout. Siri's overall intent budget is
        // ~10s; reserving ~6s for save + dialog rendering leaves headroom.
        let result = await withTaskGroup(of: SmartParseResult?.self) { group in
            group.addTask {
                await SmartExpenseParser.parseVoice(
                    input,
                    categories: categoryEntries,
                    accountNames: accountNames
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

/// A simpler intent that doesn't take parameters — just reports the user's
/// current monthly spend. Useful from Siri ("How much have I spent this month?")
/// and as a complication on the Lock Screen via Shortcuts widgets.
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
    ])
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
/// Info.plist becomes the substitution.
struct TulaShortcuts: AppShortcutsProvider {

    /// Bright accent for the Shortcuts app tile.
    static var shortcutTileColor: ShortcutTileColor { .orange }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                // Direct "log" verb
                "Log expense in \(.applicationName)",
                "Log expense to \(.applicationName)",
                "Log in \(.applicationName)",
                "Log a expense in \(.applicationName)",
                "Log a spend in \(.applicationName)",
                "\(.applicationName) log",
                "\(.applicationName) log expense",
                "\(.applicationName) log a expense",
                // "Add" verb
                "Add expense to \(.applicationName)",
                "Add expense in \(.applicationName)",
                "Add to \(.applicationName)",
                "Add a expense in \(.applicationName)",
                "\(.applicationName) add",
                "\(.applicationName) add expense",
                // "Spent / spend" verb (very natural in Indian English)
                "Spent in \(.applicationName)",
                "I spent in \(.applicationName)",
                "Spend in \(.applicationName)",
                "Spend on \(.applicationName)",
                "\(.applicationName) spent",
                "\(.applicationName) I spent",
                // "Track" verb
                "Track expense in \(.applicationName)",
                "Track spend in \(.applicationName)",
                "Track a spend in \(.applicationName)",
                "\(.applicationName) track",
                "\(.applicationName) track expense",
                // "Note / record / save"
                "Note expense in \(.applicationName)",
                "Record expense in \(.applicationName)",
                "Save expense in \(.applicationName)",
                "\(.applicationName) note",
                "\(.applicationName) record",
                // Bare app + intent
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
                "How much I spent today in \(.applicationName)",
                "Show today's spend in \(.applicationName)",
                "Show me today in \(.applicationName)",
                "\(.applicationName) today",
                "\(.applicationName) today's spend",
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
                "How much I spent in \(.applicationName)",
                "Show my monthly spend in \(.applicationName)",
                "Show this month in \(.applicationName)",
                "\(.applicationName) monthly total",
                "\(.applicationName) monthly spend",
                "\(.applicationName) this month",
                "\(.applicationName) how much"
            ],
            shortTitle: "Monthly Spend",
            systemImageName: "chart.bar.fill"
        )
    }
}
