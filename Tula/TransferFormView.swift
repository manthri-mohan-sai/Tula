import SwiftUI
import SwiftData

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
        if presetKind == .cardBillPayment {
            return activeAccounts.filter { $0.kind == .bank || $0.kind == .wallet }
        }
        return activeAccounts.filter { $0.id != toAccount?.id }
    }

    private var toOptions: [Account] {
        if presetKind == .cardBillPayment, let preset = presetToAccount {
            return [preset]
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
        default:               return "Transfer"
        }
    }

    private var canSwap: Bool {
        presetKind == nil && presetFromAccount == nil && presetToAccount == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
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
                font: .system(size: 52, weight: .bold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .foregroundStyle(amount > 0 ? .primary : .tertiary)
        }
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Routing

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            fromSection
            swapRow
            toSection
        }
    }

    private var fromSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "From")
                Spacer()
                if let from = fromAccount {
                    Text(Currency.format(from.derivedBalance, code: currencyCode))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            accountStrip(
                accounts: fromOptions,
                selection: $fromAccount,
                isLocked: presetFromAccount != nil
            )
        }
    }

    private var swapRow: some View {
        HStack {
            Spacer()
            Button {
                guard canSwap else { return }
                Haptics.selection()
                withAnimation(AppAnimation.snappy) {
                    let temp = fromAccount
                    fromAccount = toAccount
                    toAccount = temp
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(canSwap ? Color.tulaBrandFallback : Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(canSwap
                                  ? Color.tulaBrandFallback.opacity(0.1)
                                  : Color.secondary.opacity(0.06))
                    )
            }
            .disabled(!canSwap)
            Spacer()
        }
        .padding(.vertical, Spacing.xs)
    }

    private var toSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "To")
                Spacer()
                if let to = toAccount {
                    Text(Currency.format(to.derivedBalance, code: currencyCode))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
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
        let ordered: [Account] = {
            guard let selectedID = selection.wrappedValue?.id,
                  let idx = accounts.firstIndex(where: { $0.id == selectedID }) else {
                return accounts
            }
            var result = accounts
            let pick = result.remove(at: idx)
            result.insert(pick, at: 0)
            return result
        }()

        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(ordered) { account in
                        AccountChip(
                            account: account,
                            isSelected: selection.wrappedValue?.id == account.id
                        )
                        .id(account.id)
                        .onTapGesture {
                            guard !isLocked else { return }
                            Haptics.selection()
                            withAnimation(AppAnimation.snappy) {
                                selection.wrappedValue = account
                            }
                        }
                        .opacity(isLocked && selection.wrappedValue?.id != account.id ? 0.4 : 1)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .leading)),
                            removal: .opacity
                        ))
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
            .onChange(of: selection.wrappedValue?.id) { _, newID in
                guard let id = newID else { return }
                withAnimation(.snappy(duration: 0.4)) {
                    proxy.scrollTo(id, anchor: .leading)
                }
            }
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
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }

    private func inferKind(from: Account, to: Account) -> TransferKind {
        switch (from.kind, to.kind) {
        case (.bank, .creditCard), (.wallet, .creditCard): return .cardBillPayment
        case (.bank, .cash):                                return .withdrawal
        case (.cash, .bank):                                return .deposit
        default:                                            return .generic
        }
    }
}
