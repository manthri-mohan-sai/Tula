#!/usr/bin/env python3
"""Route bank alerts away from the free-text parser automatically.

Pointing a Shortcuts automation at "Log Expense" instead of "Log Bank
Transaction" is an easy mistake and the result is silent garbage:
`ExpenseInterpreter` segments multi-amount text, so one ICICI alert became
five expenses — 4,998.00 split into ₹4 and ₹998, the 2,11,305.23 available
limit into ₹11 and ₹305.23, and a helpline number into ₹1,800 — each with a
residue token for a merchant ("Call /Sms Bloc", "If Not You").

The user should not have to know which action to pick. `LogExpenseIntent` now
detects machine-shaped input and hands it to the transaction parser.
"""
import sys, pathlib

ROOT = pathlib.Path.home() / "mnt" / "Tula" / "Tula"

def patch(relpath, replacements):
    path = ROOT / relpath
    text = path.read_text()
    for label, old, new in replacements:
        n = text.count(old)
        if n != 1:
            print(f"FAIL [{relpath}] {label}: expected 1 match, found {n}")
            sys.exit(1)
        text = text.replace(old, new)
    path.write_text(text)
    print(f"OK   {relpath}  ({len(replacements)} edits)")


# ── 1. Detection helper on TransactionLogger ──
patch("Automation/LogTransactionIntent.swift", [(
    "logIfBankAlert",
    """    // MARK: Entry

    static func log(message: String, now: Date = .now) -> Outcome {""",
    """    // MARK: Entry

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

    static func log(message: String, now: Date = .now) -> Outcome {""",
)])


# ── 2. Delegate from LogExpenseIntent ──
patch("LogExpenseIntent.swift", [(
    "bank alert delegation",
    """    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = try sharedModelContext()

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []""",
    """    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // A bank or card alert routed here by mistake produces silent garbage:
        // the interpreter segments multi-amount text, so one alert becomes an
        // expense per number it finds — including the available balance and
        // the dispute helpline — each labelled with a residue token. Detect
        // machine-shaped input and hand it to the transaction parser rather
        // than depending on the right Shortcuts action being chosen.
        if let outcome = TransactionLogger.logIfBankAlert(message: expenseDescription) {
            return .result(dialog: IntentDialog(stringLiteral: outcome.spoken))
        }

        let context = try sharedModelContext()

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []""",
)])

print("patch12 complete")
