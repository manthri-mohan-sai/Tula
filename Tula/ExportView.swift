import SwiftUI
import SwiftData

/// Sheet for exporting expense data. User picks a date range and a
/// format (CSV / PDF), the file is generated, and a system share sheet
/// is presented so they can save it to Files, AirDrop, email, etc.
struct ExportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @Query(sort: \Expense.date, order: .reverse) private var allExpenses: [Expense]

    @State private var selectedRange: ExportRange = .thisMonth
    @State private var selectedFormat: ExportFormat = .csv
    @State private var sharedURL: URL?
    @State private var errorMessage: String?
    @State private var isExporting = false

    /// How many expenses fall into the currently-selected window — useful
    /// to set expectations before tapping Export (and to disable the
    /// button if the result would be empty).
    private var matchCount: Int {
        let window = selectedRange.interval()
        return allExpenses.filter { $0.date >= window.start && $0.date < window.end }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Range") {
                    Picker("Range", selection: $selectedRange) {
                        ForEach(ExportRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Format") {
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    HStack {
                        Text("Expenses to export")
                        Spacer()
                        Text("\(matchCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Button {
                        runExport()
                    } label: {
                        HStack {
                            Spacer()
                            if isExporting {
                                ProgressView().tint(.white)
                            } else {
                                Label("Export & Share", systemImage: "square.and.arrow.up")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        .background(matchCount > 0 ? Color.tulaBrandFallback : .gray)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0 || isExporting)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                } footer: {
                    Text("CSV opens in Excel, Numbers, or any spreadsheet app. PDF is a paginated report you can save or print.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $sharedURL) { url in
                ShareSheet(items: [url])
            }
            .alert("Export failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
    }

    private func runExport() {
        Haptics.tap()
        isExporting = true
        // Run on the main thread — exports are quick and the data is
        // already in memory via @Query. Off-main would force a value
        // copy that isn't worth the complexity here.
        DispatchQueue.main.async {
            defer { isExporting = false }
            do {
                let url = try ExportManager.export(
                    expenses: allExpenses,
                    range: selectedRange,
                    format: selectedFormat,
                    currencyCode: currencyCode
                )
                Haptics.success()
                sharedURL = url
            } catch {
                Haptics.error()
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - URL Identifiable shim
//
// `URL` doesn't conform to `Identifiable` out of the box, so the
// `sheet(item:)` API needs this conformance to use it as a presentation
// trigger. The hash is stable per URL string which is what we want.

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Share Sheet wrapper

/// SwiftUI wrapper around `UIActivityViewController`. Used to present
/// the system share sheet for the generated export file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
