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

    @State private var editingExpense: Expense?
    @State private var showingAllExpenses = false
    @State private var showingSettings = false
    @State private var showingCards = false
    @State private var toastMessage: String?
    @State private var toastToken: UUID = UUID()
    @State private var savePulse: Bool = false
    @State private var heroTapPulse: Bool = false

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

    private var todaysExpenses: [Expense] {
        let start = Calendar.current.startOfDay(for: .now)
        return allExpenses.filter { $0.date >= start }
    }

    private var totalToday: Double {
        todaysExpenses.reduce(0) { $0 + $1.amount }
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

    private var recentExpenses: [Expense] { Array(allExpenses.prefix(5)) }

    private var last7DaysData: [(day: Date, total: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let total = allExpenses
                .filter { $0.date >= day && $0.date < next }
                .reduce(0) { $0 + $1.amount }
            return (day, total)
        }
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
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    heroSection
                    quickLogSection
                    recentSection
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.lg)
            }
            .background(Color.tulaBackground)
            // Dismiss keyboard the instant the user starts scrolling — same
            // pattern as AddExpense and Apple's stock forms. Was previously
            // `.interactively` which required dragging past a threshold.
            .scrollDismissesKeyboard(.immediately)
            // Tap anywhere on the background also dismisses keyboard.
            .background(
                Color.tulaBackground
                    .onTapGesture { hideKeyboard() }
            )
            .navigationTitle("Tula")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showingCards = true
                    } label: {
                        Image(systemName: "creditcard")
                            .font(.body.weight(.medium))
                    }
                    // Neutral tint — these are utility navigations, not
                    // affirmative actions. Brand amber on a navigation
                    // button reads as "primary action" and visually
                    // competes with the hero amount below.
                    .tint(.primary)
                    .accessibilityLabel("Cards")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.body.weight(.medium))
                    }
                    .tint(.primary)
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: $showingCards) {
                CardsView()
            }
            .sheet(item: $editingExpense) { expense in
                AddExpenseView(existingExpense: expense)
            }
            .sheet(isPresented: $showingAllExpenses) {
                AllExpensesView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
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

    /// Hero card with full gradient and the prominent Devanagari watermark
    /// to the right side. The amber sparkline lives at the bottom. Tappable
    /// to drill into Stats — pulses on tap as a visual handshake before
    /// the tab transition.
    private var heroSection: some View {
        Button(action: tapHero) {
            ZStack(alignment: .topTrailing) {
                Text("तुला")
                    .font(.system(size: 130, weight: .bold))
                    .foregroundStyle(Color.tulaBrandFallback.opacity(0.10))
                    .offset(x: 20, y: -26)
                    .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: Spacing.md) {
                    HStack {
                        Text(Date.now, format: .dateTime.month(.wide).year())
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let change = monthOverMonthChange {
                            deltaBadge(change)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spent this month")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HeroAmountText(
                            amount: totalThisMonth,
                            currencyCode: currencyCode,
                            size: 44
                        )
                        .scaleEffect(savePulse ? 1.04 : 1.0)
                        .animation(AppAnimation.bouncy, value: savePulse)
                    }

                    if totalToday > 0 {
                        todayInline
                    }

                    if !last7DaysData.allSatisfy({ $0.total == 0 }) {
                        sparkline
                            .frame(height: 48)
                            .padding(.top, Spacing.sm)
                    }
                }
                .padding(Spacing.lg)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.tulaBrandFallback.opacity(0.14),
                                Color.tulaBrandFallback.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.large, style: .continuous))
            .scaleEffect(heroTapPulse ? 1.02 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: heroTapPulse)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func tapHero() {
        Haptics.tap()
        heroTapPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onShowStats() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { heroTapPulse = false }
    }

    private func deltaBadge(_ change: Double) -> some View {
        let isUp = change > 0
        let symbol = isUp ? "arrow.up.right" : "arrow.down.right"
        let color: Color = isUp ? .red : .green
        let percent = Int(abs(change * 100).rounded())
        return HStack(spacing: 3) {
            Image(systemName: symbol).font(.caption2.weight(.bold))
            Text("\(percent)%").font(.caption.weight(.semibold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private var todayInline: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sun.max.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Today")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(Currency.format(totalToday, code: currencyCode))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("·").foregroundStyle(.tertiary)
            Text("\(todaysExpenses.count) tx")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    /// Amber sparkline — primary brand color back on this since the user
    /// specifically called out wanting amber here.
    private var sparkline: some View {
        Chart {
            ForEach(last7DaysData, id: \.day) { item in
                BarMark(
                    x: .value("Day", item.day, unit: .day),
                    y: .value("Spent", item.total),
                    width: .ratio(0.55)
                )
                .foregroundStyle(Color.tulaBrandFallback.gradient)
                .cornerRadius(3)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    // MARK: - Quick Log

    private var quickLogSection: some View {
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
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        showToast(valid.count == 1 ? "Expense saved" : "\(valid.count) expenses saved")
    }

    private func triggerSavePulse() {
        savePulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { savePulse = false }
    }

    private func showToast(_ message: String) {
        let token = UUID()
        toastToken = token
        withAnimation(AppAnimation.snappy) { toastMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard toastToken == token else { return }
            withAnimation(AppAnimation.gentle) { toastMessage = nil }
        }
    }

    // MARK: - Recent

    /// Recent expenses use a native `List` with `.scrollDisabled(true)` so we
    /// get real `.swipeActions` (same as AllExpensesView) while the list
    /// behaves as a static block inside the parent scroll view. The fixed
    /// height matches `rowHeight × count` so there's no internal scroll
    /// area for the user to hit.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(
                title: "Recent",
                trailing: recentExpenses.isEmpty ? nil : AnyView(SeeAllLink {
                    showingAllExpenses = true
                })
            )

            if recentExpenses.isEmpty {
                emptyActivityState
            } else {
                recentList
            }
        }
    }

    /// Approximate per-row height used to size the static List. Set slightly
    /// above the ExpenseRow's minHeight (56pt) to account for separator
    /// space and rounding. If this drifts, only visible symptom is small
    /// extra/missing whitespace at the bottom of the section.
    private var rowHeight: CGFloat { 62 }

    private var recentList: some View {
        List {
            ForEach(Array(recentExpenses.enumerated()), id: \.element.id) { index, expense in
                Button {
                    Haptics.tap()
                    editingExpense = expense
                } label: {
                    ExpenseRow(expense: expense)
                        .padding(.horizontal, Spacing.lg)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                // Separator BELOW each row except the last. We must target
                // `edges: .bottom` explicitly — the default `.all` would
                // also hide the top edge of the last row, which is shared
                // with the bottom edge of the row before it, accidentally
                // erasing the line between them.
                .listRowSeparator(index == recentExpenses.count - 1 ? .hidden : .visible, edges: .bottom)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        delete(expense)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)

                    Button {
                        editingExpense = expense
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.blue)
                    .labelStyle(.iconOnly)
                }
                .contextMenu {
                    expenseContextMenu(for: expense)
                } preview: {
                    ExpenseContextPreview(expense: expense)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(recentExpenses.count) * rowHeight)
        .background(Color.tulaCardSurface)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    @ViewBuilder
    private func expenseContextMenu(for expense: Expense) -> some View {
        Button { editingExpense = expense } label: { Label("Edit", systemImage: "pencil") }
        Button { duplicate(expense) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        if let merchant = expense.merchant, !merchant.isEmpty {
            Button { logSimilar(to: expense) } label: {
                Label("Log Another \(merchant)", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        Button(role: .destructive) { delete(expense) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func duplicate(_ expense: Expense) {
        let copy = Expense(
            amount: expense.amount, date: .now,
            merchant: expense.merchant, note: expense.note,
            source: .manual, category: expense.category, account: expense.account
        )
        context.insert(copy)
        try? context.save()
        Haptics.success()
        showToast("Duplicated")
        triggerSavePulse()
    }

    private func logSimilar(to expense: Expense) {
        let template = Expense(
            amount: 0, date: .now,
            merchant: expense.merchant, note: nil,
            source: .manual, category: expense.category, account: expense.account
        )
        context.insert(template)
        try? context.save()
        editingExpense = template
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        Haptics.warning()
        showToast("Deleted")
    }

    private var emptyActivityState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "tray").font(.title2).foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: Spacing.xs) {
                Text("Nothing logged yet").font(.subheadline.weight(.semibold))
                Text("Use the + button or Quick Log above")
                    .font(.caption).foregroundStyle(.secondary)
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

// MARK: - Keyboard dismissal helper

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
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

private struct Toast: View {
    let message: String
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm + 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }
}

// MARK: - Quick Log Bar

/// After voice stops, the preview card grows in prominence and we DON'T
/// auto-focus the text field — so the parsed expense and submit button
/// are unmistakably visible. Tapping the preview card also submits, in
/// addition to the trailing arrow button.
private struct QuickLogBar: View {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    let currencyCode: String
    let onSubmit: ([ParsedExpense]) -> Void

    @State private var input: String = ""
    @FocusState private var focused: Bool
    @StateObject private var speech = SpeechRecognizer()
    @State private var showingPermissionDenied = false
    /// Tracks whether we just finished a voice session — used to give the
    /// preview card extra prominence and tappable confirm behavior.
    @State private var justFinishedVoice = false

    private var parsed: [ParsedExpense] {
        ExpenseParser.parse(
            input: input,
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: defaultAccount
        )
    }

    private var validParsed: [ParsedExpense] { parsed.filter { $0.isValid } }
    private var canSubmit: Bool { !validParsed.isEmpty && !speech.isRecording }
    private var showPreview: Bool { !validParsed.isEmpty }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            inputCapsule
            if showPreview {
                previewCard
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(AppAnimation.bouncy, value: showPreview)
        .animation(AppAnimation.snappy, value: speech.isRecording)
        .onChange(of: speech.transcript) { _, newValue in

            input = newValue

            guard !speech.isRecording else {
                return
            }

            Task {

                if let extraction = await ExpenseAIService.shared.extract(
                    from: newValue
                ) {

                    print(extraction)

                    await MainActor.run {

                        if let merchant = extraction.merchant {
                            input = merchant
                        }

                        justFinishedVoice = true
                    }
                }
            }
        }
        .alert("Voice access needed", isPresented: $showingPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enable Microphone and Speech Recognition in iOS Settings to dictate expenses.")
        }
    }

    // MARK: - Input capsule

    /// Two visual modes:
    /// 1. Idle/typing — text field with a prominent mic button on the right.
    ///    The mic is brand-amber and 44pt so it reads as the primary action;
    ///    typing is supported as the secondary path.
    /// 2. Recording — the entire capsule transforms: a live waveform replaces
    ///    the text field, the background tints red, and the trailing button
    ///    becomes a clear stop control.
    private var inputCapsule: some View {
        HStack(spacing: Spacing.md) {
            if speech.isRecording {
                recordingMode
            } else {
                idleMode
            }
        }
        .padding(.leading, Spacing.lg)
        .padding(.trailing, Spacing.xs + 2)
        .padding(.vertical, Spacing.xs + 2)
        .frame(minHeight: 56)
        .background(
            Capsule().fill(
                speech.isRecording
                    ? Color.red.opacity(0.10)
                    : Color.tulaCardSurface
            )
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    speech.isRecording ? Color.red.opacity(0.30) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    /// Idle / text-entry mode — full-width TextField + a bold trailing action.
    private var idleMode: some View {
        HStack(spacing: Spacing.md) {
            TextField("What did you spend?", text: $input)
                .focused($focused)
                .submitLabel(.send)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { submit() }
                .frame(maxWidth: .infinity)

            trailingActionButton
        }
    }

    /// Recording mode — live waveform visualization with stop button.
    /// The waveform is purely decorative animated bars; the actual transcript
    /// streams in below into the preview card once parseable.
    private var recordingMode: some View {
        HStack(spacing: Spacing.md) {
            WaveformIndicator()
                .frame(height: 24)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !input.isEmpty {
                Text("•")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(input.split(separator: " ").count) words")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Listening…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            trailingActionButton
        }
    }

    // MARK: - Trailing action button

    /// 40pt circular button that morphs between mic / stop / send.
    /// Brand-amber in idle/send (signaling the primary action), red in
    /// recording (signaling stop). Smaller and with a subtler shadow than
    /// before — the previous 44pt with a strong colored glow read as
    /// disproportionate against the quiet input capsule.
    private var trailingActionButton: some View {
        Button(action: trailingAction) {
            ZStack {
                Circle()
                    .fill(trailingButtonFill)
                    .frame(width: 40, height: 40)
                    .shadow(color: trailingButtonFill.opacity(0.22), radius: 4, y: 2)

                Image(systemName: trailingIconName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: validParsed.count)
            }
        }
        .buttonStyle(PressableScaleStyle(scale: 0.92))
        .disabled(trailingDisabled)
    }

    private var trailingIconName: String {
        if speech.isRecording { return "stop.fill" }
        if canSubmit { return "arrow.up" }
        if !input.isEmpty { return "arrow.up" }
        return "mic.fill"
    }

    private var trailingButtonFill: Color {
        if speech.isRecording { return .red }
        if canSubmit { return Color.tulaBrandFallback }
        if !input.isEmpty { return Color(uiColor: .tertiaryLabel) }
        return Color.tulaBrandFallback
    }

    private var trailingDisabled: Bool {
        if speech.isRecording { return false }
        if canSubmit { return false }
        if !input.isEmpty { return true }
        return false
    }

    private func trailingAction() {
        if speech.isRecording {
            stopVoice()
        } else if canSubmit {
            submit()
        } else if input.isEmpty {
            startVoice()
        } else {
            Haptics.error()
        }
    }

    /// Compact summary of what will be saved. After voice ends, this card
    /// becomes the primary "save here" target — bigger, with a clear CTA
    /// button at the right. Tapping anywhere on the card submits.
    private var previewCard: some View {
        Button(action: submit) {
            HStack(spacing: Spacing.sm) {
                if validParsed.count == 1, let only = validParsed.first {
                    singlePreviewRow(only)
                } else {
                    multiplePreviewRow
                }
                Spacer(minLength: 0)
                saveBadge
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 4)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(justFinishedVoice
                          ? Color.tulaBrandFallback.opacity(0.12)
                          : Color.tulaCardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .strokeBorder(
                        justFinishedVoice
                            ? Color.tulaBrandFallback.opacity(0.35)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    private var saveBadge: some View {
        HStack(spacing: 4) {
            Text("Save")
                .font(.caption.weight(.bold))
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(Color.tulaBrandFallback)
        )
        .foregroundStyle(.white)
    }

    private func singlePreviewRow(_ p: ParsedExpense) -> some View {
        HStack(spacing: Spacing.sm) {
            if let category = p.category {
                let color = Color(hex: category.colorHex)
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 28, height: 28)
                    Image(systemName: category.iconKey)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Currency.format(p.amount, code: currencyCode))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    if let merchant = p.merchant {
                        Text(merchant)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let account = p.account {
                        if p.merchant != nil { Text("·").foregroundStyle(.tertiary).font(.caption2) }
                        Text(account.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var multiplePreviewRow: some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                Circle().fill(Color.tulaBrandFallback.opacity(0.18)).frame(width: 28, height: 28)
                Image(systemName: "checklist")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(validParsed.count) expenses")
                    .font(.subheadline.weight(.bold))
                Text(Currency.format(validParsed.reduce(0) { $0 + $1.amount }, code: currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Voice actions

    private func startVoice() {
        Task {
            let ok = await speech.requestAuthorization()
            if ok {
                Haptics.impact()
                speech.start()
                justFinishedVoice = false
            } else {
                Haptics.error()
                showingPermissionDenied = true
            }
        }
    }

    /// Stops recording WITHOUT auto-focusing the text field. The preview
    /// card stays visible with an obvious "Save" CTA. User reads, taps to
    /// save — they don't see a keyboard slide up and cover the preview.
    private func stopVoice() {
        Haptics.tap()
        speech.stop()
        justFinishedVoice = !validParsed.isEmpty
        // Bouncier emphasis on the parsed preview
        if !validParsed.isEmpty {
            withAnimation(AppAnimation.bouncy) {
                justFinishedVoice = true
            }
        }
    }

    private func submit() {
        let valid = validParsed
        guard !valid.isEmpty else { return }
        if speech.isRecording { speech.stop() }
        onSubmit(valid)
        input = ""
        focused = false
        justFinishedVoice = false
    }
}

// MARK: - Waveform Indicator

/// Animated bars that pulse during voice recording. Purely decorative — the
/// bars don't represent actual audio amplitude, but their continuous motion
/// communicates "I'm actively listening" more reliably than a static icon.
///
/// Eight bars in brand-amber, each with its own randomized animation delay
/// and duration so the pattern feels organic, not mechanical.
private struct WaveformIndicator: View {
    @State private var animate: Bool = false

    private let barCount = 8
    private let baseHeights: [CGFloat] = [0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.5, 0.7]
    private let delays: [Double] = [0, 0.15, 0.3, 0.05, 0.2, 0.35, 0.1, 0.25]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.red.gradient)
                    .frame(width: 3)
                    .scaleEffect(
                        y: animate ? baseHeights[i] : 0.2,
                        anchor: .center
                    )
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(delays[i]),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
