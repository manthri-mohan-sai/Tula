import SwiftUI
import SwiftData

/// Account management — list all accounts grouped by kind, add new ones,
/// edit existing ones, archive (soft-delete) ones no longer used.
struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @PrimaryCurrency private var currencyCode

    @State private var showingAddAccount = false
    @State private var editingAccount: Account?

    private var grouped: [(kind: AccountKind, accounts: [Account])] {
        let active = allAccounts.filter { !$0.isArchived }
        return AccountKind.allCases.compactMap { kind in
            let inKind = active.filter { $0.kind == kind }
            return inKind.isEmpty ? nil : (kind, inKind)
        }
    }

    private var archived: [Account] {
        allAccounts.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    ForEach(grouped, id: \.kind) { group in
                        accountGroup(kind: group.kind, accounts: group.accounts)
                    }

                    if !archived.isEmpty {
                        archivedSection
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, Spacing.lg)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AccountFormView()
            }
            .sheet(item: $editingAccount) { account in
                AccountFormView(account: account)
            }
        }
    }

    // MARK: - Group

    private func accountGroup(kind: AccountKind, accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: kind.displayName.uppercased())

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        AccountListRow(account: account)
                            .padding(.horizontal, Spacing.md)
                            .contentShape(Rectangle())
                            .onTapGesture { editingAccount = account }
                        if account.id != accounts.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Archived")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(archived) { account in
                        ArchivedAccountRow(account: account, onRestore: { restore(account) })
                            .padding(.horizontal, Spacing.md)
                        if account.id != archived.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private func restore(_ account: Account) {
        withAnimation(AppAnimation.gentle) {
            account.isArchived = false
        }
        try? context.save()
    }
}

// MARK: - List Rows

private struct AccountListRow: View {
    let account: Account
    @PrimaryCurrency private var currencyCode

    private var color: Color { Color(hex: account.colorHex) }

    /// The label for the balance line varies by account kind to reflect
    /// what the number actually means.
    private var balanceLabel: String {
        switch account.kind {
        case .creditCard: return "Outstanding"
        case .cash: return "On hand"
        case .bank, .wallet: return "Net flow"
        }
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: account.iconKey)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                Text(balanceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(Currency.format(account.derivedBalance, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Spacing.md)
    }
}

private struct ArchivedAccountRow: View {
    let account: Account
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: account.iconKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(account.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Restore", action: onRestore)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.tulaBrandFallback)
        }
        .padding(.vertical, Spacing.md)
    }
}

// MARK: - Form

/// Create or edit an account. The kind picker is hidden when editing
/// (kind is permanent — switching from CC to Bank would corrupt accounting).
struct AccountFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    let existingAccount: Account?

    @State private var name: String
    @State private var kind: AccountKind
    @State private var iconKey: String
    @State private var colorHex: String
    @State private var openingBalance: Double
    @State private var creditLimit: Double
    @State private var hasCreditLimit: Bool

    @State private var showingDeleteConfirm = false

    init(account: Account? = nil) {
        self.existingAccount = account
        if let account {
            _name = State(initialValue: account.name)
            _kind = State(initialValue: account.kind)
            _iconKey = State(initialValue: account.iconKey)
            _colorHex = State(initialValue: account.colorHex)
            _openingBalance = State(initialValue: account.openingBalance)
            _creditLimit = State(initialValue: account.creditLimit ?? 0)
            _hasCreditLimit = State(initialValue: account.creditLimit != nil)
        } else {
            _name = State(initialValue: "")
            _kind = State(initialValue: .bank)
            _iconKey = State(initialValue: AccountKind.bank.defaultIcon)
            _colorHex = State(initialValue: "#4A90E2")
            _openingBalance = State(initialValue: 0)
            _creditLimit = State(initialValue: 0)
            _hasCreditLimit = State(initialValue: false)
        }
    }

    private var isEditing: Bool { existingAccount != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. HDFC Bank, ICICI CC", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                }

                if !isEditing {
                    Section("Type") {
                        Picker("Type", selection: $kind) {
                            ForEach(AccountKind.allCases, id: \.self) { kind in
                                Label(kind.displayName, systemImage: kind.defaultIcon)
                                    .tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        .onChange(of: kind) { _, newKind in
                            // Default icon updates with kind unless the user
                            // has explicitly customized it.
                            iconKey = newKind.defaultIcon
                        }
                    }
                }

                Section("Color") {
                    colorPicker
                }

                Section("Icon") {
                    iconPicker
                }

                if kind == .creditCard {
                    Section {
                        Toggle("Set a credit limit", isOn: $hasCreditLimit)
                        if hasCreditLimit {
                            HStack {
                                Text("Limit")
                                Spacer()
                                FormattedAmountField(
                                    value: $creditLimit,
                                    currencyCode: currencyCode,
                                    placeholder: "0"
                                )
                            }
                        }
                    } header: {
                        Text("Credit Limit")
                    } footer: {
                        Text("Optional. When set, the home screen shows what % of the limit is used.")
                    }
                } else if kind == .cash {
                    Section {
                        HStack {
                            Text("Cash on hand")
                            Spacer()
                            FormattedAmountField(
                                value: $openingBalance,
                                currencyCode: currencyCode,
                                placeholder: "0"
                            )
                        }
                    } header: {
                        Text("Opening Balance")
                    } footer: {
                        Text("How much cash is in your wallet right now? Subsequent withdrawals and expenses will adjust this.")
                    }
                }

                if isEditing {
                    Section {
                        Button("Archive Account") {
                            archive()
                        }
                        .foregroundStyle(.orange)

                        if canDelete {
                            Button("Delete Account") {
                                showingDeleteConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    } footer: {
                        if canDelete {
                            Text("Archive hides the account from pickers but keeps its history. Deleting permanently removes the account and all its transactions.")
                        } else {
                            Text("This account has transactions, so it can only be archived (hidden), not deleted.")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Account" : "New Account")
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
            .confirmationDialog(
                "Delete \(name)?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Pickers

    private var colorPicker: some View {
        let palette = [
            "#4A90E2", "#7BA68D", "#D97706", "#8B2C3A", "#9775FA",
            "#F783AC", "#51CF66", "#FFD43B", "#22B8CF", "#FF6B6B"
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle().stroke(
                                colorHex == hex ? Color.primary : .clear,
                                lineWidth: 2
                            )
                        )
                        .overlay(
                            Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2)
                                .padding(2)
                                .opacity(colorHex == hex ? 1 : 0)
                        )
                        .onTapGesture { colorHex = hex }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var iconPicker: some View {
        let icons = [
            "building.columns", "creditcard", "banknote", "wallet.pass",
            "indianrupeesign.circle", "dollarsign.circle", "eurosign.circle",
            "house.fill", "briefcase.fill", "graduationcap.fill",
            "airplane", "car.fill", "cart.fill", "gift.fill"
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(icons, id: \.self) { icon in
                    let color = Color(hex: colorHex)
                    ZStack {
                        Circle()
                            .fill(iconKey == icon ? color : color.opacity(0.15))
                            .frame(width: 42, height: 42)
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(iconKey == icon ? .white : color)
                    }
                    .onTapGesture { iconKey = icon }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private var canDelete: Bool {
        guard let existingAccount else { return false }
        return existingAccount.expenses.isEmpty
            && existingAccount.outgoingTransfers.isEmpty
            && existingAccount.incomingTransfers.isEmpty
    }

    private func save() {
        if let existingAccount {
            existingAccount.name = name
            existingAccount.iconKey = iconKey
            existingAccount.colorHex = colorHex
            existingAccount.openingBalance = openingBalance
            existingAccount.creditLimit = hasCreditLimit && creditLimit > 0 ? creditLimit : nil
        } else {
            let account = Account(
                name: name,
                kind: kind,
                iconKey: iconKey,
                colorHex: colorHex,
                openingBalance: openingBalance,
                creditLimit: hasCreditLimit && creditLimit > 0 ? creditLimit : nil,
                sortOrder: 100
            )
            context.insert(account)
        }
        try? context.save()
        dismiss()
    }

    private func archive() {
        existingAccount?.isArchived = true
        try? context.save()
        dismiss()
    }

    private func delete() {
        guard let existingAccount else { return }
        context.delete(existingAccount)
        try? context.save()
        dismiss()
    }
}
