import SwiftUI
import SwiftData
import Charts

struct HomeView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query private var allMerchantRules: [MerchantRule]
    @PrimaryCurrency private var currencyCode

    let onShowStats: () -> Void

    @State private var showingAddExpense = false
    @State private var editingExpense: Expense?
    @State private var toastMessage: String?

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""

    init(onShowStats: @escaping () -> Void = {}) {
        self.onShowStats = onShowStats
    }

    // MARK: - Derived

    private var thisMonthExpenses: [Expense] {
        let cal = Calendar.current
        guard let monthStart = cal.dateInterval(of: .month, for: .now)?.start else { return [] }
        return allExpenses.filter { $0.date >= monthStart }
    }

    private var totalThisMonth: Double {
        thisMonthExpenses.reduce(0) { $0 + $1.amount }
    }

    private var monthOverMonthChange: Double? {
        let cal = Calendar.current
        let dayOfMonth = cal.component(.day, from: .now)
        guard let thisStart = cal.dateInterval(of: .month, for: .now)?.start,
              let lastStart = cal.date(byAdding: .month, value: -1, to: thisStart),
              let comparablePoint = cal.date(byAdding: .day, value: dayOfMonth, to: lastStart) else { return nil }
        let lastSameWindow = allExpenses
            .filter { $0.date >= lastStart && $0.date < comparablePoint }
            .reduce(0) { $0 + $1.amount }
        guard lastSameWindow > 0 else { return nil }
        return (totalThisMonth - lastSameWindow) / lastSameWindow
    }

    private var creditCards: [Account] {
        allAccounts.filter { $0.kind == .creditCard && !$0.isArchived }
    }

    private var recentExpenses: [Expense] {
        Array(allExpenses.prefix(10))
    }

    private var last7DaysData: [(day: Date, total: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var data: [(Date, Double)] = []
        for offset in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let total = allExpenses
                .filter { $0.date >= day && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            data.append((day, total))
        }
        return data
    }

    private var defaultAccount: Account? {
        if !lastUsedAccountID.isEmpty,
           let uuid = UUID(uuidString: lastUsedAccountID),
           let match = allAccounts.first(where: { $0.id == uuid && !$0.isArchived }) {
            return match
        }
        return allAccounts.first(where: { !$0.isArchived })
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    heroCard
                    quickLogBar
                    if !creditCards.isEmpty { cardOutstandingsSection }
                    recentActivitySection
                }
                .padding(.horizontal)
                .padding(.bottom, Spacing.xxl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Tula")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingAddExpense = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingAddExpense) {
                AddExpenseView()
            }
            .sheet(item: $editingExpense) { expense in
                AddExpenseView(existingExpense: expense)
            }
            .overlay(alignment: .top) {
                if let toast = toastMessage {
                    Toast(message: toast)
                        .padding(.top, Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        Button(action: onShowStats) {
            ZStack(alignment: .topTrailing) {
                Text("तुला")
                    .font(.system(size: 140, weight: .bold))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.08))
                    .offset(x: 24, y: -28)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Text(Date.now, format: .dateTime.month(.wide).year())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.8)
                        Spacer()
                        if let change = monthOverMonthChange {
                            monthOverMonthBadge(change)
                        }
                    }

                    Text("Spent this month")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    Text(Currency.format(totalThisMonth, code: currencyCode))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .padding(.top, 2)

                    if !last7DaysData.allSatisfy({ $0.total == 0 }) {
                        HStack(alignment: .bottom, spacing: 0) {
                            miniChart
                                .frame(height: 48)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, Spacing.sm)
                                .padding(.bottom, 14)
                        }
                        .padding(.top, Spacing.md)
                    }
                }
                .padding(Spacing.xl)
            }
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.tulaBrandFallback.opacity(0.12),
                                Color.tulaBrandFallback.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous))
            .foregroundStyle(.primary)
        }
        .buttonStyle(PlainRowButtonStyle())
    }

    private func monthOverMonthBadge(_ change: Double) -> some View {
        let isUp = change > 0
        let symbol = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green
        let percent = Int(abs(change * 100).rounded())

        return HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            Text("\(percent)% vs last")
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var miniChart: some View {
        Chart {
            ForEach(last7DaysData, id: \.day) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Spent", item.total),
                    width: .ratio(0.6)
                )
                .foregroundStyle(Color.tulaBrandFallback.gradient)
                .cornerRadius(4)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Quick Log

    private var quickLogBar: some View {
        QuickLogBar(
            accounts: allAccounts,
            categories: allCategories,
            merchantRules: allMerchantRules,
            defaultAccount: defaultAccount,
            currencyCode: currencyCode,
            onSubmit: handleQuickLog
        )
    }

    private func handleQuickLog(_ parsedExpenses: [ParsedExpense]) {
        let valid = parsedExpenses.filter { $0.isValid }
        guard !valid.isEmpty else { return }

        var lastAccount: Account?
        for parsed in valid {
            guard let account = parsed.account else { continue }
            let expense = Expense(
                amount: parsed.amount,
                merchant: parsed.merchant,
                note: nil,
                source: .nlp,
                category: parsed.category,
                account: account
            )
            expense.rawInput = parsed.rawInput
            context.insert(expense)
            lastAccount = account
        }

        try? context.save()
        if let last = lastAccount {
            lastUsedAccountID = last.id.uuidString
        }
        Haptics.success()

        // Toast: "1 expense saved" or "3 expenses saved"
        let message = valid.count == 1
            ? "Expense saved"
            : "\(valid.count) expenses saved"
        showToast(message)
    }

    private func showToast(_ message: String) {
        withAnimation(AppAnimation.snappy) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation(AppAnimation.gentle) {
                toastMessage = nil
            }
        }
    }

    // MARK: - Card Outstandings

    private var cardOutstandingsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Card Outstandings")

            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(creditCards) { card in
                        NavigationLink {
                            AccountDetailView(account: card)
                        } label: {
                            CardOutstandingRow(card: card)
                        }
                        .buttonStyle(PlainRowButtonStyle())

                        if card.id != creditCards.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Recent Activity")

            if recentExpenses.isEmpty {
                emptyActivityState
            } else {
                Card(padding: 0, cornerRadius: CornerRadius.medium) {
                    VStack(spacing: 0) {
                        ForEach(recentExpenses) { expense in
                            Button {
                                Haptics.tap()
                                editingExpense = expense
                            } label: {
                                ExpenseRow(expense: expense)
                                    .padding(.horizontal, Spacing.md)
                            }
                            .buttonStyle(PlainRowButtonStyle())

                            if expense.id != recentExpenses.last?.id {
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyActivityState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "tray")
                    .font(.title)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: 4) {
                Text("Nothing logged yet")
                    .font(.subheadline.weight(.semibold))
                Text("Tap + or use Quick Log to start")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

// MARK: - Card Outstanding Row

private struct CardOutstandingRow: View {
    let card: Account
    @PrimaryCurrency private var currencyCode

    private var color: Color { Color(hex: card.colorHex) }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: card.iconKey)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                if let limit = card.creditLimit, limit > 0 {
                    let used = card.derivedBalance / limit
                    Text("\(Int(used * 100))% of limit used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Outstanding")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(Currency.format(card.derivedBalance, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(card.derivedBalance > 0.01 ? .primary : .secondary)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.md)
    }
}

// MARK: - Plain Row Button Style

struct PlainRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Toast

/// Subtle success indicator that slides down from the top and disappears
/// after a couple of seconds. Used for non-blocking confirmation of actions
/// like Quick Log save.
private struct Toast: View {
    let message: String

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        )
    }
}

// MARK: - Quick Log Bar

/// Smart NLP input — type something like "350 food and 400 groceries hdfc cc"
/// and it parses into one or more structured expenses live as you type.
/// Hit Enter or tap the arrow to log them all in one go.
private struct QuickLogBar: View {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    let currencyCode: String
    let onSubmit: ([ParsedExpense]) -> Void

    @State private var input: String = ""
    @FocusState private var focused: Bool

    private var parsed: [ParsedExpense] {
        ExpenseParser.parse(
            input: input,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
    }

    private var validParsed: [ParsedExpense] {
        parsed.filter { $0.isValid }
    }

    private var hasPreview: Bool {
        !input.isEmpty && !validParsed.isEmpty
    }

    private var canSubmit: Bool {
        !validParsed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .frame(width: 20)

                TextField("Quick log… try \"350 food and 400 groceries\"", text: $input)
                    .focused($focused)
                    .submitLabel(.send)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { submit() }

                if !input.isEmpty {
                    Button {
                        if canSubmit { submit() } else { Haptics.error() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(canSubmit ? Color.tulaBrandFallback : Color(uiColor: .tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, 14)

            if hasPreview {
                Divider()
                    .padding(.leading, Spacing.lg + 20 + Spacing.md)

                VStack(alignment: .leading, spacing: 6) {
                    if validParsed.count > 1 {
                        HStack {
                            Text("\(validParsed.count) expenses")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.tulaBrandFallback)
                            Spacer()
                            if focused {
                                Text("Enter to save all")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    ForEach(validParsed) { p in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.return.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                            Text(p.summary(currencyCode: currencyCode))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }

                    if validParsed.count == 1, focused {
                        HStack {
                            Spacer()
                            Text("Enter to save")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.sm)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .animation(AppAnimation.snappy, value: hasPreview)
        .animation(AppAnimation.snappy, value: validParsed.count)
    }

    private func submit() {
        let valid = validParsed
        guard !valid.isEmpty else { return }
        onSubmit(valid)
        input = ""
        focused = false
    }
}
