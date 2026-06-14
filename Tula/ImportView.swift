import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Multi-step CSV import flow:
/// 1. Pick a file
/// 2. Detect format → if generic, map columns
/// 3. Preview parsed rows
/// 4. Import
/// 5. Show summary
struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var categories: [Category]
    @Query private var accounts: [Account]
    @Query private var existingExpenses: [Expense]

    @State private var step: ImportStep = .pickFile
    @State private var showingFilePicker = true
    @State private var csvContent: String = ""
    @State private var format: ImportManager.CSVFormat = .generic
    @State private var headers: [String] = []
    @State private var mapping = ImportManager.ColumnMapping()
    @State private var parsedRows: [ImportManager.ParsedRow] = []
    @State private var importResult: ImportManager.ImportResult?
    @State private var isImporting = false

    enum ImportStep {
        case pickFile
        case mapColumns
        case preview
        case importing
        case summary
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .pickFile:
                    pickFilePlaceholder
                case .mapColumns:
                    columnMappingView
                case .preview:
                    previewView
                case .importing:
                    importingView
                case .summary:
                    summaryView
                }
            }
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if step == .preview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            performImport()
                        }
                        .fontWeight(.semibold)
                        .disabled(nonDuplicateCount == 0)
                    }
                }
                if step == .mapColumns {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") {
                            parseGenericWithMapping()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
        .onChange(of: showingFilePicker) { _, isPresented in
            if !isPresented && step == .pickFile && csvContent.isEmpty {
                dismiss()
            }
        }
    }

    // MARK: - Non-duplicate count

    private var nonDuplicateCount: Int {
        parsedRows.filter { !$0.isDuplicate }.count
    }

    private var duplicateCount: Int {
        parsedRows.filter { $0.isDuplicate }.count
    }

    // MARK: - Pick File Placeholder

    private var pickFilePlaceholder: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.indigo)
            }
            Text("Select a CSV file")
                .font(.headline)
            Text("Choose a Tula export or any CSV with expense data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)

            Button {
                showingFilePicker = true
            } label: {
                Text("Choose File")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xxl)
                    .padding(.vertical, Spacing.md)
                    .background(Color.indigo, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Column Mapping

    private var columnMappingView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Map your columns")
                        .font(.title3.weight(.bold))
                    Text("Tell us which columns contain which data. Date and Amount are required.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.lg)

                VStack(spacing: Spacing.md) {
                    mappingPicker(label: "Date", icon: "calendar", selection: Binding(
                        get: { mapping.dateCol },
                        set: { mapping.dateCol = $0 }
                    ))
                    mappingPicker(label: "Amount", icon: "number", selection: Binding(
                        get: { mapping.amountCol },
                        set: { mapping.amountCol = $0 }
                    ))
                    optionalMappingPicker(label: "Merchant", icon: "building.2", selection: Binding(
                        get: { mapping.merchantCol },
                        set: { mapping.merchantCol = $0 }
                    ))
                    optionalMappingPicker(label: "Category", icon: "tag", selection: Binding(
                        get: { mapping.categoryCol },
                        set: { mapping.categoryCol = $0 }
                    ))
                    optionalMappingPicker(label: "Account", icon: "creditcard", selection: Binding(
                        get: { mapping.accountCol },
                        set: { mapping.accountCol = $0 }
                    ))
                    optionalMappingPicker(label: "Note", icon: "note.text", selection: Binding(
                        get: { mapping.noteCol },
                        set: { mapping.noteCol = $0 }
                    ))
                }
                .padding(.horizontal, Spacing.lg)
            }
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.xxxl)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func mappingPicker(label: String, icon: String, selection: Binding<Int>) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(width: 100, alignment: .leading)
            Spacer()
            Picker(label, selection: selection) {
                ForEach(headers.indices, id: \.self) { i in
                    Text(headers[i]).tag(i)
                }
            }
            .labelsHidden()
        }
        .padding(Spacing.md)
        .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    private func optionalMappingPicker(label: String, icon: String, selection: Binding<Int?>) -> some View {
        HStack {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(width: 100, alignment: .leading)
            Spacer()
            Picker(label, selection: selection) {
                Text("None").tag(nil as Int?)
                ForEach(headers.indices, id: \.self) { i in
                    Text(headers[i]).tag(i as Int?)
                }
            }
            .labelsHidden()
        }
        .padding(Spacing.md)
        .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
    }

    // MARK: - Preview

    private var previewView: some View {
        VStack(spacing: 0) {
            // Stats bar
            HStack(spacing: Spacing.lg) {
                statPill(
                    count: nonDuplicateCount,
                    label: "to import",
                    color: .green
                )
                if duplicateCount > 0 {
                    statPill(
                        count: duplicateCount,
                        label: "duplicates",
                        color: .orange
                    )
                }
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)

            Divider()

            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(parsedRows) { row in
                        importRowView(row)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func statPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func importRowView(_ row: ImportManager.ParsedRow) -> some View {
        HStack(spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.merchant ?? "Unknown")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let cat = row.categoryName {
                        Text(cat)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.2f", row.amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if row.isDuplicate {
                    Text("Duplicate")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(Spacing.md)
        .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.small, style: .continuous))
        .opacity(row.isDuplicate ? 0.5 : 1.0)
    }

    // MARK: - Importing

    private var importingView: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Importing expenses...")
                .font(.headline)
            Text("\(nonDuplicateCount) expenses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Summary

    private var summaryView: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }

            VStack(spacing: Spacing.xs) {
                Text("Import Complete")
                    .font(.title2.weight(.bold))

                if let result = importResult {
                    VStack(spacing: 4) {
                        Text("\(result.imported) expenses imported")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if result.skipped > 0 {
                            Text("\(result.skipped) duplicates skipped")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if result.errors > 0 {
                            Text("\(result.errors) errors")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.md)
                    .background(Color.tulaBrandFallback, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Spacing.xl)

            Spacer()
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                dismiss()
                return
            }

            guard url.startAccessingSecurityScopedResource() else {
                dismiss()
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                csvContent = try String(contentsOf: url, encoding: .utf8)
            } catch {
                dismiss()
                return
            }

            format = ImportManager.detectFormat(csvContent)

            switch format {
            case .tulaExport:
                parsedRows = ImportManager.parseTulaFormat(csvContent)
                ImportManager.markDuplicates(&parsedRows, existing: existingExpenses)
                step = .preview
            case .generic:
                headers = ImportManager.readHeaders(csvContent)
                if headers.count >= 2 {
                    // Auto-detect common column names
                    autoDetectMapping()
                    step = .mapColumns
                } else {
                    dismiss()
                }
            }

        case .failure:
            dismiss()
        }
    }

    private func autoDetectMapping() {
        let lower = headers.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        for (i, h) in lower.enumerated() {
            if h.contains("date") { mapping.dateCol = i }
            if h.contains("amount") || h.contains("sum") || h.contains("total") { mapping.amountCol = i }
            if h.contains("merchant") || h.contains("payee") || h.contains("description") { mapping.merchantCol = i }
            if h.contains("category") || h.contains("type") { mapping.categoryCol = i }
            if h.contains("account") { mapping.accountCol = i }
            if h.contains("note") || h.contains("memo") || h.contains("comment") { mapping.noteCol = i }
        }
    }

    private func parseGenericWithMapping() {
        parsedRows = ImportManager.parseGeneric(csvContent, mapping: mapping)
        ImportManager.markDuplicates(&parsedRows, existing: existingExpenses)
        step = .preview
    }

    private func performImport() {
        step = .importing
        isImporting = true

        // Run import on next tick to let the UI update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let result = ImportManager.commit(
                rows: parsedRows,
                into: context,
                categories: categories,
                accounts: accounts
            )

            importResult = result
            isImporting = false
            step = .summary
            Haptics.success()
        }
    }
}
