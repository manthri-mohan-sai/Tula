import SwiftUI
import SwiftData

/// One form for all transfer types. Caller can pre-configure with:
/// - `presetKind`: e.g. .cardBillPayment for the "Pay Bill" entry point
/// - `presetFromAccount` / `presetToAccount`: lock one or both sides
/// - `presetAmount`: pre-fill amount (e.g. outstanding balance)
///
/// Auto-infers kind from from/to account types if not specified:
///   Bank → CC      = cardBillPayment
///   Bank → Cash    = withdrawal
///   Cash → Bank    = deposit
///   anything else  = generic
struct TransferFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]

    let presetKind: TransferKind?
    let presetFromAccount: Account?
    let presetToAccount: Account?
    let presetAmount: Double

    @State private var amount: Double
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var showingDate = false

    @FocusState private var amountFocused: Bool

    init(presetKind: TransferKind? = nil,
         presetFromAccount: Account? = nil,
         presetToAccount: Account? = nil,
         presetAmount: Double = 0) {
        self.presetKind = presetKind
        self.presetFromAccount = presetFromAccount
        self.presetToAccount = presetToAccount
        self.presetAmount = presetAmount
        _amount = State(initialValue: presetAmount)
        _fromAccount = State(initialValue: presetFromAccount)
        _toAccount = State(initialValue: presetToAccount)
    }

    private var activeAccounts: [Account] {
        allAccounts.filter { !$0.isArchived }
    }

    private var fromOptions: [Account] {
        // For Pay Bill, source must be a bank account (CC paying CC is not a thing)
        if presetKind == .cardBillPayment {
            return activeAccounts.filter { $0.kind == .bank || $0.kind == .wallet }
        }
        return activeAccounts.filter { $0.id != toAccount?.id }
    }

    private var toOptions: [Account] {
        if presetKind == .cardBillPayment, let preset = presetToAccount {
            return [preset]    // Destination is locked
        }
        return activeAccounts.filter { $0.id != fromAccount?.id }
    }

    private var canSave: Bool {
        amount > 0 && fromAccount != nil && toAccount != nil && fromAccount?.id != toAccount?.id
    }

    private var titleText: String {
        switch presetKind {
        case .cardBillPayment: return "Pay Card Bill"
        case .withdrawal:      return "Withdraw Cash"
        case .deposit:         return "Deposit Cash"
        default:               return "Move Money"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xxl) {
                    amountSection
                    routingSection
                    optionalSection
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if amount == 0 { amountFocused = true }
                }
            }
        }
    }

    // MARK: - Amount

    private var amountSection: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.title2.weight(.medium))
                .foregroundStyle(.secondary)

            FormattedAmountField(
                value: $amount,
                currencyCode: currencyCode,
                placeholder: "0",
                font: .system(size: 56, weight: .bold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .foregroundStyle(amount > 0 ? .primary : .tertiary)
        }
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Routing

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "From")
            accountStrip(
                accounts: fromOptions,
                selection: $fromAccount,
                isLocked: presetFromAccount != nil
            )

            SectionHeader(title: "To")
                .padding(.top, Spacing.sm)
            accountStrip(
                accounts: toOptions,
                selection: $toAccount,
                isLocked: presetToAccount != nil && presetKind == .cardBillPayment
            )
        }
    }

    private func accountStrip(accounts: [Account],
                              selection: Binding<Account?>,
                              isLocked: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(accounts) { account in
                    AccountChip(
                        account: account,
                        isSelected: selection.wrappedValue?.id == account.id
                    )
                    .onTapGesture {
                        guard !isLocked else { return }
                        Haptics.selection()
                        withAnimation(AppAnimation.snappy) {
                            selection.wrappedValue = account
                        }
                    }
                    .opacity(isLocked && selection.wrappedValue?.id != account.id ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Optional (Note / Date)

    private var optionalSection: some View {
        Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
            VStack(spacing: Spacing.md) {
                HStack {
                    Text("Note")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("Optional", text: $note)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                Divider()
                HStack {
                    Text("Date")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard let from = fromAccount, let to = toAccount, amount > 0 else { return }

        let resolvedKind: TransferKind = presetKind ?? inferKind(from: from, to: to)

        let transfer = Transfer(
            amount: amount,
            fromAccount: from,
            toAccount: to,
            date: date,
            kind: resolvedKind,
            note: note.isEmpty ? nil : note
        )
        context.insert(transfer)
        try? context.save()
        Haptics.success()
        dismiss()
    }

    /// Best-effort inference of transfer kind from the account types involved.
    private func inferKind(from: Account, to: Account) -> TransferKind {
        switch (from.kind, to.kind) {
        case (.bank, .creditCard), (.wallet, .creditCard): return .cardBillPayment
        case (.bank, .cash):                                return .withdrawal
        case (.cash, .bank):                                return .deposit
        default:                                            return .generic
        }
    }
}
