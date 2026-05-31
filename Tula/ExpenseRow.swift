import SwiftUI

/// Single-line representation of an expense. Used on the home screen's recent
/// activity, account/category detail screens, etc.
struct ExpenseRow: View {
    let expense: Expense
    @PrimaryCurrency private var currencyCode

    /// True when the backing model has been deleted from SwiftData but
    /// SwiftUI is still animating the row's exit. Reading properties of
    /// an invalidated model crashes — this guard short-circuits the body.
    private var isInvalidated: Bool { expense.modelContext == nil }

    private var categoryColor: Color {
        guard let hex = expense.category?.colorHex else { return .gray }
        return Color(hex: hex)
    }

    /// Primary display label for the row title. Merchant-first hierarchy:
    /// the merchant is the aggregatable unit ("₹3,200 at Ramachandra this
    /// month") so it earns the title slot. Specific items appear in the
    /// subtitle as context.
    ///
    /// **Why merchant-first** (not item-first): at scale, users scan
    /// expense lists to find patterns ("where am I spending too much?").
    /// A list titled by item — "Masala Dosa, Chai, Lunch, Lunch, Chai" —
    /// hides those patterns; a list titled by merchant — "Ramachandra,
    /// Swiggy, Chai Point, Chai Point" — surfaces them immediately.
    /// Apple's own data-driven apps (Wallet, Health, Calendar) all use
    /// this pattern: the aggregatable group is primary, the specific
    /// instance is supporting detail.
    ///
    /// Fallback chain when no merchant exists:
    /// 1. Item (note) — for quick entries with just a dish name
    /// 2. Category — last-resort label so the row isn't blank
    /// 3. "Uncategorized" placeholder
    private var primaryLabel: String {
        if let merchant = expense.merchant, !merchant.isEmpty { return merchant }
        if let note = expense.note, !note.isEmpty { return note }
        if let category = expense.category { return category.name }
        return "Uncategorized"
    }

    /// Subtitle stack. When the title is the merchant, the subtitle leads
    /// with the item (so the user still sees what was bought at a glance),
    /// then category, then account. When the title is the item (no merchant),
    /// the subtitle drops the item prefix to avoid showing it twice.
    private var subtitleParts: [String] {
        var parts: [String] = []
        let titleIsMerchant = !(expense.merchant ?? "").isEmpty

        if titleIsMerchant,
           let note = expense.note, !note.isEmpty,
           note.lowercased() != expense.merchant?.lowercased() {
            // Item appears in the subtitle when title is the merchant.
            // Surfaces "Masala Dosa" alongside "Ramachandra" so the user
            // sees both pieces in one glance.
            parts.append(note)
        }
        if let category = expense.category {
            parts.append(category.name)
        }
        if let account = expense.account {
            parts.append(account.name)
        }
        return parts
    }

    private var needsReview: Bool {
        expense.category == nil
    }

    /// Parsed items + total from the note string, when the note is in
    /// the structured format we emit from receipt/share-extension parsing.
    /// Empty when the note is freehand text or absent. Computed inline —
    /// cheap parse (~microseconds), no need to cache.
    private var parsedItems: (items: [ExpenseItem], total: Double?) {
        ExpenseItemParser.parse(expense.note)
    }

    /// Whether this expense has enough parsed items to be worth a sheet.
    /// Single-item lists wouldn't be useful — the note already shows
    /// "Masala Dosa ₹80" in the row.
    private var hasItemsBreakdown: Bool {
        parsedItems.items.count >= 2
    }

    /// Controls presentation of the items breakdown sheet. Sheet is
    /// triggered by tapping the items chip on the row title line.
    @State private var showingItemsSheet: Bool = false

    var body: some View {
        if isInvalidated {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(categoryColor.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: expense.category?.iconKey ?? "questionmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(categoryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(primaryLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if expense.recurringRule != nil {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Recurring")
                    }
                    if expense.source == .smartParsed {
                        Image(systemName: SFSymbols.appleIntelligence)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.tulaBrandFallback)
                            .accessibilityLabel("Parsed by Apple Intelligence")
                    }
                    if expense.receiptImageData != nil {
                        // Tiny paperclip indicator — signals "this expense
                        // has a receipt attached" so users can spot which
                        // entries are backed by photographic evidence vs
                        // typed memory. Same caption2 weight as the other
                        // metadata badges; doesn't compete for attention.
                        Image(systemName: "paperclip")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Receipt attached")
                    }
                    if hasItemsBreakdown {
                        // Tappable items chip — opens the breakdown sheet
                        // without conflicting with the row's main tap
                        // target (which navigates to edit). SwiftUI
                        // treats Button taps as distinct gestures inside
                        // a List/NavigationLink row, so this works without
                        // simultaneousGesture or buttonStyle gymnastics.
                        Button {
                            showingItemsSheet = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                    .font(.caption2.weight(.semibold))
                                Text("\(parsedItems.items.count)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.tulaBrandFallback.opacity(0.15))
                            .foregroundStyle(Color.tulaBrandFallback)
                            .clipShape(Capsule())
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(parsedItems.items.count) items")
                    }
                    if needsReview {
                        Text("Review")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
                // Subtitle stack — merchant (when title is the item),
                // then category, then account. Each piece appears only
                // when present; the centralized `subtitleParts` array
                // decides what's shown so the layout adapts to whatever
                // data exists (entries with no merchant skip that piece
                // gracefully).
                if !subtitleParts.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(subtitleParts.enumerated()), id: \.offset) { idx, part in
                            Text(part).lineLimit(1)
                            if idx < subtitleParts.count - 1 {
                                Text("·").foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: Spacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Currency.format(expense.amount, code: currencyCode))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(relativeDateString(for: expense.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        // Generous vertical padding so rows feel like distinct cards
        // rather than crammed list lines. The 10pt + 64pt floor gives
        // each row ~84pt of clear height, matching the "tappable tile"
        // density people expect from a modern finance app.
        .padding(.vertical, Spacing.md)
        .frame(minHeight: 64)
        .sheet(isPresented: $showingItemsSheet) {
            ExpenseItemsSheet(
                merchantName: expense.merchant,
                amount: expense.amount,
                date: expense.date,
                categoryName: expense.category?.name,
                receiptImageData: expense.receiptImageData,
                items: parsedItems.items,
                total: parsedItems.total
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

    /// Compact relative date: "Today", "Yesterday", "3 May" otherwise.
    private func relativeDateString(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Color hex init
//
// Color(hex:) is defined in SharedAppearance.swift (shared with the widget
// extension target) so all of the app can use it without target-specific
// duplication.

// MARK: - Context Preview

/// Rich preview shown above the iOS context menu when long-pressing an
/// expense row. Larger amount, full merchant/category/account, date —
/// gives confirmation of what action will affect.
struct ExpenseContextPreview: View {
    let expense: Expense
    @PrimaryCurrency private var currencyCode

    private var isInvalidated: Bool { expense.modelContext == nil }

    private var categoryColor: Color {
        guard let hex = expense.category?.colorHex else { return .gray }
        return Color(hex: hex)
    }

    var body: some View {
        if isInvalidated {
            EmptyView()
        } else {
            previewContent
        }
    }

    private var previewContent: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(categoryColor.opacity(0.20))
                        .frame(width: 56, height: 56)
                    Image(systemName: expense.category?.iconKey ?? "questionmark.circle")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(categoryColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    // Merchant-first headline. Mirrors the compact row's
                    // hierarchy — see `primaryLabel` for the rationale.
                    // Fallback chain: merchant → item → category.
                    if let merchant = expense.merchant, !merchant.isEmpty {
                        Text(merchant)
                            .font(.headline)
                        if let note = expense.note, !note.isEmpty,
                           note.lowercased() != merchant.lowercased() {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if let category = expense.category {
                            Text(category.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if let note = expense.note, !note.isEmpty {
                        Text(note)
                            .font(.headline)
                        if let category = expense.category {
                            Text(category.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(expense.category?.name ?? "Uncategorized")
                            .font(.headline)
                    }
                }
                Spacer()
            }

            Text(Currency.format(expense.amount, code: currencyCode))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()

            HStack {
                if let account = expense.account {
                    HStack(spacing: 4) {
                        Image(systemName: account.iconKey)
                            .font(.caption2)
                        Text(account.name)
                            .font(.caption)
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.tulaCardSurface))
                }
                Spacer()
                Text(expense.date.formatted(.dateTime.day().month(.wide).hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Original input that was parsed into this expense. Surfaced
            // here so users can verify what the speech recognizer (or
            // typed text, or Siri) actually delivered — when the saved
            // amount looks wrong, this tells you whether the audio came
            // in correctly and the parser misinterpreted, or the audio
            // itself was missing key information.
            //
            // Hidden when rawInput is the same as merchant (typed-only
            // case where rawInput is just "merchant 250" repeating data
            // already visible above) to avoid clutter on simple entries.
            if let raw = expense.rawInput,
               !raw.isEmpty,
               raw.lowercased() != expense.merchant?.lowercased() {
                HStack(spacing: 4) {
                    Image(systemName: "quote.opening")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(raw)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .italic()
                        .lineLimit(2)
                }
                .padding(.top, 2)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 320)
    }
}
