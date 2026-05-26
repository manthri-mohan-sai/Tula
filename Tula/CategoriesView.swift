import SwiftUI
import SwiftData

/// Manage categories — list, add, edit, archive.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Category.sortOrder) private var allCategories: [Category]

    @State private var showingAdd = false
    @State private var editingCategory: Category?

    private var activeCategories: [Category] {
        allCategories.filter { !$0.isArchived }
    }

    private var archivedCategories: [Category] {
        allCategories.filter { $0.isArchived }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    section(title: "Active", categories: activeCategories)
                    if !archivedCategories.isEmpty {
                        section(title: "Archived", categories: archivedCategories)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, Spacing.lg)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
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

    private func section(title: String, categories: [Category]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: title.uppercased())
            Card(padding: 0, cornerRadius: CornerRadius.medium) {
                VStack(spacing: 0) {
                    ForEach(categories) { cat in
                        Button {
                            Haptics.tap()
                            editingCategory = cat
                        } label: {
                            CategoryListRow(category: cat)
                                .padding(.horizontal, Spacing.md)
                        }
                        .buttonStyle(PlainRowButtonStyle())
                        if cat.id != categories.last?.id {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row

private struct CategoryListRow: View {
    let category: Category

    private var color: Color { Color(hex: category.colorHex) }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: category.iconKey)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(category.expenses.count) expense\(category.expenses.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.md)
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
            let cat = Category(
                name: name,
                iconKey: iconKey,
                colorHex: colorHex,
                sortOrder: 100
            )
            context.insert(cat)
        }
        try? context.save()
        Haptics.success()
        dismiss()
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
