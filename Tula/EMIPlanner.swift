//
//  EMIPlanner.swift
//  Tula
//
//  Basic EMI / installment support. An EMI is modelled as a FINITE monthly
//  RecurringRule: the recurring engine generates one expense per month on its
//  due date (so account balances stay correct — a future installment doesn't
//  reduce your balance today) and stops after the tenure via `endDate`.
//
//  This reuses the tested recurring machinery and needs no schema migration.
//  "Paid X of N" is derivable from rule.generatedExpenses.count vs the tenure.
//

import Foundation
import SwiftData

enum EMIPlanner {

    /// Inputs for a basic EMI plan.
    struct Input {
        var description: String        // e.g. "Car Insurance"
        var totalAmount: Double        // principal (what the item cost)
        var months: Int                // tenure, >= 2
        var interestAmount: Double     // total extra cost over the tenure (0 = no-cost EMI)
        var processingFee: Double = 0  // one-time upfront fee (charged once, not spread)
        var firstPaymentDate: Date
        var category: Category?
        var account: Account?
    }

    /// Per-month installment = (principal + total interest) / months, to 2dp.
    /// A small rounding remainder is acceptable for the basic version.
    static func installmentAmount(total: Double, interest: Double, months: Int) -> Double {
        guard months > 0 else { return total + interest }
        return (((total + interest) / Double(months)) * 100).rounded() / 100
    }

    /// Number of installments implied by a plan's date range (inclusive).
    /// Used to show "paid X of N".
    static func installmentCount(startDate: Date, endDate: Date?) -> Int {
        guard let endDate else { return 0 }
        let months = Calendar.current.dateComponents([.month], from: startDate, to: endDate).month ?? 0
        return max(months + 1, 1)
    }

    /// Create and insert a finite monthly recurring rule for the EMI plan.
    @discardableResult
    static func createPlan(_ input: Input, in context: ModelContext) -> RecurringRule {
        let months = max(input.months, 1)
        let perMonth = installmentAmount(
            total: input.totalAmount, interest: input.interestAmount, months: months)

        let calendar = Calendar.current
        // Normalize to start-of-day so occurrences fire at 00:00 — a "due today"
        // installment is then always <= now regardless of the current time.
        let firstDay = calendar.startOfDay(for: input.firstPaymentDate)
        // Anchor the rule one day BEFORE the first payment. The engine generates
        // occurrences strictly after its start date, so this makes the first
        // payment date itself the first generated installment (fixing "created
        // it but nothing shows"). Works for both today and future first dates.
        let anchor = calendar.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay
        // Last installment lands (months - 1) months after the first; +1 day
        // buffer so it isn't dropped at the endDate boundary.
        let lastDate = calendar.date(byAdding: .month, value: months - 1, to: firstDay) ?? firstDay
        let end = calendar.date(byAdding: .day, value: 1, to: lastDate) ?? lastDate

        let name = input.description.trimmingCharacters(in: .whitespaces)
        let rule = RecurringRule(
            name: name.isEmpty ? "EMI" : name,
            amount: perMonth,
            kind: .expense,
            dayOfMonth: calendar.component(.day, from: firstDay),
            frequency: .monthly,
            startDate: anchor
        )
        rule.endDate = end
        rule.category = input.category
        rule.account = input.account
        rule.merchant = name.isEmpty ? nil : name
        rule.note = "EMI · \(months) months"
        rule.isEMI = true
        rule.installmentTotal = months
        context.insert(rule)

        // Generate every installment already due (first date on/before now)
        // RIGHT HERE, rather than relying on the engine's walk — guarantees the
        // installment shows in the transaction list immediately. lastGeneratedDate
        // is advanced so the engine continues from the next month with no dupes.
        var due = firstDay
        let now = Date()
        while due <= now {
            RecurringEngine.createTransaction(rule: rule, date: due, in: context)
            rule.lastGeneratedDate = due
            guard let next = calendar.date(byAdding: .month, value: 1, to: due) else { break }
            due = next
        }

        // One-time processing fee (charged once, not spread across installments).
        if input.processingFee > 0 {
            let feeLabel = name.isEmpty ? "Processing fee" : "\(name) — processing fee"
            let fee = Expense(
                amount: input.processingFee,
                date: firstDay,
                merchant: feeLabel,
                note: "EMI processing fee",
                source: .manual,
                category: input.category,
                account: input.account
            )
            context.insert(fee)
        }

        return rule
    }
}
