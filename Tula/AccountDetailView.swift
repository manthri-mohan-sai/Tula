import SwiftUI
import SwiftData

/// Drill-in view for a single account. For credit cards, surfaces "Pay Bill"
/// as the headline action. For all accounts, shows the transaction history
/// (expenses + transfers, merged and sorted by date).
struct AccountDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var account: Account
    @PrimaryCurrency private var currencyCode

    @State private var showingPayBill = false
    @State private var showingTransfer = false
    @State private var showingTopUp = false
    @State private var showingEditAccount = false
    @State private var editingExpense: Expense?
    @State private var editingTransfer: Transfer?
    @State private var deletingAdjustment: BalanceAdjustment?
    @State private var showingUpdateBalance = false
    @State private var timelineScope: TimelineScope = .thisMonth
    @State private var timelineSort: TimelineSort = .dateNewest
    @State private var searchText: String = ""

    enum TimelineScope: String, CaseIterable {
        case thisMonth = "This Month"
        case lastMonth = "Last Month"
        case all = "All Time"
    }

    enum TimelineSort: String, CaseIterable {
        case dateNewest = "Newest First"
        case dateOldest = "Oldest First"
        case amountHighest = "Highest Amount"
        case amountLowest = "Lowest Amount"
    }

    private var color: Color { Color(hex: account.colorHex) }

    /// Date window for the selected scope. nil = all time.
    private var scopeWindow: DateInterval? {
        let cal = Calendar.current
        switch timelineScope {
        case .thisMonth:
            return cal.dateInterval(of: .month, for: .now)
        case .lastMonth:
            guard let lastMonth = cal.date(byAdding: .month, value: -1, to: .now) else { return nil }
            return cal.dateInterval(of: .month, for: lastMonth)
        case .all:
            return nil
        }
    }

    /// Combined timeline of activity on this account, filtered by scope and search.
    private var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        let window = scopeWindow
        for expense in account.expenses {
            if let w = window, expense.date < w.start || expense.date >= w.end { continue }
            items.append(.expense(expense))
        }
        for transfer in account.outgoingTransfers {
            if let w = window, transfer.date < w.start || transfer.date >= w.end { continue }
            items.append(.transferOut(transfer))
        }
        for transfer in account.incomingTransfers {
            if let w = window, transfer.date < w.start || transfer.date >= w.end { continue }
            items.append(.transferIn(transfer))
        }
        for adjustment in account.adjustments {
            if let w = window, adjustment.date < w.start || adjustment.date >= w.end { continue }
            items.append(.adjustment(adjustment))
        }
        // Apply search filter
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { $0.matchesSearch(query) }
        }
        switch timelineSort {
        case .dateNewest:    return items.sorted { $0.date > $1.date }
        case .dateOldest:    return items.sorted { $0.date < $1.date }
        case .amountHighest: return items.sorted { $0.amount > $1.amount }
        case .amountLowest:  return items.sorted { $0.amount < $1.amount }
        }
    }

    /// Timeline items grouped by date for sectioned display.
    private var groupedTimeline: [(label: String, items: [TimelineItem])] {
        var groups: [(label: String, items: [TimelineItem])] = []
        for item in timeline {
            let label = dateSectionLabel(for: item.date)
            if let lastIndex = groups.indices.last, groups[lastIndex].label == label {
                groups[lastIndex].items.append(item)
            } else {
                groups.append((label: label, items: [item]))
            }
        }
        return groups
    }

    private func dateSectionLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    /// Total spending for displayed expenses.
    private var timelineSpent: Double {
        timeline.compactMap {
            if case .expense(let e) = $0 { return e.amount }
            return nil
        }.reduce(0, +)
    }

    private var balanceLabel: String { account.displayLabel }

    /// This month's spending on this account (independent of timeline scope).
    private var thisMonthStats: (spent: Double, count: Int) {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: .now) else { return (0, 0) }
        let monthExpenses = account.expenses.filter {
            $0.date >= interval.start && $0.date < interval.end
        }
        let total = monthExpenses.reduce(0) { $0 + $1.amount }
        return (total, monthExpenses.count)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, Spacing.xxl)
                actionButtons
                    .padding(.bottom, Spacing.xxxl)
                timelineSection
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .background {
            ZStack {
                Color.tulaBackground
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            color.opacity(0.25),
                            color.opacity(0.08),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 420)
                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea()
        }
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search transactions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showingEditAccount = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.body.weight(.medium))
                }
                .tint(.primary)
                .accessibilityLabel("Edit account")
            }
        }
        .sheet(isPresented: $showingEditAccount) {
            AccountFormView(account: account)
        }
        .sheet(isPresented: $showingTopUp) {
            TransferFormView(
                presetKind: .topUp,
                presetToAccount: account
            )
        }
        .sheet(isPresented: $showingPayBill) {
            TransferFormView(
                presetKind: .cardBillPayment,
                presetToAccount: account,
                presetAmount: max(0, account.derivedBalance)
            )
        }
        .sheet(isPresented: $showingTransfer) {
            TransferFormView(presetFromAccount: account)
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(existingExpense: expense)
        }
        .sheet(item: $editingTransfer) { transfer in
            TransferFormView(existingTransfer: transfer)
        }
        .sheet(isPresented: $showingUpdateBalance) {
            UpdateBalanceView(account: account)
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: Spacing.lg) {
            // Account identity — icon + kind label
            VStack(spacing: Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: account.iconKey)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(color)
                }

                Text(account.kind.displayName.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            // Balance — the star, clearly separated from identity
            VStack(spacing: Spacing.xs) {
                Text(Currency.format(account.displayAmount, code: currencyCode))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: account.displayAmount))
                    .animation(.snappy(duration: 0.35), value: account.displayAmount)

                Text(balanceLabel)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if account.kind == .creditCard, let limit = account.creditLimit, limit > 0 {
                creditLimitBar(used: account.derivedBalance, limit: limit)
                    .padding(.horizontal, Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func creditLimitBar(used: Double, limit: Double) -> some View {
        let fraction = min(1, max(0, used / limit))
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(color.opacity(0.15))
                        .frame(height: 8)
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * fraction), height: 8)
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(Int(fraction * 100))% used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Limit \(Currency.compact(limit, code: currencyCode))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private var actionButtons: some View {
        HStack(spacing: Spacing.xxl) {
            if account.kind == .creditCard && account.derivedBalance > 0.01 {
                circularActionButton(
                    title: "Pay Bill",
                    icon: "indianrupeesign"
                ) {
                    Haptics.tap()
                    showingPayBill = true
                }
            }
            if account.kind == .wallet || account.kind == .cash || account.kind == .bank {
                circularActionButton(
                    title: account.kind == .bank ? "Money In" : "Top Up",
                    icon: "plus"
                ) {
                    Haptics.tap()
                    showingTopUp = true
                }
            }
            circularActionButton(
                title: "Transfer",
                icon: "arrow.left.arrow.right"
            ) {
                Haptics.tap()
                showingTransfer = true
            }
            circularActionButton(
                title: "Adjust",
                icon: "slider.horizontal.3"
            ) {
                Haptics.tap()
                showingUpdateBalance = true
            }
        }
    }

    private func circularActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill(color.opacity(0.85))
                    )
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.92))
        .accessibilityLabel(title)
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Segmented scope picker
            Picker("Period", selection: $timelineScope.animation(AppAnimation.snappy)) {
                ForEach(TimelineScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            // Compact period context — tightly coupled to picker
            HStack(alignment: .firstTextBaseline) {
                Text(timeline.isEmpty
                     ? "No spending"
                     : "\(Currency.format(timelineSpent, code: currencyCode)) spent · \(timeline.count) transaction\(timeline.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: timelineSpent))
                    .animation(.snappy(duration: 0.35), value: timelineSpent)

                Spacer()

                if !timeline.isEmpty {
                    Menu {
                        ForEach(TimelineSort.allCases, id: \.self) { sort in
                            Button {
                                withAnimation(AppAnimation.snappy) {
                                    timelineSort = sort
                                }
                            } label: {
                                if sort == timelineSort {
                                    Label(sort.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(sort.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                }
            }
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)

            if timeline.isEmpty {
                emptyTimeline
            } else {
                VStack(spacing: Spacing.xl) {
                    ForEach(Array(groupedTimeline.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            Text(group.label)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                                VStack(spacing: 0) {
                                    ForEach(group.items) { item in
                                        timelineRow(item)
                                        if item.id != group.items.last?.id {
                                            Divider().padding(.leading, 64)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem) -> some View {
        switch item {
        case .expense(let expense):
            Button {
                Haptics.tap()
                editingExpense = expense
            } label: {
                ExpenseRow(expense: expense, showTimeOnly: true)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())

        case .transferIn(let transfer):
            Button {
                Haptics.tap()
                editingTransfer = transfer
            } label: {
                TransferRow(transfer: transfer, perspective: .incoming)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())

        case .transferOut(let transfer):
            Button {
                Haptics.tap()
                editingTransfer = transfer
            } label: {
                TransferRow(transfer: transfer, perspective: .outgoing)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())

        case .adjustment(let adjustment):
            Button {
                Haptics.tap()
                deletingAdjustment = adjustment
            } label: {
                AdjustmentRow(adjustment: adjustment)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())
            .confirmationDialog(
                "Delete this balance adjustment?",
                isPresented: Binding(
                    get: { deletingAdjustment?.id == adjustment.id },
                    set: { if !$0 { deletingAdjustment = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    context.delete(adjustment)
                    try? context.save(); WidgetRefresh.refresh(using: context)
                    Haptics.warning()
                    deletingAdjustment = nil
                }
                Button("Cancel", role: .cancel) { deletingAdjustment = nil }
            } message: {
                Text("The account balance will recalculate without this adjustment.")
            }
        }
    }

    private var emptyTimeline: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(timelineScope == .all ? "No activity yet" : "No activity \(timelineScope.rawValue.lowercased())")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }
}

// MARK: - Timeline Item

enum TimelineItem: Identifiable {
    case expense(Expense)
    case transferIn(Transfer)
    case transferOut(Transfer)
    case adjustment(BalanceAdjustment)

    var id: UUID {
        switch self {
        case .expense(let e): return e.id
        case .transferIn(let t): return t.id
        case .transferOut(let t): return t.id
        case .adjustment(let a): return a.id
        }
    }

    var date: Date {
        switch self {
        case .expense(let e): return e.date
        case .transferIn(let t): return t.date
        case .transferOut(let t): return t.date
        case .adjustment(let a): return a.date
        }
    }

    var amount: Double {
        switch self {
        case .expense(let e): return e.amount
        case .transferIn(let t): return t.amount
        case .transferOut(let t): return t.amount
        case .adjustment(let a): return abs(a.delta)
        }
    }

    /// Searchable text fragments for this timeline item.
    func matchesSearch(_ query: String) -> Bool {
        let q = query.lowercased()
        switch self {
        case .expense(let e):
            if e.merchant?.lowercased().contains(q) == true { return true }
            if e.note?.lowercased().contains(q) == true { return true }
            if e.category?.name.lowercased().contains(q) == true { return true }
            return false
        case .transferIn(let t), .transferOut(let t):
            if t.note?.lowercased().contains(q) == true { return true }
            if t.fromAccount?.name.lowercased().contains(q) == true { return true }
            if t.toAccount?.name.lowercased().contains(q) == true { return true }
            return false
        case .adjustment(let a):
            if a.note?.lowercased().contains(q) == true { return true }
            return false
        }
    }
}

// MARK: - Transfer Row

struct TransferRow: View {
    let transfer: Transfer
    let perspective: TransferPerspective
    @PrimaryCurrency private var currencyCode

    enum TransferPerspective { case incoming, outgoing }

    private var icon: String {
        switch transfer.kind {
        case .cardBillPayment: return "indianrupeesign.circle.fill"
        case .withdrawal:      return "arrow.up.right.circle.fill"
        case .deposit:         return "arrow.down.left.circle.fill"
        case .topUp:           return "plus.circle.fill"
        case .generic:         return "arrow.left.arrow.right.circle.fill"
        }
    }

    private var label: String {
        switch transfer.kind {
        case .cardBillPayment:
            return perspective == .incoming ? "Bill payment received" : "Card bill paid"
        case .withdrawal:
            return perspective == .incoming ? "Cash withdrawn" : "Withdrew cash"
        case .deposit:
            return perspective == .incoming ? "Cash deposited" : "Deposited cash"
        case .topUp:
            let isBankTarget = transfer.toAccount?.kind == .bank
            if perspective == .incoming {
                if let from = transfer.fromAccount {
                    return isBankTarget ? "Money in from \(from.name)" : "Top up from \(from.name)"
                }
                return isBankTarget ? "Money in" : "Top up"
            } else {
                if let to = transfer.toAccount {
                    return isBankTarget ? "Money in to \(to.name)" : "Top up to \(to.name)"
                }
                return isBankTarget ? "Money in" : "Top up"
            }
        case .generic:
            if let other = (perspective == .incoming ? transfer.fromAccount : transfer.toAccount) {
                return perspective == .incoming ? "From \(other.name)" : "To \(other.name)"
            }
            return "Transfer"
        }
    }

    private var color: Color {
        perspective == .incoming ? .green : .blue
    }

    private var amountPrefix: String {
        perspective == .incoming ? "+" : "−"
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let note = transfer.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(amountPrefix)\(Currency.format(transfer.amount, code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(relativeDateString(for: transfer.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func relativeDateString(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Adjustment Row

struct AdjustmentRow: View {
    let adjustment: BalanceAdjustment
    @PrimaryCurrency private var currencyCode

    private var deltaPrefix: String { adjustment.delta >= 0 ? "+" : "−" }
    private var deltaColor: Color { adjustment.delta >= 0 ? .green : .orange }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Balance updated to \(Currency.format(adjustment.resultingBalance, code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(adjustment.source == .billPayment ? "After bill payment" : "Manual adjustment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(deltaPrefix)\(Currency.format(abs(adjustment.delta), code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
                Text(relativeDateString(for: adjustment.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func relativeDateString(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
