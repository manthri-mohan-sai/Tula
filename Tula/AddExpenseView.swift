import SwiftUI
import SwiftData

/// New / edit expense form. Designed for speed:
/// - Amount centered prominently at top
/// - Accounts as compact horizontal pills (icon + name, all visible at once)
/// - Categories as a 4-column grid (no scrolling needed to see all defaults)
/// - Merchant / Note / Date collapsed into one card
/// - Save anchored to bottom (always thumb-reachable)
struct AddExpenseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @Query private var allMerchantRules: [MerchantRule]

    /// Recent expenses, descending by date. Powers the predictive chip
    /// strip — we look back across the last 100 expenses and surface
    /// the user's habitual (amount, merchant, category) tuples when
    /// the current amount entry matches a frequent value.
    @Query(sort: \Expense.date, order: .reverse) private var recentExpensesForPredictions: [Expense]

    @AppStorage("lastUsedAccountID") private var lastUsedAccountID: String = ""
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false

    let existingExpense: Expense?
    let openCameraOnAppear: Bool

    @State private var amount: Double
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
    @State private var tax: Double = 0
    @State private var discount: Double = 0
    @State private var categoryManuallySet: Bool
    @State private var showingDeleteConfirm = false
    @State private var categoriesExpanded = false

    /// Drives the items-breakdown sheet that opens when the user taps
    /// the "View items" chip below the Item field. Sheet is read-only —
    /// the user edits the underlying string in the form's existing
    /// TextField, then re-opens the sheet to verify the new breakdown.
    /// Keeps editing simple while still surfacing structure on demand.
    @State private var showingItemsSheet = false

    /// Parse the current note string into structured items + total for
    /// the "View items" chip and the breakdown sheet. Returns nil when
    /// the note isn't in the structured format we emit. Computed live
    /// so editing the note in the TextField updates the chip in
    /// real-time (chip appears/disappears as the user types items into
    /// the format, or hides when they type freeform text).
    private var parsedItemsForCurrentNote: (items: [ExpenseItem], total: Double?)? {
        let parsed = ExpenseItemParser.parse(note.isEmpty ? nil : note)
        return parsed.items.isEmpty ? nil : parsed
    }

    /// Tracks which predictive chip (if any) is currently animating its
    /// "I notice this matches your history" pulse.
    @State private var pulsingChipID: String? = nil

    /// Receipt photo state. `receiptImage` is the working in-memory copy
    /// shown in the thumbnail; we only store the compressed Data on save.
    /// Kept separate so the user can replace/remove the photo before
    /// committing the expense — no premature compression cycles.
    @State private var receiptImage: UIImage? = nil
    /// True while Vision OCR is running. Drives a small inline spinner
    /// next to the thumbnail so the user sees "Tula is reading this."
    @State private var receiptOCRInFlight: Bool = false
    /// Which OCR-extracted fields the user hasn't manually overridden.
    /// We use this to mark them with a tiny ✨ glyph in the form — so
    /// the user knows "Tula filled this from the receipt, verify it."
    /// Once the user types in a field, it leaves this set.
    @State private var ocrExtractedFields: Set<OCRField> = []
    @State private var scanErrorMessage: String?
    @State private var canRetryAIGate: Bool = false
    @State private var showingScanErrorAlert: Bool = false
    enum OCRField: Hashable { case amount, merchant }

    /// Image picker presentation state. `.camera` shows the camera UI;
    /// `.library` shows the photo picker.
    @State private var showingCamera = false
    @State private var showingLibraryPicker = false
    enum ReceiptSource { case camera, library }
    /// Action sheet for choosing camera vs photo library when adding a
    /// receipt. Both paths feed the same OCR pipeline.
    @State private var showingReceiptSourcePicker: Bool = false

    // MARK: - Split Payment State

    @State private var splitModeActive: Bool = false
    @State private var splitRows: [SplitRow] = []

    struct SplitRow: Identifiable {
        let id = UUID()
        var amount: Double
        var category: Category?
        var account: Account?
    }

    @FocusState private var amountFocused: Bool

    init(existingExpense: Expense? = nil, openCameraOnAppear: Bool = false) {
        self.existingExpense = existingExpense
        self.openCameraOnAppear = openCameraOnAppear
        if let e = existingExpense {
            _amount = State(initialValue: e.amount)
            _selectedCategory = State(initialValue: e.category)
            _selectedAccount = State(initialValue: e.account)
            _merchant = State(initialValue: e.merchant ?? "")
            _note = State(initialValue: e.note ?? "")
            _date = State(initialValue: e.date)
            _tax = State(initialValue: e.tax ?? 0)
            _discount = State(initialValue: e.discount ?? 0)
            _categoryManuallySet = State(initialValue: true)
            // Decode stored receipt blob into a UIImage so the thumbnail
            // renders immediately when the form opens in edit mode.
            // Decoding is cheap (~50ms for a 200KB JPEG) and synchronous
            // here is fine because it happens once on view init.
            if let data = e.receiptImageData, let image = UIImage(data: data) {
                _receiptImage = State(initialValue: image)
            } else {
                _receiptImage = State(initialValue: nil)
            }
        } else {
            _amount = State(initialValue: 0)
            _selectedCategory = State(initialValue: nil)
            _selectedAccount = State(initialValue: nil)
            _merchant = State(initialValue: "")
            _note = State(initialValue: "")
            _date = State(initialValue: .now)
            _categoryManuallySet = State(initialValue: false)
            _receiptImage = State(initialValue: nil)
        }
    }

    private var isEditing: Bool { existingExpense != nil }
    private var activeAccounts: [Account] { allAccounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { allCategories.filter { !$0.isArchived } }
    private var canSave: Bool {
        if splitModeActive { return amount > 0 && splitIsValid }
        return amount > 0 && selectedAccount != nil
    }

    private var canShowSplitOption: Bool {
        amount > 0 && activeCategories.count >= 2 && !isEditing
    }

    private var splitAssignedTotal: Double {
        splitRows.reduce(0) { $0 + $1.amount }
    }

    private var splitIsValid: Bool {
        splitRows.count >= 2
        && splitRows.allSatisfy { $0.amount > 0 && $0.category != nil && $0.account != nil }
        && abs(splitAssignedTotal - amount) < 0.01
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    amountHero
                        .padding(.top, Spacing.lg)

                    // Predictive chips: when the amount entered matches
                    // recent expense patterns, surface chips that one-tap
                    // fill merchant + category + item. The "Tula moment" —
                    // a glow-and-breathe entrance signals "I recognized this."
                    if !predictiveSuggestions.isEmpty {
                        predictiveChipsStrip
                            .padding(.horizontal, Spacing.xl)
                    }

                    if splitModeActive {
                        splitPaymentCard
                            .padding(.horizontal, Spacing.xl)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else {
                        accountStrip

                        categoryGrid
                            .padding(.horizontal, Spacing.xl)

                        if canShowSplitOption {
                            splitPaymentButton
                                .padding(.horizontal, Spacing.xl)
                                .transition(.opacity)
                        }
                    }

                    // Merchant / Item / Date as inline rows.
                    detailsCard
                        .padding(.horizontal, Spacing.xl)

                    // Receipt photo — optional attachment with OCR pre-fill.
                    // Lives after the main fields so the photo workflow
                    // doesn't disrupt the primary text-entry flow.
                    receiptSection
                        .padding(.horizontal, Spacing.xl)

                    if isEditing {
                        deleteButton
                            .padding(.horizontal, Spacing.xl)
                    }
                }
                .padding(.bottom, Spacing.xxl)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Color.tulaBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .principal) {
                    Text(isEditing ? "Edit Expense" : "Expense")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(canSave ? Color.tulaBrandFallback : Color.secondary.opacity(0.5))
                    }
                    .disabled(!canSave)
                    .accessibilityHint("Saves this expense")
                }
            }
            .onAppear {
                setupDefaults()
                if openCameraOnAppear {
                    // Scan mode: open camera after the sheet finishes
                    // presenting. Don't focus the amount field — the
                    // keyboard would fight the camera for screen space.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        showingCamera = true
                    }
                } else if !isEditing {
                    // Only auto-open the keyboard for new expenses.
                    // In edit mode the user may just want to review, not type.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        amountFocused = true
                    }
                }
            }
            .onChange(of: merchant) { _, newValue in
                applyMerchantRule(for: newValue)
            }
            .onChange(of: amount) { old, new in
                guard splitModeActive, !splitRows.isEmpty else { return }
                splitRows[0].amount = max(0, splitRows[0].amount + (new - old))
            }
            .confirmationDialog("Delete this expense?",
                                isPresented: $showingDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action can't be undone.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .tulaStartReceiptScan)) { _ in
                amountFocused = false
                showingCamera = true
            }
            .onChange(of: scanErrorMessage) { _, newValue in
                if newValue != nil {
                    showingScanErrorAlert = true
                }
            }
            .alert("Unable to Read Receipt",
                   isPresented: $showingScanErrorAlert) {
                if canRetryAIGate {
                    Button("Try Again") {
                        if let image = receiptImage {
                            runReceiptOCR(on: image, forceCloudAI: true)
                        }
                    }
                }
                Button(canRetryAIGate ? "Enter Manually" : "OK", role: .cancel) {
                    scanErrorMessage = nil
                }
            } message: {
                Text(scanErrorMessage ?? "The receipt could not be processed. You can enter the details manually.")
            }
            .sheet(isPresented: $showingItemsSheet) {
                // Pass plain values to the sheet — no synthetic Expense
                // construction. Avoids SwiftData @Model deadlocks that
                // can hang the main thread when constructing a transient
                // model under active @Query observation.
                let parsed = parsedItemsForCurrentNote ?? ([], nil)
                ExpenseItemsSheet(
                    merchantName: merchant.isEmpty ? nil : merchant,
                    amount: amount,
                    date: date,
                    categoryName: selectedCategory?.name,
                    receiptImageData: currentReceiptImageData,
                    items: parsed.items,
                    total: parsed.total
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        // Receipt full-screen viewer — attached at NavigationStack level so
        // its dismiss animation is fully isolated from the toolbar buttons
        // beneath it (prevents the close-button tap bleeding into Save).
        .fullScreenCover(isPresented: $showingFullReceipt) {
            if let image = receiptImage {
                receiptFullScreenView(image: image)
            }
        }
    }

    /// Best-available receipt image data for the items sheet. Pulls from
    /// the existing expense's stored data when editing (zero cost), or
    /// nil when creating new — we deliberately DON'T encode the in-memory
    /// `receiptImage` to JPEG here because the sheet open should be
    /// instant. The freshly-picked photo isn't visible in the sheet
    /// thumbnail until the user saves and re-opens the expense; small
    /// trade-off for a non-blocking sheet open.
    private var currentReceiptImageData: Data? {
        existingExpense?.receiptImageData
    }

    // MARK: - Predictive Suggestions
    //
    // Surfaces the user's most-probable expense completions based on past
    // behavior. Three sources, in priority order:
    //
    // 1. **Exact amount match**: when the user types an amount they've
    //    spent before, recent expenses at that exact amount are surfaced
    //    first — "you spent ₹350 at Swiggy last week, same thing?"
    // 2. **Frequent merchants in recent activity**: when no amount match,
    //    surface the top-3 merchants by visit count over the last 60 days.
    //    Predicts "you're probably going to log Mayur Mess again."
    // 3. Empty when neither produces signal — chips simply don't appear.
    //
    // Tapping a chip fills merchant + category + item in sequence with a
    // wave animation. The amount stays as the user entered it (we don't
    // overwrite — they've already committed to that number).

    /// Suggestion shown as a chip. Carries enough info to fill the form
    /// from a single tap, plus a stable ID for SwiftUI ForEach + animation.
    ///
    /// **ID stability**: derived deterministically from merchant + isExactAmountMatch
    /// rather than fresh UUID per recompute. Without this, SwiftUI's
    /// ForEach diff would treat every chip as "removed and re-added" on
    /// any state change — re-triggering the breathing animation on
    /// every keystroke, which would feel like spam, not delight.
    struct PredictiveSuggestion: Identifiable {
        let id: String
        let merchant: String
        let category: Category?
        let item: String?
        let recentAmount: Double?
        let visitCount: Int
        let isExactAmountMatch: Bool
    }

    /// Top predictive suggestions for the current form state. Cached
    /// implicitly via SwiftUI's view diffing — recomputes only when the
    /// amount changes (driving the dependency).
    private var predictiveSuggestions: [PredictiveSuggestion] {
        guard amount > 0 else { return [] }
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: .now) ?? .now
        let pool = recentExpensesForPredictions
            .filter { $0.date >= cutoff }
            .prefix(100)

        // Phase 1: exact amount matches first. Group by merchant so
        // 3 visits to Swiggy at ₹350 surface as one chip, not three.
        let exactMatches = pool
            .filter { abs($0.amount - amount) < 0.5 && ($0.merchant?.isEmpty == false) }
        let exactByMerchant = Dictionary(grouping: exactMatches) { $0.merchant ?? "" }
        var suggestions: [PredictiveSuggestion] = exactByMerchant
            .compactMap { (merchant, expenses) -> PredictiveSuggestion? in
                guard let first = expenses.first else { return nil }
                return PredictiveSuggestion(
                    // Stable ID: merchant + match-type tag. Same merchant
                    // at the same amount across renders produces the same
                    // string, so SwiftUI treats this as the same chip and
                    // doesn't re-trigger the breathing animation.
                    id: "exact-\(merchant)",
                    merchant: merchant,
                    category: first.category,
                    item: first.note,
                    recentAmount: first.amount,
                    visitCount: expenses.count,
                    isExactAmountMatch: true
                )
            }
            .sorted { $0.visitCount > $1.visitCount }

        // Phase 2: fill remaining slots (cap 3 chips total) with top
        // frequent merchants that aren't already in exact matches.
        if suggestions.count < 3 {
            let frequentByMerchant = Dictionary(grouping: pool.filter { ($0.merchant?.isEmpty == false) }) {
                $0.merchant ?? ""
            }
            let existingMerchants = Set(suggestions.map { $0.merchant.lowercased() })
            let frequent = frequentByMerchant
                .filter { !existingMerchants.contains($0.key.lowercased()) }
                .map { (merchant, expenses) -> PredictiveSuggestion in
                    let first = expenses.first
                    return PredictiveSuggestion(
                        id: "frequent-\(merchant)",
                        merchant: merchant,
                        category: first?.category,
                        item: nil,  // amount-agnostic suggestions skip item
                        recentAmount: nil,
                        visitCount: expenses.count,
                        isExactAmountMatch: false
                    )
                }
                .sorted { $0.visitCount > $1.visitCount }
                .prefix(3 - suggestions.count)
            suggestions.append(contentsOf: frequent)
        }

        return Array(suggestions.prefix(3))
    }

    /// Predictive chips strip. Title bar with ✨ glyph + horizontal scroll
    /// of chips. Each chip shows merchant + (category icon when known).
    /// Exact-match chips get the breathing amber glow that earned the
    /// "Tula moment" treatment — restrained but unmistakable.
    private var predictiveChipsStrip: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.tulaBrandFallback)
                Text(predictiveHeaderText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(predictiveSuggestions) { suggestion in
                        predictiveChip(for: suggestion)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .padding(.horizontal, 2)
            }
            .scrollClipDisabled()
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
            removal: .opacity
        ))
        // Animation key: use the count of suggestions + a hash of the
        // merchant set. Cheaper for SwiftUI's diffing than mapping the
        // UUIDs into an array, and avoids any type-inference quirks with
        // `.animation(_:value:)` and arrays of identifiable IDs.
        .animation(.snappy(duration: 0.3), value: predictiveSuggestions.count)
    }

    /// Contextual header text — "Recent at ₹350" when amount matches,
    /// "Frequent merchants" when surfacing the fallback list. The label
    /// teaches the user what the chips mean without being preachy.
    private var predictiveHeaderText: String {
        if predictiveSuggestions.contains(where: { $0.isExactAmountMatch }) {
            return "Recent at \(Currency.format(amount, code: currencyCode))"
        }
        return "Frequent merchants"
    }

    /// Whether the given chip is the one currently pulsing. Extracted as a
    /// helper because inlining `pulsingChipID == suggestion.id` repeatedly
    /// inside complex SwiftUI view builders sometimes confuses the type
    /// checker — making this a typed `Bool` function removes ambiguity.
    private func isChipPulsing(_ suggestion: PredictiveSuggestion) -> Bool {
        guard let active = pulsingChipID else { return false }
        return active == suggestion.id
    }

    /// Single predictive chip. The exact-match variant breathes with a
    /// soft amber glow; the frequent-merchant variant is calm and gray.
    /// Tap fills the form in sequence.
    private func predictiveChip(for suggestion: PredictiveSuggestion) -> some View {
        let pulsing = isChipPulsing(suggestion)
        return Button {
            applyPredictiveSuggestion(suggestion)
        } label: {
            HStack(spacing: 6) {
                if let category = suggestion.category {
                    Image(systemName: category.iconKey)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(hex: category.colorHex))
                }
                Text(suggestion.merchant)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(suggestion.isExactAmountMatch
                          ? Color.tulaBrandFallback.opacity(0.12)
                          : Color.secondary.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(
                        suggestion.isExactAmountMatch
                            ? Color.tulaBrandFallback.opacity(pulsing ? 0.5 : 0.3)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .scaleEffect(pulsing ? 1.04 : 1.0)
            .shadow(
                color: suggestion.isExactAmountMatch && pulsing
                    ? Color.tulaBrandFallback.opacity(0.35)
                    : .clear,
                radius: 10
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.95))
        .onAppear {
            // Trigger the breathing pulse animation once per exact-match
            // chip when it first appears. Skipped under Reduce Motion.
            if suggestion.isExactAmountMatch && !AppAnimation.reduceMotion {
                let chipID = suggestion.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(
                        .easeInOut(duration: 1.4)
                        .repeatCount(3, autoreverses: true)
                    ) {
                        pulsingChipID = chipID
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                        withAnimation(.easeOut(duration: 0.5)) {
                            pulsingChipID = nil
                        }
                    }
                }
            }
        }
    }

    /// Apply a predictive suggestion to the form. Fills merchant first,
    /// then category, then item with a cascading delay — produces a
    /// satisfying "wave" effect that confirms the action visibly. The
    /// amount stays unchanged (user already entered it deliberately).
    private func applyPredictiveSuggestion(_ suggestion: PredictiveSuggestion) {
        Haptics.success()
        // Wave-fill: each field animates in 80ms after the previous.
        // The total delay (~250ms) is short enough to feel instant but
        // long enough that the user perceives the form completing itself.
        withAnimation(.snappy(duration: 0.2)) {
            merchant = suggestion.merchant
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.snappy(duration: 0.2)) {
                if let category = suggestion.category {
                    selectedCategory = category
                    categoryManuallySet = true
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.snappy(duration: 0.2)) {
                if let item = suggestion.item, !item.isEmpty {
                    note = item
                }
            }
        }
    }

    // MARK: - Amount Hero
    //
    // Calculator-style display: massive number, no input chrome, currency
    // symbol whispering above. The number IS the screen. Following Apple
    // Cash and Calculator conventions — the value being entered earns the
    // visual real estate proportional to its importance.

    private var amountHero: some View {
        VStack(spacing: Spacing.xs) {
            Text(Currency.symbol(for: currencyCode))
                .font(.body.weight(.medium))
                .foregroundStyle(.tertiary)

            FormattedAmountField(
                value: $amount,
                currencyCode: currencyCode,
                placeholder: "0",
                // Larger and lighter than the previous 56pt bold. At
                // 64pt the number commands the screen the way Apple Cash
                // does ("$0" on Cash is ~80pt). `.rounded` keeps the
                // numeric feel friendly rather than typographically heavy.
                font: .system(size: 64, weight: .semibold, design: .rounded),
                alignment: .center
            )
            .focused($amountFocused)
            .frame(maxWidth: .infinity)
            .foregroundStyle(amount > 0 ? .primary : .tertiary)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.2), value: amount)
        }
    }

    // MARK: - Account Strip
    //
    // Horizontal scrollable pills with NO header. The pills are visually
    // self-explanatory (account icon + name) — adding a "Paid with" label
    // above them is redundant noise. Selection auto-applies the user's
    // last-used default, so the form opens with a sensible choice already
    // made; the user typically just confirms with one glance, not a tap.

    // MARK: - Split Payment

    private var splitPaymentButton: some View {
        Button {
            Haptics.tap()
            activateSplitMode()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "scissors")
                    .font(.caption.weight(.semibold))
                Text("Split expense")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(Color.tulaBrandFallback)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.xs)
        }
        .buttonStyle(.plain)
    }

    @State private var splitRowsAppeared: Set<UUID> = []

    private var splitPaymentCard: some View {
        VStack(spacing: Spacing.md) {
            // Header — quiet, like SectionHeader
            HStack(alignment: .firstTextBaseline) {
                Text("Split expense")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Haptics.tap()
                    deactivateSplitMode()
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Unified card — rows separated by dividers, like detailsCard
            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(Array(splitRows.enumerated()), id: \.element.id) { index, _ in
                        splitRowView(row: $splitRows[index], index: index)
                            .opacity(splitRowsAppeared.contains(splitRows[index].id) ? 1 : 0)
                            .onAppear {
                                let rowID = splitRows[index].id
                                guard !splitRowsAppeared.contains(rowID) else { return }
                                withAnimation(AppAnimation.gentle.delay(Double(index) * 0.1)) {
                                    splitRowsAppeared.insert(rowID)
                                }
                            }

                        if index < splitRows.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }

                    // Add split row — inside the card, simple
                    if splitRows.count < 5 {
                        Divider().padding(.leading, 56)
                        Button {
                            Haptics.selection()
                            addSplitRow()
                        } label: {
                            HStack(spacing: Spacing.md) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Color.tulaBrandFallback)
                                    .frame(width: 36, height: 36)
                                Text("Add split")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.tulaBrandFallback)
                                Spacer()
                            }
                            .padding(.horizontal, Spacing.lg)
                            .padding(.vertical, Spacing.md)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Progress bar + balance label below the card
            splitProgressSection
        }
    }

    /// Binding that auto-balances: editing any non-last row adjusts the last row.
    private func splitAmountBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { splitRows[index].amount },
            set: { newValue in
                splitRows[index].amount = newValue
                guard index < splitRows.count - 1 else { return }
                let othersTotal = splitRows.enumerated()
                    .filter { $0.offset != splitRows.count - 1 }
                    .reduce(0.0) { $0 + $1.element.amount }
                splitRows[splitRows.count - 1].amount = max(0, amount - othersTotal)
            }
        )
    }

    private func splitRowView(row: Binding<SplitRow>, index: Int) -> some View {
        let catColor: Color = row.wrappedValue.category.map { Color(hex: $0.colorHex) } ?? .secondary
        let hasAmount = row.wrappedValue.amount > 0

        return HStack(spacing: Spacing.md) {
            // Category circle — sole color carrier
            Menu {
                ForEach(activeCategories) { category in
                    Button {
                        Haptics.selection()
                        withAnimation(AppAnimation.snappy) {
                            row.wrappedValue.category = category
                        }
                    } label: {
                        Label(category.name, systemImage: category.iconKey)
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(catColor.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: row.wrappedValue.category?.iconKey ?? "square.grid.2x2")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(catColor)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }

            // Labels — all neutral colors
            VStack(alignment: .leading, spacing: 2) {
                // Category name — primary, never colored
                Menu {
                    ForEach(activeCategories) { category in
                        Button {
                            Haptics.selection()
                            withAnimation(AppAnimation.snappy) {
                                row.wrappedValue.category = category
                            }
                        } label: {
                            Label(category.name, systemImage: category.iconKey)
                        }
                    }
                } label: {
                    Text(row.wrappedValue.category?.name ?? "Category")
                        .font(.body.weight(.medium))
                        .foregroundStyle(row.wrappedValue.category != nil ? Color.primary : Color.secondary)
                        .lineLimit(1)
                }

                // Account — fully neutral, no icon color
                Menu {
                    ForEach(activeAccounts) { account in
                        Button {
                            Haptics.selection()
                            withAnimation(AppAnimation.snappy) {
                                row.wrappedValue.account = account
                            }
                        } label: {
                            Label(account.name, systemImage: account.iconKey)
                        }
                    }
                } label: {
                    Text(row.wrappedValue.account?.name ?? "Account")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Spacing.sm)

            // Amount — all rows editable; non-last rows auto-balance the last
            FormattedAmountField(
                value: splitAmountBinding(at: index),
                currencyCode: currencyCode,
                placeholder: "0",
                font: .title3.weight(.semibold),
                alignment: .trailing
            )
            .frame(minWidth: 60)
            .opacity(hasAmount ? 1 : 0.35)

            // Remove (only if >2 rows)
            if splitRows.count > 2 {
                Button {
                    Haptics.tap()
                    removeSplitRow(id: row.wrappedValue.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove split")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .contentShape(Rectangle())
    }

    private var splitProgressSection: some View {
        let fraction = amount > 0 ? min(splitAssignedTotal / amount, 1.0) : 0
        let remaining = amount - splitAssignedTotal
        let balanced = abs(remaining) < 0.01
        let over = splitAssignedTotal > amount + 0.01
        let barColor: Color = balanced ? .green : (over ? .red : Color.tulaBrandFallback)

        return VStack(spacing: Spacing.xs) {
            // Thin progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.1))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(0, min(geo.size.width * fraction, geo.size.width)))
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.35), value: fraction)

            // Balance label
            HStack {
                Spacer()
                Group {
                    if balanced {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("Balanced")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.green)
                    } else if remaining > 0 {
                        Text("\(Currency.format(remaining, code: currencyCode)) remaining")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Currency.format(-remaining, code: currencyCode)) over")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                    }
                }
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: balanced)
            }
        }
    }

    // MARK: - Split Lifecycle

    private func activateSplitMode() {
        let firstAccount = mostFrequentAccount ?? selectedAccount ?? activeAccounts.first
        let secondAccount = activeAccounts.first { $0.id != firstAccount?.id } ?? firstAccount
        let currentCategory = selectedCategory

        splitRows = [
            SplitRow(amount: amount, category: currentCategory, account: firstAccount),
            SplitRow(amount: 0, category: currentCategory, account: secondAccount)
        ]

        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            splitModeActive = true
        }
    }

    private func deactivateSplitMode() {
        if let firstCategory = splitRows.first?.category {
            selectedCategory = firstCategory
            categoryManuallySet = true
        }
        if let firstAccount = splitRows.first?.account {
            selectedAccount = firstAccount
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            splitModeActive = false
            splitRows = []
            splitRowsAppeared = []
        }
    }

    private func addSplitRow() {
        let inheritedCategory = splitRows.last?.category ?? selectedCategory
        let usedAccountIDs = Set(splitRows.compactMap { $0.account?.id })
        let nextAccount = activeAccounts.first { !usedAccountIDs.contains($0.id) } ?? activeAccounts.first
        let remaining = max(0, amount - splitAssignedTotal)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            splitRows.append(SplitRow(amount: remaining, category: inheritedCategory, account: nextAccount))
        }
    }

    private func removeSplitRow(id: UUID) {
        guard let index = splitRows.firstIndex(where: { $0.id == id }) else { return }
        let removedAmount = splitRows[index].amount
        withAnimation(AppAnimation.gentle) {
            splitRows.remove(at: index)
            // Give removed amount to the last row so the total stays balanced
            if !splitRows.isEmpty {
                splitRows[splitRows.count - 1].amount += removedAmount
            }
        }
    }

    // MARK: - Account Strip

    private var accountStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(prioritizedAccounts) { account in
                        AccountPill(
                            account: account,
                            isSelected: selectedAccount?.id == account.id
                        )
                        .id(account.id)
                        .onTapGesture {
                            Haptics.selection()
                            withAnimation(AppAnimation.bouncy) {
                                selectedAccount = account
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.sm)
            }
            .scrollClipDisabled()
            .onChange(of: selectedAccount?.id) { _, newID in
                guard let id = newID else { return }
                withAnimation(.snappy(duration: 0.4)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Category Grid
    //
    // Inline 4-column grid showing every active category at once. No
    // expansion, no "More" tile — categories are the substance of the
    // entry, not a fold-away detail. Scanning a full grid is fastest
    // for the user; hiding categories behind a sheet was the wrong call.

    private var visibleCategories: [Category] {
        let all = prioritizedCategories
        if categoriesExpanded { return all }
        // When selected category isn't in the first 3, swap it in
        let first3 = Array(all.prefix(3))
        if let sel = selectedCategory, !first3.contains(where: { $0.id == sel.id }) {
            return [sel] + Array(first3.prefix(2))
        }
        return first3
    }

    private var categoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4),
            spacing: Spacing.md
        ) {
            ForEach(visibleCategories) { category in
                CategoryGridItem(
                    category: category,
                    isSelected: selectedCategory?.id == category.id
                )
                .onTapGesture {
                    Haptics.selection()
                    withAnimation(AppAnimation.bouncy) {
                        if selectedCategory?.id == category.id {
                            selectedCategory = nil
                            categoryManuallySet = false
                        } else {
                            selectedCategory = category
                            categoryManuallySet = true
                        }
                    }
                }
            }

            if prioritizedCategories.count > 3 {
                VStack(spacing: Spacing.xs) {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.15))
                            .frame(width: 50, height: 50)
                        Image(systemName: categoriesExpanded ? "chevron.up" : "chevron.down")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(categoriesExpanded ? "Less" : "More")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.selection()
                    withAnimation(AppAnimation.bouncy) {
                        categoriesExpanded.toggle()
                    }
                }
            }
        }
    }

    // MARK: - Details Card (merchant, item, date)
    //
    // Inline text fields stacked in a single rounded card. Each row is
    // the field's icon + label + the live text input. No sheet detour
    // for typing — tap and start typing. This was the right pattern
    // all along; my sheet-based redesign was over-engineering.

    private var detailsCard: some View {
        Card(padding: 0, cornerRadius: CornerRadius.medium) {
            VStack(spacing: 0) {
                detailRow(label: "Merchant", icon: "storefront.fill") {
                    TextField("Store, app or person", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 48)
                detailRow(label: "Item", icon: "text.alignleft") {
                    TextField("What did you spend on?", text: $note)
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                }
                // Items-breakdown link — appears as a quiet trailing-
                // aligned text link only when the note text parses to
                // ≥2 structured items. Sits just under the Item row
                // (no divider between them; it visually belongs to
                // that field). Hyperlink-style affordance — brand-amber
                // text, no chevron, no icon — keeps it lightweight.
                if let parsedItems = parsedItemsForCurrentNote, parsedItems.items.count >= 2 {
                    HStack {
                        Spacer()
                        Button {
                            showingItemsSheet = true
                        } label: {
                            Text("View all \(parsedItems.items.count) items")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.tulaBrandFallback)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xs)
                }
                if tax > 0 || discount > 0 {
                    Divider().padding(.leading, 48)
                    taxDiscountRows
                }
                Divider().padding(.leading, 48)
                detailRow(label: "Date", icon: "calendar") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                }
            }
        }
    }

    private var taxDiscountRows: some View {
        VStack(spacing: 0) {
            if discount > 0 {
                detailRow(label: "Discount", icon: "minus.circle") {
                    HStack(spacing: 4) {
                        Text(Currency.symbol(for: currencyCode))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("0", value: $discount, format: .number)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.green)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .onChange(of: discount) { oldVal, newVal in
                                let delta = newVal - oldVal
                                amount = max(0, amount - delta)
                            }
                    }
                }
            }
            if discount > 0 && tax > 0 {
                Divider().padding(.leading, 48)
            }
            if tax > 0 {
                detailRow(label: "Tax", icon: "plus.circle") {
                    HStack(spacing: 4) {
                        Text(Currency.symbol(for: currencyCode))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("0", value: $tax, format: .number)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .onChange(of: tax) { oldVal, newVal in
                                let delta = newVal - oldVal
                                amount = max(0, amount + delta)
                            }
                    }
                }
            }
        }
    }

    private func detailRow<Content: View>(
        label: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md - 2)
    }

    // MARK: - Receipt
    //
    // Optional photo attachment for an expense. Two paths:
    //
    //   - **Empty state**: A single tappable card showing "Add receipt"
    //     with a camera glyph. Tapping opens a confirmation dialog
    //     offering camera vs photo library — both end up running the
    //     same Vision OCR pipeline.
    //
    //   - **Populated state**: Thumbnail of the photo + small ✨ glyph
    //     if any OCR pre-fill happened, plus a trash button to remove.
    //
    // **OCR triggers automatically** on photo addition. The amount and
    // merchant fields receive a small sparkle marker (in their detail row)
    // indicating "Tula filled this from the receipt — verify before save."

    private var receiptSection: some View {
        Group {
            if let image = receiptImage {
                receiptThumbnailCard(image: image)
            } else {
                receiptEmptyCard
            }
        }
        .confirmationDialog(
            "Add receipt",
            isPresented: $showingReceiptSourcePicker,
            titleVisibility: .visible
        ) {
            Button("Take photo") { amountFocused = false; showingCamera = true }
            Button("Choose from library") { amountFocused = false; showingLibraryPicker = true }
            Button("Cancel", role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            ReceiptPicker(source: .camera) { image in
                showingCamera = false
                guard let image else { return }
                Haptics.success()
                receiptImage = image
                runReceiptOCR(on: image)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingLibraryPicker) {
            ReceiptPicker(source: .library) { image in
                showingLibraryPicker = false
                guard let image else { return }
                Haptics.success()
                receiptImage = image
                runReceiptOCR(on: image)
            }
        }
    }

    /// Empty receipt card — invites the user to add a photo. Quiet,
    /// optional-looking by design; receipts are extra, not required.
    private var receiptEmptyCard: some View {
        Button {
            Haptics.tap()
            showingReceiptSourcePicker = true
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add receipt")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("Photo + auto-fill from text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
            .accessibilityHint("Opens camera or photo library to scan a receipt")
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    @State private var showingFullReceipt = false

    private func receiptThumbnailCard(image: UIImage) -> some View {
        VStack(spacing: 0) {
            Button {
                showingFullReceipt = true
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
                    .contentShape(Rectangle())
                    .background(Color.black.opacity(0.04))
            }
            .buttonStyle(.plain)

            HStack(spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Receipt")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if !ocrExtractedFields.isEmpty {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.tulaBrandFallback)
                        }
                    }
                    if receiptOCRInFlight {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text("Reading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let errorMsg = scanErrorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(errorMsg)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                            if canRetryAIGate {
                                Button("Retry") {
                                        runReceiptOCR(on: image, forceCloudAI: true)
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.tulaBrandFallback)
                                    .clipShape(RoundedRectangle(cornerRadius: 20))
                            }
                        }
                    } else if !ocrExtractedFields.isEmpty {
                        Text(ocrSummaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    Haptics.tap()
                    runReceiptOCR(on: image)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.tulaBrandFallback)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(receiptOCRInFlight)

                Button {
                    Haptics.tap()
                    showingReceiptSourcePicker = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.tulaBrandFallback)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button {
                    Haptics.tap()
                    receiptImage = nil
                    ocrExtractedFields.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red.opacity(0.8))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)

            // AI not configured warning
            if !SmartExpenseParser.isAvailable && scanErrorMessage == nil && !receiptOCRInFlight {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("AI not configured — receipt won't be auto-read. Set up in Settings > AI Provider.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.bottom, Spacing.sm)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
    }

    @State private var receiptSaved = false

    private func receiptFullScreenView(image: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableReceiptView(image: image)
            // Top bar with gradient scrim for icon visibility on any background
            VStack {
                HStack {
                    Button {
                        Haptics.tap()
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        receiptSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            receiptSaved = false
                        }
                    } label: {
                        Image(systemName: receiptSaved ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                            .padding()
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .contentShape(Rectangle())

                    Spacer()

                    Button {
                        showingFullReceipt = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                            .padding()
                    }
                    .contentShape(Rectangle())
                }
                Spacer()
            }
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.5), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                .ignoresSafeArea()
                .allowsHitTesting(false),
                alignment: .top
            )
        }
    }

    /// Short summary text describing what OCR pulled from the receipt.
    /// Shown under the "Receipt attached" label so the user sees what
    /// was filled.
    private var ocrSummaryText: String {
        var parts: [String] = []
        if ocrExtractedFields.contains(.amount) { parts.append("Amount") }
        if ocrExtractedFields.contains(.merchant) { parts.append("Merchant") }
        guard !parts.isEmpty else { return "Stored with this expense" }
        return "Filled: \(parts.joined(separator: " + "))"
    }

    /// Trigger Vision OCR on the freshly attached image. Runs as a
    /// detached task so it doesn't block the UI. Results pre-fill the
    /// form's amount + merchant fields when present, and mark those
    /// fields as OCR-sourced for the ✨ indicator.
    ///
    /// **Doesn't overwrite user input**: if the user has already typed
    /// an amount or merchant before the OCR finishes, we don't clobber
    /// their data. Late OCR finishes that arrive after editing are
    /// silently ignored for those fields.
    private func runReceiptOCR(on image: UIImage, forceCloudAI: Bool = false) {
        receiptOCRInFlight = true
        canRetryAIGate = false
        scanErrorMessage = nil
        let beforeAmount = amount
        let beforeMerchant = merchant
        let beforeNote = note
        let beforeDate = date

        let categoryEntries = activeCategories.map {
            CategoryEntry(name: $0.name, iconKey: $0.iconKey)
        }

        // Build the situational + DB context block BEFORE the detached
        // task so we can access the ModelContext on MainActor. Pass
        // the resulting string into the detached task — strings are
        // Sendable so the actor hop is safe.
        let contextBlock = FMContextBuilder.build(modelContext: context)

        let isDirectImageMode = SmartExpenseParser.hasCloudVision

        Task.detached(priority: .userInitiated) {
            let gateResult: ReceiptStorage.ReceiptLikelihoodResult?
            if isDirectImageMode && !forceCloudAI {
                gateResult = await ReceiptStorage.likelyExpenseDocument(from: image)
            } else {
                gateResult = nil
            }

            // For cloud AI with direct image mode: send the photo straight
            // to the AI — no OCR needed. The AI reads the image itself.
            // For Apple FM: run OCR first, then send the text to FM.
            let regexResult: ReceiptStorage.ParseResult?
            if isDirectImageMode {
                regexResult = nil
            } else {
                regexResult = await ReceiptStorage.parse(image)
            }

            let smartResult: ReceiptSmartParseResult? = await withTaskGroup(of: ReceiptSmartParseResult?.self) { group in
                group.addTask {
                    guard SmartExpenseParser.isAvailable else { return nil }

                    if isDirectImageMode {
                        if let gateResult, !gateResult.shouldCallAI {
                            return nil
                        }
                        guard let optimizedData = CloudAIParser.prepareImageForGemini(image) else { return nil }
                        return await SmartExpenseParser.parseReceiptImage(
                            optimizedData,
                            categories: categoryEntries,
                            contextBlock: contextBlock,
                            skipResize: true
                        )
                    }

                    guard let regexResult else { return nil }
                    return await SmartExpenseParser.parseReceipt(
                        regexResult.rawText,
                        categories: categoryEntries,
                        documentType: regexResult.documentType,
                        contextBlock: contextBlock
                    )
                }
                group.addTask {
                    let timeout: Duration = isDirectImageMode ? .seconds(30) : .seconds(6)
                    try? await Task.sleep(for: timeout)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }

            await MainActor.run {
                receiptOCRInFlight = false

                if isDirectImageMode,
                   let gateResult,
                   !gateResult.shouldCallAI,
                   !forceCloudAI {
                    scanErrorMessage = "\(gateResult.reason) Tap Try Again if this is a receipt."
                    canRetryAIGate = true
                } else if smartResult == nil && (isDirectImageMode || regexResult == nil) {
                    scanErrorMessage = CloudAIParser.lastParseError
                        ?? "Couldn't read this receipt. Enter details manually."
                    canRetryAIGate = false
                } else {
                    scanErrorMessage = nil
                    canRetryAIGate = false
                }

                // AMOUNT
                let mergedAmount: Double?
                if isDirectImageMode {
                    mergedAmount = smartResult?.amount
                } else {
                    let isStructuredDoc = regexResult?.documentType == .upi
                        || regexResult?.documentType == .orderSummary
                    if isStructuredDoc, let rgx = regexResult?.amount, rgx > 0 {
                        mergedAmount = rgx
                    } else {
                        mergedAmount = smartResult?.amount ?? regexResult?.amount
                    }
                }
                if let parsedAmount = mergedAmount, parsedAmount > 0,
                   amount == beforeAmount, amount == 0 {
                    withAnimation(.snappy(duration: 0.25)) {
                        amount = parsedAmount
                        ocrExtractedFields.insert(.amount)
                    }
                }

                let mergedMerchant: String?
                if isDirectImageMode {
                    mergedMerchant = smartResult?.merchant
                } else {
                    let isStructuredDoc = regexResult?.documentType == .upi
                        || regexResult?.documentType == .orderSummary
                    if isStructuredDoc, let rgx = regexResult?.merchant, !rgx.isEmpty {
                        mergedMerchant = rgx
                    } else {
                        mergedMerchant = smartResult?.merchant ?? regexResult?.merchant
                    }
                }
                if let m = mergedMerchant, !m.isEmpty,
                   merchant == beforeMerchant, merchant.isEmpty {
                    withAnimation(.snappy(duration: 0.25)) {
                        merchant = m
                        ocrExtractedFields.insert(.merchant)
                    }
                }

                let resolvedDate: Date?
                if isDirectImageMode {
                    resolvedDate = parseFMDate(smartResult?.date, time: smartResult?.time)
                } else {
                    resolvedDate = regexResult?.date ?? parseFMDate(smartResult?.date, time: smartResult?.time)
                }
                if let parsedDate = resolvedDate, date == beforeDate,
                   Calendar.current.isDateInToday(date) {
                    // Only override if the form date is still "today"
                    // (the default) — respects any manual date the user
                    // already set before OCR completed.
                    //
                    // **Time preservation**: we use the receipt's
                    // calendar day BUT keep the current time-of-day.
                    // Why: a receipt printed at 8am photographed at
                    // 6pm should still sort above other 6pm expenses
                    // in the recent list ("just added rises to top"
                    // matches user mental model). Setting the date
                    // to 8am sorted it BELOW today's earlier entries
                    // — the exact "added expense goes to last in
                    // today's section" bug. Using the day from the
                    // receipt but the time from now fixes the sort
                    // order without losing the receipt's true date
                    // when it's from a previous day.
                    let cal = Calendar.current
                    let dayComponents = cal.dateComponents([.year, .month, .day], from: parsedDate)
                    let timeComponents = cal.dateComponents([.hour, .minute, .second], from: .now)
                    var merged = DateComponents()
                    merged.year = dayComponents.year
                    merged.month = dayComponents.month
                    merged.day = dayComponents.day
                    merged.hour = timeComponents.hour
                    merged.minute = timeComponents.minute
                    merged.second = timeComponents.second
                    let finalDate = cal.date(from: merged) ?? parsedDate
                    withAnimation(.snappy(duration: 0.25)) {
                        date = finalDate
                    }
                }

                let itemsForNote: String?
                if let smart = smartResult, !smart.items.isEmpty {
                    itemsForNote = formatSmartItems(smart.items, total: amount)
                } else if !isDirectImageMode {
                    itemsForNote = regexResult?.formattedNote(currencyCode: currencyCode)
                } else {
                    itemsForNote = nil
                }
                if let formatted = itemsForNote, note == beforeNote, note.isEmpty {
                    withAnimation(.snappy(duration: 0.25)) {
                        note = formatted
                    }
                }

                if let smart = smartResult {
                    if let t = smart.tax, t > 0 {
                        withAnimation(.snappy(duration: 0.25)) { tax = t }
                    }
                    if let d = smart.discount, d > 0 {
                        withAnimation(.snappy(duration: 0.25)) { discount = d }
                    }
                }

                // CATEGORY: resolution order matters.
                //   1. MerchantRule lookup against the merchant we just
                //      extracted — deterministic, uses user's learned
                //      mappings ("BPCL" → Transport from 50 prior saves).
                //   2. FM-suggested category from the smart parser.
                //   3. No change (user can pick manually).
                //
                // The MerchantRule check is the BIG win — if the user has
                // ever categorized this merchant before, we route deterministically
                // without involving FM. Faster, more consistent, and learns
                // from the user's actual behavior.
                //
                // **Two-pass name match for FM result**: first try exact
                // case-insensitive equality. If that fails, try substring
                // overlap in either direction ("Food" ↔ "Food & Drinks").
                // FM occasionally returns slight variants of the category
                // name despite the prompt asking for exact matches —
                // substring fallback recovers from that.
                if !categoryManuallySet {
                    // Phase 1: MerchantRule lookup. Use the merchant we
                    // just merged (FM-preferred, regex-fallback). We're
                    // already inside the outer `MainActor.run` block so
                    // direct call is fine — `context` is the @Environment
                    // ModelContext bound at line 11.
                    let merchantForLookup: String? = mergedMerchant
                    let ruleCategory: Category? = MerchantRuleResolver.category(
                        for: merchantForLookup,
                        in: context
                    )
                    if let ruleCategory {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedCategory = ruleCategory
                        }
                    } else if let categoryName = smartResult?.category,
                              let resolved = resolveCategory(named: categoryName) {
                        // Phase 2: FM suggestion fallback.
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedCategory = resolved
                        }
                    }
                }

                // ACCOUNT: try to match a card/bank name from the receipt
                // to one of the user's accounts. Sources checked in order:
                //   1. FM-extracted paymentMode ("IndusInd Credit Card")
                //   2. Raw OCR text (catches "HDFC BANK" printed on receipt)
                // Only override if the user hasn't manually picked yet.
                if let matched = resolveAccountFromReceipt(
                    paymentMode: smartResult?.paymentMode,
                    cardLast4: smartResult?.cardLast4,
                    rawText: isDirectImageMode ? nil : regexResult?.rawText
                ) {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedAccount = matched
                    }
                }
            }
        }
    }

    /// Resolve a category name (e.g. from FM output) to one of the
    /// user's active categories. Tries exact match first, then partial
    /// overlap. Returns nil when nothing reasonable matches.
    private func resolveCategory(named name: String) -> Category? {
        let target = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        // Pass 1: exact case-insensitive match
        if let exact = activeCategories.first(where: { $0.name.lowercased() == target }) {
            return exact
        }

        // Pass 2: substring overlap — either direction. Picks the
        // category whose name is contained in the FM output OR vice
        // versa. "Food" matches "Food & Drinks" and "Food" matches
        // "Foods". Sorted shortest-first so "Food" wins over "Food
        // & Drinks" when both match.
        let overlaps = activeCategories
            .filter { cat in
                let catLower = cat.name.lowercased()
                return target.contains(catLower) || catLower.contains(target)
            }
            .sorted { $0.name.count < $1.name.count }
        return overlaps.first
    }

    /// Match the receipt's card/bank info to one of the user's accounts.
    /// Strategies tried in priority order:
    /// 1. **Exact 4-digit match** — strongest signal, unambiguous.
    /// 2. **Partial digit suffix + card-name match** — when AI extracts
    ///    only 2-3 digits (e.g. "43"), combine with name matching for
    ///    a confident result. Requires BOTH signals to avoid false positives.
    /// 3. **Name-word match on paymentMode** — distinctive words from the
    ///    account name ("IndusInd", "HDFC") matched against the AI's
    ///    paymentMode string.
    /// 4. **Name-word match on raw OCR text** (FM mode only).
    private func resolveAccountFromReceipt(paymentMode: String?, cardLast4: String?, rawText: String?) -> Account? {
        // Strategy 1: direct last-4-digit match from Gemini.
        if let digits = cardLast4, digits.count == 4 {
            for account in activeAccounts {
                guard let acctDigits = account.last4Digits, acctDigits.count >= 2 else { continue }
                if acctDigits.suffix(4) == digits { return account }
            }
        }

        // Build a haystack from all text sources for name matching.
        var haystack = ""
        if let pm = paymentMode { haystack += " " + pm.lowercased() }
        if let raw = rawText { haystack += " " + raw.lowercased() }

        let generic: Set<String> = [
            "bank", "card", "credit", "debit", "cash", "wallet",
            "account", "savings", "current", "the", "my", "upi"
        ]

        // Strategy 2: partial digit suffix (2-3 digits) + name match.
        // When the AI only extracted 2-3 digits, we combine that with
        // card-name matching for confidence. "43" alone is ambiguous,
        // but "43" + "HDFC" in the payment mode is a strong match
        // against an account named "HDFC Bank" with last4 "8743".
        if let digits = cardLast4, digits.count >= 2, digits.count < 4, !haystack.isEmpty {
            for account in activeAccounts {
                guard let acctDigits = account.last4Digits, acctDigits.count >= 2 else { continue }
                // Check if the account's stored digits end with the
                // extracted digits (suffix match).
                guard acctDigits.hasSuffix(digits) else { continue }
                // Also require at least one distinctive name-word match
                // to avoid false positives from digit coincidence.
                let words = account.name
                    .lowercased()
                    .components(separatedBy: .alphanumerics.inverted)
                    .filter { $0.count >= 3 && !generic.contains($0) }
                let nameMatch = words.contains { haystack.contains($0) }
                if nameMatch { return account }
            }
        }

        // Strategy 3 & 4: name-word fuzzy match only.
        guard !haystack.isEmpty else { return nil }

        var bestAccount: Account?
        var bestScore = 0
        for account in activeAccounts {
            let words = account.name
                .lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= 3 && !generic.contains($0) }
            var score = words.filter { haystack.contains($0) }.count
            // Boost accounts that have a digit suffix match even without
            // meeting the full Strategy 2 bar — a partial digit match
            // alongside a name match is a stronger signal than name alone.
            if let digits = cardLast4, digits.count >= 2,
               let acctDigits = account.last4Digits,
               acctDigits.hasSuffix(digits) {
                score += 2
            }
            if score > bestScore {
                bestScore = score
                bestAccount = account
            }
        }
        return bestAccount
    }

    private func parseFMDate(_ string: String?, time timeString: String? = nil) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let dateOnly = formatter.date(from: string) else { return nil }

        if let timeString, !timeString.isEmpty {
            let parts = timeString.split(separator: ":").compactMap { Int($0) }
            if parts.count >= 2 {
                let cal = Calendar.current
                var comps = cal.dateComponents([.year, .month, .day], from: dateOnly)
                comps.hour = parts[0]
                comps.minute = parts[1]
                return cal.date(from: comps)
            }
        }
        return dateOnly
    }

    /// Render FM-extracted items as a note string. Same format as the
    /// regex pipeline produces for consistency.
    /// Format FM-extracted items into a single note string. For short
    /// lists, show all items inline. For LONG lists (DMart with 30+
    /// items, hospital bills with many line items), truncate to the
    /// first few + "and N more" suffix — full items dump becomes
    /// unreadable past about 5 items in a note field.
    ///
    /// The Expense's note is meant to be a SUMMARY, not a full inventory.
    /// Users who want to see every line can review the original receipt
    /// photo (which we save attached to the expense).
    private func formatSmartItems(_ items: [ReceiptLineItem], total: Double) -> String {
        let parts = items.map { item -> String in
            let qty = item.quantity > 1 ? "×\(item.quantity) " : ""
            return "\(item.name) \(qty)\(Currency.format(item.price, code: currencyCode))"
        }
        let body = parts.joined(separator: " · ")

        if total > 0 {
            return "\(body) (Total \(Currency.format(total, code: currencyCode)))"
        }
        return body
    }

    // MARK: - Delete (edit mode only)

    private var deleteButton: some View {
        Button(role: .destructive) {
            Haptics.warning()
            showingDeleteConfirm = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete Expense").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md + 2)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    // MARK: - Account Priority

    /// Account display order in the strip:
    /// 1. **Selected first** so the chosen pill is always at the leading edge.
    /// 2. **Most-recently-used next** — recency uses the latest date among
    ///    that account's expenses + incoming + outgoing transfers.
    /// 3. **`sortOrder` fallback** for accounts that have never been used.
    private var prioritizedAccounts: [Account] {
        let active = activeAccounts
        return active.sorted { lhs, rhs in
            if let selectedID = selectedAccount?.id {
                if lhs.id == selectedID && rhs.id != selectedID { return true }
                if rhs.id == selectedID && lhs.id != selectedID { return false }
            }
            let lDate = latestActivityDate(for: lhs)
            let rDate = latestActivityDate(for: rhs)
            switch (lDate, rDate) {
            case let (.some(a), .some(b)): return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none):
                return lhs.sortOrder < rhs.sortOrder
            }
        }
    }

    /// Latest activity date for an account — looks at expenses,
    /// incoming transfers, and outgoing transfers. Returns nil for
    /// accounts that have never been touched.
    private func latestActivityDate(for account: Account) -> Date? {
        let expenseLatest = account.expenses.map(\.date).max()
        let outgoingLatest = account.outgoingTransfers.map(\.date).max()
        let incomingLatest = account.incomingTransfers.map(\.date).max()
        return [expenseLatest, outgoingLatest, incomingLatest]
            .compactMap { $0 }
            .max()
    }

    /// The account with the most expenses — used as default for split rows.
    private var mostFrequentAccount: Account? {
        activeAccounts.max(by: { $0.expenses.count < $1.expenses.count })
    }

    // MARK: - Category Priority

    /// Sort categories with three tiers:
    /// 1. **"Other" always last** — fallback bucket, shouldn't displace real categories.
    /// 2. **Usage frequency (last 30 days), descending** — most-picked rises.
    /// 3. **Alphabetical** for ties.
    private var prioritizedCategories: [Category] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
        let useCounts: [UUID: Int] = activeCategories.reduce(into: [:]) { dict, cat in
            dict[cat.id] = cat.expenses.filter { $0.date >= cutoff }.count
        }
        return activeCategories.sorted { lhs, rhs in
            let lIsOther = lhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            let rIsOther = rhs.name.localizedCaseInsensitiveCompare("Other") == .orderedSame
            if lIsOther != rIsOther {
                return !lIsOther
            }
            let l = useCounts[lhs.id] ?? 0
            let r = useCounts[rhs.id] ?? 0
            if l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Logic

    private func setupDefaults() {
        if isEditing { return }
        if selectedAccount == nil {
            if !lastUsedAccountID.isEmpty,
               let uuid = UUID(uuidString: lastUsedAccountID),
               let match = activeAccounts.first(where: { $0.id == uuid }) {
                selectedAccount = match
            } else {
                selectedAccount = activeAccounts.first
            }
        }
        // Smart default: pre-select the most common category for this
        // time of day based on the user's history. Only if no category
        // was already set (e.g. from a merchant rule or receipt parse).
        if selectedCategory == nil && !categoryManuallySet {
            selectedCategory = timeBasedDefaultCategory()
        }
    }

    /// Returns the user's most commonly used category for the current
    /// time-of-day bucket, based on recent expense history. Returns nil
    /// if no clear pattern exists (fewer than 3 data points).
    private func timeBasedDefaultCategory() -> Category? {
        let hour = Calendar.current.component(.hour, from: .now)
        let bucket: ClosedRange<Int>
        switch hour {
        case 5...9:   bucket = 5...9    // Morning
        case 10...13: bucket = 10...13  // Lunch
        case 14...17: bucket = 14...17  // Afternoon
        case 18...22: bucket = 18...22  // Evening/Dinner
        default:      return nil        // Late night — no default
        }
        let recent = Array(recentExpensesForPredictions.prefix(200))
        let matching = recent.filter { expense in
            let h = Calendar.current.component(.hour, from: expense.date)
            return bucket.contains(h) && expense.category != nil
        }
        guard matching.count >= 3 else { return nil }
        let counts = Dictionary(grouping: matching, by: { $0.category!.id })
        guard let topEntry = counts.max(by: { $0.value.count < $1.value.count }),
              topEntry.value.count >= 2,
              Double(topEntry.value.count) / Double(matching.count) >= 0.3 else { return nil }
        return topEntry.value.first?.category
    }

    private func applyMerchantRule(for input: String) {
        guard !categoryManuallySet else { return }
        let needle = input.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else {
            selectedCategory = nil
            return
        }
        let userRules = allMerchantRules.filter { $0.isUserDefined }
        let defaultRules = allMerchantRules.filter { !$0.isUserDefined }
        for rule in userRules + defaultRules {
            if needle.contains(rule.pattern) {
                withAnimation(AppAnimation.snappy) { selectedCategory = rule.category }
                return
            }
        }
    }

    private func save() {
        // Split mode: create N independent expenses, one per split row.
        // Each row has its own category and account.
        if splitModeActive {
            guard splitIsValid else { return }
            let receiptData = receiptImage.flatMap { ReceiptStorage.compress($0) }

            for (i, row) in splitRows.enumerated() {
                guard let account = row.account else { continue }
                let expense = Expense(
                    amount: row.amount, date: date,
                    merchant: merchant.isEmpty ? nil : merchant,
                    note: note.isEmpty ? nil : note,
                    source: .manual,
                    category: row.category, account: account
                )
                expense.tax = nil
                expense.discount = nil
                // Attach receipt to first split only — avoids N copies of same blob.
                if i == 0 { expense.receiptImageData = receiptData }
                context.insert(expense)
            }

            try? context.save()
            WidgetRefresh.refresh(using: context)
            NotificationManager.refreshDailyReminder(using: context)
            if let first = splitRows.first?.account {
                lastUsedAccountID = first.id.uuidString
            }
            Haptics.success()
            evaluateBudgetAlerts()
            dismiss()
            return
        }

        guard let account = selectedAccount, amount > 0 else { return }
        // Compress the receipt image if one was attached. Done here (not
        // on attach) because we don't want to spend CPU compressing
        // photos the user might still discard before saving. Returns nil
        // on encode failure or when no receipt was attached.
        let receiptData: Data? = receiptImage.flatMap { ReceiptStorage.compress($0) }

        if let existingExpense {
            existingExpense.amount = amount
            existingExpense.date = date
            existingExpense.merchant = merchant.isEmpty ? nil : merchant
            existingExpense.note = note.isEmpty ? nil : note
            existingExpense.category = selectedCategory
            existingExpense.account = account
            existingExpense.tax = tax > 0 ? tax : nil
            existingExpense.discount = discount > 0 ? discount : nil
            // Receipt: only update if the user actually attached a new
            // photo this session. Removing a receipt is handled by the
            // trash button which sets `receiptImage = nil`; in that case
            // we explicitly clear the stored data.
            if receiptImage != nil {
                existingExpense.receiptImageData = receiptData
            } else if existingExpense.receiptImageData != nil && !isEditing {
                // Edit path: if image was cleared during this session,
                // null out the stored blob. (isEditing always true here
                // since we're in the `let existingExpense` branch.)
                existingExpense.receiptImageData = nil
            }
        } else {
            let expense = Expense(
                amount: amount, date: date,
                merchant: merchant.isEmpty ? nil : merchant,
                note: note.isEmpty ? nil : note,
                source: .manual,
                category: selectedCategory, account: account
            )
            expense.tax = tax > 0 ? tax : nil
            expense.discount = discount > 0 ? discount : nil
            expense.receiptImageData = receiptData
            context.insert(expense)
        }
        // Learn from the user's choice: if they typed a merchant AND picked
        // a category, remember that mapping so the next "icecream" or
        // "office mess" auto-picks the right category. Silent — the user
        // doesn't see anything happen, but the app gets smarter with use.
        learnMerchantCategory()
        try? context.save(); WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
        lastUsedAccountID = account.id.uuidString
        Haptics.success()
        // Evaluate budget thresholds after persisting — fires a
        // notification if this expense pushed any active budget
        // past 75% or 100%. No-op when budget alerts are disabled.
        evaluateBudgetAlerts()
        dismiss()
    }

    /// User-learning hook: upserts a user-defined MerchantRule when the
    /// expense has both a merchant string and a category. Filters out
    /// pollution (very short merchants, merchant equal to category name,
    /// purely numeric merchants).
    ///
    /// Upsert semantics:
    /// - If a user-defined rule exists for this merchant → update its category.
    /// - If only a default rule exists → leave defaults alone; create a
    ///   higher-priority user rule. The parser checks user rules first, so
    ///   the user's choice wins.
    /// - If no rule exists → create one.
    private func learnMerchantCategory() {
        let trimmed = merchant.trimmingCharacters(in: .whitespaces).lowercased()
        guard let category = selectedCategory,
              !trimmed.isEmpty,
              trimmed.count >= 3,
              // Avoid storing pure numbers ("100" → Food) which add no value.
              !trimmed.allSatisfy({ $0.isNumber || $0.isWhitespace }),
              // Avoid storing rules where merchant equals the category name —
              // these add no new information and could collide.
              trimmed != category.name.lowercased()
        else { return }

        // Look up existing user-defined rule for this exact pattern.
        let fetch = FetchDescriptor<MerchantRule>()
        let allRules = (try? context.fetch(fetch)) ?? []
        let existingUserRule = allRules.first {
            $0.isUserDefined && $0.pattern == trimmed
        }

        if let existing = existingUserRule {
            // Update the category if the user picked a different one this time.
            if existing.category?.id != category.id {
                existing.category = category
            }
        } else {
            // Brand new — insert a user-defined rule. Default rules with the
            // same pattern are left untouched; the parser sees user rules
            // first and they win.
            let rule = MerchantRule(pattern: trimmed,
                                    category: category,
                                    isUserDefined: true)
            context.insert(rule)
        }
    }

    /// Walks active budgets and posts threshold notifications for any
    /// that just crossed 75% or 100%. Gated by the user's opt-in
    /// AppStorage flag — won't fire when budget alerts are off.
    private func evaluateBudgetAlerts() {
        guard budgetAlertsEnabled else { return }
        let budgetFetch = FetchDescriptor<Budget>(
            predicate: #Predicate<Budget> { $0.isActive == true }
        )
        let expenseFetch = FetchDescriptor<Expense>()
        let budgets = (try? context.fetch(budgetFetch)) ?? []
        let expenses = (try? context.fetch(expenseFetch)) ?? []
        NotificationManager.evaluateBudgetThresholds(
            budgets: budgets,
            expenses: expenses
        )
    }

    private func delete() {
        guard let existingExpense else { return }
        withAnimation {
            context.delete(existingExpense)
            try? context.save()
        }
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
        Haptics.success()
        dismiss()
    }
}

// MARK: - Zoomable receipt viewer

/// A UIScrollView-backed image viewer with pinch-to-zoom, pan, and
/// double-tap-to-zoom. Used by AddExpenseView's full-screen receipt cover.
private struct ZoomableReceiptView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 6.0
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = context.coordinator
        scroll.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        // Double-tap: zoom in 3× at tap point, or reset if already zoomed.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let imageView = context.coordinator.imageView else { return }
        DispatchQueue.main.async {
            let size = scroll.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let img = image.size
            let scale = min(size.width / img.width, size.height / img.height)
            let w = img.width * scale
            let h = img.height * scale
            imageView.frame = CGRect(
                x: (size.width - w) / 2,
                y: (size.height - h) / 2,
                width: w, height: h
            )
            scroll.contentSize = size
            scroll.zoomScale = 1.0
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        // Keep the image centered while zooming.
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let iv = imageView else { return }
            let bounds = scrollView.bounds.size
            var frame = iv.frame
            frame.origin.x = frame.size.width < bounds.width
                ? (bounds.width - frame.size.width) / 2 : 0
            frame.origin.y = frame.size.height < bounds.height
                ? (bounds.height - frame.size.height) / 2 : 0
            iv.frame = frame
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView else { return }
            if scroll.zoomScale > 1.0 {
                scroll.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let zoomRect = CGRect(
                    x: point.x - 40, y: point.y - 40,
                    width: 80, height: 80
                )
                scroll.zoom(to: zoomRect, animated: true)
            }
        }
    }
}

// MARK: - Account Pill (used in this view)

struct AccountPill: View {
    let account: Account
    let isSelected: Bool

    private var color: Color { Color(hex: account.colorHex) }

    private var outlinedIconKey: String {
        account.iconKey.replacingOccurrences(of: ".fill", with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? account.iconKey : outlinedIconKey)
                .font(.subheadline.weight(.medium))
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 10)
        .foregroundStyle(isSelected ? .white : .secondary)
        .background(
            Capsule().fill(isSelected ? color : Color.tulaCardSurface)
        )
        .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 6, y: 2)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(account.name) account")
    }
}

// MARK: - Account Chip (used by TransferFormView)
// Kept for backward compatibility — TransferFormView relies on this name.

struct AccountChip: View {
    let account: Account
    let isSelected: Bool

    private var color: Color { Color(hex: account.colorHex) }

    private var outlinedIconKey: String {
        account.iconKey.replacingOccurrences(of: ".fill", with: "")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? account.iconKey : outlinedIconKey)
                .font(.subheadline.weight(.medium))
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 12)
        .foregroundStyle(isSelected ? .white : .secondary)
        .background(
            Capsule().fill(isSelected ? color : Color.tulaCardSurface)
        )
        .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 6, x: 0, y: 2)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(AppAnimation.bouncy, value: isSelected)
    }
}

// MARK: - Category Grid Item

struct CategoryGridItem: View {
    let category: Category
    let isSelected: Bool

    private var color: Color { Color(hex: category.colorHex) }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                Circle()
                    .fill(isSelected ? color : color.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: category.iconKey)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(isSelected ? .white : color)
                    .symbolEffect(.bounce, value: isSelected)
            }
            .shadow(color: isSelected ? color.opacity(0.4) : .clear, radius: 8, y: 3)

            Text(category.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(isSelected ? color.opacity(0.08) : Color.clear)
        )
        .scaleEffect(isSelected ? 1.08 : 1.0)
        .animation(AppAnimation.bouncy, value: isSelected)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("\(category.name) category")
    }
}
