import SwiftUI

/// Multi-day backfill flow.
///
/// **Layering.** The sheet collects intent and hands back values; it never
/// touches `ModelContext`. This mirrors `VoiceInputOverlay`, which builds
/// uninserted `Expense` objects and lets `HomeView` persist them, and keeps
/// business logic out of the view per the project's stated separation of
/// concerns.
///
/// **Order of operations is deliberate.** Overdue recurring items come first
/// because they are the highest value per tap — one button can reconstruct
/// most of a typical week. Per-day entry follows for everything else.
struct CatchUpSheet: View {

    let state: CatchUpState
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    let currencyCode: String

    /// Commit the staged backfill. The host persists via `ExpenseWriter`.
    let onCommitDrafts: ([ExpenseDraft]) -> Void
    /// Mark or unmark a day as "nothing spent".
    let onSetNoSpend: (Date, Bool) -> Void
    /// Materialise overdue recurring occurrences.
    let onConfirmRecurring: ([PendingOccurrence]) -> Void
    /// Close out unlogged days older than the lookback window.
    let onDismissOlder: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date?
    @State private var input: String = ""
    @State private var previewDrafts: [ExpenseDraft] = []
    @State private var parseTask: Task<Void, Never>?
    @State private var staged: [StagedDraft] = []
    @State private var resolvedRecurring: Set<String> = []
    @State private var locallyClosed: Set<String> = []
    @FocusState private var inputFocused: Bool

    /// A draft queued for commit, with stable identity for `ForEach` and for
    /// binding into `EditableExpenseCard`.
    private struct StagedDraft: Identifiable {
        let id = UUID()
        var draft: ExpenseDraft
    }

    // MARK: - Derived

    private var pendingRecurring: [PendingOccurrence] {
        state.pendingRecurring.filter { !resolvedRecurring.contains($0.id) }
    }

    private var openDays: [CatchUpState.Day] {
        state.days.filter { day in
            !locallyClosed.contains(DayKey.string(from: day.date))
        }
    }

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { categories.filter { !$0.isArchived } }

    /// Backfilled expenses are anchored at midday rather than `startOfDay`.
    /// Midnight is the boundary most likely to be shifted by a DST transition
    /// and can land an expense on the neighbouring day; midday is
    /// unambiguous in every zone.
    private func anchor(for day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
    }

    private var validPreviewDrafts: [ExpenseDraft] {
        previewDrafts.filter(\.isValid)
    }

    private var stagedTotal: Double {
        staged.reduce(0) { $0 + $1.draft.amount }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xxl) {
                    if !pendingRecurring.isEmpty {
                        recurringSection
                    }
                    if !state.days.isEmpty {
                        daysSection
                    }
                    if !staged.isEmpty {
                        stagedSection
                    }
                    if state.truncatedOlderDays > 0 {
                        olderRow
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xxxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.tulaBackground)
            .navigationTitle("Catch up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle) { commit() }
                        .fontWeight(.semibold)
                        .disabled(staged.isEmpty)
                }
            }
            .onAppear(perform: selectFirstOpenDay)
        }
    }

    private var saveTitle: String {
        staged.isEmpty ? "Save" : "Save \(staged.count)"
    }

    // MARK: - Recurring

    private var recurringSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Due while you were away")

            VStack(spacing: 0) {
                ForEach(pendingRecurring) { occurrence in
                    recurringRow(occurrence)
                    if occurrence.id != pendingRecurring.last?.id {
                        Divider().padding(.leading, Spacing.lg)
                    }
                }
            }
            .background(Color.tulaCardSurface)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
            )

            Button {
                Haptics.success()
                confirmRecurring(pendingRecurring)
            } label: {
                Label(
                    pendingRecurring.count == 1
                        ? "Confirm this payment"
                        : "Confirm all \(pendingRecurring.count)",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func recurringRow(_ occurrence: PendingOccurrence) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: occurrence.isBill ? "doc.text.fill" : "repeat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(occurrence.ruleName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(occurrence.dueDate, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Spacing.sm)

            Text(Currency.format(occurrence.expectedAmount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Button {
                Haptics.tap()
                resolvedRecurring.insert(occurrence.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip \(occurrence.ruleName)")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    // MARK: - Days

    private var daysSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Missed days")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(state.days) { day in
                        dayChip(day)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }

            if let selected = selectedDate {
                entryPanel(for: selected)
            }
        }
    }

    private func dayChip(_ day: CatchUpState.Day) -> some View {
        let key = DayKey.string(from: day.date)
        let closed = locallyClosed.contains(key)
        let isSelected = selectedDate.map {
            DayKey.string(from: $0) == key
        } ?? false
        let resolved = closed || !day.needsAttention
        let stagedCount = staged.filter {
            DayKey.string(from: $0.draft.date) == key
        }.count

        return Button {
            Haptics.selection()
            selectedDate = day.date
            input = ""
            previewDrafts = []
        } label: {
            VStack(spacing: 3) {
                Text(day.date, format: .dateTime.weekday(.abbreviated))
                    .font(.caption2.weight(.semibold))
                Text(day.date, format: .dateTime.day())
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                chipIndicator(resolved: resolved, stagedCount: stagedCount)
            }
            .frame(width: 52, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.tulaCardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .foregroundStyle(resolved ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        )
        .accessibilityValue(resolved ? "Done" : "Unlogged")
    }

    @ViewBuilder
    private func chipIndicator(resolved: Bool, stagedCount: Int) -> some View {
        if stagedCount > 0 {
            Text("\(stagedCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.accentColor)
        } else if resolved {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.green)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.2)
                .frame(width: 7, height: 7)
        }
    }

    // MARK: - Entry

    private func entryPanel(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                TextField("What did you spend?", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit(stagePreview)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .background(
                        Capsule().fill(Color.tulaCardSurface)
                    )

                Button(action: stagePreview) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            validPreviewDrafts.isEmpty ? Color.secondary : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(validPreviewDrafts.isEmpty)
                .accessibilityLabel("Add to this day")
            }

            ForEach(validPreviewDrafts.indices, id: \.self) { index in
                previewRow(validPreviewDrafts[index])
            }

            Button {
                Haptics.success()
                closeDayAsNoSpend(day)
            } label: {
                Label("Nothing spent this day", systemImage: "moon.zzz")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .onChange(of: input) { _, newValue in
            scheduleParse(newValue, for: day)
        }
    }

    private func previewRow(_ draft: ExpenseDraft) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(Currency.format(draft.amount, code: currencyCode))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            if let merchant = draft.merchant {
                Text(merchant)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let category = draft.category {
                Image(systemName: category.iconKey)
                    .font(.caption)
                    .foregroundStyle(Color(hex: category.colorHex))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    // MARK: - Staged

    private var stagedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(title: "Ready to save")

            ForEach($staged) { $item in
                EditableExpenseCard(
                    draft: $item.draft,
                    accounts: activeAccounts,
                    categories: activeCategories,
                    currencyCode: currencyCode,
                    animateIn: false
                )
            }

            HStack {
                Text("\(staged.count) expense\(staged.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Currency.format(stagedTotal, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private var olderRow: some View {
        Button {
            Haptics.tap()
            onDismissOlder()
            dismiss()
        } label: {
            HStack {
                Text("\(state.truncatedOlderDays) older days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Dismiss")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func selectFirstOpenDay() {
        guard selectedDate == nil else { return }
        selectedDate = openDays.first(where: \.needsAttention)?.date
            ?? state.days.last?.date
    }

    /// Debounced parse, matching `QuickLogBar`'s 180ms cadence — the
    /// interpreter runs NLTagger NER plus regex, which is cheap once but not
    /// once per keystroke.
    private func scheduleParse(_ text: String, for day: Date) {
        parseTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            previewDrafts = []
            return
        }
        let reference = anchor(for: day)
        parseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            previewDrafts = ExpenseInterpreter(
                accounts: accounts,
                categories: categories,
                merchantRules: merchantRules,
                defaultAccount: defaultAccount,
                referenceDate: reference
            ).interpret(text)
        }
    }

    private func stagePreview() {
        let drafts = validPreviewDrafts
        guard !drafts.isEmpty else { return }
        Haptics.success()
        staged.append(contentsOf: drafts.map { StagedDraft(draft: $0) })
        input = ""
        previewDrafts = []
        parseTask?.cancel()
    }

    private func closeDayAsNoSpend(_ day: Date) {
        onSetNoSpend(day, true)
        locallyClosed.insert(DayKey.string(from: day))
        advanceSelection(after: day)
    }

    private func confirmRecurring(_ occurrences: [PendingOccurrence]) {
        guard !occurrences.isEmpty else { return }
        onConfirmRecurring(occurrences)
        resolvedRecurring.formUnion(occurrences.map(\.id))
    }

    /// Moves focus to the next day still needing attention, so closing a day
    /// keeps the flow moving without a second tap.
    private func advanceSelection(after day: Date) {
        let key = DayKey.string(from: day)
        let remaining = state.days.filter {
            let candidate = DayKey.string(from: $0.date)
            return candidate != key
                && $0.needsAttention
                && !locallyClosed.contains(candidate)
        }
        withAnimation(AppAnimation.snappy) {
            selectedDate = remaining.first?.date
        }
        input = ""
        previewDrafts = []
    }

    private func commit() {
        let drafts = staged.map(\.draft).filter(\.isValid)
        guard !drafts.isEmpty else { return }
        onCommitDrafts(drafts)
        staged.removeAll()
        dismiss()
    }
}
