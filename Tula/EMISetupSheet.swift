//
//  EMISetupSheet.swift
//  Tula
//
//  Basic EMI setup. Collects total + tenure (+ optional interest), then creates
//  a finite monthly recurring rule via EMIPlanner. Balance-correct: installments
//  are generated on their due dates by the recurring engine, not upfront.
//

import SwiftUI
import SwiftData

struct EMISetupSheet: View {
    let accounts: [Account]
    let categories: [Category]
    var initialAmount: Double = 0
    var initialDescription: String = ""
    var initialCategory: Category? = nil
    var initialAccount: Account? = nil
    var currencyCode: String = "INR"
    var onCreated: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionText = ""
    @State private var totalText = ""
    @State private var months = 3
    @State private var hasInterest = false
    @State private var interestText = ""
    @State private var processingFeeText = ""
    @State private var firstDate = Date()
    @State private var category: Category?
    @State private var account: Account?

    private var total: Double { Double(totalText) ?? 0 }
    private var interest: Double { hasInterest ? (Double(interestText) ?? 0) : 0 }
    private var processingFee: Double { Double(processingFeeText) ?? 0 }
    private var perMonth: Double {
        EMIPlanner.installmentAmount(total: total, interest: interest, months: months)
    }
    private var isValid: Bool { total > 0 && months >= 2 && account != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Purchase") {
                    TextField("Description (e.g. Car Insurance)", text: $descriptionText)
                    TextField("Total amount", text: $totalText)
                        .keyboardType(.decimalPad)
                }

                Section("Plan") {
                    Stepper("Tenure: \(months) months", value: $months, in: 2...36)
                    DatePicker("First payment",
                               selection: $firstDate,
                               displayedComponents: .date)
                    Toggle("Add interest", isOn: $hasInterest)
                    if hasInterest {
                        TextField("Total interest over tenure", text: $interestText)
                            .keyboardType(.decimalPad)
                    }
                    TextField("Processing fee (one-time)", text: $processingFeeText)
                        .keyboardType(.decimalPad)
                }

                Section("Category & Account") {
                    Picker("Category", selection: $category) {
                        Text("None").tag(Category?.none)
                        ForEach(categories) { cat in
                            Text(cat.name).tag(Category?.some(cat))
                        }
                    }
                    Picker("Account", selection: $account) {
                        Text("Select").tag(Account?.none)
                        ForEach(accounts) { acc in
                            Text(acc.name).tag(Account?.some(acc))
                        }
                    }
                    if account?.kind == .creditCard {
                        Text("On a credit card the full amount is billed now, but "
                             + "Tula tracks the EMI as a monthly spend so your "
                             + "cash-flow stays accurate. Log your card bill "
                             + "payment separately as a transfer.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isValid {
                    Section {
                        Text("\(months) monthly payments of "
                             + "\(Currency.format(perMonth, code: currencyCode)) "
                             + "starting \(firstDate.formatted(date: .abbreviated, time: .omitted))."
                             + (processingFee > 0
                                ? " Plus a one-time \(Currency.format(processingFee, code: currencyCode)) processing fee."
                                : ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text("Each payment is logged automatically on its due "
                             + "date, so your balance updates month by month.")
                    }
                }
            }
            .navigationTitle("Split into EMI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!isValid)
                }
            }
            .onAppear {
                if initialAmount > 0, totalText.isEmpty {
                    totalText = String(format: "%.0f", initialAmount)
                }
                if descriptionText.isEmpty { descriptionText = initialDescription }
                if category == nil { category = initialCategory }
                if account == nil { account = initialAccount ?? accounts.first }
            }
        }
    }

    private func create() {
        EMIPlanner.createPlan(
            EMIPlanner.Input(
                description: descriptionText,
                totalAmount: total,
                months: months,
                interestAmount: interest,
                processingFee: processingFee,
                firstPaymentDate: firstDate,
                category: category,
                account: account
            ),
            in: context
        )
        Haptics.success()
        onCreated()
        dismiss()
    }
}
