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
        .padding(.vertical, Spacing.md - 2)
        .frame(minHeight: 56)
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

// MARK: - Context Preview

/// Rich preview shown above the iOS context menu when long-pressing an
/// expense row. Larger amount, full merchant/category/account, date —
/// gives confirmation of what action will affect.
struct ExpenseContextPreview: View {
    let expense: Expense
    @PrimaryCurrency private var currencyCode

    private var categoryColor: Color {
        guard let hex = expense.category?.colorHex else { return .gray }
        return Color(hex: hex)
    }

    var body: some View {
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
                    if let merchant = expense.merchant, !merchant.isEmpty {
                        Text(merchant)
                            .font(.headline)
                    } else {
                        Text(expense.category?.name ?? "Uncategorized")
                            .font(.headline)
                    }
                    if let category = expense.category, expense.merchant != nil {
                        Text(category.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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

            if let note = expense.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 320)
    }
}
