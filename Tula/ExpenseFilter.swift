import SwiftUI
import SwiftData

// MARK: - Filter Model

/// Composable filter state for the Activity view. Each field is an
/// independent narrowing dimension; they're ANDed in `matches(_:)`.
///
/// Kept as a plain struct (not a SwiftData model) — filter state is purely
/// session-local and doesn't need to persist across launches.
struct ExpenseFilter: Equatable, Hashable {
    var categoryIDs: Set<UUID> = []
    var accountIDs: Set<UUID> = []
    var dateRange: DateRange = .anytime

    static let empty = ExpenseFilter()

    /// True when at least one dimension is narrowing results — used to
    /// decide whether to show the chip bar / pulse the toolbar icon.
    var hasAnyFilter: Bool {
        !categoryIDs.isEmpty || !accountIDs.isEmpty || dateRange != .anytime
    }

    /// Returns true if the expense passes every active filter.
    func matches(_ expense: Expense) -> Bool {
        if !categoryIDs.isEmpty {
            guard let cat = expense.category, categoryIDs.contains(cat.id) else {
                return false
            }
        }
        if !accountIDs.isEmpty {
            guard let acc = expense.account, accountIDs.contains(acc.id) else {
                return false
            }
        }
        if dateRange != .anytime {
            let (start, end) = dateRange.interval()
            guard expense.date >= start && expense.date < end else { return false }
        }
        return true
    }
}

// MARK: - Date Range

/// Preset windows for filtering. We use presets rather than a free-form
/// range picker because expense triage is almost always "recent" — week,
/// month, last month. "Custom" is the escape hatch for the rare arbitrary
/// range needs.
enum DateRange: Equatable, Hashable {
    case anytime
    case thisWeek
    case thisMonth
    case lastMonth
    case last30Days
    case last90Days
    case thisYear
    case custom(start: Date, end: Date)

    var label: String {
        switch self {
        case .anytime:     return "Anytime"
        case .thisWeek:    return "This week"
        case .thisMonth:   return "This month"
        case .lastMonth:   return "Last month"
        case .last30Days:  return "Last 30 days"
        case .last90Days:  return "Last 90 days"
        case .thisYear:    return "This year"
        case .custom(let s, let e):
            let f = DateFormatter()
            f.dateFormat = "d MMM"
            return "\(f.string(from: s)) – \(f.string(from: e))"
        }
    }

    /// Half-open interval `[start, end)` matching the preset, relative to now.
    func interval(now: Date = .now, calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch self {
        case .anytime:
            return (.distantPast, .distantFuture)
        case .thisWeek:
            let i = calendar.dateInterval(of: .weekOfYear, for: now)
                ?? DateInterval(start: now, duration: 0)
            return (i.start, i.end)
        case .thisMonth:
            let i = calendar.dateInterval(of: .month, for: now)
                ?? DateInterval(start: now, duration: 0)
            return (i.start, i.end)
        case .lastMonth:
            guard let prev = calendar.date(byAdding: .month, value: -1, to: now),
                  let i = calendar.dateInterval(of: .month, for: prev) else {
                return (now, now)
            }
            return (i.start, i.end)
        case .last30Days:
            let start = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            return (start, now)
        case .last90Days:
            let start = calendar.date(byAdding: .day, value: -90, to: now) ?? now
            return (start, now)
        case .thisYear:
            let i = calendar.dateInterval(of: .year, for: now)
                ?? DateInterval(start: now, duration: 0)
            return (i.start, i.end)
        case .custom(let s, let e):
            // End is inclusive in the picker; bump by 1 second so the
            // half-open `< end` matches "through end of day".
            let endExclusive = calendar.date(byAdding: .second, value: 1, to: e) ?? e
            return (s, endExclusive)
        }
    }

    /// Presets shown in the sheet. Custom is excluded from this list since
    /// it's accessed via a dedicated "Custom" entry below.
    static let presets: [DateRange] = [
        .anytime, .thisWeek, .thisMonth, .lastMonth,
        .last30Days, .last90Days, .thisYear
    ]
}

// MARK: - Filter Sheet

/// Modal sheet for setting filters. Three sections — categories, accounts,
/// date range. Multi-select via tap chips; date range is single-select.
struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: ExpenseFilter
    let categories: [Category]
    let accounts: [Account]

    /// Draft state — we mutate this freely and only commit on "Apply".
    /// Avoids the chip bar flickering as the user toggles inside the sheet.
    @State private var draft: ExpenseFilter = .empty
    @State private var showingCustomRangePicker = false
    @State private var customStart: Date = .now
    @State private var customEnd: Date = .now

    var body: some View {
        NavigationStack {
            Form {
                categorySection
                accountSection
                dateRangeSection
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        Haptics.tap()
                        draft = .empty
                    }
                    .disabled(!draft.hasAnyFilter)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        Haptics.tap()
                        filter = draft
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                draft = filter
                // Hydrate custom-range pickers if currently set, else default to month range.
                if case .custom(let s, let e) = filter.dateRange {
                    customStart = s
                    customEnd = e
                } else {
                    customStart = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
                    customEnd = .now
                }
            }
            .sheet(isPresented: $showingCustomRangePicker) {
                customRangeSheet
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: - Category Section

    private var categorySection: some View {
        Section("Categories") {
            if categories.isEmpty {
                Text("No categories yet").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { cat in
                            FilterChip(
                                label: cat.name,
                                icon: cat.iconKey,
                                color: Color(hex: cat.colorHex),
                                isSelected: draft.categoryIDs.contains(cat.id)
                            ) {
                                toggle(categoryID: cat.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggle(categoryID: UUID) {
        if draft.categoryIDs.contains(categoryID) {
            draft.categoryIDs.remove(categoryID)
        } else {
            draft.categoryIDs.insert(categoryID)
        }
        Haptics.selection()
    }

    // MARK: - Account Section

    private var accountSection: some View {
        Section("Accounts") {
            if accounts.isEmpty {
                Text("No accounts yet").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(accounts) { acc in
                            FilterChip(
                                label: acc.name,
                                icon: acc.iconKey,
                                color: Color(hex: acc.colorHex),
                                isSelected: draft.accountIDs.contains(acc.id)
                            ) {
                                toggle(accountID: acc.id)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func toggle(accountID: UUID) {
        if draft.accountIDs.contains(accountID) {
            draft.accountIDs.remove(accountID)
        } else {
            draft.accountIDs.insert(accountID)
        }
        Haptics.selection()
    }

    // MARK: - Date Range Section

    private var dateRangeSection: some View {
        Section("Date") {
            ForEach(DateRange.presets, id: \.self) { range in
                Button {
                    Haptics.selection()
                    draft.dateRange = range
                } label: {
                    HStack {
                        Text(range.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        if draft.dateRange == range {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.tulaBrandFallback)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            // Custom range row — opens the date picker sheet
            Button {
                Haptics.tap()
                showingCustomRangePicker = true
            } label: {
                HStack {
                    Text("Custom…")
                        .foregroundStyle(.primary)
                    Spacer()
                    if case .custom = draft.dateRange {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.tulaBrandFallback)
                            .font(.body.weight(.semibold))
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Custom range picker

    private var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customStart, displayedComponents: .date)
                DatePicker("To", selection: $customEnd,
                           in: customStart...,
                           displayedComponents: .date)
            }
            .navigationTitle("Custom Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showingCustomRangePicker = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Set") {
                        let start = Calendar.current.startOfDay(for: customStart)
                        let end = endOfDay(customEnd)
                        draft.dateRange = .custom(start: start, end: end)
                        showingCustomRangePicker = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func endOfDay(_ date: Date) -> Date {
        Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: date) ?? date
    }
}

// MARK: - Filter Chip (in-sheet)

/// Pill-shaped multi-select chip used inside the filter sheet for
/// categories and accounts. Filled tint when selected, hollow otherwise.
private struct FilterChip: View {
    let label: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? color : color.opacity(0.13))
            )
            .overlay(
                Capsule()
                    .strokeBorder(color.opacity(isSelected ? 0 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Active Filter Chip Bar (above the list)

/// Compact horizontal bar above the list summarising active filters with
/// individual remove-buttons on each chip, plus a "Clear all" affordance.
struct ActiveFilterChipBar: View {
    @Binding var filter: ExpenseFilter
    let currencyCode: String

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]

    private var selectedCategories: [Category] {
        allCategories.filter { filter.categoryIDs.contains($0.id) }
    }

    private var selectedAccounts: [Account] {
        allAccounts.filter { filter.accountIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if filter.dateRange != .anytime {
                    chip(
                        label: filter.dateRange.label,
                        icon: "calendar",
                        color: .secondary
                    ) {
                        filter.dateRange = .anytime
                    }
                }

                ForEach(selectedCategories) { cat in
                    chip(
                        label: cat.name,
                        icon: cat.iconKey,
                        color: Color(hex: cat.colorHex)
                    ) {
                        filter.categoryIDs.remove(cat.id)
                    }
                }

                ForEach(selectedAccounts) { acc in
                    chip(
                        label: acc.name,
                        icon: acc.iconKey,
                        color: Color(hex: acc.colorHex)
                    ) {
                        filter.accountIDs.remove(acc.id)
                    }
                }

                // Clear-all — only shown when 2+ chips present
                if filterChipCount >= 2 {
                    Button {
                        Haptics.tap()
                        filter = .empty
                    } label: {
                        Text("Clear all")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var filterChipCount: Int {
        (filter.dateRange != .anytime ? 1 : 0)
            + selectedCategories.count
            + selectedAccounts.count
    }

    private func chip(label: String, icon: String, color: Color,
                      onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Button {
                Haptics.tap()
                withAnimation(.snappy(duration: 0.2)) {
                    onRemove()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.leading, 2)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Opacity bumped 0.13 → 0.18 so the capsule reads as a defined
        // pill rather than a wash of color. Particularly noticeable for
        // .secondary-tinted chips (date range, clear-all) where 0.13
        // was nearly invisible on the system grouped background.
        .background(color.opacity(0.18), in: Capsule())
    }
}
