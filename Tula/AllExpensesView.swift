import SwiftUI
import SwiftData

/// Full list of every expense, grouped by day. Uses native `.insetGrouped`
/// list style with `.swipeActions` — the Loan Tracker pattern. iOS handles
/// the row clipping, swipe animation, and corner radius natively, so swipes
/// never break the card shape.
///
/// Search matches across merchant, note, category, account, and amount.
/// Opened from Home → "See all".
struct AllExpensesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]
    @PrimaryCurrency private var currencyCode

    @State private var searchText: String = ""
    @State private var editingExpense: Expense?

    // MARK: - Filtering & Grouping

    private var filtered: [Expense] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return allExpenses }
        return allExpenses.filter { expense in
            if let m = expense.merchant?.lowercased(), m.contains(trimmed) { return true }
            if let n = expense.note?.lowercased(), n.contains(trimmed) { return true }
            if let c = expense.category?.name.lowercased(), c.contains(trimmed) { return true }
            if let a = expense.account?.name.lowercased(), a.contains(trimmed) { return true }
            if let queryAmount = Double(trimmed), abs(expense.amount - queryAmount) < 0.01 {
                return true
            }
            return false
        }
    }

    private struct DaySection: Identifiable {
        let id: Date
        let label: String
        let expenses: [Expense]
        let total: Double
    }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let groupedByDay = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groupedByDay.keys.sorted(by: >).map { day in
            let dayExpenses = groupedByDay[day] ?? []
            let label: String
            if cal.isDateInToday(day) {
                label = "Today"
            } else if cal.isDateInYesterday(day) {
                label = "Yesterday"
            } else {
                label = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            }
            return DaySection(
                id: day,
                label: label,
                expenses: dayExpenses,
                total: dayExpenses.reduce(0) { $0 + $1.amount }
            )
        }
    }

    private var grandTotal: Double {
        filtered.reduce(0) { $0 + $1.amount }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    expensesList
                }
            }
            .navigationTitle("Activity")
            .navigationSubtitle(subtitleText)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by merchant, category, amount"
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
    }

    /// Subtitle showing transaction count + grand total.
    private var subtitleText: String {
        guard !filtered.isEmpty else { return "" }
        let unit = filtered.count == 1 ? "transaction" : "transactions"
        return "\(filtered.count) \(unit) · \(Currency.format(grandTotal, code: currencyCode))"
    }

    // MARK: - List

    /// Native iOS grouped list. Each day becomes a Section with a header
    /// showing the day label + the day's total. Rows have proper swipe
    /// actions that respect the section's rounded corners.
    private var expensesList: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.expenses) { expense in
                        Button {
                            Haptics.tap()
                            editingExpense = expense
                        } label: {
                            ExpenseRow(expense: expense)
                        }
                        .buttonStyle(.plain)
                        // Let the row control its own height. We add 2pt
                        // top/bottom for subtle breathing room between
                        // tiles — fully tight read as a dense table, this
                        // gives just enough air to feel like individual
                        // items without making the list feel sparse.
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete(expense)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editingExpense = expense
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button { editingExpense = expense } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button { duplicate(expense) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            Divider()
                            Button(role: .destructive) { delete(expense) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } preview: {
                            ExpenseContextPreview(expense: expense)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Spacer()
                        Text(Currency.format(section.total, code: currencyCode))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Actions

    private func duplicate(_ expense: Expense) {
        let copy = Expense(
            amount: expense.amount,
            date: .now,
            merchant: expense.merchant,
            note: expense.note,
            source: .manual,
            category: expense.category,
            account: expense.account
        )
        context.insert(copy)
        try? context.save()
        Haptics.success()
    }

    private func delete(_ expense: Expense) {
        context.delete(expense)
        try? context.save()
        Haptics.warning()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tulaBrandFallback.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(Color.tulaBrandFallback)
            }
            VStack(spacing: 4) {
                Text(searchText.isEmpty ? "Nothing here yet" : "No matches")
                    .font(.subheadline.weight(.semibold))
                Text(searchText.isEmpty
                     ? "Logged expenses will appear here"
                     : "Try a different merchant, category, or amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}
