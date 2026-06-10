import SwiftUI
import SwiftData

// MARK: - List View

/// Top-level Recurring screen reached from Settings → Recurring (and the
/// Upcoming section on Home). Lists every rule grouped by active/paused
/// state. Tap a row to edit; "+" toolbar to add a new rule.
struct RecurringRulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \RecurringRule.createdAt) private var allRules: [RecurringRule]
    @PrimaryCurrency private var currencyCode

    @State private var showingAdd = false
    @State private var editingRule: RecurringRule?
    @State private var ruleToDelete: RecurringRule?
    @State private var showingDeleteConfirm = false

    let showOnlyOverdue: Bool

    init(showOnlyOverdue: Bool = false) {
        self.showOnlyOverdue = showOnlyOverdue
    }

    private var activeRules: [RecurringRule] { allRules.filter { !$0.isPaused } }
    private var pausedRules: [RecurringRule] { allRules.filter { $0.isPaused } }

    private var overdueRules: [RecurringRule] {
        allRules.filter { rule in
            !rule.isPaused && !RecurringEngine.overdueDates(for: rule).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    if showOnlyOverdue {
                        if overdueRules.isEmpty {
                            emptyState
                        } else {
                            section(title: "Overdue", rules: overdueRules)
                        }
                    } else if allRules.isEmpty {
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
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(showOnlyOverdue ? "Overdue" : "Recurring")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !showOnlyOverdue {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Haptics.tap()
                            showingAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                RecurringRuleFormView()
            }
            .sheet(item: $editingRule) { rule in
                RecurringRuleFormView(rule: rule)
            }
            .confirmationDialog(
                "Delete \(ruleToDelete?.name ?? "rule")?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let rule = ruleToDelete {
                        deleteRule(rule)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This recurring rule will be permanently removed.")
            }
        }
    }

    private func section(title: String, rules: [RecurringRule]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: title.uppercased())
            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(rules) { rule in
                        SwipeToDeleteRow {
                            ruleToDelete = rule
                            showingDeleteConfirm = true
                        } content: {
                            Button {
                                Haptics.tap()
                                editingRule = rule
                            } label: {
                                RuleRow(rule: rule)
                                    .padding(.horizontal, Spacing.md)
                            }
                            .buttonStyle(PlainRowButtonStyle())
                        }

                        if rule.id != rules.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    private func deleteRule(_ rule: RecurringRule) {
        NotificationManager.cancelConfirmations(for: rule.id)
        withAnimation(AppAnimation.snappy) {
            context.delete(rule)
            try? context.save()
            WidgetRefresh.refresh(using: context)
        }
        Haptics.success()
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
        if rule.isPaused {
            // Show resume date when set — gives the user context about
            // when the rule will start producing transactions again.
            if let until = rule.pausedUntil, until > .now {
                let untilStr = until.formatted(.dateTime.day().month(.abbreviated))
                return "Paused · resumes \(untilStr)"
            }
            return "Paused"
        }
        if let next = RecurringEngine.nextDueDate(for: rule) {
            let nextStr = next.formatted(.dateTime.day().month(.abbreviated))
            return "Next: \(nextStr) · \(rule.cadenceLabel)"
        }
        return rule.cadenceLabel.capitalized
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

            if rule.isVariable {
                Text("Varies")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(Currency.format(rule.amount, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(rule.isPaused ? .tertiary : .primary)
            }
        }
        .padding(.vertical, Spacing.md)
        .opacity(rule.isPaused ? 0.6 : 1)
    }
}

// MARK: - Form

/// Form for adding or editing a recurring rule.
///
/// Each Section is its own `some View` computed property. The main `body`
/// just stacks them inside a Form. Section bodies are deliberately kept
/// small — when too much logic lives inside one builder closure, the
/// Swift type-checker fails to infer Section's generic Content parameter
/// and emits a cascade of "missing argument label 'content:'" / "cannot
/// convert String to () -> Content" errors.
struct RecurringRuleFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]

    let existingRule: RecurringRule?

    // MARK: State

    @State private var name: String
    @State private var amount: Double
    @State private var kind: RecurringKind
    @State private var frequency: RecurringFrequency
    @State private var dayOfMonth: Int
    /// Weekdays the rule fires on (1=Sun ... 7=Sat). Only used when
    /// frequency == .weekly. Initialized from the rule's mask (or
    /// startDate's weekday for new rules / legacy single-day rules).
    @State private var weekdays: Set<Int>
    @State private var customInterval: Int
    @State private var customUnit: CustomIntervalUnit
    @State private var startDate: Date
    @State private var hasEndDate: Bool
    @State private var endDate: Date
    @State private var category: Category?
    @State private var account: Account?
    @State private var fromAccount: Account?
    @State private var toAccount: Account?
    @State private var merchant: String
    @State private var note: String
    @State private var isPaused: Bool
    @State private var confirmationRequired: Bool
    @State private var hasSpecificTime: Bool
    @State private var hasPauseEnd: Bool
    @State private var pauseUntil: Date
    @State private var isVariable: Bool
    @State private var showingDeleteConfirm = false

    init(rule: RecurringRule? = nil) {
        self.existingRule = rule
        if let r = rule {
            _name = State(initialValue: r.name)
            _amount = State(initialValue: r.amount)
            _kind = State(initialValue: r.kind)
            _frequency = State(initialValue: r.frequency)
            _dayOfMonth = State(initialValue: r.dayOfMonth)
            let initialWeekdays: Set<Int> = {
                if !r.weekdaysSet.isEmpty { return r.weekdaysSet }
                return [Calendar.current.component(.weekday, from: r.startDate)]
            }()
            _weekdays = State(initialValue: initialWeekdays)
            _customInterval = State(initialValue: r.customInterval)
            _customUnit = State(initialValue: r.customUnit)
            _startDate = State(initialValue: r.startDate)
            _hasEndDate = State(initialValue: r.endDate != nil)
            _endDate = State(initialValue: r.endDate ?? .now.addingTimeInterval(60 * 60 * 24 * 365))
            _category = State(initialValue: r.category)
            _account = State(initialValue: r.account)
            _fromAccount = State(initialValue: r.fromAccount)
            _toAccount = State(initialValue: r.toAccount)
            _merchant = State(initialValue: r.merchant ?? "")
            _note = State(initialValue: r.note ?? "")
            _isPaused = State(initialValue: r.isPaused)
            _confirmationRequired = State(initialValue: r.confirmationRequired)
            _hasSpecificTime = State(initialValue: r.hasSpecificTime)
            _hasPauseEnd = State(initialValue: r.pausedUntil != nil)
            _pauseUntil = State(initialValue: r.pausedUntil ?? .now.addingTimeInterval(60 * 60 * 24 * 7))
            _isVariable = State(initialValue: r.isVariable)
        } else {
            _name = State(initialValue: "")
            _amount = State(initialValue: 0)
            _kind = State(initialValue: .expense)
            _frequency = State(initialValue: .monthly)
            _dayOfMonth = State(initialValue: Calendar.current.component(.day, from: .now))
            _weekdays = State(initialValue: Set(1...7))
            _customInterval = State(initialValue: 1)
            _customUnit = State(initialValue: .month)
            _startDate = State(initialValue: .now)
            _hasEndDate = State(initialValue: false)
            _endDate = State(initialValue: .now.addingTimeInterval(60 * 60 * 24 * 365))
            _category = State(initialValue: nil)
            _account = State(initialValue: nil)
            _fromAccount = State(initialValue: nil)
            _toAccount = State(initialValue: nil)
            _merchant = State(initialValue: "")
            _note = State(initialValue: "")
            _isPaused = State(initialValue: false)
            _confirmationRequired = State(initialValue: false)
            _hasSpecificTime = State(initialValue: false)
            _hasPauseEnd = State(initialValue: false)
            _pauseUntil = State(initialValue: .now.addingTimeInterval(60 * 60 * 24 * 7))
            _isVariable = State(initialValue: false)
        }
    }

    init(suggestion: RecurringSuggestion) {
        self.existingRule = nil
        _name = State(initialValue: suggestion.merchant)
        _amount = State(initialValue: suggestion.isVariable ? 0 : suggestion.lastAmount)
        _kind = State(initialValue: .expense)
        _frequency = State(initialValue: suggestion.frequency)
        _dayOfMonth = State(initialValue: suggestion.dayOfMonth)
        _weekdays = State(initialValue: suggestion.frequency == .weekly
            ? [Calendar.current.component(.weekday, from: .now)]
            : Set(1...7))
        _customInterval = State(initialValue: 1)
        _customUnit = State(initialValue: .month)
        _startDate = State(initialValue: .now)
        _hasEndDate = State(initialValue: false)
        _endDate = State(initialValue: .now.addingTimeInterval(60 * 60 * 24 * 365))
        _category = State(initialValue: suggestion.category)
        _account = State(initialValue: suggestion.account)
        _fromAccount = State(initialValue: nil)
        _toAccount = State(initialValue: nil)
        _merchant = State(initialValue: suggestion.merchant)
        _note = State(initialValue: "")
        _isPaused = State(initialValue: false)
        _confirmationRequired = State(initialValue: suggestion.isVariable)
        _hasSpecificTime = State(initialValue: false)
        _hasPauseEnd = State(initialValue: false)
        _pauseUntil = State(initialValue: .now.addingTimeInterval(60 * 60 * 24 * 7))
        _isVariable = State(initialValue: suggestion.isVariable)
    }

    private var isEditing: Bool { existingRule != nil }
    private var activeAccounts: [Account] { allAccounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { allCategories.filter { !$0.isArchived } }

    private var canSave: Bool {
        let nameOK = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let amountOK = isVariable ? true : amount > 0
        if kind == .expense {
            return nameOK && amountOK && account != nil
        }
        return nameOK && amountOK
            && fromAccount != nil
            && toAccount != nil
            && fromAccount?.id != toAccount?.id
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                typeSection
                routingSection
                scheduleSection
                confirmationSection
                noteSection
                pauseSection
                if isEditing {
                    deleteSection
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

    // MARK: Sections

    private var detailsSection: some View {
        Section {
            TextField("Name (e.g. Rent, Netflix)", text: $name)
                .textInputAutocapitalization(.words)
            HStack {
                Text(isVariable ? "Reference Amount" : "Amount")
                Spacer()
                FormattedAmountField(
                    value: $amount,
                    currencyCode: currencyCode,
                    placeholder: isVariable ? "Optional" : "0"
                )
            }
            Toggle(isOn: $isVariable.animation(.snappy(duration: 0.25))) {
                Text("Variable amount")
            }
            .onChange(of: isVariable) { _, newValue in
                if newValue { confirmationRequired = true }
            }
            TextField("Merchant (optional)", text: $merchant)
                .textInputAutocapitalization(.words)
        } header: {
            Text("Details")
        } footer: {
            if isVariable {
                Text("Amount varies each time (e.g. power bill, fuel). You'll be asked to enter the actual amount.")
            } else if !merchant.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Expenses will be logged under \"\(merchant.trimmingCharacters(in: .whitespaces))\" as merchant.")
            }
        }
    }

    private var typeSection: some View {
        Section {
            Picker("Type", selection: $kind) {
                Text("Expense").tag(RecurringKind.expense)
                Text("Card Payment").tag(RecurringKind.cardPayment)
                Text("Transfer").tag(RecurringKind.transfer)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Type")
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        if kind == .expense {
            expenseRoutingSection
        } else {
            transferRoutingSection
        }
    }

    private var expenseRoutingSection: some View {
        Section {
            categoryPicker
            accountPicker(selection: $account, label: "Pay from")
        } header: {
            Text("Category & Account")
        }
    }

    private var transferRoutingSection: some View {
        Section {
            accountPicker(selection: $fromAccount, label: "From")
            accountPicker(selection: $toAccount, label: "To")
        } header: {
            Text("Routing")
        }
    }

    private var scheduleSection: some View {
        Section {
            frequencyPicker
            frequencyVariantRows
            startDateRow
            endDateToggleRow
            endDateDatePickerRow
        } header: {
            Text("Schedule")
        } footer: {
            Text(scheduleFooter)
        }
    }

    private var noteSection: some View {
        Section {
            TextField("Optional", text: $note, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text("Note")
        }
    }

    /// Ask-before-logging toggle. When on, the rule's occurrences don't
    /// auto-log — instead the app schedules an interactive notification
    /// at each due date with "Log it" and "Skip" buttons. The user
    /// decides per-occurrence. Built for daily patterns that can be
    /// skipped (mess meals, gym fees on rest days, commute on WFH days).
    private var confirmationSection: some View {
        Section {
            Toggle(isOn: $confirmationRequired) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask before logging")
                        .font(.body)
                    Text("Get a notification with Log / Skip buttons at each due date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isVariable)

            // Time-of-day. The user toggles whether this rule has a
            // specific time. When off, the rule is "general" / all-day —
            // surfaced on home as a stackable card alongside other
            // all-day items. When on, the rule fires at the picked time,
            // shows as the single "nearest scheduled" card on home, and
            // (if confirmationRequired is also on) drives the notification
            // delivery time.
            //
            // Side-effect: flipping `hasSpecificTime` ON also auto-enables
            // `confirmationRequired`. Reasoning: a user setting a
            // specific time is implicitly saying "I want to be reminded
            // at this time" — auto-logging at the specific time without
            // a notification is almost never what they meant. They can
            // turn confirmation back off if they really want silent
            // auto-log at a specific time.
            Toggle("Specific time", isOn: $hasSpecificTime)
                .onChange(of: hasSpecificTime) { _, newValue in
                    if newValue, !confirmationRequired {
                        confirmationRequired = true
                    }
                }
            if hasSpecificTime {
                DatePicker(
                    "Time",
                    selection: $startDate,
                    displayedComponents: .hourAndMinute
                )
            }
        } header: {
            Text("Confirmation")
        } footer: {
            Text(confirmationRequired
                 ? "Notifications fire at the chosen time. Tap \"Log it\" to record the expense, or \"Skip\" to ignore that occurrence."
                 : "Occurrences post automatically based on the schedule.")
        }
    }

    /// Pause controls. Two flavours:
    ///   • Indefinite pause — the rule stays off until manually re-enabled
    ///   • Pause until a date — auto-resumes on that date (e.g. vacation)
    /// When the rule is editing (`isEditing` true) AND already isPaused
    /// with a future pausedUntil, this section also reports when it'll
    /// resume so the user has context before they save.
    private var pauseSection: some View {
        Section {
            Toggle("Paused", isOn: $isPaused.animation(AppAnimation.gentle))

            if isPaused {
                Toggle("Resume on a date", isOn: $hasPauseEnd.animation(AppAnimation.gentle))

                if hasPauseEnd {
                    DatePicker(
                        "Resume on",
                        selection: $pauseUntil,
                        in: Date.now...,
                        displayedComponents: .date
                    )
                }
            }
        } header: {
            Text("Pause")
        } footer: {
            if isPaused && hasPauseEnd {
                Text("The rule will skip occurrences until \(pauseUntil.formatted(.dateTime.day().month(.wide).year())), then auto-resume.")
            } else if isPaused {
                Text("The rule is paused indefinitely. Turn this off to resume.")
            } else {
                Text("Pause to stop generating expenses without deleting the rule.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete Rule", role: .destructive) {
                showingDeleteConfirm = true
            }
        }
    }

    // MARK: Schedule sub-rows

    private var frequencyPicker: some View {
        Picker("Repeats", selection: $frequency) {
            Text("Weekly").tag(RecurringFrequency.weekly)
            Text("Monthly").tag(RecurringFrequency.monthly)
            Text("Yearly").tag(RecurringFrequency.yearly)
            Text("Custom").tag(RecurringFrequency.custom)
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    @ViewBuilder
    private var frequencyVariantRows: some View {
        if frequency == .weekly {
            weekdayPickerRow
        } else if frequency == .monthly {
            monthlyStepperRow
        } else if frequency == .custom {
            customIntervalRow
            customUnitRow
        } else {
            EmptyView()
        }
    }

    /// Apple-Reminders-style weekday selector. Seven circular buttons
    /// labeled S M T W T F S (Sun→Sat). Tap to toggle. Selected days
    /// fill with brand color; unselected show a subtle neutral background.
    ///
    /// Designed so common patterns are achievable with minimum taps:
    /// - Single day (legacy): pre-selected based on startDate
    /// - Weekdays / weekends / every day: a couple of taps
    /// - "Mess meals Mon-Fri": tap S, S to remove from default-all
    ///
    /// At least one day must remain selected — if the user tries to
    /// deselect the last remaining day, we silently keep it (no toast,
    /// matches Reminders' behavior).
    private var weekdayPickerRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 0) {
                ForEach(1...7, id: \.self) { day in
                    let isSelected = weekdays.contains(day)
                    Button {
                        toggleWeekday(day)
                    } label: {
                        Text(weekdayInitial(day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                Circle()
                                    .fill(isSelected
                                          ? Color.tulaBrandFallback
                                          : Color.secondary.opacity(0.12))
                                    .frame(width: 36, height: 36)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            // Subtle helper line so users see what they picked summarized
            // in words, without having to mentally read the circles.
            if !weekdays.isEmpty {
                Text(weekdaysHumanSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, Spacing.xs)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func weekdayInitial(_ day: Int) -> String {
        // S M T W T F S — the convention every iOS user already reads.
        // Two T's and two S's are inherent to this convention; tooltip-on-tap
        // would over-engineer for the 0.1% who can't infer position.
        switch day {
        case 1: return "S"
        case 2: return "M"
        case 3: return "T"
        case 4: return "W"
        case 5: return "T"
        case 6: return "F"
        case 7: return "S"
        default: return ""
        }
    }

    private func toggleWeekday(_ day: Int) {
        Haptics.tap()
        if weekdays.contains(day) {
            // Don't allow zero days — keep at least one selected, silently.
            guard weekdays.count > 1 else { return }
            weekdays.remove(day)
        } else {
            weekdays.insert(day)
        }
    }

    /// Same logic as RecurringRule.weekdaysSummary but readable from the
    /// form's `weekdays` state directly, before save. Kept in sync with
    /// the model-side version.
    private var weekdaysHumanSummary: String {
        if weekdays == Set(1...7) { return "Every day" }
        if weekdays == [2, 3, 4, 5, 6] { return "Weekdays" }
        if weekdays == [1, 7] { return "Weekends" }
        if weekdays.count == 1, let only = weekdays.first {
            let fullNames = [1: "Sundays", 2: "Mondays", 3: "Tuesdays",
                             4: "Wednesdays", 5: "Thursdays",
                             6: "Fridays", 7: "Saturdays"]
            return fullNames[only] ?? "Custom"
        }
        let names = [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed",
                     5: "Thu", 6: "Fri", 7: "Sat"]
        return weekdays.sorted().compactMap { names[$0] }.joined(separator: ", ")
    }

    private var monthlyStepperRow: some View {
        let label: String = "Day \(dayOfMonth) of every month"
        return Stepper(value: $dayOfMonth, in: 1...31) {
            Text(label)
        }
    }

    private var customIntervalRow: some View {
        let unitName: String = customUnit.label(for: customInterval)
        let label: String = "Every \(customInterval) \(unitName)"
        return Stepper(value: $customInterval, in: 1...99) {
            Text(label)
        }
    }

    private var customUnitRow: some View {
        Picker("Unit", selection: $customUnit) {
            Text(unitLabel(.day)).tag(CustomIntervalUnit.day)
            Text(unitLabel(.week)).tag(CustomIntervalUnit.week)
            Text(unitLabel(.month)).tag(CustomIntervalUnit.month)
            Text(unitLabel(.year)).tag(CustomIntervalUnit.year)
        }
        .pickerStyle(.segmented)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private var startDateRow: some View {
        let label: String = (frequency == .weekly) ? "First date" : "Start date"
        return DatePicker(label, selection: $startDate, displayedComponents: .date)
    }

    private var endDateToggleRow: some View {
        Toggle("Has end date", isOn: $hasEndDate)
    }

    @ViewBuilder
    private var endDateDatePickerRow: some View {
        if hasEndDate {
            DatePicker("End date", selection: $endDate, displayedComponents: .date)
        }
    }

    private func unitLabel(_ unit: CustomIntervalUnit) -> String {
        unit.label(for: customInterval).capitalized
    }

    private var scheduleFooter: String {
        switch frequency {
        case .weekly:
            if weekdays.count == 1, let only = weekdays.first {
                let weekdayName = Calendar.current.weekdaySymbols[only - 1]
                let dateStr = startDate.formatted(.dateTime.day().month())
                return "Fires every \(weekdayName) starting \(dateStr)."
            }
            return "Fires on \(weekdaysHumanSummary.lowercased()), every week."
        case .monthly:
            return "Fires on day \(dayOfMonth) of every month. For short months (Feb, Apr) it's clamped to the last day."
        case .yearly:
            let dateStr = startDate.formatted(.dateTime.day().month(.wide))
            return "Fires once a year on \(dateStr)."
        case .custom:
            let unitName = customUnit.label(for: customInterval)
            let dateStr = startDate.formatted(.dateTime.day().month())
            return "Fires every \(customInterval) \(unitName) starting \(dateStr)."
        }
    }

    // MARK: Pickers

    private var categoryPicker: some View {
        Picker("Category", selection: $category) {
            Text("None").tag(Category?.none)
            ForEach(activeCategories) { cat in
                Text(cat.name).tag(Category?.some(cat))
            }
        }
    }

    private func accountPicker(selection: Binding<Account?>, label: String) -> some View {
        Picker(label, selection: selection) {
            Text("Select").tag(Account?.none)
            ForEach(activeAccounts) { acc in
                Text(acc.name).tag(Account?.some(acc))
            }
        }
    }

    // MARK: Actions

    private func save() {
        if let rule = existingRule {
            applyChanges(to: rule)
        } else {
            let rule = RecurringRule(
                name: name,
                amount: amount,
                kind: kind,
                dayOfMonth: dayOfMonth,
                frequency: frequency,
                startDate: startDate
            )
            applyChanges(to: rule)
            context.insert(rule)
        }
        try? context.save(); WidgetRefresh.refresh(using: context)
        // Re-run the engine so any new confirmation rule starts firing
        // notifications immediately (and any edited rule picks up its
        // new time/amount), instead of waiting for the next app launch.
        // For auto-log rules this also generates any past-due
        // occurrences if startDate is in the past.
        RecurringEngine.generateMissing(in: context)
        Haptics.success()
        dismiss()
    }

    /// Copies state into the given rule. Shared between edit (mutate
    /// existing) and create (mutate freshly-built) so the field-mapping
    /// rules apply identically in both paths.
    private func applyChanges(to rule: RecurringRule) {
        rule.name = name
        rule.amount = amount
        rule.kind = kind
        rule.frequency = frequency
        rule.dayOfMonth = dayOfMonth
        // Persist weekday selection only for weekly rules. For other
        // frequencies, zero the mask so a future flip back to weekly
        // starts fresh rather than reusing stale state.
        if frequency == .weekly {
            // If user picked exactly one day AND that day matches startDate's
            // weekday, store mask = 0 (legacy single-day mode). This keeps
            // the data tidy for the common case and avoids a "needless mask"
            // appearing on rules that don't actually need multi-day logic.
            let startWeekday = Calendar.current.component(.weekday, from: startDate)
            if weekdays == [startWeekday] {
                rule.weekdaysMask = 0
            } else {
                rule.weekdaysSet = weekdays
            }
        } else {
            rule.weekdaysMask = 0
        }
        rule.customInterval = customInterval
        rule.customUnit = customUnit
        rule.startDate = startDate
        rule.endDate = hasEndDate ? endDate : nil
        rule.category = (kind == .expense) ? category : nil
        rule.account = (kind == .expense) ? account : nil
        rule.fromAccount = (kind != .expense) ? fromAccount : nil
        rule.toAccount = (kind != .expense) ? toAccount : nil
        rule.merchant = merchant.trimmingCharacters(in: .whitespaces).isEmpty ? nil : merchant.trimmingCharacters(in: .whitespaces)
        rule.note = note.isEmpty ? nil : note
        rule.isPaused = isPaused
        rule.confirmationRequired = confirmationRequired
        rule.isVariable = isVariable
        rule.hasSpecificTime = hasSpecificTime
        // Persist pausedUntil only if user has both paused and chosen a
        // resume date. Otherwise clear it (covers: not paused, or paused
        // indefinitely, or just toggled off the resume-date option).
        rule.pausedUntil = (isPaused && hasPauseEnd) ? pauseUntil : nil

        // Always wipe pending confirmations on save. If the user edited
        // the time-of-day, amount, or name, the old notifications carry
        // stale data and the new ones use different identifiers (which
        // include the dueDate epoch) — so without cancelling we'd see
        // duplicates until the old ones expired. The engine reschedules
        // fresh ones immediately after save (see save()).
        NotificationManager.cancelConfirmations(for: rule.id)
    }

    private func delete() {
        guard let rule = existingRule else { return }
        // Pending confirmation notifications would still fire for a
        // deleted rule — clear them before removal.
        NotificationManager.cancelConfirmations(for: rule.id)
        context.delete(rule)
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Swipe To Delete Row

private struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var hapticFired = false

    private let deleteWidth: CGFloat = 80
    private let commitThreshold: CGFloat = 90

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack {
                Spacer()
                Button {
                    onDelete()
                    withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                            .font(.subheadline.weight(.semibold))
                        Text("Delete")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.white)
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
                }
                .buttonStyle(.plain)
            }
            .opacity(offset < -1 ? 1 : 0)

            content()
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            let raw = value.translation.width
                            if raw > 0 {
                                offset = raw * 0.15
                            } else if abs(raw) > 130 {
                                let excess = abs(raw) - 130
                                offset = -(130 + excess * 0.3)
                            } else {
                                offset = raw
                            }

                            if abs(raw) > commitThreshold && !hapticFired {
                                Haptics.tap()
                                hapticFired = true
                            } else if abs(raw) < commitThreshold {
                                hapticFired = false
                            }
                        }
                        .onEnded { value in
                            let raw = value.translation.width
                            if raw < -commitThreshold {
                                withAnimation(.snappy(duration: 0.25)) {
                                    offset = -deleteWidth
                                }
                            } else {
                                withAnimation(.snappy(duration: 0.25)) {
                                    offset = 0
                                }
                            }
                        }
                )
        }
        .clipped()
    }
}
