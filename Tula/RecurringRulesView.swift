import SwiftUI
import SwiftData

/// List of all recurring rules with the ability to add, edit, pause, delete.
/// Shows next due date for each active rule.
struct RecurringRulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecurringRule.createdAt) private var allRules: [RecurringRule]
    @PrimaryCurrency private var currencyCode

    @State private var showingAdd = false
    @State private var editingRule: RecurringRule?

    private var activeRules: [RecurringRule] { allRules.filter { !$0.isPaused } }
    private var pausedRules: [RecurringRule] { allRules.filter { $0.isPaused } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    if allRules.isEmpty {
                        emptyState
                    } else {
                        if !activeRules.isEmpty {
                            section(title: "Active", rules: activeRules)
                        }
                        if !pausedRules.isEmpty {
                            section(title: "Paused", rules: pausedRules)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, Spacing.lg)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Recurring")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                RecurringRuleFormView()
            }
            .sheet(item: $editingRule) { rule in
                RecurringRuleFormView(rule: rule)
            }
        }
    }

    private func section(title: String, rules: [RecurringRule]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: title.uppercased())
            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(rules) { rule in
                        Button {
                            Haptics.tap()
                            editingRule = rule
                        } label: {
                            RuleRow(rule: rule)
                                .padding(.horizontal, Spacing.md)
                        }
                        .buttonStyle(PlainRowButtonStyle())

                        if rule.id != rules.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "calendar.badge.clock")
                    .font(.title)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: 4) {
                Text("No recurring rules yet")
                    .font(.subheadline.weight(.semibold))
                Text("Add subscriptions, rent, or recurring bills\nso they auto-log each month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: RecurringRule
    @PrimaryCurrency private var currencyCode

    private var icon: String {
        switch rule.kind {
        case .expense:     return rule.category?.iconKey ?? "circle.fill"
        case .transfer:    return "arrow.left.arrow.right"
        case .cardPayment: return "creditcard.fill"
        }
    }

    private var color: Color {
        switch rule.kind {
        case .expense:     return Color(hex: rule.category?.colorHex ?? "#888888")
        case .transfer:    return .blue
        case .cardPayment: return Color.tulaBrandFallback
        }
    }

    private var subtitle: String {
        if rule.isPaused { return "Paused" }
        if let next = RecurringEngine.nextDueDate(for: rule) {
            return "Next: \(next.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return "Day \(rule.dayOfMonth) every month"
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Currency.format(rule.amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(rule.isPaused ? .tertiary : .primary)
        }
        .padding(.vertical, Spacing.md)
        .opacity(rule.isPaused ? 0.6 : 1)
    }
}

// MARK: - Form

struct RecurringRuleFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]

    let existingRule: RecurringRule?

    @State private var name: String
    @State private var amount: Double
    @State private var kind: RecurringKind
    @State private var dayOfMonth: Int
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var category: Category?
    @State private var account: Account?
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    @State private var note: String
    @State private var isPaused: Bool

    @State private var showingDeleteConfirm = false

    init(rule: RecurringRule? = nil) {
        self.existingRule = rule
        if let r = rule {
            _name = State(initialValue: r.name)
            _amount = State(initialValue: r.amount)
            _kind = State(initialValue: r.kind)
            _dayOfMonth = State(initialValue: r.dayOfMonth)
            _startDate = State(initialValue: r.startDate)
            _hasEndDate = State(initialValue: r.endDate != nil)
            _endDate = State(initialValue: r.endDate ?? .now.addingTimeInterval(60 * 60 * 24 * 365))
            _category = State(initialValue: r.category)
            _account = State(initialValue: r.account)
            _fromAccount = State(initialValue: r.fromAccount)
            _toAccount = State(initialValue: r.toAccount)
            _note = State(initialValue: r.note ?? "")
            _isPaused = State(initialValue: r.isPaused)
        } else {
            _name = State(initialValue: "")
            _amount = State(initialValue: 0)
            _kind = State(initialValue: .expense)
            _dayOfMonth = State(initialValue: Calendar.current.component(.day, from: .now))
            _startDate = State(initialValue: .now)
            _hasEndDate = State(initialValue: false)
            _endDate = State(initialValue: .now.addingTimeInterval(60 * 60 * 24 * 365))
            _category = State(initialValue: nil)
            _account = State(initialValue: nil)
            _fromAccount = State(initialValue: nil)
            _toAccount = State(initialValue: nil)
            _note = State(initialValue: "")
            _isPaused = State(initialValue: false)
        }
    }

    private var isEditing: Bool { existingRule != nil }

    private var activeAccounts: [Account] { allAccounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { allCategories.filter { !$0.isArchived } }

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasAmount = amount > 0
        switch kind {
        case .expense:
            return hasName && hasAmount && account != nil
        case .transfer, .cardPayment:
            return hasName && hasAmount && fromAccount != nil && toAccount != nil
                && fromAccount?.id != toAccount?.id
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name (e.g. Rent, Netflix)", text: $name)
                        .textInputAutocapitalization(.words)

                    HStack {
                        Text("Amount")
                        Spacer()
                        FormattedAmountField(
                            value: $amount,
                            currencyCode: currencyCode,
                            placeholder: "0"
                        )
                    }
                }

                Section("Type") {
                    Picker("Type", selection: $kind) {
                        Text("Expense").tag(RecurringKind.expense)
                        Text("Card Payment").tag(RecurringKind.cardPayment)
                        Text("Transfer").tag(RecurringKind.transfer)
                    }
                    .pickerStyle(.segmented)
                }

                if kind == .expense {
                    Section("Category & Account") {
                        categoryPicker
                        accountPicker(selection: $account, label: "Pay from")
                    }
                } else {
                    Section("Routing") {
                        accountPicker(selection: $fromAccount, label: "From")
                        accountPicker(selection: $toAccount, label: "To")
                    }
                }

                Section("Schedule") {
                    Stepper("Day \(dayOfMonth) of every month", value: $dayOfMonth, in: 1...31)
                    DatePicker("Start date", selection: $startDate, displayedComponents: .date)
                    Toggle("Has end date", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("End date", selection: $endDate, displayedComponents: .date)
                    }
                }

                Section {
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("Note")
                }

                if isEditing {
                    Section {
                        Toggle("Pause rule", isOn: $isPaused)
                    } footer: {
                        Text("Paused rules don't generate new transactions, but existing ones stay.")
                    }

                    Section {
                        Button("Delete Rule") {
                            showingDeleteConfirm = true
                        }
                        .foregroundStyle(.red)
                    } footer: {
                        Text("Deleting removes the rule but keeps any transactions it generated.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Rule" : "New Rule")
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
                "Delete this rule?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    // MARK: - Pickers

    private var categoryPicker: some View {
        Picker("Category", selection: $category) {
            Text("None").tag(Category?.none)
            ForEach(activeCategories) { cat in
                HStack {
                    Image(systemName: cat.iconKey)
                        .foregroundStyle(Color(hex: cat.colorHex))
                    Text(cat.name)
                }
                .tag(Category?.some(cat))
            }
        }
    }

    private func accountPicker(selection: Binding<Account?>, label: String) -> some View {
        Picker(label, selection: selection) {
            Text("Select").tag(Account?.none)
            ForEach(activeAccounts) { acc in
                HStack {
                    Image(systemName: acc.iconKey)
                        .foregroundStyle(Color(hex: acc.colorHex))
                    Text(acc.name)
                }
                .tag(Account?.some(acc))
            }
        }
    }

    // MARK: - Actions

    private func save() {
        if let rule = existingRule {
            rule.name = name
            rule.amount = amount
            rule.kind = kind
            rule.dayOfMonth = dayOfMonth
            rule.startDate = startDate
            rule.endDate = hasEndDate ? endDate : nil
            rule.category = kind == .expense ? category : nil
            rule.account = kind == .expense ? account : nil
            rule.fromAccount = kind != .expense ? fromAccount : nil
            rule.toAccount = kind != .expense ? toAccount : nil
            rule.note = note.isEmpty ? nil : note
            rule.isPaused = isPaused
        } else {
            let rule = RecurringRule(
                name: name,
                amount: amount,
                kind: kind,
                dayOfMonth: dayOfMonth,
                startDate: startDate
            )
            rule.endDate = hasEndDate ? endDate : nil
            rule.category = kind == .expense ? category : nil
            rule.account = kind == .expense ? account : nil
            rule.fromAccount = kind != .expense ? fromAccount : nil
            rule.toAccount = kind != .expense ? toAccount : nil
            rule.note = note.isEmpty ? nil : note
            context.insert(rule)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let rule = existingRule else { return }
        context.delete(rule)
        try? context.save()
        Haptics.success()
        dismiss()
    }
}
