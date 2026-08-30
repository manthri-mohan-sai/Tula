import Foundation

/// Which way the money moved.
enum TransactionDirection: String, Equatable {
    case debit
    case credit
    /// No direction keyword found. Treated as *not* safe to log — guessing
    /// wrong turns a ₹50,000 salary credit into a ₹50,000 expense.
    case unknown
}

/// A transaction extracted from a bank or card alert.
///
/// Deliberately a plain value type with no SwiftData involvement:
/// `BankMessageParser` is a pure function so it can be exhaustively tested
/// against real message samples without a container.
struct BankTransaction: Equatable {

    /// How much of the message we actually recognised. Drives whether the
    /// result is logged silently or left for review.
    enum Confidence: Int, Comparable {
        /// Amount, direction, and an account or merchant were all found.
        case high = 2
        /// Amount and direction found, but nothing to attribute it to.
        case medium = 1
        /// Amount found, direction ambiguous.
        case low = 0

        static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var amount: Double
    var direction: TransactionDirection
    /// Last four digits of the account or card, when the message carried them.
    var accountLast4: String?
    /// Merchant exactly as the bank wrote it — kept for auditing and for
    /// `rawInput`, since normalisation is lossy.
    var merchantRaw: String?
    /// Cleaned merchant, suitable for display and category matching.
    var merchant: String?
    /// Bank's own transaction reference (UPI ref, UTR, txn id).
    ///
    /// The single most valuable field for deduplication: Indian banks
    /// routinely send the same transaction twice — once from the issuing
    /// bank, once from the card network — and this is the only token that
    /// is reliably identical across both.
    var reference: String?
    /// Date parsed from the message. Nil means "use now" — an alert almost
    /// always arrives within seconds of the transaction.
    var date: Date?
    var currencyCode: String?

    var confidence: Confidence {
        if direction == .unknown { return .low }
        if accountLast4 != nil || merchant != nil { return .high }
        return .medium
    }

    /// Only debits become expenses. Credits (salary, refunds, reversals) and
    /// unknown-direction messages never do.
    var isLoggableExpense: Bool {
        direction == .debit && amount > 0
    }
}
