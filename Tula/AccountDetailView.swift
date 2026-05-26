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
    @State private var editingExpense: Expense?

    private var color: Color { Color(hex: account.colorHex) }

    /// Combined timeline of activity on this account, expenses and transfers
    /// merged and sorted by date.
    private var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        for expense in account.expenses {
            items.append(.expense(expense))
        }
        for transfer in account.outgoingTransfers {
            items.append(.transferOut(transfer))
        }
        for transfer in account.incomingTransfers {
            items.append(.transferIn(transfer))
        }
        return items.sorted { $0.date > $1.date }
    }

    /// The balance label that fits the account kind's mental model.
    private var balanceLabel: String {
        switch account.kind {
        case .creditCard: return "Outstanding"
        case .cash: return "On hand"
        case .bank, .wallet: return "Net flow this period"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                heroCard
                actionButtons
                timelineSection
            }
            .padding(.horizontal)
            .padding(.bottom, Spacing.xxl)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(account.name)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.20))
                        .frame(width: 48, height: 48)
                    Image(systemName: account.iconKey)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(account.name)
                        .font(.headline)
                    Text(account.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(balanceLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .padding(.top, Spacing.sm)

            Text(Currency.format(account.derivedBalance, code: currencyCode))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if account.kind == .creditCard, let limit = account.creditLimit, limit > 0 {
                creditLimitBar(used: account.derivedBalance, limit: limit)
                    .padding(.top, Spacing.sm)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.12), color.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
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
        HStack(spacing: Spacing.sm) {
            if account.kind == .creditCard && account.derivedBalance > 0.01 {
                primaryActionButton(
                    title: "Pay Bill",
                    icon: "indianrupeesign.circle.fill"
                ) {
                    Haptics.tap()
                    showingPayBill = true
                }
            }
            secondaryActionButton(
                title: "Move Money",
                icon: "arrow.left.arrow.right"
            ) {
                Haptics.tap()
                showingTransfer = true
            }
        }
    }

    private func primaryActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaBrandFallback)
            )
        }
    }

    private func secondaryActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .foregroundStyle(Color.tulaBrandFallback)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaBrandFallback.opacity(0.12))
            )
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Activity")

            if timeline.isEmpty {
                emptyTimeline
            } else {
                Card(padding: 0, cornerRadius: CornerRadius.medium) {
                    VStack(spacing: 0) {
                        ForEach(timeline) { item in
                            timelineRow(item)
                            if item.id != timeline.last?.id {
                                Divider().padding(.leading, 64)
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
                ExpenseRow(expense: expense)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())

        case .transferIn(let transfer):
            TransferRow(transfer: transfer, perspective: .incoming)
                .padding(.horizontal, Spacing.md)

        case .transferOut(let transfer):
            TransferRow(transfer: transfer, perspective: .outgoing)
                .padding(.horizontal, Spacing.md)
        }
    }

    private var emptyTimeline: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "tray")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No activity yet")
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

    var id: UUID {
        switch self {
        case .expense(let e): return e.id
        case .transferIn(let t): return t.id
        case .transferOut(let t): return t.id
        }
    }

    var date: Date {
        switch self {
        case .expense(let e): return e.date
        case .transferIn(let t): return t.date
        case .transferOut(let t): return t.date
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
