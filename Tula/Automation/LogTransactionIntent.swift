import AppIntents
import Foundation
import SwiftData

/// Logs a bank or card transaction from its alert text.
///
/// Built for a Shortcuts personal automation on the **Message** trigger,
/// filtered by sender (`HDFCBK`, `ICICIB`) or content ("debited"). The whole
/// shortcut is one action: pass the message text in.
///
/// **Why the app parses rather than Shortcuts.** Keeping format knowledge in
/// Swift means a new bank is an app update with tests behind it, not regex
/// surgery in the Shortcuts editor on a phone. It also keeps deduplication,
/// account matching and categorisation in one place instead of duplicated
/// across one shortcut per bank.
struct LogTransactionIntent: AppIntent {

    static var title: LocalizedStringResource = "Log Bank Transaction"

    static var description = IntentDescription(
        """
        Reads a bank or credit-card alert and logs the spend in Tula. \
        Credits, refunds and reversals are recognised and ignored. Duplicate \
        alerts for the same transaction are detected and skipped.
        """,
        categoryName: "Automation"
    )

    /// Never open the app. An automation firing on every bank SMS that yanked
    /// the user out of what they were doing would be uninstalled within a day.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @Parameter(
        title: "Message",
        description: "The full text of the bank or card alert.",
        requestValueDialog: IntentDialog("Paste the transaction message")
    )
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Log transaction from \(\.$message)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let outcome = TransactionLogger.log(message: message)
        // `IntentDialog` is ExpressibleByStringLiteral, so the bare
        // `IntentDialog("...")` form only accepts a literal. `spoken` is a
        // computed String, which needs the explicit initialiser.
        return .result(
            value: outcome.shortcutValue,
            dialog: IntentDialog(stringLiteral: outcome.spoken)
        )
    }
}

// MARK: - Logger

/// The work behind `LogTransactionIntent`, factored out so it is testable
/// without invoking the intent machinery.
@MainActor
enum TransactionLogger {

    enum Outcome {
        case logged(amount: Double, merchant: String?, currency: String, needsReview: Bool)
        case skippedCredit(amount: Double, currency: String)
        case skippedDuplicate(reference: String?)
        case unparsed
        case noAccounts

        /// Machine-readable value so a shortcut can branch on the result.
        var shortcutValue: String {
            switch self {
            case .logged(_, _, _, let needsReview): return needsReview ? "logged_review" : "logged"
            case .skippedCredit: return "skipped_credit"
            case .skippedDuplicate: return "skipped_duplicate"
            case .unparsed: return "unparsed"
            case .noAccounts: return "no_accounts"
            }
        }

        var spoken: String {
            switch self {
            case .logged(let amount, let merchant, let code, let needsReview):
                let formatted = Currency.format(amount, code: code)
                let base = merchant.map { "Logged \(formatted) at \($0)." }
                    ?? "Logged \(formatted)."
                return needsReview ? base + " Flagged for review." : base
            case .skippedCredit(let amount, let code):
                return "Ignored a credit of \(Currency.format(amount, code: code))."
            case .skippedDuplicate:
                return "Already logged — skipped duplicate."
            case .unparsed:
                return "Couldn't find a transaction in that message."
            case .noAccounts:
                return "Set up an account in Tula first."
            }
        }
    }

    // MARK: Entry

    /// Logs `message` only if it looks like a machine-generated bank alert.
    /// Returns nil for ordinary human input so the caller can fall through to
    /// its normal free-text path.
    ///
    /// The discriminator is deliberately narrow: masked account digits or a
    /// bank reference. Neither appears in anything a person types by hand
    /// ("450 swiggy hdfc cc"), and both are present in essentially every bank
    /// or card alert — so this reroutes exactly the messages that would
    /// otherwise be shredded, and nothing else.
    static func logIfBankAlert(message: String, now: Date = .now) -> Outcome? {
        guard let transaction = BankMessageParser.parse(message) else { return nil }
        guard transaction.direction != .unknown else { return nil }
        guard transaction.accountLast4 != nil || transaction.reference != nil else {
            return nil
        }
        return log(message: message, now: now)
    }

    static func log(message: String, now: Date = .now) -> Outcome {
        guard let transaction = BankMessageParser.parse(message) else { return .unparsed }

        // Credits, refunds and reversals are never expenses. An unknown
        // direction is treated the same way: guessing wrong turns a salary
        // credit into a five-figure expense, and a missed spend is far
        // cheaper to fix than a fabricated one.
        guard transaction.isLoggableExpense else {
            return .skippedCredit(
                amount: transaction.amount,
                currency: transaction.currencyCode ?? primaryCurrency
            )
        }

        guard let context = try? sharedAutomationContext() else { return .unparsed }

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let active = accounts.filter { !$0.isArchived }
        guard !active.isEmpty else { return .noAccounts }

        if isDuplicate(transaction, in: context, now: now) {
            return .skippedDuplicate(reference: transaction.reference)
        }

        let match = AccountMatcher.match(
            accounts: accounts, last4: transaction.accountLast4, hint: message
        )
        guard let account = match.account ?? fallbackAccount(from: active) else {
            return .noAccounts
        }

        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let merchantRules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []
        let category = resolveCategory(
            merchant: transaction.merchant,
            message: message,
            categories: categories,
            rules: merchantRules
        )

        // The amount is regex-extracted from a currency-marked figure, so it
        // is reliable. What can be wrong is *attribution* — which account,
        // which category. Leaving the category off when it is uncertain puts
        // the expense straight into the app's existing review banner rather
        // than burying a bad classification in the totals.
        let needsReview = category == nil || !match.isConfident

        let expense = Expense(
            amount: transaction.amount,
            date: transaction.date ?? now,
            merchant: transaction.merchant,
            note: nil,
            source: .automation,
            category: category,
            account: account
        )
        // Full alert retained: it is the audit trail, and it carries the
        // reference that deduplication depends on.
        expense.rawInput = message

        ExpenseWriter.commit(
            built: [expense],
            in: context,
            options: ExpenseWriter.Options(postSavedNotification: false)
        )

        return .logged(
            amount: transaction.amount,
            merchant: transaction.merchant,
            currency: transaction.currencyCode ?? account.currencyCode,
            needsReview: needsReview
        )
    }

    // MARK: Duplicates

    /// Window for duplicate detection.
    ///
    /// Long enough to catch the issuing bank and the card network sending the
    /// same purchase minutes apart; short enough that two genuine ₹120 coffees
    /// on the same card in one afternoon are not collapsed into one.
    private static let duplicateWindow: TimeInterval = 30 * 60
    private static let referenceLookback: TimeInterval = 7 * 24 * 60 * 60

    /// Two tests, strongest first.
    ///
    /// A bank reference is definitive: identical reference means identical
    /// transaction, whatever else differs. Without one, an exact amount match
    /// on the same account inside the window is the best available proxy.
    private static func isDuplicate(
        _ transaction: BankTransaction,
        in context: ModelContext,
        now: Date
    ) -> Bool {
        if let reference = transaction.reference {
            let recent = fetchRecentlyWritten(within: referenceLookback, in: context, now: now)
            let seen = recent.contains { expense in
                // Only alerts this intent created carry a bank reference.
                // Without this guard, a manual note containing a 12-digit
                // number could falsely suppress a real transaction.
                guard expense.source == .automation else { return false }
                guard let raw = expense.rawInput else { return false }
                guard let existing = BankMessageParser.extractReference(from: raw) else {
                    return false
                }
                return existing == reference
            }
            if seen { return true }
        }

        let recent = fetchRecentlyWritten(within: duplicateWindow, in: context, now: now)
        return recent.contains { isSameTransaction(transaction, as: $0) }
    }

    /// Whether `expense` looks like the row `transaction` would create.
    ///
    /// Split out as a pure comparison so the rules are testable without a
    /// container, and so the reasoning sits in one place rather than inline
    /// in a fetch closure.
    static func isSameTransaction(
        _ transaction: BankTransaction,
        as expense: Expense
    ) -> Bool {
        guard expense.source == .automation else { return false }
        guard abs(expense.amount - transaction.amount) < 0.01 else { return false }

        // Different card is a different transaction, full stop.
        if let last4 = transaction.accountLast4,
           let digits = expense.account?.last4Digits,
           digits.count >= 4 {
            guard digits.suffix(4) == last4 else { return false }
        }

        // When both sides name a merchant and the names disagree, these are
        // two different purchases that happen to cost the same. Only compared
        // when both are present: the issuing bank and the card network often
        // send the same purchase with one of them omitting the payee.
        if let incoming = transaction.merchant?.lowercased(),
           let existing = expense.merchant?.lowercased(),
           incoming != existing {
            return false
        }

        return true
    }

    /// Rows written in the last `window`, by `createdAt`.
    ///
    /// Deliberately not `date`: that is when the *purchase* happened, which an
    /// alert can report as hours or days ago, and searching it with a window
    /// anchored on `now` misses exactly the rows we just wrote.
    private static func fetchRecentlyWritten(
        within window: TimeInterval,
        in context: ModelContext,
        now: Date
    ) -> [Expense] {
        let since = now.addingTimeInterval(-window)
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.createdAt >= since }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Category

    /// User-defined merchant rules win over the generic classifier — an
    /// explicit rule is the user telling us the answer.
    private static func resolveCategory(
        merchant: String?,
        message: String,
        categories: [Category],
        rules: [MerchantRule]
    ) -> Category? {
        let active = categories.filter { !$0.isArchived }
        guard !active.isEmpty else { return nil }

        if let merchant {
            let lowered = merchant.lowercased()
            let userRules = rules.filter { $0.isUserDefined }
            if let hit = userRules.first(where: { lowered.contains($0.pattern) })?.category {
                return hit
            }
            if let hit = rules.first(where: { lowered.contains($0.pattern) })?.category {
                return hit
            }
            if let inferred = CategoryClassifier.classify(merchant, into: active) {
                return inferred
            }
        }
        return CategoryClassifier.classify(message, into: active)
    }

    // MARK: Helpers

    private static var primaryCurrency: String {
        UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
    }

    private static func fallbackAccount(from active: [Account]) -> Account? {
        let stored = UserDefaults.standard.string(forKey: "lastUsedAccountID") ?? ""
        if !stored.isEmpty, let uuid = UUID(uuidString: stored),
           let hit = active.first(where: { $0.id == uuid }) {
            return hit
        }
        return active.first
    }

    private static func sharedAutomationContext() throws -> ModelContext {
        guard let container = RecurringConfirmationHandler.sharedContainer() else {
            throw AutomationError.storeUnavailable
        }
        return ModelContext(container)
    }

    enum AutomationError: Error {
        case storeUnavailable
    }
}
