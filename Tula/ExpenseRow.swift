import SwiftUI
import SwiftData

/// Single-line representation of an expense. Used on the home screen's recent
/// activity, account/category detail screens, etc.
struct ExpenseRow: View {
    let expense: Expense
    var showTimeOnly: Bool = false
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
        if !expense.items.isEmpty { return itemsSummary }
        if let category = expense.category { return category.name }
        return "Uncategorized"
    }

    /// Comma-joined item names from the structured `items` relationship.
    /// Strips stray array-literal punctuation from any older/mislabelled data
    /// (e.g. a name saved as `["Chicken Biryani"]`).
    private var itemsSummary: String {
        expense.items
            .map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "[]\"' ")).capitalized }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Subtitle stack. When the title is the merchant, the subtitle leads
    /// with the item (so the user still sees what was bought at a glance),
    /// then category, then account. When the title is the item (no merchant),
    /// the subtitle drops the item prefix to avoid showing it twice.
    private var subtitleParts: [String] {
        var parts: [String] = []
        let titleIsMerchant = !(expense.merchant ?? "").isEmpty

        if titleIsMerchant {
            // Item(s) appear in the subtitle when the title is the merchant —
            // surfaces "Milk, Curd" alongside "Raithu Kendra" in one glance.
            // Prefer the structured items; fall back to a freehand note.
            if !expense.items.isEmpty {
                parts.append(itemsSummary)
            } else if let note = expense.note, !note.isEmpty,
                      note.lowercased() != expense.merchant?.lowercased() {
                parts.append(note)
            }
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

    /// Items to display: the structured `items` relationship when present
    /// (voice / quick-log / Siri), otherwise items parsed from a receipt note.
    private var displayItems: [ExpenseItem] {
        if !expense.items.isEmpty {
            return expense.items.map { ExpenseItem(name: $0.name, price: $0.price ?? 0) }
        }
        return parsedItems.items
    }

    /// Total shown in the items sheet — only for note-based (priced) items.
    private var itemsTotal: Double? {
        expense.items.isEmpty ? parsedItems.total : nil
    }

    /// Whether this expense has enough items to be worth a sheet.
    private var hasItemsBreakdown: Bool {
        displayItems.count >= 2
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
                    if let emi = expense.emiLabel {
                        Text(emi)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.tulaBrandFallback.opacity(0.15))
                            .foregroundStyle(Color.tulaBrandFallback)
                            .clipShape(Capsule())
                            .fixedSize()
                            .accessibilityLabel(emi)
                    } else if expense.recurringRule != nil {
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
                        Image(systemName: "paperclip")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Receipt attached")
                    }
                    if hasItemsBreakdown {
                        Button {
                            showingItemsSheet = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                    .font(.caption2.weight(.semibold))
                                Text("\(displayItems.count)")
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
                        .accessibilityLabel("Show \(displayItems.count) items")
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
                if let tax = expense.tax, tax > 0 {
                    Text("+\(Currency.format(tax, code: currencyCode)) tax")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.orange)
                }
                if let discount = expense.discount, discount > 0 {
                    Text("-\(Currency.format(discount, code: currencyCode)) off")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.green)
                }
                Text(relativeDateString(for: expense.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.md)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            var parts: [String] = [primaryLabel]
            parts.append(Currency.format(expense.amount, code: currencyCode))
            if let cat = expense.category { parts.append(cat.name) }
            if let acc = expense.account { parts.append(acc.name) }
            parts.append(relativeDateString(for: expense.date))
            return parts.joined(separator: ", ")
        }())
        .sheet(isPresented: $showingItemsSheet) {
            ExpenseItemsSheet(
                merchantName: expense.merchant ?? primaryLabel,
                amount: expense.amount,
                date: expense.date,
                categoryName: expense.category?.name ?? "Uncategorized",
                receiptImageData: expense.receiptImageData,
                items: displayItems,
                total: itemsTotal
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Context-aware date/time label.
    /// - `showTimeOnly`: just the clock time (for views already grouped by day).
    /// - Default: time for today, "Yest, time" for yesterday, "date, time" for older.
    private func relativeDateString(for date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if showTimeOnly { return time }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time }
        if cal.isDateInYesterday(date) { return "Yest, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + ", \(time)"
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
                    } else if !expense.items.isEmpty {
                        Text(expense.items.map { $0.name.capitalized }.joined(separator: ", "))
                            .font(.headline)
                            .lineLimit(2)
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
