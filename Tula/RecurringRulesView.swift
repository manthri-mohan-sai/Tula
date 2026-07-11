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
    @State private var ruleToLog: RecurringRule?
    @State private var logDate: Date?
    @State private var showingLogConfirm = false
    @State private var showingVariableAmountSheet = false
    @State private var variableAmount: Double = 0
    @State private var sheetLogDate: Date = .now

    let showOnlyOverdue: Bool

    init(showOnlyOverdue: Bool = false) {
        self.showOnlyOverdue = showOnlyOverdue
    }

    private var activeRules: [RecurringRule] { allRules.filter { !$0.isPaused } }
    private var pausedRules: [RecurringRule] { allRules.filter { $0.isPaused } }

    private var monthlySubtitle: String {
        let total = monthlyTotal(for: activeRules)
        guard total > 0 else { return "" }
        return "~\(total.formatted(.currency(code: currencyCode).precision(.fractionLength(0))))/month"
    }

    private var overdueRules: [RecurringRule] {
        allRules.filter { rule in
            !rule.isPaused && !RecurringEngine.overdueDates(for: rule).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if showOnlyOverdue {
                    if overdueRules.isEmpty {
                        ScrollView { emptyState.padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm) }
                    } else {
                        ruleList(sections: [("Overdue", overdueRules)])
                    }
                } else if allRules.isEmpty {
                    ScrollView { emptyState.padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm) }
                } else {
                    ruleList(sections:
                        (activeRules.isEmpty ? [] : [("Active", activeRules)])
                        + (pausedRules.isEmpty ? [] : [("Paused", pausedRules)])
                    )
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(showOnlyOverdue ? "Overdue" : "Recurring")
            .tulaNavigationSubtitle(showOnlyOverdue ? "" : monthlySubtitle)
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
            .sheet(isPresented: $showingVariableAmountSheet) {
                variableAmountSheet
            }
        }
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Native List

    /// Uses a native `List` so `.swipeActions` work perfectly with
    /// scrolling — no gesture conflicts, standard iOS discoverability.
    private func ruleList(sections: [(title: String, rules: [RecurringRule])]) -> some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.rules) { rule in
                        Button {
                            Haptics.tap()
                            editingRule = rule
                        } label: {
                            RuleRow(rule: rule)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if !rule.isPaused {
                                Button {
                                    markPaid(rule)
                                } label: {
                                    Label("Paid", systemImage: "checkmark.circle.fill")
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                ruleToDelete = rule
                                showingDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)

                            if !rule.isPaused {
                                Button {
                                    skipNextOccurrence(rule)
                                } label: {
                                    Label("Skip", systemImage: "forward.fill")
                                }
                                .tint(.orange)
                            }
                        }
                        .contextMenu {
                            if !rule.isPaused {
                                Button { markPaid(rule) } label: {
                                    Label("Mark Paid", systemImage: "checkmark.circle.fill")
                                }
                                Button { skipNextOccurrence(rule) } label: {
                                    Label("Skip Next", systemImage: "forward.fill")
                                }
                                Button { snoozeRule(rule, days: 7) } label: {
                                    Label("Snooze 1 Week", systemImage: "moon.zzz.fill")
                                }
                                Button { snoozeRule(rule, days: 30) } label: {
                                    Label("Snooze 1 Month", systemImage: "calendar.badge.clock")
                                }
                            } else {
                                Button { resumeRule(rule) } label: {
                                    Label("Resume Now", systemImage: "play.fill")
                                }
                            }
                            Divider()
                            Button { Haptics.tap(); editingRule = rule } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                ruleToDelete = rule
                                showingDeleteConfirm = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .confirmationDialog(
                            "Delete \(rule.name)?",
                            isPresented: Binding(
                                get: { ruleToDelete?.id == rule.id && showingDeleteConfirm },
                                set: { if !$0 { ruleToDelete = nil; showingDeleteConfirm = false } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Delete", role: .destructive) {
                                deleteRule(rule)
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This recurring rule will be permanently removed.")
                        }
                        .confirmationDialog(
                            "Log \(rule.name)?",
                            isPresented: Binding(
                                get: { ruleToLog?.id == rule.id && showingLogConfirm },
                                set: { if !$0 { ruleToLog = nil; showingLogConfirm = false } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Log") {
                                if let date = logDate {
                                    logRule(rule, date: date)
                                }
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("This will record \(Currency.format(rule.amount, code: currencyCode)) as an expense.")
                        }
                    }
                } header: {
                    Text(section.title)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Amount + date/time input sheet — shown when logging a variable-amount
    /// rule, or any rule whose stored amount is 0, so the user can enter
    /// the actual amount and confirm (or adjust) when it was paid.
    private var variableAmountSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(ruleToLog?.name ?? "Amount")
                            .foregroundStyle(.secondary)
                        Spacer()
                        FormattedAmountField(
                            value: $variableAmount,
                            currencyCode: currencyCode,
                            placeholder: "0"
                        )
                    }
                } header: {
                    Text("How much was this?")
                } footer: {
                    if let rule = ruleToLog, rule.amount > 0 {
                        Text("Last recorded: \(Currency.format(rule.amount, code: currencyCode))")
                    }
                }

                Section {
                    DatePicker("Date", selection: $sheetLogDate, displayedComponents: .date)
                    DatePicker("Time", selection: $sheetLogDate, displayedComponents: .hourAndMinute)
                } header: {
                    Text("When")
                } footer: {
                    Text("Defaults to the scheduled date. Change if you're logging late or backdating.")
                }
            }
            .navigationTitle("Log Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingVariableAmountSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") {
                        guard let rule = ruleToLog else { return }
                        // Pass logDate as originalDueDate so the notification
                        // keyed on the scheduled date is cancelled even when
                        // the user picks a different date in the sheet.
                        logRule(rule, date: sheetLogDate, customAmount: variableAmount, originalDueDate: logDate)
                        showingVariableAmountSheet = false
                    }
                    .fontWeight(.semibold)
                    .disabled(variableAmount <= 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Skips the next occurrence of a recurring rule. For overdue rules,
    /// advances `lastGeneratedDate` (and `lastPaidDate` for bills) past
    /// all overdue dates so the overdue tag clears immediately. For
    /// non-overdue rules, pauses until just after the next due date.
    private func skipNextOccurrence(_ rule: RecurringRule) {
        let overdueDates = RecurringEngine.overdueDates(for: rule)
        if !overdueDates.isEmpty {
            // Skip all overdue occurrences by advancing the boundary
            withAnimation(AppAnimation.snappy) {
                if let latest = overdueDates.last {
                    RecurringEngine.skipOccurrence(rule: rule, dueDate: latest)
                    if rule.isBill {
                        rule.lastPaidDate = .now
                    }
                }
                context.safeSave()
            }
        } else {
            guard let nextDue = RecurringEngine.nextDueDate(for: rule) else { return }
            // Pause until the day after the next due date
            let resumeDate = Calendar.current.date(byAdding: .day, value: 1, to: nextDue) ?? nextDue
            withAnimation(AppAnimation.snappy) {
                rule.isPaused = true
                rule.pausedUntil = resumeDate
                context.safeSave()
            }
        }
        NotificationManager.cancelConfirmations(for: rule.id)
        Haptics.success()
    }

    /// Snoozes the rule for the given number of days from now.
    private func snoozeRule(_ rule: RecurringRule, days: Int) {
        let resumeDate = Calendar.current.date(byAdding: .day, value: days, to: .now) ?? .now
        withAnimation(AppAnimation.snappy) {
            rule.isPaused = true
            rule.pausedUntil = resumeDate
            context.safeSave()
        }
        NotificationManager.cancelConfirmations(for: rule.id)
        Haptics.success()
    }

    /// Immediately resumes a paused rule.
    private func resumeRule(_ rule: RecurringRule) {
        withAnimation(AppAnimation.snappy) {
            rule.isPaused = false
            rule.pausedUntil = nil
            context.safeSave()
        }
        RecurringEngine.generateMissing(in: context)
        Haptics.success()
    }

    private func deleteRule(_ rule: RecurringRule) {
        NotificationManager.cancelConfirmations(for: rule.id)
        withAnimation(AppAnimation.snappy) {
            context.delete(rule)
            context.safeSave()
            WidgetRefresh.refresh(using: context)
        }
        Haptics.success()
    }

    /// Route the "Mark Paid" action. Fixed-amount rules (amount > 0) show a
    /// simple confirmation dialog; variable-amount or zero-amount rules open
    /// the amount + date sheet so the user can enter the actual bill amount.
    private func markPaid(_ rule: RecurringRule) {
        let overdueDates = RecurringEngine.overdueDates(for: rule)
        let date = overdueDates.first ?? RecurringEngine.nextDueDate(for: rule) ?? .now
        ruleToLog = rule
        logDate = date

        if rule.isVariable || rule.amount == 0 {
            // Pre-fill with prediction (uses history) or fall back to rule amount.
            let prediction = SmartAmountPredictor.predict(for: rule, on: date)
            variableAmount = prediction.amount
            sheetLogDate = defaultSheetDate(rule: rule, scheduledDate: date)
            showingVariableAmountSheet = true
        } else {
            showingLogConfirm = true
        }
    }

    /// Returns a default date/time for the amount sheet.
    /// - For rules with a specific time, use the scheduled date as-is.
    /// - For all-day rules (hasSpecificTime == false), keep the scheduled
    ///   calendar date but substitute the current wall-clock time so the
    ///   picker doesn't show midnight as the default.
    private func defaultSheetDate(rule: RecurringRule, scheduledDate: Date) -> Date {
        guard !rule.hasSpecificTime else { return scheduledDate }
        let cal = Calendar.current
        let scheduledComponents = cal.dateComponents([.year, .month, .day], from: scheduledDate)
        let nowComponents = cal.dateComponents([.hour, .minute], from: Date())
        var merged = scheduledComponents
        merged.hour = nowComponents.hour
        merged.minute = nowComponents.minute
        return cal.date(from: merged) ?? scheduledDate
    }

    /// Log a recurring rule occurrence as an expense. When `customAmount`
    /// is provided (variable-amount bills), the expense is created with
    /// that amount. `originalDueDate` is the scheduled date used to key
    /// the pending notification — needed when the user picks a different
    /// date in the sheet so we still cancel the right notification.
    private func logRule(_ rule: RecurringRule, date: Date, customAmount: Double? = nil, originalDueDate: Date? = nil) {
        Haptics.success()
        withAnimation(AppAnimation.snappy) {
            RecurringEngine.createTransaction(rule: rule, date: date, in: context, customAmount: customAmount)
            if rule.lastGeneratedDate == nil || rule.lastGeneratedDate! < date {
                rule.lastGeneratedDate = date
            }
            // Update lastPaidDate for bill rules so the overdue tag clears.
            // Use .now (not the overdue date) so BillReminderEngine sees it
            // as paid in the current month — matches markAsPaid semantics.
            if rule.isBill {
                rule.lastPaidDate = .now
            }
            context.safeSave()
            WidgetRefresh.refresh(using: context)
        }
        // Cancel notification keyed on the original scheduled due date.
        // If the user changed the date in the sheet, also cancel by that
        // date so we don't leave a stale notification behind.
        NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: date)
        if let original = originalDueDate, !Calendar.current.isDate(original, inSameDayAs: date) {
            NotificationManager.cancelConfirmation(ruleID: rule.id, dueDate: original)
        }
    }

    private func monthlyTotal(for rules: [RecurringRule]) -> Double {
        rules
            .filter { $0.kind == .expense && !$0.isPaused }
            .reduce(0.0) { sum, rule in
                switch rule.frequency {
                case .weekly:
                    return sum + rule.amount * 4.33
                case .monthly:
                    return sum + rule.amount
                case .yearly:
                    return sum + rule.amount / 12.0
                case .custom:
                    switch rule.customUnit {
                    case .day:
                        return sum + rule.amount * (30.0 / Double(max(rule.customInterval, 1)))
                    case .week:
                        return sum + rule.amount * (4.33 / Double(max(rule.customInterval, 1)))
                    case .month:
                        return sum + rule.amount / Double(max(rule.customInterval, 1))
                    case .year:
                        return sum + rule.amount / (12.0 * Double(max(rule.customInterval, 1)))
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
        if rule.isPaused {
            // Show resume date when set — gives the user context about
            // when the rule will start producing transactions again.
            if let until = rule.pausedUntil, until > .now {
                let untilStr = until.formatted(.dateTime.day().month(.abbreviated))
                return "Paused · resumes \(untilStr)"
            }
            return "Paused"
        }
        if hasOrphanedRelationship {
            switch rule.kind {
            case .expense:     return "Missing category or account"
            case .transfer, .cardPayment: return "Missing linked account"
            }
        }
        if rule.isBill {
            let countdown = BillReminderEngine.countdownLabel(for: rule)
            return "\(countdown) · \(rule.cadenceLabel)"
        }
        if let next = RecurringEngine.nextDueDate(for: rule) {
            let nextStr = next.formatted(.dateTime.day().month(.abbreviated))
            return "Next: \(nextStr) · \(rule.cadenceLabel)"
        }
        return rule.cadenceLabel.capitalized
    }

    /// True when a relationship this rule depends on has been deleted.
    /// Expense rules need a category; transfer rules need from/to accounts.
    /// Only warns for rules that have actually generated transactions
    /// (lastGeneratedDate != nil), so brand-new rules aren't flagged.
    private var hasOrphanedRelationship: Bool {
        guard rule.lastGeneratedDate != nil else { return false }
        switch rule.kind {
        case .expense:
            return rule.category == nil || rule.account == nil
        case .transfer, .cardPayment:
            return rule.fromAccount == nil || rule.toAccount == nil
        }
    }

    /// Urgency color for bill countdown — green (>3d), amber (1-3d), red (overdue).
    private var billUrgencyColor: Color? {
        guard rule.isBill, !rule.isPaused else { return nil }
        switch BillReminderEngine.countdownColor(for: rule) {
        case .normal: return .green
        case .warning: return .orange
        case .urgent, .overdue: return .red
        }
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
            .overlay(alignment: .topTrailing) {
                if hasOrphanedRelationship {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .offset(x: 4, y: -4)
                }
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

            VStack(alignment: .trailing, spacing: 2) {
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

                if let urgency = billUrgencyColor {
                    Text(BillReminderEngine.countdownLabel(for: rule))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(urgency, in: Capsule())
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .opacity(rule.isPaused ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(rule.name), \(rule.isVariable ? "variable amount" : Currency.format(rule.amount, code: currencyCode)), \(rule.cadenceLabel)")
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
    @State private var isBill: Bool
    @State private var billDueDayOfMonth: Int
    @State private var reminderDaysBefore: Int
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
            _isBill = State(initialValue: r.isBill)
            _billDueDayOfMonth = State(initialValue: max(r.dueDayOfMonth, 1))
            _reminderDaysBefore = State(initialValue: r.reminderDaysBefore)
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
            _isBill = State(initialValue: false)
            _billDueDayOfMonth = State(initialValue: Calendar.current.component(.day, from: .now))
            _reminderDaysBefore = State(initialValue: 3)
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
        _isBill = State(initialValue: false)
        _billDueDayOfMonth = State(initialValue: suggestion.dayOfMonth)
        _reminderDaysBefore = State(initialValue: 3)
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
                billSection
                routingSection
                scheduleSection
                confirmationSection
                if isEditing {
                    pauseSection
                    deleteSection
                }
            }
            .navigationTitle(isEditing ? "Edit Rule" : (isBill ? "New Bill" : "New Rule"))
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
        }
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section {
            TextField("Name (e.g. Rent, Netflix)", text: $name)
                .textInputAutocapitalization(.words)
            if !isVariable {
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
            Toggle(isOn: $isVariable.animation(.snappy(duration: 0.25))) {
                Text("Variable amount")
            }
            .onChange(of: isVariable) { _, newValue in
                if newValue {
                    confirmationRequired = true
                    amount = 0
                }
            }
            TextField("Merchant (optional)", text: $merchant)
                .textInputAutocapitalization(.words)
            TextField("Note (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
        } header: {
            Text("Details")
        } footer: {
            if isVariable {
                Text("Amount varies each time (e.g. power bill, fuel). You'll enter the actual amount when logging.")
            } else if !merchant.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Expenses will be logged under \"\(merchant.trimmingCharacters(in: .whitespaces))\" as merchant.")
            }
        }
    }

    @ViewBuilder
    private var billSection: some View {
        Section {
            Toggle(isOn: $isBill.animation(.snappy(duration: 0.25))) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This is a bill")
                        .font(.body)
                    Text("Get reminders before the due date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: isBill) { _, newValue in
                if newValue {
                    dayOfMonth = billDueDayOfMonth
                }
            }

            if isBill {
                Stepper(value: $billDueDayOfMonth, in: 1...31) {
                    Text("Due on day \(billDueDayOfMonth)")
                }
                .onChange(of: billDueDayOfMonth) { _, newValue in
                    dayOfMonth = newValue
                }

                Stepper(value: $reminderDaysBefore, in: 1...14) {
                    Text("Remind \(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before")
                }
            }
        } header: {
            Text("Bill")
        } footer: {
            if isBill {
                Text("You'll receive a notification \(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before day \(billDueDayOfMonth) each period.")
            }
        }
    }

    @ViewBuilder
    private var routingSection: some View {
        Section {
            Picker("Type", selection: $kind) {
                Text("Expense").tag(RecurringKind.expense)
                Text("Card Payment").tag(RecurringKind.cardPayment)
                Text("Transfer").tag(RecurringKind.transfer)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if kind == .expense {
                categoryPicker
                accountPicker(selection: $account, label: "Pay from")
            } else {
                accountPicker(selection: $fromAccount, label: "From")
                accountPicker(selection: $toAccount, label: "To")
            }
        } header: {
            Text("Type & Account")
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
            // When isBill, the bill due day drives the schedule — no
            // separate day-of-month picker needed.
            if !isBill {
                monthlyStepperRow
            }
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
        context.safeSave(); WidgetRefresh.refresh(using: context)
        // Re-run the engine so any new confirmation rule starts firing
        // notifications immediately (and any edited rule picks up its
        // new time/amount), instead of waiting for the next app launch.
        // For auto-log rules this also generates any past-due
        // occurrences if startDate is in the past.
        RecurringEngine.generateMissing(in: context)
        // Reschedule bill reminders if this is a bill rule
        if isBill {
            let bills = (try? context.fetch(FetchDescriptor<RecurringRule>(
                predicate: #Predicate { $0.isBill == true }
            ))) ?? []
            BillReminderEngine.scheduleBillReminders(rules: bills)
        }
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

        // Bill fields
        rule.isBill = isBill
        rule.dueDayOfMonth = isBill ? billDueDayOfMonth : 0
        rule.reminderDaysBefore = isBill ? reminderDaysBefore : 3

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
        context.safeSave(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }
}


