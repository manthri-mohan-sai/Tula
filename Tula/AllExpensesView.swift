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
    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @PrimaryCurrency private var currencyCode

    @State private var searchText: String = ""
    @State private var editingExpense: Expense?
    @State private var isSearchPresented: Bool = false

    // Filter state — kept on this view so it survives the sheet open/close.
    @State private var filter: ExpenseFilter = .empty
    @State private var showingFilterSheet = false

    /// Optional preset filter passed in from another screen (e.g. Stats
    /// → tap "Top Category" deep-links here with that category preselected).
    /// nil means "no preset" — the user starts unfiltered.
    private let presetFilter: ExpenseFilter?

    /// When true, the search bar is focused with the keyboard showing
    /// as soon as the view appears.
    private let startSearchFocused: Bool

    init(presetFilter: ExpenseFilter? = nil, startSearchFocused: Bool = false) {
        self.presetFilter = presetFilter
        self.startSearchFocused = startSearchFocused
        if let preset = presetFilter {
            _filter = State(initialValue: preset)
        }
    }

    // MARK: - Filtering & Grouping

    /// Combined search + filter pipeline. Filter clauses are ANDed; search
    /// is the final fuzzy pass over what filters left behind.
    private var filtered: [Expense] {
        let afterFilters = allExpenses.filter { filter.matches($0) }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return afterFilters }
        return afterFilters.filter { expense in
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
    //
    // No outer NavigationStack — this view is wrapped by its presenter:
    //   • As a sheet from Home: presenter wraps in NavigationStack
    //   • As a pushed destination from Stats: parent's NavigationStack hosts
    // Wrapping ourselves caused nested-stack runtime warnings and a
    // blank "destination" page when navigated to as a push.

    var body: some View {
        VStack(spacing: 0) {
            // Active filter chips — only visible when filters are set.
            // Sits above the list to make it obvious what's narrowing
            // the results and to provide one-tap removal. Bottom gap
            // larger than top so the chips visually attach to the
            // search bar above them, with breathing room before the
            // first day-section header below.
            if filter.hasAnyFilter {
                ActiveFilterChipBar(
                    filter: $filter,
                    currencyCode: currencyCode
                )
                .padding(.horizontal, Spacing.lg)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Group {
                if filtered.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                } else {
                    expensesList
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: filter.hasAnyFilter)
        .background {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.tulaBrandFallback.opacity(0.12), Color.tulaBrandFallback.opacity(0.05), Color.tulaBackground],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 400)
                Color.tulaBackground
            }
            .ignoresSafeArea()
        }
        .navigationTitle("Activity")
        .tulaNavigationSubtitle(subtitleText)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search by merchant, category, amount"
        )
        .onAppear {
            if startSearchFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isSearchPresented = true
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.tap()
                    showingFilterSheet = true
                } label: {
                    // Show the badge when any filter is active so the
                    // entry point reads as "currently filtered".
                    Image(systemName: filter.hasAnyFilter
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .font(.body.weight(.medium))
                }
                .tint(filter.hasAnyFilter ? Color.tulaBrandFallback : .primary)
                .accessibilityLabel("Filters")
            }
            // "Done" only when presented as a sheet (dismiss is meaningful);
            // when pushed, the default back chevron handles return.
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $editingExpense) { expense in
            AddExpenseView(existingExpense: expense)
        }
        .sheet(isPresented: $showingFilterSheet) {
            FilterSheet(
                filter: $filter,
                categories: allCategories.filter { !$0.isArchived },
                accounts: allAccounts.filter { !$0.isArchived }
            )
        }
    }

    /// Whether to render the "Done" toolbar button. True when this view
    /// is the root of its own NavigationStack (sheet presentation); false
    /// when it's pushed onto an existing stack and the back chevron is
    /// already doing the job.
    private var showsDoneButton: Bool {
        presetFilter == nil
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
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
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
        try? context.save(); WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
        Haptics.success()
    }

    private func delete(_ expense: Expense) {
        withAnimation {
            context.delete(expense)
            try? context.save()
        }
        WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
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
