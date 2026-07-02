import SwiftUI

// MARK: - Expense Draft
//
// Mutable staging value used by every "review before save" surface (voice
// overlay, quick-log). Holds parsed data WITHOUT touching SwiftData — the real
// `Expense` is created only when the user commits, so Discard/Start Over leave
// no trace in the store.

/// Editable, non-persistent representation of a parsed expense plus the
/// confidence the parser assigned to each field.
struct ExpenseDraft: Equatable {
    var amount: Double
    var date: Date
    var merchant: String?
    var note: String?
    /// Individual purchased items ("apples", "tomatoes", "ginger garlic paste").
    var items: [String] = []
    var category: Category?
    var account: Account?
    var rawInput: String
    var confidence: ParseConfidence

    static func == (lhs: ExpenseDraft, rhs: ExpenseDraft) -> Bool {
        lhs.amount == rhs.amount &&
        lhs.date == rhs.date &&
        lhs.merchant == rhs.merchant &&
        lhs.note == rhs.note &&
        lhs.items == rhs.items &&
        lhs.category?.id == rhs.category?.id &&
        lhs.account?.id == rhs.account?.id &&
        lhs.confidence == rhs.confidence
    }

    var isValid: Bool { amount > 0 && account != nil }
}

// MARK: - Editable Expense Card
//
// SRP: renders a parsed draft and lets the user correct it inline. It owns no
// save/discard logic — hosts compose it with `ResultActionBar`. Every field is
// tap-to-edit; fields the parser wasn't confident about wear an amber ring so
// the user knows exactly what to glance at, which is how we hold the line on
// ≥90% accurate saved data without slowing down the confident path.

struct EditableExpenseCard: View {
    @Binding var draft: ExpenseDraft
    let accounts: [Account]
    let categories: [Category]
    let currencyCode: String
    /// Plays the scramble/roll reveal the first time the card appears.
    var animateIn: Bool = true

    @State private var editingAmount = false
    @State private var editingMerchant = false
    @State private var showDatePicker = false
    @State private var amountText = ""
    @State private var merchantText = ""
    @FocusState private var amountFocused: Bool
    @FocusState private var merchantFocused: Bool

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }
    private var activeCategories: [Category] { categories.filter { !$0.isArchived } }
    private var catColor: Color { draft.category.map { Color(hex: $0.colorHex) } ?? .green }

    var body: some View {
        VStack(spacing: 0) {
            confidenceSummary
            categoryBanner
            divider(catColor.opacity(0.12), inset: Spacing.xxl)
            amountField
            itemsSection
            detailsSection
        }
        .padding(.bottom, Spacing.md)
        .background(cardBackground)
    }

    // MARK: Items

    /// Purchased items as removable chips. Hidden when the parse found none.
    @ViewBuilder
    private var itemsSection: some View {
        if !draft.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ITEMS")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.35))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(draft.items.enumerated()), id: \.offset) { index, item in
                            itemChip(item, at: index)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.sm)
        }
    }

    private func itemChip(_ item: String, at index: Int) -> some View {
        HStack(spacing: 5) {
            Text(item.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
            Button {
                Haptics.selection()
                if draft.items.indices.contains(index) { draft.items.remove(at: index) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(item)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    // MARK: Confidence summary

    private var confidenceSummary: some View {
        let needsReview = draft.confidence.needsReview
        return HStack(spacing: 6) {
            Image(systemName: needsReview ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .font(.caption2)
            Text(needsReview ? "Tap highlighted fields to confirm" : "High confidence")
                .font(.caption2.weight(.semibold))
            Spacer()
            Text("\(Int((draft.confidence.overall * 100).rounded()))%")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
        }
        .foregroundStyle(needsReview ? Color.orange.opacity(0.9) : Color.green.opacity(0.8))
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
    }

    // MARK: Category banner

    private var categoryBanner: some View {
        Menu {
            categoryMenuItems
        } label: {
            VStack(spacing: Spacing.sm) {
                ZStack {
                    Circle().fill(catColor.opacity(0.15)).frame(width: 56, height: 56)
                    Circle().fill(catColor.opacity(0.06)).frame(width: 72, height: 72).blur(radius: 10)
                    Image(systemName: draft.category?.iconKey ?? "questionmark.circle.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(catColor)
                }
                .reviewRing(active: draft.confidence.category < .high)

                HStack(spacing: 4) {
                    Text(draft.category?.name.uppercased() ?? "PICK CATEGORY")
                        .font(.caption.weight(.bold))
                        .tracking(1.5)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(catColor.opacity(0.85))
            }
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.md)
    }

    private var categoryMenuItems: some View {
        ForEach(activeCategories, id: \.id) { category in
            Button {
                Haptics.selection()
                draft.category = category
            } label: {
                Label(category.name, systemImage: category.iconKey)
            }
        }
    }

    // MARK: Amount

    private var amountField: some View {
        Group {
            if editingAmount {
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 48, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.tulaBrandFallback)
                    .focused($amountFocused)
                    .onSubmit(commitAmount)
                    .onChange(of: amountFocused) { _, focused in
                        if !focused { commitAmount() }
                    }
            } else {
                Button {
                    Haptics.tap()
                    amountText = draft.amount > 0 ? trimmedAmount(draft.amount) : ""
                    editingAmount = true
                    amountFocused = true
                } label: {
                    Group {
                        if animateIn {
                            RollingAmount(value: draft.amount, currencyCode: currencyCode,
                                          color: Color.tulaBrandFallback)
                        } else {
                            Text(Currency.format(draft.amount, code: currencyCode))
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .foregroundStyle(Color.tulaBrandFallback)
                                .monospacedDigit()
                        }
                    }
                    .reviewRing(active: draft.confidence.amount < .high)
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: Color.tulaBrandFallback.opacity(0.25), radius: 18, y: 4)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: Details

    private var detailsSection: some View {
        VStack(spacing: Spacing.md) {
            merchantRow
            accountRow
            dateRow
        }
        .padding(.vertical, Spacing.md)
    }

    private var merchantRow: some View {
        HStack(spacing: Spacing.sm) {
            rowIcon("mappin.circle.fill", color: .blue.opacity(0.7))
            Text("Merchant").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            Spacer()
            if editingMerchant {
                TextField("Merchant", text: $merchantText)
                    .multilineTextAlignment(.trailing)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .focused($merchantFocused)
                    .onSubmit(commitMerchant)
                    .onChange(of: merchantFocused) { _, focused in
                        if !focused { commitMerchant() }
                    }
            } else {
                Button {
                    Haptics.tap()
                    merchantText = draft.merchant ?? ""
                    editingMerchant = true
                    merchantFocused = true
                } label: {
                    Text(draft.merchant?.isEmpty == false ? draft.merchant! : "Add merchant")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.merchant?.isEmpty == false ? .white : .white.opacity(0.45))
                        .reviewRing(active: draft.confidence.merchant < .high && draft.merchant?.isEmpty == false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Merchant, \(draft.merchant ?? "not set"). Tap to edit.")
            }
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 36)
    }

    private var accountRow: some View {
        HStack(spacing: Spacing.sm) {
            rowIcon(draft.account.map(Self.icon(for:)) ?? "creditcard",
                    color: draft.account.map { Color(hex: $0.colorHex) } ?? .white.opacity(0.45))
            Text("Account").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Menu {
                ForEach(activeAccounts, id: \.id) { account in
                    Button {
                        Haptics.selection()
                        draft.account = account
                    } label: {
                        Label(account.name, systemImage: Self.icon(for: account))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(draft.account?.name ?? "Select account")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.account == nil ? .white.opacity(0.45) : .white)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .reviewRing(active: draft.confidence.account < .high)
            }
            .accessibilityLabel("Account, \(draft.account?.name ?? "not set"). Tap to change.")
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 36)
    }

    private var dateRow: some View {
        HStack(spacing: Spacing.sm) {
            rowIcon("calendar", color: .white.opacity(0.55))
            Text("Date").font(.subheadline).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button {
                Haptics.tap()
                showDatePicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(dateLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Date, \(dateLabel). Tap to change.")
        }
        .padding(.horizontal, Spacing.lg)
        .frame(minHeight: 36)
        .sheet(isPresented: $showDatePicker) { datePickerSheet }
    }

    /// Human-readable date — "Today" / "Yesterday" / "3 Jun 2026".
    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(draft.date) { return "Today" }
        if cal.isDateInYesterday(draft.date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: draft.date)
    }

    /// Graphical date picker on a standard (readable) sheet background.
    private var datePickerSheet: some View {
        NavigationStack {
            DatePicker("Date", selection: $draft.date,
                       in: ...Date.now, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Color.tulaBrandFallback)
                .padding()
                .navigationTitle("Date")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDatePicker = false }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    // MARK: Building blocks

    private func rowIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(color)
            .frame(width: 20, alignment: .center)
    }

    private func divider(_ color: Color, inset: CGFloat) -> some View {
        Rectangle().fill(color).frame(height: 1).padding(.horizontal, inset)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: CornerRadius.xLarge, style: .continuous)
            .fill(.ultraThinMaterial.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.xLarge, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [catColor.opacity(0.2), .white.opacity(0.04), catColor.opacity(0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: catColor.opacity(0.08), radius: 30, y: 10)
    }

    // MARK: Commit helpers

    private func commitAmount() {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let value = Double(cleaned), value > 0 {
            draft.amount = value
            // A user-confirmed amount is, by definition, fully trusted now.
            draft.confidence.amount = .high
        }
        editingAmount = false
    }

    private func commitMerchant() {
        let trimmed = merchantText.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.merchant = trimmed.isEmpty ? nil : trimmed
        if !trimmed.isEmpty { draft.confidence.merchant = .high }
        editingMerchant = false
    }

    private func trimmedAmount(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    nonisolated static func icon(for account: Account) -> String {
        switch account.kind {
        case .creditCard: return "creditcard.fill"
        case .bank:       return "building.columns.fill"
        case .cash:       return "banknote.fill"
        case .wallet:     return "wallet.bifold.fill"
        }
    }
}

// MARK: - Review Ring

/// Amber pulsing outline that marks a field the parser wasn't sure about.
/// Draws attention without blocking — the value is still usable as-is.
private struct ReviewRing: ViewModifier {
    var active: Bool
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, active ? 8 : 0)
            .padding(.vertical, active ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.orange.opacity(active ? (pulse ? 0.7 : 0.3) : 0), lineWidth: 1.5)
            )
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

private extension View {
    func reviewRing(active: Bool) -> some View {
        modifier(ReviewRing(active: active))
    }
}

// MARK: - Result Action Bar
//
// The four-verb control row shared by every review surface: Discard the parse,
// Start Over (re-capture), open the full Edit form, or Save. Hosts supply the
// closures; the bar owns only its layout and enabled state.

struct ResultActionBar: View {
    var canSave: Bool
    /// "Edit" opens the full form — only meaningful for a single expense, so
    /// hosts hide it when reviewing a multi-expense list.
    var showEdit: Bool = true
    var saveTitle: String = "Save"
    var onDiscard: () -> Void
    var onStartOver: () -> Void
    var onEdit: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                secondary(title: "Discard", icon: "trash", action: onDiscard)
                secondary(title: "Start Over", icon: "arrow.counterclockwise", action: onStartOver)
                if showEdit {
                    secondary(title: "Edit", icon: "pencil", action: onEdit)
                }
            }

            Button {
                onSave()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.caption.weight(.bold))
                    Text(saveTitle).font(.headline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(canSave ? Color.tulaBrandFallback : Color.tulaBrandFallback.opacity(0.2),
                           in: Capsule())
                .shadow(color: canSave ? Color.tulaBrandFallback.opacity(0.4) : .clear, radius: 18, y: 6)
            }
            .disabled(!canSave)
        }
    }

    private func secondary(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.subheadline.weight(.medium))
                Text(title).font(.caption2.weight(.medium))
            }
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
        }
    }
}
