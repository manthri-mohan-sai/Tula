import Foundation
import SwiftData

// MARK: - Account

/// A place money lives or originates from. Bank accounts, credit cards, cash,
/// wallets — all share this type, differentiated by `kind`.
///
/// Note on currency: `currencyCode` is stored on each account as a forward-
/// compatibility slot. v1 is single-currency (set globally via @AppStorage)
/// and all accounts inherit that on creation. Per-account currencies become
/// useful in v2 if/when we support multi-currency.
@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""                  // User-visible: "HDFC Bank", "Cash", "ICICI CC"
    var kind: AccountKind = AccountKind.bank
    var currencyCode: String = "INR"
    var iconKey: String = "building.columns"
    var colorHex: String = "#4A90E2"
    var isArchived: Bool = false           // Soft-delete: hidden from pickers, data preserved
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    /// Optional credit limit for credit cards. Nil for other account types.
    /// Used to show "₹X of ₹Y used" on the CC tile if set.
    var creditLimit: Double? = nil

    /// Optional opening balance (mainly for cash accounts where the user wants
    /// to track "I have ₹X in my wallet right now"). Defaults to 0.
    var openingBalance: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \Expense.account)
    var expenses: [Expense] = []

    @Relationship(deleteRule: .cascade, inverse: \Transfer.fromAccount)
    var outgoingTransfers: [Transfer] = []

    @Relationship(deleteRule: .cascade, inverse: \Transfer.toAccount)
    var incomingTransfers: [Transfer] = []

    init(name: String, kind: AccountKind, currencyCode: String = "INR",
         iconKey: String = "building.columns", colorHex: String = "#4A90E2",
         openingBalance: Double = 0, creditLimit: Double? = nil, sortOrder: Int = 0) {
        self.name = name
        self.kind = kind
        self.currencyCode = currencyCode
        self.iconKey = iconKey
        self.colorHex = colorHex
        self.openingBalance = openingBalance
        self.creditLimit = creditLimit
        self.sortOrder = sortOrder
    }

    /// Derived balance — different semantics by account kind:
    /// - **Credit card**: outstanding amount (what you owe). Positive = owed.
    ///                    Sum of expenses on this card minus payments received.
    /// - **Bank/Cash/Wallet**: opening balance + incoming transfers
    ///                          - outgoing transfers - expenses paid from here.
    ///                          A spending-flow view, not a true bank balance
    ///                          (since we don't track income in v1).
    var derivedBalance: Double {
        let expenseTotal = expenses.reduce(0) { $0 + $1.amount }
        let outgoing = outgoingTransfers.reduce(0) { $0 + $1.amount }
        let incoming = incomingTransfers.reduce(0) { $0 + $1.amount }

        switch kind {
        case .creditCard:
            return expenseTotal - incoming
        case .bank, .cash, .wallet:
            return openingBalance + incoming - outgoing - expenseTotal
        }
    }
}

enum AccountKind: String, Codable, CaseIterable {
    case bank
    case creditCard
    case cash
    case wallet

    var displayName: String {
        switch self {
        case .bank: return "Bank"
        case .creditCard: return "Credit Card"
        case .cash: return "Cash"
        case .wallet: return "Wallet"
        }
    }

    var defaultIcon: String {
        switch self {
        case .bank: return "building.columns"
        case .creditCard: return "creditcard"
        case .cash: return "banknote"
        case .wallet: return "wallet.pass"
        }
    }
}

// MARK: - Category

@Model
final class Category {
    var id: UUID = UUID()
    var name: String = ""
    var iconKey: String = "questionmark.circle"
    var colorHex: String = "#888888"
    var isArchived: Bool = false
    var sortOrder: Int = 0
    var createdAt: Date = Date()

    @Relationship(deleteRule: .nullify, inverse: \Expense.category)
    var expenses: [Expense] = []

    init(name: String, iconKey: String, colorHex: String, sortOrder: Int = 0) {
        self.name = name
        self.iconKey = iconKey
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

// MARK: - Expense

/// A consumption event. Reduces net worth. Counted in "spent this month".
@Model
final class Expense {
    var id: UUID = UUID()
    var amount: Double = 0
    var date: Date = Date()
    var merchant: String? = nil
    var note: String? = nil
    var createdAt: Date = Date()

    /// The original text the user typed/dictated, if entered via NLP.
    /// Stored for two reasons: (1) re-parsing if NLP improves later,
    /// (2) debugging weird categorizations.
    var rawInput: String? = nil

    var source: ExpenseSource = ExpenseSource.manual

    /// Optional receipt photo attached to this expense. JPEG-compressed
    /// to ~200KB before storage (1600px max dimension, quality 0.7) —
    /// see `ReceiptStorage.compress(_:)`. Nil for the majority of
    /// expenses (typed entries don't have receipts).
    ///
    /// **`.externalStorage` attribute** tells SwiftData to keep this
    /// blob outside the main SQLite store. Fetches of Expense don't load
    /// the image into memory; only when explicitly accessed. This is
    /// SwiftData's "have your cake and eat it" answer to the "store
    /// big blobs alongside small models" problem — backups + CloudKit
    /// sync capture it automatically, but everyday fetches stay fast.
    @Attribute(.externalStorage)
    var receiptImageData: Data? = nil

    var category: Category?
    var account: Account?

    /// If this expense was generated by a recurring rule, link back to it.
    var recurringRule: RecurringRule?

    init(amount: Double, date: Date = .now, merchant: String? = nil,
         note: String? = nil, source: ExpenseSource = .manual,
         category: Category? = nil, account: Account? = nil) {
        self.amount = amount
        self.date = date
        self.merchant = merchant
        self.note = note
        self.source = source
        self.category = category
        self.account = account
    }
}

enum ExpenseSource: String, Codable {
    case manual       // Typed into the form
    case nlp          // Parsed from natural language (rule-based parser)
    case smartParsed  // Parsed by on-device Foundation Models (voice flow)
    case siri         // Via Siri shortcut
    case widget       // Quick-add from widget
    case recurring    // Auto-created by a RecurringRule
}

// MARK: - Transfer

/// Money moving between the user's own accounts. NOT counted as a spend.
/// Examples: ATM withdrawal (Bank → Cash), credit card bill payment
/// (Bank → CC), bank-to-bank transfer.
@Model
final class Transfer {
    var id: UUID = UUID()
    var amount: Double = 0
    var date: Date = Date()
    var note: String? = nil
    var createdAt: Date = Date()

    /// Distinguishes a card bill payment from a generic transfer so the UI
    /// can surface it on the CC's history.
    var kind: TransferKind = TransferKind.generic

    var fromAccount: Account?
    var toAccount: Account?

    var recurringRule: RecurringRule?

    init(amount: Double, fromAccount: Account?, toAccount: Account?,
         date: Date = .now, kind: TransferKind = .generic, note: String? = nil) {
        self.amount = amount
        self.fromAccount = fromAccount
        self.toAccount = toAccount
        self.date = date
        self.kind = kind
        self.note = note
    }
}

enum TransferKind: String, Codable {
    case generic
    case cardBillPayment   // Bank → Credit Card
    case withdrawal        // Bank → Cash (ATM, etc.)
    case deposit           // Cash → Bank
}

// MARK: - Recurring Rule

/// A user-defined schedule that auto-creates expenses or transfers.
/// e.g. "Netflix ₹649 on HDFC CC on the 12th every month."
@Model
final class RecurringRule {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var kind: RecurringKind = RecurringKind.expense

    /// Recurrence frequency (weekly / monthly / yearly). Stored as String
    /// for SwiftData compatibility — use `frequencyEnum` for typed access.
    /// Defaults to monthly to preserve behavior of pre-v2 rules.
    var frequencyRaw: String = RecurringFrequency.monthly.rawValue

    /// Day of month, 1-31, clamped to month length for short months.
    /// Only used when frequency == .monthly.
    var dayOfMonth: Int = 1

    /// Bitmask of weekdays the rule should fire on, when frequency == .weekly.
    /// Bit 0 = Sunday, bit 1 = Monday, ..., bit 6 = Saturday — matching
    /// `Calendar.component(.weekday, from:)` minus one.
    ///
    /// **A mask of 0 means "use startDate's weekday"** — preserves the
    /// original single-weekday behavior for pre-multi-day rules. Any
    /// non-zero mask overrides startDate's weekday: the rule fires on
    /// every day whose bit is set.
    ///
    /// Examples:
    /// - 0           → legacy: same weekday as startDate
    /// - 0b0111110   → weekdays only (Mon-Fri)
    /// - 0b1000001   → weekends only (Sat + Sun)
    /// - 0b1111111   → every day
    var weekdaysMask: Int = 0

    /// For custom recurrence — number of units per cycle. Defaults to 1
    /// so a fresh-default custom rule starts as "every 1 month" before
    /// the user adjusts it. Ignored for non-custom frequencies.
    var customInterval: Int = 1

    /// For custom recurrence — the unit (day/week/month/year). Stored
    /// as String for SwiftData; use `customUnit` for typed access.
    var customUnitRaw: String = CustomIntervalUnit.month.rawValue

    var startDate: Date = Date()
    var endDate: Date? = nil
    var isPaused: Bool = false

    /// When set, the rule is treated as paused only until this date,
    /// then auto-resumes on the next engine run. Used for "snooze
    /// while on vacation" — set `pausedUntil` to the return date, the
    /// engine skips all due-dates before it, then resumes naturally.
    /// nil means indefinite pause (relies on `isPaused`).
    var pausedUntil: Date? = nil

    // For expense rules:
    var category: Category? = nil
    var account: Account? = nil

    // For transfer rules:
    var fromAccount: Account? = nil
    var toAccount: Account? = nil

    var merchant: String? = nil
    var note: String? = nil
    var createdAt: Date = Date()

    /// Last date the rule actually generated a transaction. The dedup key —
    /// when the app launches and walks recurring rules, it generates any
    /// missing transactions for past due dates and updates this field.
    var lastGeneratedDate: Date? = nil

    /// When true, this rule fires at a specific time of day (taken from
    /// `startDate`'s time-of-day component). When false, it's an all-day
    /// rule — due "today" without a specific time. Affects home-screen
    /// display: time-scheduled rules show only the nearest one (since
    /// they have ordering by time), while all-day rules stack together.
    ///
    /// Defaults to false (all-day) for safety — existing rules created
    /// before this field existed silently become general/all-day rules,
    /// which matches the looser intent of pre-this-update behavior.
    var hasSpecificTime: Bool = false

    /// When true, the engine doesn't auto-log this rule's occurrences.
    /// Instead, it sends an interactive notification with "Log it" / "Skip"
    /// actions, so the user can decide per-occurrence. Designed for daily
    /// patterns the user might skip (e.g. mess meals, gym fees on rest days,
    /// commute fare on WFH days).
    ///
    /// Defaults to false to preserve pre-confirmation behavior on existing
    /// rules — they keep auto-logging exactly as before.
    var confirmationRequired: Bool = false

    /// When true, the amount on this rule is a reference only — the actual
    /// amount varies each period (e.g. power bills, fuel). The rule always
    /// uses confirmation mode: it reminds the user and opens the log form
    /// with merchant + category pre-filled but amount empty, showing the
    /// last/average amount as a hint. Fixed-amount rules (false) can
    /// auto-log the exact amount.
    var isVariable: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \Expense.recurringRule)
    var generatedExpenses: [Expense] = []

    @Relationship(deleteRule: .nullify, inverse: \Transfer.recurringRule)
    var generatedTransfers: [Transfer] = []

    init(name: String, amount: Double, kind: RecurringKind, dayOfMonth: Int,
         frequency: RecurringFrequency = .monthly,
         startDate: Date = .now) {
        self.name = name
        self.amount = amount
        self.kind = kind
        self.dayOfMonth = dayOfMonth
        self.frequencyRaw = frequency.rawValue
        self.startDate = startDate
    }

    /// Typed access to the frequency. Falls back to `.monthly` for legacy
    /// rules that predate the field.
    var frequency: RecurringFrequency {
        get { RecurringFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    /// Typed access to the custom interval unit. Only meaningful when
    /// frequency == .custom; safe to read otherwise (just returns month).
    var customUnit: CustomIntervalUnit {
        get { CustomIntervalUnit(rawValue: customUnitRaw) ?? .month }
        set { customUnitRaw = newValue.rawValue }
    }

    /// The set of weekdays this rule should fire on, derived from
    /// `weekdaysMask`. Uses Calendar's 1-7 convention (1 = Sunday).
    /// Empty set means "use startDate's weekday" (legacy single-day mode).
    var weekdaysSet: Set<Int> {
        get {
            guard weekdaysMask != 0 else { return [] }
            var result: Set<Int> = []
            for i in 0..<7 where (weekdaysMask & (1 << i)) != 0 {
                result.insert(i + 1)   // 1-indexed (Sun=1)
            }
            return result
        }
        set {
            weekdaysMask = newValue.reduce(0) { acc, weekday in
                acc | (1 << (weekday - 1))
            }
        }
    }

    /// Human-readable description of the cadence. Used in row subtitles.
    var cadenceLabel: String {
        switch frequency {
        case .weekly:
            // If multi-day mask is set, describe the days. Otherwise just
            // say "every week" — same as before for legacy rules.
            return weekdaysSummary ?? frequency.shortDescription
        case .monthly, .yearly:
            return frequency.shortDescription
        case .custom:
            return "every \(customInterval) \(customUnit.label(for: customInterval))"
        }
    }

    /// Compact description of weekday selection — "Weekdays", "Weekends",
    /// "Every day", or "Mon, Wed, Fri". Nil when no multi-day mask is set
    /// (caller should fall back to single-day description).
    var weekdaysSummary: String? {
        let days = weekdaysSet
        guard !days.isEmpty else { return nil }
        if days == Set(1...7) { return "every day" }
        if days == [2, 3, 4, 5, 6] { return "weekdays" }
        if days == [1, 7] { return "weekends" }
        // List form: "Mon, Wed, Fri". Order Sun→Sat for consistency.
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed",
                     5: "Thu", 6: "Fri", 7: "Sat"]
        return days.sorted().compactMap { names[$0] }.joined(separator: ", ")
    }
}

enum RecurringKind: String, Codable {
    case expense
    case transfer
    case cardPayment   // Specifically a card bill payment transfer
}

/// How often a recurring rule fires.
/// - **weekly**: fires on the same weekday as `startDate`
/// - **monthly**: fires on `dayOfMonth` each month
/// - **yearly**: fires on the same month + day as `startDate`
/// - **custom**: fires every N units (days/weeks/months/years) from
///   `startDate` — interval/unit live on `RecurringRule`
enum RecurringFrequency: String, Codable, CaseIterable, Identifiable {
    case weekly
    case monthly
    case yearly
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        case .custom:  return "Custom"
        }
    }

    var shortDescription: String {
        switch self {
        case .weekly:  return "every week"
        case .monthly: return "every month"
        case .yearly:  return "every year"
        case .custom:  return "custom"
        }
    }
}

/// Unit for a custom recurring interval. Stored as String on RecurringRule
/// for SwiftData compatibility; the typed `CustomInterval` enum wraps it.
enum CustomIntervalUnit: String, Codable, CaseIterable, Identifiable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    /// Singular/plural-aware label for "Every N <unit>".
    func label(for count: Int) -> String {
        switch self {
        case .day:   return count == 1 ? "day" : "days"
        case .week:  return count == 1 ? "week" : "weeks"
        case .month: return count == 1 ? "month" : "months"
        case .year:  return count == 1 ? "year" : "years"
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        }
    }
}

// MARK: - Merchant Rule

/// Maps merchant substring → category, so the app can auto-categorize.
/// Shipped with sensible defaults (Swiggy → Food, Uber → Transport, etc.)
/// and grows as the user logs new merchants.
@Model
final class MerchantRule {
    var id: UUID = UUID()
    var pattern: String = ""           // Lowercased substring. "swiggy", "zomato"
    var category: Category?
    var account: Account?              // Optional default account for this merchant
    var createdAt: Date = Date()

    /// User-defined rules outrank default-shipped ones when both match.
    var isUserDefined: Bool = false

    init(pattern: String, category: Category?, account: Account? = nil,
         isUserDefined: Bool = false) {
        self.pattern = pattern.lowercased()
        self.category = category
        self.account = account
        self.isUserDefined = isUserDefined
    }
}
