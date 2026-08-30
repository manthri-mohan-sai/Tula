import Foundation
import Testing
@testable import Tula

/// Cover for the duplicate-detection rules.
///
/// The window itself (`createdAt`, not `date`) is a fetch concern and is
/// exercised by using the app; what is testable in isolation — and what got
/// the semantics wrong once already — is the comparison that decides whether
/// two rows describe the same purchase.
@MainActor
@Suite("Transaction deduplication")
struct TransactionDedupeTests {

    private func account(last4: String?) -> Account {
        let account = Account(name: "Test Card", kind: .creditCard)
        account.last4Digits = last4
        return account
    }

    private func existing(
        amount: Double,
        merchant: String? = nil,
        last4: String? = "9068",
        source: ExpenseSource = .automation
    ) -> Expense {
        Expense(
            amount: amount,
            merchant: merchant,
            source: source,
            account: account(last4: last4)
        )
    }

    private func incoming(
        amount: Double,
        merchant: String? = nil,
        last4: String? = "9068"
    ) -> BankTransaction {
        BankTransaction(
            amount: amount,
            direction: .debit,
            accountLast4: last4,
            merchantRaw: merchant,
            merchant: merchant,
            reference: nil,
            date: nil,
            currencyCode: "INR"
        )
    }

    // MARK: - Matches

    @Test("same amount, same card, same merchant is a duplicate")
    func straightforwardDuplicate() {
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 605.95, merchant: "Abhibus"),
            as: existing(amount: 605.95, merchant: "Abhibus")
        ))
    }

    /// The issuing bank and the card network word the same purchase
    /// differently, and one of them frequently omits the payee. A missing
    /// merchant on either side must not defeat the match.
    @Test("a missing merchant on one side still matches")
    func merchantAbsentOnOneSide() {
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 605.95, merchant: "Abhibus"),
            as: existing(amount: 605.95, merchant: nil)
        ))
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 605.95, merchant: nil),
            as: existing(amount: 605.95, merchant: "Abhibus")
        ))
    }

    @Test("a missing card number on either side still matches")
    func last4AbsentOnOneSide() {
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 100, last4: nil),
            as: existing(amount: 100, last4: "9068")
        ))
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 100, last4: "9068"),
            as: existing(amount: 100, last4: nil)
        ))
    }

    // MARK: - Does not match

    @Test("a different amount is never a duplicate")
    func differentAmount() {
        #expect(!TransactionLogger.isSameTransaction(
            incoming(amount: 605.95),
            as: existing(amount: 604.95)
        ))
    }

    @Test("a different card is never a duplicate")
    func differentCard() {
        #expect(!TransactionLogger.isSameTransaction(
            incoming(amount: 100, last4: "9068"),
            as: existing(amount: 100, last4: "8009")
        ))
    }

    /// Two genuine purchases that happen to cost the same, close together on
    /// one card — a coffee and a bus fare both at ₹120. Collapsing these
    /// silently loses real spending.
    @Test("same amount but a different merchant is not a duplicate")
    func sameAmountDifferentMerchant() {
        #expect(!TransactionLogger.isSameTransaction(
            incoming(amount: 120, merchant: "Abhibus"),
            as: existing(amount: 120, merchant: "Starbucks")
        ))
    }

    /// Manual entries are outside this mechanism entirely: an automation
    /// alert must never be suppressed because the user had already typed the
    /// same amount in themselves.
    @Test("a manually entered expense never suppresses an alert")
    func manualEntryIgnored() {
        #expect(!TransactionLogger.isSameTransaction(
            incoming(amount: 605.95, merchant: "Abhibus"),
            as: existing(amount: 605.95, merchant: "Abhibus", source: .manual)
        ))
    }

    @Test("a Siri free-text entry never suppresses an alert")
    func siriEntryIgnored() {
        #expect(!TransactionLogger.isSameTransaction(
            incoming(amount: 605.95),
            as: existing(amount: 605.95, source: .siri)
        ))
    }

    // MARK: - Merchant comparison is case-insensitive

    @Test("merchant comparison ignores case")
    func merchantCaseInsensitive() {
        #expect(TransactionLogger.isSameTransaction(
            incoming(amount: 100, merchant: "Abhibus"),
            as: existing(amount: 100, merchant: "ABHIBUS")
        ))
    }
}
