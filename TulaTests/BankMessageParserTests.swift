import Foundation
import Testing
@testable import Tula

/// Cover for the bank-alert parser.
///
/// The samples below are representative of the *shapes* Indian bank and card
/// alerts take, not transcriptions of one issuer's format. The parser is
/// structure-driven for exactly that reason, and these cases pin the
/// structural invariants: currency-marked amount, direction verb, masked
/// account digits, merchant after a preposition, reference token.
///
/// When a real message fails in the wild, paste it in as a new case first —
/// the failing test is the specification.
@Suite("Bank message parsing")
struct BankMessageParserTests {

    // MARK: - Amount

    @Test("extracts a decimal amount with thousands separators")
    func amountWithSeparators() {
        let sms = "INR 1,299.00 spent on HDFC Bank Card x5678 at AMAZON on 25-08-26"
        let result = BankMessageParser.parse(sms)
        #expect(result?.amount == 1299.00)
    }

    @Test("handles Rs, INR and the rupee sign")
    func currencyMarkers() {
        #expect(BankMessageParser.parse("Rs.450.00 debited from A/c XX1234")?.amount == 450)
        #expect(BankMessageParser.parse("INR 450 debited from A/c XX1234")?.amount == 450)
        #expect(BankMessageParser.parse("₹450 debited from A/c XX1234")?.amount == 450)
    }

    /// The single most damaging failure available to this parser: nearly every
    /// alert ends with a balance, and logging it as a purchase is silently
    /// catastrophic.
    @Test("never mistakes the closing balance for the transaction")
    func ignoresBalance() {
        let sms = "Rs.450.00 debited from A/c XX1234 to SWIGGY. Avl Bal Rs.12,345.67"
        let result = BankMessageParser.parse(sms)
        #expect(result?.amount == 450)
    }

    @Test("ignores available limit on card alerts")
    func ignoresLimit() {
        let sms = "INR 2,500 spent on Card xx9012 at UBER. Available limit INR 47,500"
        #expect(BankMessageParser.parse(sms)?.amount == 2500)
    }

    @Test("returns nil when there is no amount at all")
    func noAmount() {
        #expect(BankMessageParser.parse("Your OTP is 445566. Do not share.") == nil)
    }

    // MARK: - Direction

    @Test("recognises debits")
    func debitDirection() {
        let words = ["debited", "spent", "withdrawn", "paid", "deducted"]
        for word in words {
            let sms = "Rs.100 \(word) from A/c XX1234"
            #expect(BankMessageParser.parse(sms)?.direction == .debit, "failed on \(word)")
        }
    }

    @Test("recognises credits")
    func creditDirection() {
        let words = ["credited", "received", "refunded", "reversed"]
        for word in words {
            let sms = "Rs.100 \(word) to A/c XX1234"
            #expect(BankMessageParser.parse(sms)?.direction == .credit, "failed on \(word)")
        }
    }

    /// UPI alerts routinely contain both verbs. The leading one describes what
    /// happened to the user's money.
    @Test("takes the first direction verb when a message contains both")
    func mixedDirectionPrefersFirst() {
        let sms = "Rs.250 debited from your A/c XX1234 and credited to merchant@ybl"
        #expect(BankMessageParser.parse(sms)?.direction == .debit)
    }

    @Test("a salary credit is never a loggable expense")
    func salaryCreditNotLoggable() {
        let sms = "Your A/c XX1234 is credited with Rs.50,000.00 on 01-09-26 by SALARY"
        let result = BankMessageParser.parse(sms)
        #expect(result?.direction == .credit)
        #expect(result?.isLoggableExpense == false)
    }

    @Test("an unknown direction is not loggable")
    func unknownDirectionNotLoggable() {
        let sms = "Transaction of Rs.500 on card xx1234 at STORE"
        let result = BankMessageParser.parse(sms)
        #expect(result?.direction == .unknown)
        #expect(result?.isLoggableExpense == false)
        #expect(result?.confidence == .low)
    }

    // MARK: - Account

    @Test("extracts masked account digits in common shapes")
    func accountDigits() {
        #expect(BankMessageParser.parse("Rs.10 debited from A/c XX1234")?.accountLast4 == "1234")
        #expect(BankMessageParser.parse("Rs.10 spent on Card xx5678 at X")?.accountLast4 == "5678")
        #expect(BankMessageParser.parse("Rs.10 debited, card ending 9012")?.accountLast4 == "9012")
        #expect(BankMessageParser.parse("Rs.10 debited from a/c no. XXXXXX4321")?.accountLast4 == "4321")
    }

    // MARK: - Merchant

    @Test("extracts the merchant after a preposition")
    func merchantAfterPreposition() {
        #expect(BankMessageParser.parse("Rs.450 spent at SWIGGY on 25-08-26")?.merchant == "Swiggy")
        #expect(BankMessageParser.parse("Rs.450 debited to ZOMATO.")?.merchant == "Zomato")
    }

    @Test("strips aggregator prefixes and location noise")
    func merchantNormalisation() {
        #expect(BankMessageParser.normalizeMerchant("PAYTM*UBER") == "Uber")
        #expect(BankMessageParser.normalizeMerchant("SWIGGY BANGALORE IND") == "Swiggy")
        #expect(BankMessageParser.normalizeMerchant("zomato@ybl") == "Zomato")
        #expect(BankMessageParser.normalizeMerchant("AMZN Mktp IN") == "Amzn Mktp")
    }

    @Test("does not treat grammar as a merchant")
    func rejectsStopWords() {
        let sms = "Rs.450 debited from your account for the transaction"
        let merchant = BankMessageParser.parse(sms)?.merchant
        #expect(merchant == nil)
    }

    @Test("extracts a UPI payee handle")
    func upiHandle() {
        let sms = "Rs.250 debited from A/c XX1234 VPA merchantname@okhdfcbank"
        #expect(BankMessageParser.parse(sms)?.merchant == "Merchantname")
    }

    // MARK: - Reference

    @Test("extracts UPI, UTR and txn references")
    func references() {
        #expect(BankMessageParser.parse("Rs.10 debited. UPI Ref 123456789012")?.reference == "123456789012")
        #expect(BankMessageParser.parse("Rs.10 debited. Ref No: ABC123456")?.reference == "ABC123456")
        #expect(BankMessageParser.parse("Rs.10 debited. UTR 987654321098")?.reference == "987654321098")
    }

    /// Regression. An earlier version also matched any bare 12-digit run,
    /// which latched onto the dispute helpline number printed in every alert
    /// from a given bank. Two unrelated purchases then shared a "reference"
    /// and the second was silently discarded as a duplicate — real spending
    /// vanishing with no error, the worst failure this feature can have.
    @Test("a helpline number is never mistaken for a reference")
    func helplineIsNotAReference() {
        let a = "INR 250.00 spent on Card XX1111 at CAFE. Call 180012345678 to dispute"
        let b = "INR 999.00 spent on Card XX1111 at SHOP. Call 180012345678 to dispute"

        #expect(BankMessageParser.parse(a)?.reference == nil)
        #expect(BankMessageParser.parse(b)?.reference == nil)
    }

    @Test("the same transaction from two senders yields the same reference")
    func referenceStableAcrossSenders() {
        // This is what makes deduplication work: the bank and the card network
        // word the alert differently but carry one shared reference.
        let bank = "Rs.450.00 debited from A/c XX1234 to SWIGGY. UPI Ref 556677889900"
        let network = "INR 450 spent on Card xx1234 at SWIGGY BANGALORE. Ref No 556677889900"
        let a = BankMessageParser.parse(bank)?.reference
        let b = BankMessageParser.parse(network)?.reference
        #expect(a != nil)
        #expect(a == b)
    }

    // MARK: - Date

    @Test("parses numeric and alphabetic dates")
    func dates() {
        let calendar = Calendar.current
        let numeric = BankMessageParser.parse("Rs.10 debited on 25-08-26 at X")?.date
        let alpha = BankMessageParser.parse("Rs.10 debited on 25-Aug-2026 at X")?.date
        #expect(numeric != nil)
        #expect(alpha != nil)
        if let numeric, let alpha {
            #expect(calendar.isDate(numeric, inSameDayAs: alpha))
        }
    }

    /// A misread date must not file the expense in the future — falling back
    /// to "now" is always safer, since an alert arrives within seconds of the
    /// transaction anyway.
    @Test("rejects a date in the future")
    func rejectsFutureDate() {
        let sms = "Rs.10 debited on 25-08-99 at X"
        #expect(BankMessageParser.parse(sms)?.date == nil)
    }

    @Test("keeps the clock time from the alert")
    func extractsTimeOfDay() {
        // Flattening every transaction to noon starves UserLearningEngine's
        // hour-of-day category model.
        let calendar = Calendar.current

        let pm = BankMessageParser.parse(
            "INR 605.95 spent on Card XX9068 on 28-08-2026 05:45:54 pm at ABHIBUS"
        )?.date
        #expect(pm.map { calendar.component(.hour, from: $0) } == 17)
        #expect(pm.map { calendar.component(.minute, from: $0) } == 45)

        let twentyFour = BankMessageParser.parse(
            "INR 300 spent on Card XX2222 on 28-08-2026 17:45 at METRO"
        )?.date
        #expect(twentyFour.map { calendar.component(.hour, from: $0) } == 17)

        let midnight = BankMessageParser.parse(
            "INR 300 spent on Card XX2222 on 28-08-2026 12:15:00 am at DINER"
        )?.date
        #expect(midnight.map { calendar.component(.hour, from: $0) } == 0)
    }

    @Test("falls back to noon when no clock time is present")
    func noonWhenTimeAbsent() {
        let date = BankMessageParser.parse("Rs.10 debited on 25-08-26 at X")?.date
        #expect(date.map { Calendar.current.component(.hour, from: $0) } == 12)
    }

    /// Regression: without `\b`, the `ac` alternative matched inside
    /// "transaction", "account" and "contact".
    @Test("account keywords require word boundaries")
    func accountKeywordBoundaries() {
        let sms = "Rs.100.00 debited for transaction 4321 at STORE"
        #expect(BankMessageParser.parse(sms)?.accountLast4 == nil)
    }

    // MARK: - Confidence

    @Test("confidence reflects how much was recognised")
    func confidenceLevels() {
        let full = BankMessageParser.parse("Rs.450 debited from A/c XX1234 to SWIGGY")
        #expect(full?.confidence == .high)

        let bare = BankMessageParser.parse("Rs.450 debited")
        #expect(bare?.confidence == .medium)

        let vague = BankMessageParser.parse("Transaction Rs.450")
        #expect(vague?.confidence == .low)
    }

    // MARK: - End to end

    @Test("parses a full UPI debit alert")
    func fullUpiAlert() {
        let sms = """
        Dear Customer, Rs.450.00 has been debited from your A/c XX1234 on \
        25-08-26 to SWIGGY. UPI Ref 556677889900. Avl Bal Rs.24,550.10
        """
        let result = BankMessageParser.parse(sms)

        #expect(result?.amount == 450)
        #expect(result?.direction == .debit)
        #expect(result?.accountLast4 == "1234")
        #expect(result?.merchant == "Swiggy")
        #expect(result?.reference == "556677889900")
        #expect(result?.isLoggableExpense == true)
        #expect(result?.confidence == .high)
    }

    @Test("parses a full card purchase alert")
    func fullCardAlert() {
        let sms = """
        INR 1,299.00 spent on HDFC Bank Card x5678 at AMZN Mktp IN on \
        25-08-26. Available limit INR 48,701. Not you? Call 18002586161
        """
        let result = BankMessageParser.parse(sms)

        #expect(result?.amount == 1299)
        #expect(result?.direction == .debit)
        #expect(result?.accountLast4 == "5678")
        #expect(result?.isLoggableExpense == true)
    }
}

@Suite("Account matching")
struct AccountMatcherTests {

    private func account(_ name: String, last4: String?) -> Account {
        let account = Account(name: name, kind: .creditCard)
        account.last4Digits = last4
        return account
    }

    @Test("exact masked digits win outright")
    func exactDigits() {
        let hdfc = account("HDFC Credit Card", last4: "5678")
        let icici = account("ICICI Savings", last4: "1234")

        let match = AccountMatcher.match(
            accounts: [hdfc, icici], last4: "5678", hint: "spent on card x5678"
        )

        #expect(match.account === hdfc)
        #expect(match.isConfident)
    }

    @Test("falls back to name words when digits are absent")
    func nameFallback() {
        let hdfc = account("HDFC Credit Card", last4: nil)
        let icici = account("ICICI Savings", last4: nil)

        let match = AccountMatcher.match(
            accounts: [hdfc, icici], last4: nil, hint: "INR 500 spent on HDFC Bank Card"
        )

        #expect(match.account === hdfc)
        #expect(!match.isConfident)
    }

    @Test("generic words alone never produce a match")
    func genericWordsIgnored() {
        let a = account("My Bank Card", last4: nil)
        let b = account("Savings Account", last4: nil)

        let match = AccountMatcher.match(
            accounts: [a, b], last4: nil, hint: "debited from your bank account card"
        )

        #expect(match == .none)
    }

    @Test("archived accounts are never matched")
    func archivedExcluded() {
        let old = account("HDFC Credit Card", last4: "5678")
        old.isArchived = true

        let match = AccountMatcher.match(accounts: [old], last4: "5678", hint: nil)

        #expect(match == .none)
    }

    @Test("no accounts yields no match")
    func emptyAccounts() {
        #expect(AccountMatcher.match(accounts: [], last4: "1234", hint: "x") == .none)
    }
}
