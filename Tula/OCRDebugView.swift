import SwiftUI
import PhotosUI
import PDFKit

/// Debug screen that lets you pick a receipt image, runs the OCR pipeline,
/// and displays the raw extracted text that would be sent to Foundation
/// Models. The "Log" button saves the text as a PDF to the Files app.
struct OCRDebugView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var ocrText: String?
    @State private var documentType: ReceiptStorage.DocumentType?
    @State private var isProcessing = false
    @State private var showingFileSaver = false
    @State private var pdfData: Data?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Image picker area
                if let image = pickedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                } else {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.viewfinder")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("Pick a Receipt Image")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }

                if isProcessing {
                    ProgressView("Running OCR…")
                        .padding()
                }

                // OCR output
                if let text = ocrText {
                    VStack(alignment: .leading, spacing: 8) {
                        if let docType = documentType {
                            HStack {
                                Text("Type:")
                                    .font(.caption.bold())
                                Text(docType.rawValue)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.15), in: Capsule())
                            }
                        }

                        Text("OCR Text → FM")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(text)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.horizontal)
                }

                Spacer()

                // Action buttons
                if ocrText != nil {
                    Button {
                        savePDF()
                    } label: {
                        Label("Log", systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
            }
            .navigationTitle("OCR Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if pickedImage != nil {
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                        }
                    }
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pickedImage = image
                        await runOCR(on: image)
                    }
                }
            }
            .sheet(isPresented: $showingFileSaver) {
                if let pdfData {
                    DocumentExportView(data: pdfData, filename: "OCR_Log_\(dateStamp()).pdf")
                }
            }
        }
    }

    // MARK: - OCR

    private func runOCR(on image: UIImage) async {
        isProcessing = true
        defer { isProcessing = false }

        let result = await ReceiptStorage.parse(image)
        ocrText = result.rawText
        documentType = result.documentType
    }

    // MARK: - PDF Export

    private func savePDF() {
        guard let text = ocrText else { return }

        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let margin: CGFloat = 40
        let textRect = pageRect.insetBy(dx: margin, dy: margin)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4

            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .paragraphStyle: paragraphStyle,
                .foregroundColor: UIColor.black
            ]

            let attrString = NSAttributedString(string: text, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attrString)
            var currentIndex = 0
            let totalLength = attrString.length

            while currentIndex < totalLength {
                context.beginPage()

                let path = CGPath(rect: textRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRangeMake(currentIndex, 0),
                    path,
                    nil
                )

                let ctx = context.cgContext
                ctx.textMatrix = .identity
                ctx.translateBy(x: 0, y: pageRect.height)
                ctx.scaleBy(x: 1, y: -1)

                CTFrameDraw(frame, ctx)

                let visibleRange = CTFrameGetVisibleStringRange(frame)
                currentIndex += visibleRange.length

                if visibleRange.length == 0 { break } // safety
            }
        }

        self.pdfData = data
        showingFileSaver = true
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - Document Export (saves to Files app)

/// Wraps UIDocumentPickerViewController to let the user save a file
/// to the Files app (iCloud Drive, On My iPhone, etc.).
struct DocumentExportView: UIViewControllerRepresentable {
    let data: Data
    let filename: String

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Write to a temp file so UIDocumentPicker can export it.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? data.write(to: tempURL)

        let picker = UIDocumentPickerViewController(forExporting: [tempURL])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // File saved successfully — nothing else to do.
        }
    }
}
