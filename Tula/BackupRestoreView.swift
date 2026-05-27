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

    @State private var exportData: Data?
    @State private var showingShareSheet = false
    @State private var exportError: String?

    @State private var showingImportPicker = false
    @State private var importedFileURL: URL?
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
            .sheet(isPresented: $showingShareSheet) {
                if let data = exportData {
                    ShareSheetView(data: data)
                }
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
                    importedFileURL = nil
                }
            } message: {
                Text("This will replace all current data with the backup. Type the passphrase used when creating the backup.")
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

            Button {
                runExport()
            } label: {
                HStack {
                    Image(systemName: "arrow.up.doc.fill")
                    Text("Create Encrypted Backup")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(!canExport)

            if let error = exportError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("Pick a passphrase you'll remember. You'll need it to restore.")
        }
    }

    private var canExport: Bool {
        passphrase.count >= 6 && passphrase == confirmPassphrase
    }

    private func runExport() {
        do {
            let data = try BackupManager.exportBackup(from: context, passphrase: passphrase)
            exportData = data
            exportError = nil
            Haptics.success()
            showingShareSheet = true
        } catch {
            exportError = error.localizedDescription
            Haptics.error()
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

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        importedFileURL = url
        restorePassphrase = ""
        restoreError = nil
        showingPassphrasePrompt = true
    }

    private func attemptRestore() {
        guard let url = importedFileURL else { return }
        do {
            let data = try Data(contentsOf: url)
            try BackupManager.importBackup(data, into: context, passphrase: restorePassphrase)
            Haptics.success()
            restoreSuccess = true
        } catch let error as BackupError {
            restoreError = error.errorDescription
            Haptics.error()
        } catch {
            restoreError = error.localizedDescription
            Haptics.error()
        }
        restorePassphrase = ""
    }
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
