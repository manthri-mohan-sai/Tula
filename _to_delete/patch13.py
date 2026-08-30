#!/usr/bin/env python3
"""Fix: duplicate detection searched the wrong time field.

`fetchExpenses(since:)` filtered on `Expense.date` — when the *purchase*
happened, taken from the alert — while the window was anchored on `now`. An
IndusInd alert stamped 17:45 arriving again at 19:15 was searched for in
18:45→now, so the row that should have matched sat before the window and was
never seen. ICICI is worse: no clock time in the message means noon, so any
run after 12:30 could never find it.

"Did I already write this row?" is a question about `createdAt`, not `date`.

Also tightens the fallback: when both sides carry a merchant and they differ,
it is not a duplicate. Two genuine ₹120 coffees on one card an hour apart were
previously collapsed into one.
"""
import sys, pathlib

PATH = pathlib.Path.home() / "mnt" / "Tula" / "Tula" / "Automation" / "LogTransactionIntent.swift"
text = PATH.read_text()


def replace(label, old, new):
    global text
    n = text.count(old)
    if n != 1:
        print(f"FAIL [{label}]: expected 1 match, found {n}")
        sys.exit(1)
    text = text.replace(old, new)
    print(f"OK   {label}")


replace(
    "duplicate detection on createdAt",
    """    private static func isDuplicate(
        _ transaction: BankTransaction,
        in context: ModelContext,
        now: Date
    ) -> Bool {
        if let reference = transaction.reference {
            let since = now.addingTimeInterval(-referenceLookback)
            let recent = fetchExpenses(since: since, in: context)
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

        let since = now.addingTimeInterval(-duplicateWindow)
        let recent = fetchExpenses(since: since, in: context)
        return recent.contains { expense in
            guard abs(expense.amount - transaction.amount) < 0.01 else { return false }
            guard expense.source == .automation else { return false }
            guard let last4 = transaction.accountLast4 else { return true }
            guard let digits = expense.account?.last4Digits else { return true }
            return digits.suffix(4) == last4
        }
    }""",
    """    private static func isDuplicate(
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
    }""",
)

replace(
    "fetch by createdAt",
    """    private static func fetchExpenses(since: Date, in context: ModelContext) -> [Expense] {
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= since }
        )
        return (try? context.fetch(descriptor)) ?? []
    }""",
    """    /// Rows written in the last `window`, by `createdAt`.
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
    }""",
)

PATH.write_text(text)
print("patch13 complete")
