import SwiftUI
import SwiftData

/// Gallery view showing all expenses that have receipt images attached.
/// Organized by month with search. Tapping a thumbnail opens the expense
/// in AddExpenseView for viewing/editing.
struct ReceiptGalleryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    @State private var searchText: String = ""
    @State private var editingExpense: Expense?

    private var receipts: [Expense] {
        let withReceipts = allExpenses.filter { $0.receiptImageData != nil }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return withReceipts }
        return withReceipts.filter { expense in
            if let m = expense.merchant?.lowercased(), FuzzyMatcher.searchContains(m, query: trimmed) { return true }
            if let n = expense.note?.lowercased(), FuzzyMatcher.searchContains(n, query: trimmed) { return true }
            if let c = expense.category?.name.lowercased(), FuzzyMatcher.searchContains(c, query: trimmed) { return true }
            return false
        }
    }

    private struct MonthSection: Identifiable {
        let id: Date          // first day of month (stable identity)
        let label: String     // "July 2026"
        let receipts: [Expense]
    }

    private var sections: [MonthSection] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: receipts) { expense in
            cal.dateInterval(of: .month, for: expense.date)?.start ?? expense.date
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { (monthStart, expenses) in
                let label = monthStart.formatted(.dateTime.month(.wide).year())
                return MonthSection(id: monthStart, label: label, receipts: expenses)
            }
    }

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm)
    ]

    var body: some View {
        Group {
            if receipts.isEmpty {
                if searchText.isEmpty {
                    emptyState
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack {
                                    Text(section.label)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(section.receipts.count)")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, Spacing.xs)

                                LazyVGrid(columns: columns, spacing: Spacing.sm) {
                                    ForEach(section.receipts) { expense in
                                        receiptThumbnail(expense)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Spacing.md)
                }
            }
        }
        .navigationTitle("Receipts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search by merchant, note, or category"
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(existingExpense: expense)
        }
    }

    private func receiptThumbnail(_ expense: Expense) -> some View {
        Button {
            editingExpense = expense
        } label: {
            ZStack(alignment: .bottom) {
                if let data = expense.receiptImageData,
                   let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 150)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.tulaCardSurface)
                        .frame(height: 150)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(Currency.format(expense.amount, code: currencyCode))
                        .font(.caption.weight(.bold))
                    Text(expense.merchant ?? expense.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: "photo.on.rectangle")
                    .font(.largeTitle)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            Text("No receipts yet")
                .font(.headline)
            Text("Attach a photo when adding an expense to see it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
        }
    }
}
