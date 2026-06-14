import SwiftUI
import SwiftData

/// Gallery view showing all expenses that have receipt images attached.
/// Displays a grid of receipt thumbnails; tapping opens the full receipt
/// in AddExpenseView for viewing/editing.
struct ReceiptGalleryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    private var receipts: [Expense] {
        allExpenses.filter { $0.receiptImageData != nil }
    }

    @State private var editingExpense: Expense?

    private let columns = [
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm),
        GridItem(.flexible(), spacing: Spacing.sm)
    ]

    var body: some View {
        Group {
            if receipts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.sm) {
                        ForEach(receipts) { expense in
                            receiptThumbnail(expense)
                        }
                    }
                    .padding(Spacing.md)
                }
            }
        }
        .navigationTitle("Receipts")
        .navigationBarTitleDisplayMode(.inline)
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
