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

    /// When editing an existing transfer, this holds the original object.
    /// Nil means "create new". Set means "update existing".
    let existingTransfer: Transfer?

    @State private var amount: Double
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    @State private var note: String = ""
    @State private var date: Date = .now
    @State private var showingDate = false
    @State private var showingDeleteConfirmation = false
    @State private var reconcileAfterPayment = false
    @State private var cardBalanceAfter: Double = 0
    @State private var selectedReason: MoneyInReason?

    @FocusState private var amountFocused: Bool

    private var isEditing: Bool { existingTransfer != nil }

    init(presetKind: TransferKind? = nil,
         presetFromAccount: Account? = nil,
         presetToAccount: Account? = nil,
         presetAmount: Double = 0) {
        self.presetKind = presetKind
        self.presetFromAccount = presetFromAccount
        self.presetToAccount = presetToAccount
        self.presetAmount = presetAmount
        self.existingTransfer = nil
        _amount = State(initialValue: presetAmount)
        _fromAccount = State(initialValue: presetFromAccount)
        _toAccount = State(initialValue: presetToAccount)
    }

    /// Edit an existing transfer.
    init(existingTransfer: Transfer) {
        self.existingTransfer = existingTransfer
        // Don't set presets — user should be able to change everything.
        self.presetKind = nil
        self.presetFromAccount = nil
        self.presetToAccount = nil
        self.presetAmount = existingTransfer.amount
        _amount = State(initialValue: existingTransfer.amount)
        _fromAccount = State(initialValue: existingTransfer.fromAccount)
        _toAccount = State(initialValue: existingTransfer.toAccount)
        _note = State(initialValue: existingTransfer.note ?? "")
        _date = State(initialValue: existingTransfer.date)
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
        guard amount > 0, toAccount != nil else { return false }
        if presetKind == .topUp {
            return fromAccount == nil || fromAccount?.id != toAccount?.id
        }
        return fromAccount != nil && fromAccount?.id != toAccount?.id
    }

    private var titleText: String {
        if isEditing { return "Edit Transfer" }
        switch presetKind {
        case .cardBillPayment: return "Pay Card Bill"
        case .withdrawal:      return "Withdraw Cash"
        case .deposit:         return "Deposit Cash"
        case .topUp:
            return presetToAccount?.kind == .bank ? "Money In" : "Top Up"
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
                    cardReconcileSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isEditing {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Transfer", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .confirmationDialog("Delete this transfer?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                if let transfer = existingTransfer {
                                    context.delete(transfer)
                                    try? context.save(); WidgetRefresh.refresh(using: context)
                                    Haptics.warning()
                                }
                                dismiss()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Update" : "Save", action: save)
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
                SectionHeader(title: presetKind == .topUp ? "Source (optional)" : "From")
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
                isLocked: presetFromAccount != nil,
                allowsDeselection: presetKind == .topUp
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
                              isLocked: Bool,
                              allowsDeselection: Bool = false) -> some View {
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
                                if allowsDeselection && selection.wrappedValue?.id == account.id {
                                    selection.wrappedValue = nil
                                } else {
                                    selection.wrappedValue = account
                                }
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

    // MARK: - Optional (Reason / Note / Date)

    private var optionalSection: some View {
        Card(padding: Spacing.lg, cornerRadius: CornerRadius.medium) {
            VStack(spacing: Spacing.md) {
                if presetKind == .topUp {
                    HStack {
                        Text("Reason")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Spacer()
                        Menu {
                            Button {
                                if let old = selectedReason, note == old.notePrefix { note = "" }
                                selectedReason = nil
                            } label: {
                                if selectedReason == nil {
                                    Label("None", systemImage: "checkmark")
                                } else {
                                    Text("None")
                                }
                            }
                            ForEach(MoneyInReason.allCases) { reason in
                                Button {
                                    let oldPrefix = selectedReason?.notePrefix
                                    selectedReason = reason
                                    if note.isEmpty || note == oldPrefix {
                                        note = reason.notePrefix
                                    }
                                } label: {
                                    if selectedReason == reason {
                                        Label(reason.label, systemImage: "checkmark")
                                    } else {
                                        Label(reason.label, systemImage: reason.icon)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(selectedReason?.label ?? "Optional")
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.medium))
                            }
                            .font(.subheadline)
                            .foregroundStyle(selectedReason != nil ? Color.primary : Color.primary.opacity(0.55))
                        }
                    }
                    Divider()
                }
                HStack {
                    Text("Note")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    TextField("Optional", text: $note)
                        .multilineTextAlignment(.trailing)
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

    // MARK: - Optional post-payment reconcile (pay-bill mode only)

    @ViewBuilder
    private var cardReconcileSection: some View {
        // Only when paying a card bill for a brand-new transfer — lets the
        // user snap the card's outstanding to whatever their bank app shows
        // after the payment, instead of trusting Tula's derived figure.
        if presetKind == .cardBillPayment, !isEditing {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Toggle(isOn: $reconcileAfterPayment.animation(AppAnimation.snappy)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update card balance")
                            .font(.subheadline.weight(.semibold))
                        Text("Match what your card shows after this payment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.tulaBrandFallback)

                if reconcileAfterPayment {
                    HStack {
                        SectionHeader(title: "Card now shows")
                        Spacer()
                        FormattedAmountField(
                            value: $cardBalanceAfter,
                            currencyCode: currencyCode,
                            placeholder: "0",
                            font: .title3.weight(.semibold),
                            alignment: .trailing
                        )
                        .frame(maxWidth: 160)
                    }
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
    }

    private func save() {
        guard let to = toAccount, amount > 0 else { return }

        let resolvedKind: TransferKind
        if let preset = presetKind {
            resolvedKind = preset
        } else if let from = fromAccount {
            resolvedKind = inferKind(from: from, to: to)
        } else {
            resolvedKind = .generic
        }

        if let existing = existingTransfer {
            // Update existing transfer
            existing.amount = amount
            existing.fromAccount = fromAccount
            existing.toAccount = to
            existing.date = date
            existing.kind = resolvedKind
            existing.note = note.isEmpty ? nil : note
        } else {
            // Create new transfer
            let transfer = Transfer(
                amount: amount,
                fromAccount: fromAccount,
                toAccount: to,
                date: date,
                kind: resolvedKind,
                note: note.isEmpty ? nil : note
            )
            context.insert(transfer)

            // Optional re-anchor: if the user told us what the card shows
            // after this payment, record an adjustment on the destination
            // card so its outstanding matches reality. Runs after insert so
            // `derivedBalance` already reflects this payment.
            if presetKind == .cardBillPayment, reconcileAfterPayment {
                BalanceReconciler.reconcile(
                    account: to,
                    to: cardBalanceAfter,
                    source: .billPayment,
                    in: context
                )
            }
        }
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

// MARK: - Money-In Reason

/// Quick-pick reasons for topUp / Money In flows. Stored in the Transfer's
/// `note` field — no new models, just convenience for the user.
enum MoneyInReason: String, CaseIterable, Identifiable {
    case salary
    case loan
    case refund
    case cashback
    case freelance

    var id: String { rawValue }

    var label: String {
        switch self {
        case .salary:    return "Salary"
        case .loan:      return "Loan"
        case .refund:    return "Refund"
        case .cashback:  return "Cashback"
        case .freelance: return "Freelance"
        }
    }

    var icon: String {
        switch self {
        case .salary:    return "briefcase"
        case .loan:      return "person.2"
        case .refund:    return "arrow.uturn.backward"
        case .cashback:  return "gift"
        case .freelance: return "laptopcomputer"
        }
    }

    /// Pre-filled note prefix for the Transfer's note field.
    var notePrefix: String {
        switch self {
        case .salary:    return "Salary"
        case .loan:      return "Loan from "
        case .refund:    return "Refund"
        case .cashback:  return "Cashback"
        case .freelance: return "Freelance"
        }
    }
}
