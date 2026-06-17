import SwiftUI
import SwiftData

/// Manage categories — list, add, edit, archive, reorder.
///
/// Switched from a custom scroll-of-cards layout to a native List so we
/// get free `.onMove` reordering, `EditButton`, and consistent platform
/// behavior. Two sections — Active (with drag-to-reorder in edit mode)
/// and Archived (with an unarchive button on each row).
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(sort: \Category.sortOrder) private var allCategories: [Category]

    @State private var showingAdd = false
    @State private var editingCategory: Category?
    @State private var editMode: EditMode = .inactive

    private var activeCategories: [Category] {
        allCategories.filter { !$0.isArchived }
    }

    private var archivedCategories: [Category] {
        allCategories.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Active") {
                    ForEach(activeCategories) { cat in
                        Button {
                            Haptics.tap()
                            editingCategory = cat
                        } label: {
                            CategoryListRow(
                                category: cat,
                                currencyCode: currencyCode
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onMove(perform: moveActive)
                }

                if !archivedCategories.isEmpty {
                    Section("Archived") {
                        ForEach(archivedCategories) { cat in
                            HStack {
                                CategoryListRow(
                                    category: cat,
                                    currencyCode: currencyCode
                                )
                                Spacer(minLength: 8)
                                Button {
                                    Haptics.tap()
                                    unarchive(cat)
                                } label: {
                                    Text("Unarchive")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Color.tulaBrandFallback.opacity(0.15),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(Color.tulaBrandFallback)
                                }
                                .buttonStyle(.plain)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Haptics.tap()
                                editingCategory = cat
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.large)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Show Edit toggle only when there's something to reorder.
                        if activeCategories.count > 1 {
                            Button(editMode.isEditing ? "Done" : "Edit") {
                                withAnimation {
                                    editMode = editMode.isEditing ? .inactive : .active
                                }
                            }
                        }
                        Button {
                            Haptics.tap()
                            showingAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                CategoryFormView()
            }
            .sheet(item: $editingCategory) { cat in
                CategoryFormView(category: cat)
            }
        }
    }

    // MARK: - Reorder

    /// Updates the `sortOrder` field of every active category to match the
    /// new on-screen order. Uses 10-step increments so future manual edits
    /// don't immediately need a renumber.
    private func moveActive(from source: IndexSet, to destination: Int) {
        var items = activeCategories
        items.move(fromOffsets: source, toOffset: destination)
        for (index, cat) in items.enumerated() {
            cat.sortOrder = index * 10
        }
        try? context.save()
        Haptics.tap()
    }

    private func unarchive(_ cat: Category) {
        cat.isArchived = false
        try? context.save()
        Haptics.success()
    }
}

// MARK: - Row

/// Single category line in the list. Three pieces of info:
///   • icon in category color
///   • name + total spent (lifetime — most actionable summary)
///   • transaction count (smaller, supporting)
private struct CategoryListRow: View {
    let category: Category
    let currencyCode: String

    private var color: Color { Color(hex: category.colorHex) }

    private var totalSpent: Double {
        category.expenses.reduce(0) { $0 + $1.amount }
    }

    private var countLabel: String {
        let n = category.expenses.count
        return "\(n) \(n == 1 ? "expense" : "expenses")"
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: category.iconKey)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if totalSpent > 0 {
                Text(Currency.format(totalSpent, code: currencyCode))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .opacity(category.isArchived ? 0.6 : 1)
    }
}

// MARK: - Form

struct CategoryFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let existingCategory: Category?

    @State private var name: String
    @State private var iconKey: String
    @State private var colorHex: String

    @State private var showingDeleteConfirm = false

    init(category: Category? = nil) {
        self.existingCategory = category
        if let c = category {
            _name = State(initialValue: c.name)
            _iconKey = State(initialValue: c.iconKey)
            _colorHex = State(initialValue: c.colorHex)
        } else {
            _name = State(initialValue: "")
            _iconKey = State(initialValue: "tag.fill")
            _colorHex = State(initialValue: "#4A90E2")
        }
    }

    private var isEditing: Bool { existingCategory != nil }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canDelete: Bool {
        existingCategory?.expenses.isEmpty ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Subscriptions", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Color") { colorPicker }
                Section("Icon") { iconPicker }

                if isEditing {
                    Section {
                        Button("Archive Category") {
                            archive()
                        }
                        .foregroundStyle(.orange)

                        if canDelete {
                            Button("Delete Category") {
                                showingDeleteConfirm = true
                            }
                            .foregroundStyle(.red)
                        }
                    } footer: {
                        Text(canDelete
                             ? "Archive hides it from pickers; delete removes it entirely."
                             : "This category has expenses — only archive is available.")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Category" : "New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete \(name)?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { delete() }
                Button("Cancel", role: .cancel) { }
            }
        }
    }

    @Query(sort: \Category.sortOrder) private var allCategoriesForColor: [Category]
    @State private var showCustomColorPicker = false
    @State private var customColor: Color = .blue

    private static let palette = [
        "#E03E3E", "#2D9CDB", "#27AE60", "#F2994A", "#9B51E0",
        "#EB5757", "#219653", "#2F80ED", "#F2C94C", "#BB6BD9",
        "#56CCF2", "#6FCF97", "#F78DA7", "#4A90D9", "#D35400",
        "#1ABC9C", "#E74C8B", "#8E44AD", "#3498DB", "#E67E22"
    ]

    private var usedColorHexes: Set<String> {
        let others = allCategoriesForColor
            .filter { $0.id != existingCategory?.id && !$0.isArchived }
            .map { $0.colorHex.uppercased().replacingOccurrences(of: "#", with: "") }
        return Set(others)
    }

    private func isColorUsed(_ hex: String) -> Bool {
        let clean = hex.uppercased().replacingOccurrences(of: "#", with: "")
        return usedColorHexes.contains(clean)
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.md) {
                    ForEach(Self.palette, id: \.self) { hex in
                        let used = isColorUsed(hex)
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 32, height: 32)
                            .opacity(used && colorHex != hex ? 0.35 : 1)
                            .overlay(
                                Circle().stroke(
                                    colorHex == hex ? Color.primary : .clear,
                                    lineWidth: 2
                                )
                                .padding(-3)
                            )
                            .overlay {
                                if used && colorHex != hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .onTapGesture { colorHex = hex }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
            }
            .scrollClipDisabled(false)
            .mask(
                Capsule()
                    .padding(.vertical, -2)
            )
            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { _, newValue in
                    colorHex = newValue.toHex()
                }
        }
    }

    private static let iconSections: [(title: String, icons: [String])] = [
        ("Food & Drink", [
            "fork.knife", "cup.and.saucer", "takeoutbag.and.cup.and.straw",
            "wineglass", "carrot"
        ]),
        ("Home & Utilities", [
            "house", "lightbulb", "drop", "flame",
            "wifi", "tv", "trash", "wrench.and.screwdriver"
        ]),
        ("Transport", [
            "car", "fuelpump", "parkingsign.circle",
            "bus", "tram", "airplane", "bicycle"
        ]),
        ("Shopping", [
            "cart", "bag", "tshirt", "shoe.2", "gift"
        ]),
        ("Health & Wellness", [
            "cross.case", "pills", "heart", "bandage",
            "figure.run", "scissors", "comb"
        ]),
        ("Entertainment", [
            "ticket", "gamecontroller", "music.note",
            "party.popper", "popcorn"
        ]),
        ("Education & Work", [
            "book.closed", "graduationcap", "briefcase",
            "desktopcomputer", "folder"
        ]),
        ("Finance", [
            "banknote", "creditcard", "building.columns",
            "chart.pie", "lock", "arrow.up.right.circle",
            "arrow.down.left.circle", "indianrupeesign.circle"
        ]),
        ("People & Family", [
            "person", "person.2", "figure.2.and.child.holdinghands",
            "pawprint"
        ]),
        ("Other", [
            "calendar", "bell", "tag", "signature",
            "shippingbox", "hands.sparkles", "leaf",
            "questionmark.circle"
        ])
    ]

    private static let categoryIcons: [String] = iconSections.flatMap(\.icons)

    @State private var customIconSearch = ""

    private var iconPicker: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
        let color = Color(hex: colorHex)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.iconSections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(section.icons, id: \.self) { icon in
                            iconCell(icon: icon, color: color)
                        }
                    }
                }
            }

            // Custom SF Symbol search
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Icon")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(spacing: 10) {
                    TextField("SF Symbol name, e.g. globe", text: $customIconSearch)
                        .font(.subheadline)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !customIconSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                        let symbolName = customIconSearch.trimmingCharacters(in: .whitespaces)
                        if UIImage(systemName: symbolName) != nil {
                            Button {
                                Haptics.selection()
                                iconKey = symbolName
                            } label: {
                                iconCell(icon: symbolName, color: color)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func iconCell(icon: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(iconKey == icon ? color : color.opacity(0.12))
                .frame(height: 44)
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(iconKey == icon ? .white : color)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.selection()
            iconKey = icon
        }
    }

    private func save() {
        if let cat = existingCategory {
            cat.name = name
            cat.iconKey = iconKey
            cat.colorHex = colorHex
        } else {
            // Place new categories at the end of the active list.
            let cat = Category(
                name: name,
                iconKey: iconKey,
                colorHex: colorHex,
                sortOrder: nextSortOrder()
            )
            context.insert(cat)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }

    /// Find the next sortOrder slot — append after the highest existing.
    private func nextSortOrder() -> Int {
        let descriptor = FetchDescriptor<Category>(
            sortBy: [SortDescriptor(\.sortOrder, order: .reverse)]
        )
        let last = (try? context.fetch(descriptor))?.first
        return (last?.sortOrder ?? 0) + 10
    }

    private func archive() {
        existingCategory?.isArchived = true
        try? context.save()
        dismiss()
    }

    private func delete() {
        guard let cat = existingCategory else { return }
        context.delete(cat)
        try? context.save()
        dismiss()
    }
}
