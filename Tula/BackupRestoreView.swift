import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Encrypted backup and restore UI. Two flows:
/// 1. Export: user types a passphrase, the database is serialized + AES-GCM
///    encrypted into a .tulabackup file, then surfaced via the share sheet.
/// 2. Restore: user picks a .tulabackup file, types the passphrase, the
///    backup is decrypted and replaces the current database.
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var passphrase: String = ""
    @State private var confirmPassphrase: String = ""

    @State private var isExporting = false
    @State private var includeAttachments = true
    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?

    @State private var isRestoring = false

    @State private var showingImportPicker = false
    /// Raw bytes of the picked backup file. We read these *inside* the
    /// file picker callback while iOS's security-scoped access is
    /// still live — storing just the URL fails on the subsequent
    /// `Data(contentsOf:)` because the scoped access ends with the
    /// callback's defer block, before the user has typed the passphrase.
    @State private var importedFileData: Data?
    /// Original filename for the picked backup — purely for display
    /// in the passphrase prompt so the user knows which file they're
    /// about to restore from.
    @State private var importedFileName: String?
    @State private var showingPassphrasePrompt = false
    @State private var restorePassphrase: String = ""
    @State private var restoreError: String?
    @State private var showingRestoreConfirm = false
    @State private var restoreSuccess: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                exportSection
                importSection

                Section {} footer: {
                    Text("Backups are encrypted with your passphrase using AES-GCM. If you forget the passphrase, the backup is unrecoverable — Tula has no way to read it.")
                }
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(isExporting || isRestoring)
            .overlay {
                if isExporting || isRestoring {
                    ZStack {
                        Color(.systemBackground).opacity(0.6)
                            .ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text(isExporting ? "Creating backup…" : "Restoring…")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .sheet(item: $exportShareItem) { item in
                ShareSheetView(data: item.data)
            }
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Restore Backup", isPresented: $showingPassphrasePrompt) {
                SecureField("Passphrase", text: $restorePassphrase)
                Button("Restore", role: .destructive) { attemptRestore() }
                Button("Cancel", role: .cancel) {
                    restorePassphrase = ""
                    importedFileData = nil
                    importedFileName = nil
                }
            } message: {
                if let name = importedFileName {
                    Text("Restoring from \(name). This will replace all current data. Type the passphrase used when creating the backup.")
                } else {
                    Text("This will replace all current data with the backup. Type the passphrase used when creating the backup.")
                }
            }
            .alert("Backup restored", isPresented: $restoreSuccess) {
                Button("OK") { dismiss() }
            } message: {
                Text("Your data has been restored.")
            }
        }
    }

    // MARK: - Export Section

    private var exportSection: some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                .textContentType(.newPassword)
            SecureField("Confirm passphrase", text: $confirmPassphrase)
                .textContentType(.newPassword)

            // Live validation hint — replaces the silent "button is
            // disabled, why?" puzzle with an explicit reason. Only
            // shown when the user has typed something but the rules
            // aren't satisfied yet.
            if let hint = validationHint {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text(hint)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Toggle(isOn: $includeAttachments) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include receipt photos")
                    Text("Larger file size when enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                runExport()
            } label: {
                HStack {
                    Image(systemName: "arrow.up.doc.fill")
                    Text("Create Encrypted Backup")
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(canExport ? Color.tulaBrandFallback : .secondary)
            }
            .disabled(!canExport || isExporting)

            if let error = exportError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Pick a passphrase of at least 6 characters. You'll need it to restore.")
        }
    }

    private var canExport: Bool {
        passphrase.count >= 6 && passphrase == confirmPassphrase
    }

    /// Why the export button is disabled, or nil when it's ready to go.
    /// We only return a hint once the user has started typing — empty
    /// fields show no hint (they're self-explanatory from the placeholders).
    private var validationHint: String? {
        if passphrase.isEmpty && confirmPassphrase.isEmpty {
            return nil
        }
        if passphrase.count < 6 {
            return "Passphrase needs at least 6 characters."
        }
        if confirmPassphrase.isEmpty {
            return "Confirm your passphrase."
        }
        if passphrase != confirmPassphrase {
            return "Passphrases don't match."
        }
        return nil
    }

    private func runExport() {
        isExporting = true
        Task {
            // Yield so SwiftUI renders the loading overlay before blocking work.
            await Task.yield()
            do {
                let data = try BackupManager.exportBackup(from: context, passphrase: passphrase, includeAttachments: includeAttachments)
                exportError = nil
                Haptics.success()
                exportShareItem = ExportShareItem(data: data)
            } catch {
                exportError = error.localizedDescription
                Haptics.error()
            }
            isExporting = false
        }
    }

    // MARK: - Import Section

    private var importSection: some View {
        Section {
            Button {
                Haptics.tap()
                showingImportPicker = true
            } label: {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                    Text("Restore from Backup")
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(.orange)
            }

            if let error = restoreError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Restore")
        } footer: {
            Text("Restoring will replace all current data. Make a backup of current data first if needed.")
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        // Read the file's bytes IMMEDIATELY while iOS's scoped access
        // is live. Storing just the URL would fail on the later
        // `Data(contentsOf:)` because access ends with this function's
        // defer block — before the user types the passphrase.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        do {
            let bytes = try Data(contentsOf: url)
            importedFileData = bytes
            importedFileName = url.lastPathComponent
            restorePassphrase = ""
            restoreError = nil
            showingPassphrasePrompt = true
        } catch {
            restoreError = "Couldn't read the file: \(error.localizedDescription)"
            Haptics.error()
        }
    }

    private func attemptRestore() {
        guard let data = importedFileData else {
            restoreError = "Backup file is missing — try selecting it again."
            return
        }
        isRestoring = true
        let pw = restorePassphrase
        restorePassphrase = ""
        Task {
            // Yield so SwiftUI renders the loading overlay before blocking work.
            await Task.yield()
            do {
                try BackupManager.importBackup(data, into: context, passphrase: pw)
                Haptics.success()
                restoreSuccess = true
            } catch let error as BackupError {
                restoreError = error.errorDescription
                Haptics.error()
            } catch {
                restoreError = error.localizedDescription
                Haptics.error()
            }
            isRestoring = false
        }
    }
}

// MARK: - Export Share Item

/// Identifiable wrapper so `.sheet(item:)` can tie the share sheet's
/// lifecycle to the data's existence — no race between a Bool flag
/// and the Data arriving.
struct ExportShareItem: Identifiable {
    let id = UUID()
    let data: Data
}

// MARK: - Share Sheet

private struct ShareSheetView: UIViewControllerRepresentable {
    let data: Data

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tula-backup-\(Int(Date.now.timeIntervalSince1970)).tulabackup")
        try? data.write(to: tempURL)
        return UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
