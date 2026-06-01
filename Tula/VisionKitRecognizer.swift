import UIKit
import VisionKit

/// VisionKit-based OCR for the main app only. This file is intentionally
/// NOT included in the TulaShare target's build settings.
///
/// **Why**: `import VisionKit` triggers framework loading at process
/// launch. On the share extension that pushes peak memory close to iOS's
/// ~120MB cap, and iOS kills the extension before its UI appears.
/// Symptom: "Extension closes immediately when I share, no UI shown,
/// only on first launch after install."
///
/// **Behavior**: main app's `ReceiptStorage.parse(_:)` calls the
/// top-level function here. The share extension's `parseForExtension(_:)`
/// uses Vision API directly without VisionKit. This means slightly
/// lower OCR accuracy in the share extension (Vision is the older
/// model) — acceptable trade-off vs. the extension not working at all.
///
/// When adding NEW files that use VisionKit, make sure they're ONLY
/// in the Tula target, never in TulaShare. Check the file's Target
/// Membership in Xcode's File Inspector.

/// Run VisionKit's ImageAnalyzer to extract text from an image.
/// Same OCR engine that powers iOS's Live Text feature in the Photos
/// app and Camera viewfinder — noticeably better than `VNRecognizeTextRequest`
/// on photographed paper documents (receipts, hospital bills,
/// restaurant invoices).
///
/// **Trade-offs**: ImageAnalyzer must be created and analyzed on
/// `@MainActor`. The analysis itself runs on a background queue
/// inside VisionKit; only the API call is MainActor-bound.
///
/// **Returns**: array of recognized text LINES (newline-split
/// transcript), or `nil` if VisionKit failed (no Live Text support
/// on device, image too small, internal error). The caller should
/// fall back to `VNRecognizeTextRequest` on nil.
@MainActor
func recognizeTextWithVisionKit(_ image: UIImage) async -> [String]? {
    // ImageAnalyzer is iOS 16+; we're on iOS 18+ so always available.
    // But isSupported can still be false on certain devices/locales —
    // guard against it returning empty results silently.
    guard ImageAnalyzer.isSupported else { return nil }

    let analyzer = ImageAnalyzer()
    let configuration = ImageAnalyzer.Configuration([.text])

    do {
        let analysis = try await analyzer.analyze(image, configuration: configuration)
        let transcript = analysis.transcript
        guard !transcript.isEmpty else { return nil }

        // VisionKit returns the transcript as a single string with
        // newlines preserving the document's visual line breaks.
        // Split it into lines for our existing line-based extractors.
        let lines = transcript
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.isEmpty ? nil : lines
    } catch {
        // VisionKit can throw on bizarre inputs (too-small images,
        // unsupported formats). Return nil so the caller falls back
        // to Vision rather than crashing the pipeline.
        return nil
    }
}
