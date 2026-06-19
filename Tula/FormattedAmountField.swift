import SwiftUI

/// Text field for monetary input — shows empty when value is 0, inserts
/// grouping separators live as the user types, and respects the active
/// currency's locale (Indian grouping for INR, Western for USD/EUR/etc.).
///
/// Ported from Loan Tracker's pattern, generalized to read the currency code
/// rather than hardcoding INR.
struct FormattedAmountField: View {
    @Binding var value: Double
    let currencyCode: String

    /// Optional: visible placeholder shown when the field is empty.
    var placeholder: String = ""

    /// Optional: text style for the field. Defaults to body weight.
    var font: Font = .body
    var alignment: TextAlignment = .trailing

    @State private var text: String = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.decimalPad)
            .font(font)
            .multilineTextAlignment(alignment)
            .accessibilityLabel("Amount")
            .accessibilityValue(value > 0 ? formatted(value) : "empty")
            .onAppear { text = formatted(value) }
            .onChange(of: text) { _, newValue in handleTextChange(newValue) }
            .onChange(of: value) { _, newValue in
                let external = formatted(newValue)
                if external != text { text = external }
            }
            .onChange(of: currencyCode) { _, _ in
                // Currency switched mid-edit — rebuild display with new grouping
                text = formatted(value)
            }
    }

    private func formatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Currency.locale(for: currencyCode)
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 2
        return f
    }

    private func formatted(_ v: Double) -> String {
        v == 0 ? "" : (formatter().string(from: NSNumber(value: v)) ?? "")
    }

    private func handleTextChange(_ input: String) {
        // Strip whatever the locale-aware grouping separator is — it could be
        // a comma (en_US, en_IN) or a space/period in other locales.
        let separator = formatter().groupingSeparator ?? ","
        let cleaned = input.replacingOccurrences(of: separator, with: "")

        guard !cleaned.isEmpty else {
            value = 0
            return
        }
        guard let parsed = Double(cleaned) else { return }
        value = parsed

        if cleaned.contains(".") {
            // Decimal mid-edit: format the whole-number part with grouping,
            // preserve everything after the dot exactly as the user typed it.
            let parts = cleaned.split(separator: ".", maxSplits: 1,
                                      omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let whole = Double(parts[0]) else { return }
            let formattedWhole = formatter().string(from: NSNumber(value: whole)) ?? parts[0]
            let display = "\(formattedWhole).\(parts[1])"
            if display != input { text = display }
        } else {
            let display = formatter().string(from: NSNumber(value: parsed)) ?? cleaned
            if display != input { text = display }
        }
    }
}
