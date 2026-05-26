import SwiftUI

/// Single-line representation of an expense. Used on the home screen's recent
/// activity, account/category detail screens, etc.
struct ExpenseRow: View {
    let expense: Expense
    @PrimaryCurrency private var currencyCode

    private var categoryColor: Color {
        guard let hex = expense.category?.colorHex else { return .gray }
        return Color(hex: hex)
    }

    private var primaryLabel: String {
        if let merchant = expense.merchant, !merchant.isEmpty { return merchant }
        if let category = expense.category { return category.name }
        return "Uncategorized"
    }

    private var needsReview: Bool {
        expense.category == nil
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(categoryColor.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: expense.category?.iconKey ?? "questionmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(categoryColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(primaryLabel)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if needsReview {
                        Text("Review")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                            .fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    if let category = expense.category, expense.merchant != nil {
                        Text(category.name)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if let account = expense.account {
                        Text(account.name)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .padding(.vertical, Spacing.sm)
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

extension Color {
    /// Initialize from a hex string like "#FF6B6B" or "FF6B6B".
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgb), cleaned.count == 6 else {
            self = .gray
            return
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
