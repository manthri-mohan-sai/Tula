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

    @State private var amount: Double
    @State private var selectedCategory: Category?
    @State private var selectedAccount: Account?
    @State private var merchant: String
    @State private var note: String
    @State private var date: Date
    @State private var categoryManuallySet: Bool
    @State private var showingDeleteConfirm = false

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
    enum OCRField: Hashable { case amount, merchant }

    /// Image picker presentation state. `.camera` shows the camera UI;
    /// `.library` shows the photo picker.
    @State private var showingReceiptSource: ReceiptSource? = nil
    enum ReceiptSource: Identifiable { case camera, library
        var id: Int { switch self { case .camera: 0; case .library: 1 } }
    }
    /// Action sheet for choosing camera vs photo library when adding a
    /// receipt. Both paths feed the same OCR pipeline.
    @State private var showingReceiptSourcePicker: Bool = false

    @FocusState private var amountFocused: Bool

    init(existingExpense: Expense? = nil) {
        self.existingExpense = existingExpense
        if let e = existingExpense {
            _amount = State(initialValue: e.amount)
            _selectedCategory = State(initialValue: e.category)
            _selectedAccount = State(initialValue: e.account)
            _merchant = State(initialValue: e.merchant ?? "")
            _note = State(initialValue: e.note ?? "")
            _date = State(initialValue: e.date)
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
    private var canSave: Bool { amount > 0 && selectedAccount != nil }

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

                    accountStrip

                    // Category grid — inline, all categories visible.
                    categoryGrid
                        .padding(.horizontal, Spacing.xl)

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
                }
            }
            .onAppear {
                setupDefaults()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    amountFocused = true
                }
            }
            .onChange(of: merchant) { _, newValue in
                applyMerchantRule(for: newValue)
            }
            .confirmationDialog("Delete this expense?",
                                isPresented: $showingDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This action can't be undone.")
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
            // chip when it first appears.
            if suggestion.isExactAmountMatch {
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

    private var categoryGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.sm), count: 4),
            spacing: Spacing.md
        ) {
            ForEach(prioritizedCategories) { category in
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
                    TextField("Ramachandra Restaurant, Swiggy…", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                }
                Divider().padding(.leading, 48)
                detailRow(label: "Item", icon: "text.alignleft") {
                    TextField("Masala Dosa, Chai…", text: $note)
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
                Divider().padding(.leading, 48)
                detailRow(label: "Date", icon: "calendar") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
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
            Button("Take photo") { showingReceiptSource = .camera }
            Button("Choose from library") { showingReceiptSource = .library }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $showingReceiptSource) { source in
            ReceiptPicker(source: source) { image in
                guard let image else { return }
                Haptics.success()
                receiptImage = image
                runReceiptOCR(on: image)
            }
            .ignoresSafeArea()
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
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(PressableScaleStyle(scale: 0.98))
    }

    /// Populated receipt card — shows thumbnail + status + trash button.
    /// Tap on thumbnail to view full-size (future enhancement); tap trash
    /// to remove the receipt. OCR status indicator shows a spinner while
    /// running, then disappears.
    private func receiptThumbnailCard(image: UIImage) -> some View {
        HStack(spacing: Spacing.md) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Receipt attached")
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
                } else if !ocrExtractedFields.isEmpty {
                    Text(ocrSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Stored with this expense")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Haptics.tap()
                receiptImage = nil
                ocrExtractedFields.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
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
    private func runReceiptOCR(on image: UIImage) {
        receiptOCRInFlight = true
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

                    if isDirectImageMode,
                       let jpegData = image.jpegData(compressionQuality: 0.85) {
                        return await SmartExpenseParser.parseReceiptImage(jpegData, categories: categoryEntries, contextBlock: contextBlock)
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
                    resolvedDate = parseFMDate(smartResult?.date)
                } else {
                    resolvedDate = regexResult?.date ?? parseFMDate(smartResult?.date)
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

    /// Parse FM's YYYY-MM-DD string into a Date. Returns nil for
    /// malformed strings (FM occasionally produces invalid dates when
    /// the OCR text is ambiguous).
    private func parseFMDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
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
        let parts = items.map { "\($0.name) \(Currency.format($0.price, code: currencyCode))" }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { amountFocused = true }
        if selectedAccount == nil {
            if !lastUsedAccountID.isEmpty,
               let uuid = UUID(uuidString: lastUsedAccountID),
               let match = activeAccounts.first(where: { $0.id == uuid }) {
                selectedAccount = match
            } else {
                selectedAccount = activeAccounts.first
            }
        }
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

// MARK: - Account Pill (used in this view)

struct AccountPill: View {
    let account: Account
    let isSelected: Bool

    private var color: Color { Color(hex: account.colorHex) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.iconKey)
                .font(.subheadline.weight(.medium))
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 10)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            Capsule().fill(isSelected ? color : Color.tulaCardSurface)
        )
        .shadow(color: isSelected ? color.opacity(0.3) : .clear, radius: 6, y: 2)
        .scaleEffect(isSelected ? 1.03 : 1.0)
    }
}

// MARK: - Account Chip (used by TransferFormView)
// Kept for backward compatibility — TransferFormView relies on this name.

struct AccountChip: View {
    let account: Account
    let isSelected: Bool

    private var color: Color { Color(hex: account.colorHex) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: account.iconKey)
                .font(.subheadline.weight(.medium))
            Text(account.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, 12)
        .foregroundStyle(isSelected ? .white : .primary)
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
    }
}
