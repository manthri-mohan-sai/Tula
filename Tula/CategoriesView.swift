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

    private var colorPicker: some View {
        let palette = [
            "#FF6B6B", "#51CF66", "#339AF0", "#F783AC", "#9775FA",
            "#FFD43B", "#A18072", "#FF8787", "#20C997", "#22B8CF",
            "#CC5DE8", "#D97706", "#7BA68D", "#8B2C3A", "#868E96"
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(palette, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle().stroke(
                                colorHex == hex ? Color.primary : .clear,
                                lineWidth: 2
                            )
                            .padding(-3)
                        )
                        .onTapGesture { colorHex = hex }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var iconPicker: some View {
        let icons = [
            "fork.knife", "cart.fill", "car.fill", "bag.fill", "popcorn.fill",
            "bolt.fill", "house.fill", "cross.case.fill", "book.fill", "airplane",
            "drop.fill", "ellipsis.circle.fill", "gift.fill", "tshirt.fill",
            "fuelpump.fill", "phone.fill", "gamecontroller.fill", "music.note",
            "wrench.and.screwdriver.fill", "stethoscope", "graduationcap.fill",
            "pawprint.fill", "leaf.fill", "tag.fill"
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(icons, id: \.self) { icon in
                    let color = Color(hex: colorHex)
                    ZStack {
                        Circle()
                            .fill(iconKey == icon ? color : color.opacity(0.15))
                            .frame(width: 42, height: 42)
                        Image(systemName: icon)
                            .font(.subheadline)
                            .foregroundStyle(iconKey == icon ? .white : color)
                    }
                    .onTapGesture { iconKey = icon }
                }
            }
            .padding(.vertical, 6)
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
