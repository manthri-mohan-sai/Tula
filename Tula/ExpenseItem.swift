import SwiftUI

/// Plain Swift struct (not @Model) representing a single line item
/// parsed from an expense's note string. Used purely for display in
/// the items sheet — items live in the note field as formatted text
/// for now, and we parse them back into structure when the user wants
/// to see the breakdown.
///
/// **Why not @Model**: items are currently display-only. No editing,
/// no filtering, no cross-expense queries. Storing them as text in
/// the note avoids a schema migration on existing data — and the
/// receipt photo (still attached on the Expense) remains the
/// source-of-truth for the full breakdown anyway.
struct ExpenseItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let price: Double
}

/// Parses items out of an Expense's note string. Returns the parsed
/// items + the trailing total (when present), or empty/nil when the
/// note doesn't match the structured format we emit.
///
/// **Format we emit** (from `formatSmartItems` in AddExpenseView,
/// `formattedNote` in ReceiptStorage, and the share extension):
///
///     "Item Name ₹PRICE · Item Name ₹PRICE · ... (Total ₹TOTAL)"
///
/// Or for long lists:
///
///     "Item1 ₹X · ... · Item5 ₹X · and N more items (Total ₹TOTAL)"
///
/// **Parsing strategy**: split on " · ", inspect each chunk for a
/// trailing currency value. Chunks that don't match (the "and N more"
/// suffix, freehand-edited notes) are dropped from the items list but
/// don't break parsing. The "(Total ₹X)" suffix is extracted
/// separately and removed before chunk-splitting.
///
/// **Failure mode**: if zero structured items can be extracted, returns
/// `(items: [], total: nil)` — caller treats the note as plain text.
enum ExpenseItemParser {

    /// Parse a note string into items + total. See type docs for format.
    static func parse(_ note: String?) -> (items: [ExpenseItem], total: Double?) {
        guard let note, !note.isEmpty else { return ([], nil) }

        var working = note
        var parsedTotal: Double? = nil

        // Extract the "(Total ₹X)" suffix if present. Match anywhere
        // near the end; we anchor on "(Total" so freehand parentheses
        // earlier in the note don't trigger.
        if let totalRange = working.range(of: #"\(Total\s+[^)]+\)"#,
                                           options: [.regularExpression, .backwards]) {
            let totalSubstring = String(working[totalRange])
            parsedTotal = extractFirstCurrencyValue(in: totalSubstring)
            working.removeSubrange(totalRange)
            working = working.trimmingCharacters(in: .whitespaces)
        }

        // Split on the " · " separator that all three formatters use.
        // ALSO accept " - " and " | " as legacy separators in case
        // older notes used different formatting.
        let chunks = working
            .components(separatedBy: CharacterSet(charactersIn: "·|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var items: [ExpenseItem] = []
        for chunk in chunks {
            // Skip the "and N more items" suffix — it's a count line,
            // not a real item.
            let lower = chunk.lowercased()
            if lower.hasPrefix("and "), lower.hasSuffix("items") || lower.hasSuffix("item") || lower.contains("more") {
                continue
            }
            guard let parsed = parseChunk(chunk) else { continue }
            items.append(parsed)
        }

        return (items, parsedTotal)
    }

    /// Parse a single chunk like "Masala Dosa ₹80" into an item.
    /// Returns nil for chunks that don't match (no currency value
    /// present, name part empty, etc).
    ///
    /// **Algorithm**: scan backwards from the end of the chunk looking
    /// for the rightmost currency value. The text before that value is
    /// the name. Currency value can be prefixed by ₹, Rs, or nothing;
    /// can have commas and decimals; ends at the last digit.
    private static func parseChunk(_ chunk: String) -> ExpenseItem? {
        // Try to match: anything (greedy) + optional ₹/Rs + digits with
        // commas + optional decimal portion, at the end of the chunk.
        let pattern = #"^(.+?)\s*[₹Rs.]*\s*([\d,]+(?:\.\d+)?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(chunk.startIndex..<chunk.endIndex, in: chunk)
        guard let match = regex.firstMatch(in: chunk, range: range),
              match.numberOfRanges >= 3 else { return nil }

        let nameRange = match.range(at: 1)
        let priceRange = match.range(at: 2)
        guard let nameSubrange = Range(nameRange, in: chunk),
              let priceSubrange = Range(priceRange, in: chunk) else { return nil }

        let name = String(chunk[nameSubrange])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "₹Rs."))
            .trimmingCharacters(in: .whitespaces)

        let priceString = String(chunk[priceSubrange]).replacingOccurrences(of: ",", with: "")
        guard let price = Double(priceString), !name.isEmpty else { return nil }
        return ExpenseItem(name: name, price: price)
    }

    /// Extract the first currency-shaped number from a substring.
    /// Used to pull the total out of "(Total ₹140)".
    private static func extractFirstCurrencyValue(in text: String) -> Double? {
        let pattern = #"[\d,]+(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchedRange = Range(match.range, in: text) else { return nil }
        let raw = String(text[matchedRange]).replacingOccurrences(of: ",", with: "")
        return Double(raw)
    }
}

// MARK: - Items Sheet

/// Bottom-sheet UI for browsing the items in an expense. Shown when
/// the user taps the "items" chip on an expense row, or the "View
/// items" link in AddExpenseView.
///
/// **Why a sheet, not a navigation push**: items are SECONDARY context.
/// The user came to look at expenses; the items breakdown is an aside.
/// A sheet preserves their place in the list and dismisses with a swipe.
///
/// **Why plain values instead of an `Expense` model**: SwiftData
/// `@Model` instances are tied to a `ModelContext` and constructing
/// transient ones (e.g., to preview unsaved form state) can deadlock
/// the main thread under @Query observation pressure. Plain
/// String/Double/Date/Data inputs make the sheet a pure view —
/// nothing observes anything, nothing can hang. The caller pulls the
/// needed values off of whichever Expense/form-state it has.
struct ExpenseItemsSheet: View {
    let merchantName: String?
    let amount: Double
    let date: Date
    let categoryName: String?
    let receiptImageData: Data?
    let items: [ExpenseItem]
    let total: Double?

    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    itemsList
                    if let receiptImageData,
                       let image = UIImage(data: receiptImageData) {
                        receiptThumbnail(image)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    /// Header card with merchant + date + total amount. Reads like the
    /// expense's identity at a glance, so the items below are framed
    /// in the right context.
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let merchantName, !merchantName.isEmpty {
                Text(merchantName)
                    .font(.headline)
            } else {
                Text(categoryName ?? "Expense")
                    .font(.headline)
            }
            HStack(spacing: 8) {
                Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(Currency.format(amount, code: currencyCode))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Items list. Each row: item name on left, price on right. Total
    /// row at the bottom — styled as emphasis so the user can verify
    /// the items sum approximately matches the expense amount.
    private var itemsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    Text(Currency.format(item.price, code: currencyCode))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                if index < items.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
            if let total {
                Divider().padding(.leading, 16)
                HStack {
                    Text("Total")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(Currency.format(total, code: currencyCode))
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Receipt thumbnail. Same treatment as the share-extension preview
    /// — soft shadow, rounded corners, "Tap to view full receipt" hint.
    /// Currently informational only; tapping doesn't open a full viewer
    /// (could be added later).
    private func receiptThumbnail(_ image: UIImage) -> some View {
        VStack(spacing: 6) {
            Text("Receipt")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
    }
}
