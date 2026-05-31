import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Receipt-photo helpers for Tula. Two responsibilities, kept in one file
/// because they're always used together:
///
///   1. **Compression**: Take a `UIImage` from the camera/photo picker and
///      produce a ~200KB JPEG `Data` blob suitable for storage on the
///      Expense model. Keeps the SwiftData store sane while preserving
///      enough resolution that the receipt is readable on retrieval.
///
///   2. **OCR parsing**: Run Apple Vision's text recognition on a receipt
///      image and extract two best-effort fields — `amount` (the total)
///      and `merchant` (the business name). Returns a `ReceiptParseResult`
///      with nil fields where extraction wasn't confident. The caller
///      pre-fills the AddExpenseView form and the user confirms.
///
/// **Why best-effort, not auto-save**: Indian receipts vary wildly in
/// format. Auto-saving a wrong amount silently corrupts the user's
/// records. Pre-filling with a visible "AI-extracted" badge lets the user
/// verify with one glance, fix with one tap, and save deliberately.
enum ReceiptStorage {

    /// Maximum dimension (in pixels) for the stored receipt image. 1600px
    /// is comfortably readable when zoomed on retrieval but small enough
    /// that JPEG compression at 0.7 quality lands around 150-300KB.
    private static let maxDimension: CGFloat = 1600

    /// JPEG compression quality. 0.7 is the sweet spot for receipts:
    /// text stays sharp, color noise minimal, file size modest.
    private static let jpegQuality: CGFloat = 0.7

    /// Compress a UIImage to a storage-ready JPEG blob. Returns nil if
    /// the image fails to encode (rare — only happens with corrupt or
    /// zero-sized images).
    ///
    /// **Pipeline**: downscale by aspect ratio → JPEG encode at quality 0.7.
    /// On a typical 12MP camera photo (4032×3024 ≈ 6MB raw), this
    /// produces a ~200KB JPEG at 1600×1200.
    static func compress(_ image: UIImage) -> Data? {
        let scaled = downscale(image, to: maxDimension)
        return scaled.jpegData(compressionQuality: jpegQuality)
    }

    /// Scale an image so its larger dimension equals `maxDim`. Preserves
    /// aspect ratio. If the image is already smaller, returns it unchanged
    /// (no upscaling — that just bloats the file without adding info).
    private static func downscale(_ image: UIImage, to maxDim: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDim else { return image }

        let scale = maxDim / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        // UIGraphicsImageRenderer is the modern, color-correct path.
        // `scale: 1` keeps the bitmap from being multiplied by device
        // scale factor — receipts don't need @3x density.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - OCR Parsing

    /// Coarse classification of what kind of document this OCR text
    /// represents. Drives extractor dispatch: each type has a slightly
    /// different layout and extraction strategy. `.generic` is the
    /// fallback for anything we can't confidently classify.
    ///
    /// **Why this matters**: a UPI confirmation screenshot, a Swiggy
    /// order summary, and a printed restaurant bill all contain
    /// "amounts" and "merchant-like text" but the SPATIAL LAYOUT and
    /// KEYWORDS are very different. Treating them all as "receipts"
    /// produces mediocre extraction on all three. Per-type parsers
    /// tuned to each layout produce significantly better results.
    enum DocumentType: String, Sendable {
        /// UPI payment confirmation screenshot (PhonePe, GPay, Paytm,
        /// bank apps). Format: amount near top, merchant + transaction
        /// ID below, payment status banner. Very consistent across apps.
        case upi
        /// Food / grocery delivery order summary (Swiggy, Zomato, Blinkit,
        /// Zepto, Instamart). Format: brand header, item list, total at
        /// bottom, restaurant/store name often mid-page.
        case orderSummary
        /// Printed restaurant / kirana bill. Format: merchant + bill
        /// number at top, table/order info, line items with prices,
        /// subtotal + grand total at bottom.
        case restaurantBill
        /// Hospital / clinic / diagnostics bill. Format: patient header,
        /// service line items, multiple tax/discount sections, "Net
        /// Payable" or "Final Amount" at bottom. Often complex.
        case hospitalBill
        /// Utility bill (electricity, water, gas, broadband). Format:
        /// consumer details, billing period, units consumed, "Amount
        /// Due" with a due date prominent.
        case utilityBill
        /// Anything we couldn't confidently classify — generic receipt
        /// path. Uses the general-purpose extractors with no
        /// layout-specific tuning.
        case generic
    }

    /// Result of an OCR scan. All fields except `rawText` are optional —
    /// Vision's confidence on a given receipt may be insufficient. The
    /// caller pre-fills what's present and leaves the rest blank for the
    /// user to type.
    struct ParseResult {
        let amount: Double?
        let merchant: String?
        /// Structured item list extracted from the receipt body. Each
        /// entry is `(item name, price)`. Used to build a human-readable
        /// note like "Masala Dosa ₹80, Idli ₹40, Tax ₹20 → Total ₹140".
        /// Empty when no line items could be extracted.
        let items: [(name: String, price: Double)]
        /// Transaction date if present on the receipt. Nil when no date
        /// could be parsed — caller falls back to "now" (today). When
        /// present, this is preferred because the user may be
        /// photographing a receipt from earlier in the day or week.
        let date: Date?
        /// The full OCR'd text, joined by newlines. Useful for the
        /// caller to surface in a "review extracted text" debug view, or
        /// to feed into Foundation Models for a second pass later.
        let rawText: String
        /// What type of document we classified this as. Exposed so
        /// callers can show contextual UI ("UPI Payment" vs "Receipt")
        /// and so the smart parser can use it as a prompt hint.
        let documentType: DocumentType

        /// Render a structured note from the items + amount. Returns nil
        /// when there's nothing meaningful to render (no items). Format:
        /// "Masala Dosa ₹80 · Idli ₹40 · Sambar ₹20 (Total ₹140)"
        /// The total in parentheses serves as a quick sanity-check vs
        /// the extracted amount field — if they disagree, the user can
        /// see which to trust.
        func formattedNote(currencyCode: String) -> String? {
            guard !items.isEmpty else { return nil }
            // Long lists get truncated to keep the note readable.
            // Matches the formatter logic in AddExpenseView and
            // ShareSession — single source of truth would be nicer
            // but keeping each formatter self-contained avoids
            // import gymnastics in the share extension.
            let maxInline = 5
            let parts = items.map { "\($0.name) \(Currency.format($0.price, code: currencyCode))" }
            let itemStr: String
            if parts.count > maxInline {
                let visible = parts.prefix(maxInline).joined(separator: " · ")
                let remaining = parts.count - maxInline
                itemStr = "\(visible) · and \(remaining) more item\(remaining == 1 ? "" : "s")"
            } else {
                itemStr = parts.joined(separator: " · ")
            }
            if let total = amount {
                return "\(itemStr) (Total \(Currency.format(total, code: currencyCode)))"
            }
            return itemStr
        }
    }

    /// Preprocess a receipt photo to improve Vision OCR accuracy. Runs a
    /// CoreImage filter chain that addresses the most common causes of
    /// poor recognition on real-world receipts: thermal-paper fade, low
    /// contrast in dim lighting, slight motion blur, and yellow/pink
    /// backgrounds that confuse text-vs-paper detection.
    ///
    /// **Pipeline**:
    ///   1. Grayscale conversion — removes color noise; receipt text is
    ///      always black/dark, color is irrelevant to recognition.
    ///   2. Contrast boost — pushes faded thermal text toward black.
    ///   3. Brightness lift — lightens the paper background away from
    ///      the text, widening the contrast gap.
    ///   4. Light sharpening — undoes minor camera focus blur. Heavy
    ///      sharpening introduces artifacts that hurt OCR, so we use
    ///      a conservative `sharpness` value.
    ///
    /// **When to skip**: if the original image is already high-quality
    /// (good contrast, sharp, well-lit) preprocessing can over-correct
    /// and make OCR *worse*. We estimate quality from the image's
    /// brightness histogram — well-balanced images skip preprocessing,
    /// dim/washed-out ones get the full treatment.
    ///
    /// **Cost**: ~50-150ms on a typical receipt photo. Acceptable
    /// because it gates Vision OCR (which is the expensive step).
    /// Returns the original image if any filter fails — never crashes
    /// the OCR flow.
    private static func preprocessImage(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        // Estimate average brightness via CIAreaAverage. Result is a
        // 1x1 image whose pixel encodes the average RGBA of the input.
        // Low average → dim photo → preprocess. High average → already
        // well-lit → skip to avoid over-correcting.
        let averageBrightness: CGFloat = {
            let filter = CIFilter.areaAverage()
            filter.inputImage = ciImage
            filter.extent = ciImage.extent
            guard let output = filter.outputImage else { return 0.5 }
            var bitmap = [UInt8](repeating: 0, count: 4)
            let context = CIContext()
            context.render(output,
                           toBitmap: &bitmap,
                           rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: nil)
            // Use the luminance channel approximation: 0.299*R + 0.587*G + 0.114*B
            let r = CGFloat(bitmap[0]) / 255.0
            let g = CGFloat(bitmap[1]) / 255.0
            let b = CGFloat(bitmap[2]) / 255.0
            return 0.299 * r + 0.587 * g + 0.114 * b
        }()

        // Filter chain — each stage takes the previous output as input.
        // Built using the strongly-typed CIFilter.* builders (iOS 13+).
        var current: CIImage = ciImage

        // 1. ALWAYS grayscale — color information is never useful for
        //    receipt text recognition. Removing it eliminates color noise
        //    (tinted thermal paper, colored ink, background patterns) and
        //    gives Vision a cleaner signal regardless of lighting.
        let desaturate = CIFilter.colorControls()
        desaturate.inputImage = current
        desaturate.saturation = 0
        desaturate.brightness = 0
        desaturate.contrast = 1.0
        if let out = desaturate.outputImage { current = out }

        // For well-lit images (0.6-0.82), stop after grayscale —
        // contrast and sharpening would over-correct. The narrower
        // band (was 0.55-0.85) ensures more borderline images get
        // the full treatment.
        if averageBrightness > 0.6 && averageBrightness < 0.82 {
            let context = CIContext()
            guard let cgOut = context.createCGImage(current, from: current.extent) else {
                return image
            }
            return UIImage(cgImage: cgOut, scale: image.scale, orientation: image.imageOrientation)
        }

        // 2. Boost contrast — pushes faded thermal text darker.
        //    Value 1.4 is empirically good; >2.0 starts clipping.
        let contrast = CIFilter.colorControls()
        contrast.inputImage = current
        contrast.saturation = 0
        // Lift dim images more aggressively than bright ones.
        let brightnessBoost: Float = averageBrightness < 0.5 ? 0.1 : 0.05
        contrast.brightness = brightnessBoost
        contrast.contrast = 1.4
        if let out = contrast.outputImage { current = out }

        // 3. Light sharpening to recover focus-blur losses. CIUnsharpMask
        //    is gentler than CISharpenLuminance for text.
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = current
        sharpen.radius = 1.5
        sharpen.intensity = 0.3
        if let out = sharpen.outputImage { current = out }

        // Render back to UIImage. Use a fresh context (cheap to allocate)
        // and render at the original image's scale so pixel dimensions
        // match the input (Vision uses absolute pixel size).
        let context = CIContext()
        guard let cgOutput = context.createCGImage(current, from: current.extent) else {
            return image
        }
        return UIImage(cgImage: cgOutput, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Run Vision OCR on the given image and best-effort extract amount
    /// and merchant. Async because Vision text recognition is a
    /// nontrivial workload (~200-500ms on a typical receipt photo).
    ///
    /// Failures (image too small, Vision request errors, no text found)
    /// return a `ParseResult` with all fields nil and `rawText` empty —
    /// the caller treats this as "no signal, user fills the form
    /// manually." Never throws to the caller; failure is silent.
    static func parse(_ image: UIImage) async -> ParseResult {
        // Run a quick first-pass OCR to detect if this is a digital
        // screenshot (UPI, order summary). Digital images have perfect
        // contrast and sharpness — preprocessing would over-correct them.
        // We classify first on a fast OCR pass, then decide whether to
        // preprocess for the accurate pass.
        let rawCGImage = image.cgImage
        let quickType = await quickClassify(image: image)
        let isDigitalScreenshot = quickType == .upi || quickType == .orderSummary

        // Preprocess before the accurate OCR pass — boosts accuracy on
        // dim/faded physical receipts while skipping digital screenshots.
        let prepared = isDigitalScreenshot ? image : preprocessImage(image)
        guard let cgImage = prepared.cgImage ?? rawCGImage else {
            return ParseResult(amount: nil, merchant: nil, items: [], date: nil, rawText: "", documentType: .generic)
        }

        // Capture observations off the main actor — Vision callbacks may
        // arrive on any queue, so we collect into a local array and then
        // hand the results back via the continuation.
        let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let results = request.results as? [VNRecognizedTextObservation] ?? []
                continuation.resume(returning: results)
            }
            // `.accurate` is slower than `.fast` (~2x) but markedly better
            // on small/noisy text — typical for thermal-printed receipts.
            request.recognitionLevel = .accurate
            // Language correction ON for English-only receipts — fixes
            // common OCR errors where thermal-print characters are
            // misread ('l' for '1', 'O' for '0' in word context).
            // We keep it OFF only for numeric-heavy fields handled by
            // our own regex extractors which don't need word correction.
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-IN", "en-US"]
            // Minimum text height filter — ignore text smaller than 1.5%
            // of the image height. Tiny text is usually footer fine-print,
            // barcode digits, or thermal-noise artefacts that pollute
            // extraction without contributing useful information.
            request.minimumTextHeight = 0.015

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }

        // Filter by recognition confidence. Low-confidence candidates are
        // where most OCR noise originates — garbled characters from
        // thermal-print artefacts, shadows, paper creases, and partial
        // text at image edges. Threshold 0.25 drops obvious garbage while
        // keeping faded but legible text (which typically scores 0.3-0.6).
        let lines = observations
            .compactMap { obs -> String? in
                guard let candidate = obs.topCandidates(1).first,
                      candidate.confidence >= 0.25 else { return nil }
                return candidate.string
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Clean noise lines before classification and FM parsing.
        // OCR of barcodes, QR code fragments, and thermal-print artefacts
        // produces lines that are overwhelmingly non-alphanumeric (e.g.
        // "||||||||||||", "---***---", "https://...?token=ABCDEF123").
        // These pollute the FM prompt and can cause hallucinated amounts
        // from barcode digit sequences. We filter them out while keeping
        // lines that are mostly alphanumeric text.
        let cleanedLines = lines.filter { line in
            let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Minimum content: at least 3 non-whitespace characters.
            // Single/double chars are stray marks, not useful text.
            guard stripped.count >= 3 else { return false }

            // Repeated-character lines: "========", "--------", "********"
            // These are decorative separators that add no extraction value.
            let uniqueChars = Set(stripped)
            if uniqueChars.count <= 2 { return false }

            // At least 50% of NON-WHITESPACE characters must be letters
            // or digits. Previous threshold was 45% and incorrectly
            // counted whitespace, letting garbage like "| | | | |" pass.
            let nonWhitespace = stripped.filter { !$0.isWhitespace }
            guard nonWhitespace.count > 0 else { return false }
            let alphanumericCount = nonWhitespace.filter { $0.isLetter || $0.isNumber }.count
            return Double(alphanumericCount) / Double(nonWhitespace.count) >= 0.50
        }

        // De-duplicate consecutive identical lines. Vision sometimes
        // returns overlapping bounding boxes that produce the same text
        // twice — this confuses FM into doubling amounts and creates
        // false "item" entries in the regex extractor.
        let dedupedLines: [String] = {
            var result: [String] = []
            for line in cleanedLines {
                let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if normalized == result.last?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    continue
                }
                result.append(line)
            }
            return result
        }()

        // rawText uses cleaned + de-duped lines so FM gets focused
        // signal, not barcode noise or repeated observations.
        // Full lines array is still used by regex extractors which have
        // their own pattern matching and aren't fooled by noise lines.
        let rawText = dedupedLines.joined(separator: "\n")

        // Classify the document first. The class determines which set
        // of extractors we use — UPI screenshots, food delivery order
        // summaries, restaurant bills, and generic receipts each have
        // a different layout that the per-type extractors handle better
        // than the one-size-fits-all approach.
        let documentType = classifyDocument(from: lines)

        let amount: Double?
        let merchant: String?
        let date: Date?
        let items: [(name: String, price: Double)]

        switch documentType {
        case .upi:
            // UPI confirmations: amount is usually the only big number,
            // merchant is "Paid to" / "To" label's value, no line items.
            amount = extractUPIAmount(from: lines)
            merchant = extractUPIMerchant(from: lines)
            date = extractDate(from: lines)
            items = []
        case .orderSummary:
            // Order summaries (Swiggy/Zomato): total is at the bottom
            // labeled "Bill total" or "Total Paid", restaurant name
            // is mid-page after "from" or near an "Order from" header.
            amount = extractOrderSummaryAmount(from: lines)
            merchant = extractOrderSummaryMerchant(from: lines)
            date = extractDate(from: lines)
            items = extractLineItems(from: lines, total: amount)
        case .hospitalBill:
            // Hospital bills: "Net Payable" / "Amount Payable" / "Final
            // Amount" near the bottom. Merchant is the hospital name in
            // the top header (usually first line). Items are services
            // / procedures / medicines listed with prices.
            amount = extractHospitalAmount(from: lines)
            merchant = extractMerchant(from: lines, observations: observations)
            date = extractDate(from: lines)
            items = extractLineItems(from: lines, total: amount)
        case .utilityBill:
            // Utility bills: "Amount Due" / "Total Payable" with a due
            // date. Merchant is the utility provider name (top header).
            // No line items in the typical sense — bill has one total.
            amount = extractUtilityAmount(from: lines)
            merchant = extractMerchant(from: lines, observations: observations)
            date = extractDate(from: lines)
            items = []
        case .restaurantBill, .generic:
            // Standard path — what we had before. Restaurant bills and
            // generic unclassified documents both work fine with the
            // general-purpose extractors.
            amount = extractAmount(from: lines)
            merchant = extractMerchant(from: lines, observations: observations)
            date = extractDate(from: lines)
            items = extractLineItems(from: lines, total: amount)
        }

        return ParseResult(
            amount: amount,
            merchant: merchant,
            items: items,
            date: date,
            rawText: rawText,
            documentType: documentType
        )
    }

    // MARK: - Document Classification
    //
    // Decide what KIND of document this OCR text represents. The
    // classifier looks at distinctive keywords and structural hints
    // — it's deliberately conservative, falling through to `.generic`
    // when the signal isn't strong. False positives (mis-routing) are
    // worse than false negatives (handling as generic) because the
    // per-type extractors are tuned to specific layouts.

    /// UPI-app keyword set. Lines containing any of these strongly
    /// suggest a UPI confirmation screenshot. Single-word matches
    /// like "upi" alone aren't sufficient — restaurant bills sometimes
    /// say "Payment: UPI" too. We require co-occurrence of multiple
    /// hints (see `classifyDocument`).
    private static let upiKeywords: Set<String> = [
        "upi ref", "upi transaction", "transaction id", "transaction reference",
        "paid successfully", "payment successful", "paid to", "money transferred",
        "rrn", "utr no", "utr reference",
        "phonepe", "google pay", "gpay", "paytm", "bhim",
        "@oksbi", "@okhdfcbank", "@okicici", "@okaxis", "@paytm", "@ybl", "@axl"
    ]

    /// Food / grocery delivery keyword set. Co-occurrence of these
    /// with line-item-like content classifies as `.orderSummary`.
    private static let orderSummaryKeywords: Set<String> = [
        "swiggy", "zomato", "blinkit", "zepto", "instamart", "dunzo",
        "bigbasket", "country delight", "licious",
        "order id", "order #", "order placed", "order confirmation",
        "delivery address", "delivery partner", "delivered to",
        "bill total", "total paid", "to pay", "item total"
    ]

    /// Restaurant-bill markers — printed at the top of most table
    /// service / cafe / kirana bills.
    private static let restaurantKeywords: Set<String> = [
        "bill no", "table no", "table :", "floor :",
        "cash bill", "tax invoice", "kot no", "captain", "steward",
        "service charge", "cgst", "sgst"
    ]

    /// Hospital / clinic / diagnostics bill markers.
    private static let hospitalKeywords: Set<String> = [
        "patient name", "patient id", "mrd no", "mrd number",
        "diagnosis", "consultation", "consultant", "discharge",
        "admission", "ward", "bed no", "ipd", "opd",
        "procedure", "lab test", "investigation",
        "net payable", "amount payable", "final amount",
        "advance paid", "balance due"
    ]

    /// Utility bill markers — electricity, water, gas, broadband.
    private static let utilityKeywords: Set<String> = [
        "consumer no", "consumer number", "account no", "service no",
        "units consumed", "kwh", "billing period", "billing month",
        "due date", "previous reading", "current reading",
        "electricity", "water board", "gas connection",
        "broadband", "fiber", "internet plan", "mobile recharge",
        "amount due", "total payable"
    ]

    /// Classify the OCR'd document into one of four buckets. Algorithm:
    /// score each candidate type by how many of its keywords appear in
    /// the text; pick the highest-scoring type if it crosses a confidence
    /// threshold. Ties / low scores fall back to `.generic`.
    ///
    /// Quick first-pass classify to decide whether preprocessing is needed.
    /// Uses Vision's `.fast` recognition level — lower accuracy but ~3× faster.
    /// Only used to distinguish digital screenshots (UPI/order summary) from
    /// physical receipts so we can skip unnecessary image preprocessing.
    private static func quickClassify(image: UIImage) async -> DocumentType {
        guard let cgImage = image.cgImage else { return .generic }
        let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                continuation.resume(returning: (req.results as? [VNRecognizedTextObservation]) ?? [])
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return classifyDocument(from: lines)
    }

    /// **Why score-based instead of single-keyword?** Each individual
    /// keyword is noisy (a restaurant might mention "UPI" once; a UPI
    /// screen might mention a merchant that's also a restaurant chain).
    /// Requiring multiple hits reduces false positives.
    private static func classifyDocument(from lines: [String]) -> DocumentType {
        let combinedText = lines.joined(separator: " ").lowercased()

        let upiScore = upiKeywords.filter { combinedText.contains($0) }.count
        let orderScore = orderSummaryKeywords.filter { combinedText.contains($0) }.count
        let restaurantScore = restaurantKeywords.filter { combinedText.contains($0) }.count
        let hospitalScore = hospitalKeywords.filter { combinedText.contains($0) }.count
        let utilityScore = utilityKeywords.filter { combinedText.contains($0) }.count

        // Confidence threshold: need at least 2 keyword hits to commit
        // to a type. Lone hits are too easily produced by coincidence.
        let threshold = 2

        // Pick the type with the highest score over threshold. Priority
        // when tied: hospital > utility > upi > orderSummary > restaurant.
        // Hospital and utility bills have the most distinct vocabularies
        // so they should win when their keywords appear; restaurant
        // keywords are common enough to lose ties.
        let scores: [(DocumentType, Int)] = [
            (.hospitalBill, hospitalScore),
            (.utilityBill, utilityScore),
            (.upi, upiScore),
            (.orderSummary, orderScore),
            (.restaurantBill, restaurantScore)
        ]
        let top = scores.max { $0.1 < $1.1 }
        guard let (type, score) = top, score >= threshold else {
            return .generic
        }
        return type
    }

    // MARK: - UPI Extractors
    //
    // UPI confirmation screens have a remarkably consistent layout
    // across PhonePe, GPay, Paytm, and bank apps:
    //   - "₹AMOUNT" near the top in large text (the paid amount)
    //   - "Paid to MERCHANT NAME" right below
    //   - Transaction ID / UTR / Ref later
    //   - "Payment Successful" or similar banner
    //
    // Extractors here are tighter than the generic ones — they trust
    // the layout instead of scanning the entire image.

    /// Pull the payment amount from a UPI confirmation. The amount in
    /// UPI screens is almost always the FIRST currency-shaped number
    /// in the text, displayed prominently at the top. We take the first
    /// plausible currency value we encounter rather than the largest
    /// (which would risk picking up account-balance footers).
    private static func extractUPIAmount(from lines: [String]) -> Double? {
        // Priority 1: a line that's just "₹AMOUNT" or has a label like
        // "Amount", "Paid", "Amount Paid".
        let amountLabels = ["amount paid", "amount", "you paid", "paid", "transferred"]
        for line in lines {
            let lower = line.lowercased()
            if amountLabels.contains(where: { lower.contains($0) }),
               let value = currencyValue(in: line) {
                return value
            }
        }

        // Priority 2: first standalone currency value. UPI screens
        // display the amount at the top, so the first match is usually
        // the right one. Skip lines that are clearly footers (balance,
        // available, history, etc).
        let footerMarkers = ["balance", "available", "history", "limit", "remaining"]
        for line in lines {
            let lower = line.lowercased()
            if footerMarkers.contains(where: { lower.contains($0) }) { continue }
            if let value = currencyValue(in: line) {
                return value
            }
        }
        return nil
    }

    /// Pull the merchant name from a UPI confirmation. Look for the
    /// "Paid to" / "To" label and grab the value next to or below it.
    /// Falls back to scanning for a line that looks like a name (not a
    /// transaction ID, not a date) appearing right after the amount.
    private static func extractUPIMerchant(from lines: [String]) -> String? {
        let merchantLabels = ["paid to", "to:", "to ", "transferred to", "sent to"]
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard merchantLabels.contains(where: { lower.contains($0) }) else { continue }

            // Try the same line first — "Paid to MERCHANT NAME"
            for label in merchantLabels {
                if let range = lower.range(of: label) {
                    let after = String(line[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !after.isEmpty, looksLikeMerchantName(after) {
                        return titleCased(after)
                    }
                }
            }

            // Fall back to the next line (label on one line, value below).
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeMerchantName(next) {
                    return titleCased(next)
                }
            }
        }
        return nil
    }

    // MARK: - Order Summary Extractors
    //
    // Swiggy / Zomato / Blinkit order summaries have a consistent
    // pattern: brand header at very top, "Order from MERCHANT" or
    // similar, then item list, then a clearly labeled grand total
    // ("Bill Total", "Total Paid", "Amount Charged") at the bottom.

    /// Bill-total label set for order summaries. These labels are
    /// VERY specific to delivery apps — they reliably mark the final
    /// charge including delivery fees and platform fees.
    private static let orderTotalKeywords = [
        "bill total", "total paid", "amount paid", "total amount",
        "amount charged", "you paid", "order total"
    ]

    /// Pull the total from an order summary. Strategy: scan for one
    /// of the order-summary-specific total keywords (which are highly
    /// reliable), take its associated value. Fall back to the generic
    /// largest-total heuristic if no specific keyword found.
    private static func extractOrderSummaryAmount(from lines: [String]) -> Double? {
        for (index, line) in lines.enumerated() {
            guard !isPaymentMethodLine(line) else { continue }
            let lower = line.lowercased()
            guard orderTotalKeywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = currencyValue(in: line) { return amount }
            // Peek both directions — same as generic extractor.
            if index > 0, !isPaymentMethodLine(lines[index - 1]),
               let amount = currencyValue(in: lines[index - 1]) {
                return amount
            }
            if index + 1 < lines.count, !isPaymentMethodLine(lines[index + 1]),
               let amount = currencyValue(in: lines[index + 1]) {
                return amount
            }
        }
        // Fall back to the generic extractor.
        return extractAmount(from: lines)
    }

    /// Pull the restaurant / store name from an order summary. Look for
    /// "Order from X" / "from X" labels first. Fall back to the line
    /// right after the brand header (Swiggy/Zomato) when no label found.
    private static func extractOrderSummaryMerchant(from lines: [String]) -> String? {
        let merchantLabels = ["order from", "from ", "ordered from"]
        for (index, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard merchantLabels.contains(where: { lower.contains($0) }) else { continue }

            // Same line — "Order from RESTAURANT"
            for label in merchantLabels {
                if let range = lower.range(of: label) {
                    let after = String(line[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !after.isEmpty, looksLikeMerchantName(after) {
                        return titleCased(after)
                    }
                }
            }

            // Next line
            if index + 1 < lines.count {
                let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeMerchantName(next) {
                    return titleCased(next)
                }
            }
        }

        // Last resort: skip the brand header (Swiggy/Zomato/etc) at the
        // top and find the first merchant-looking line below it.
        let brandSet: Set<String> = ["swiggy", "zomato", "blinkit", "zepto", "instamart", "dunzo"]
        for line in lines.dropFirst(3) {  // skip first 3 lines (brand headers)
            let lower = line.lowercased()
            if brandSet.contains(where: { lower.contains($0) }) { continue }
            if looksLikeMerchantName(line) {
                return titleCased(line)
            }
        }
        return nil
    }

    // MARK: - Hospital Bill Extractors
    //
    // Hospital / clinic bills are dense with sub-totals: consultation
    // charges, lab work, pharmacy, room charges, taxes, discounts,
    // advance paid, and finally "Net Payable". The grand total is
    // ALMOST ALWAYS in the bottom 30% of the document with a clear
    // label. We anchor on that label, falling back to the generic
    // largest-wins approach if labels are missing.

    /// Hospital-specific final-total labels. These are very strong
    /// signals — when one appears in a hospital bill it IS the amount.
    private static let hospitalTotalKeywords = [
        "net payable", "amount payable", "final amount",
        "net amount payable", "total payable", "amount due",
        "balance due", "balance payable"
    ]

    /// Pull the final payable amount from a hospital bill. Strategy:
    /// scan in REVERSE order (from bottom of document up) so we hit
    /// the bottommost total first — hospitals print the final amount
    /// last after listing all components. Look for hospital-specific
    /// labels with look-back + look-forward like the generic extractor.
    private static func extractHospitalAmount(from lines: [String]) -> Double? {
        // Reverse iteration — the final payable is the LAST matching
        // total, never an earlier sub-total.
        for (revIdx, line) in lines.reversed().enumerated() {
            let realIdx = lines.count - 1 - revIdx
            guard !isPaymentMethodLine(line) else { continue }
            let lower = line.lowercased()
            guard hospitalTotalKeywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = currencyValue(in: line) { return amount }
            if realIdx > 0,
               !isPaymentMethodLine(lines[realIdx - 1]),
               let amount = currencyValue(in: lines[realIdx - 1]) {
                return amount
            }
            if realIdx + 1 < lines.count,
               !isPaymentMethodLine(lines[realIdx + 1]),
               let amount = currencyValue(in: lines[realIdx + 1]) {
                return amount
            }
        }
        // Fall back to the generic extractor.
        return extractAmount(from: lines)
    }

    // MARK: - Utility Bill Extractors
    //
    // Utility bills are well-structured but vary across providers
    // (electricity boards, water boards, telcos). The amount is almost
    // always labeled "Amount Due", "Total Payable", "Amount to Pay",
    // accompanied by a due date.

    private static let utilityTotalKeywords = [
        "amount due", "total payable", "amount payable",
        "total amount due", "bill amount", "amount to pay",
        "net amount", "current bill amount"
    ]

    /// Pull the payable amount from a utility bill. Utility totals are
    /// straightforward — single explicit label, single value. We scan
    /// forward (top-down) since the amount is often in the upper-middle
    /// of the bill near "Due Date".
    private static func extractUtilityAmount(from lines: [String]) -> Double? {
        for (idx, line) in lines.enumerated() {
            guard !isPaymentMethodLine(line) else { continue }
            let lower = line.lowercased()
            guard utilityTotalKeywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = currencyValue(in: line) { return amount }
            if idx > 0, !isPaymentMethodLine(lines[idx - 1]),
               let amount = currencyValue(in: lines[idx - 1]) {
                return amount
            }
            if idx + 1 < lines.count, !isPaymentMethodLine(lines[idx + 1]),
               let amount = currencyValue(in: lines[idx + 1]) {
                return amount
            }
        }
        return extractAmount(from: lines)
    }

    // MARK: - Amount extraction
    //
    // **Strategy**: scan for "final total" markers first (unambiguous —
    // "grand total", "bill amount", "payable"), then fall back to plain
    // "total" markers (which can match line items), then to the largest
    // plausible currency number on the receipt.
    //
    // **Key insight**: when "total" appears multiple times on a receipt
    // (often the case — "Item 1 Total ₹40", "Item 2 Total ₹100", "Grand
    // Total ₹140"), we MUST take the largest matched value, not the
    // first. Line-item totals are smaller than the grand total they
    // sum to, so largest-wins gives the correct result without needing
    // perfect keyword recognition. This was a real bug — the parser
    // returned ₹40 (a line-item total) instead of ₹140 (the receipt
    // total) because the loop returned on first keyword hit.

    /// Final-total markers — unambiguous, never apply to line items.
    /// Checked first; if any of these match, we trust that value.
    /// Expanded set covers hospital bills, utility bills, fancy
    /// restaurant POS output, and Indian English variations.
    private static let finalTotalKeywords = [
        "grand total", "gr total", "net amount", "net total",
        "net payable", "net amount payable",
        "bill amount", "amount payable", "amt payable", "to pay",
        "total payable", "final amount", "round off total",
        "amount due", "total due", "balance due", "balance payable",
        "you pay", "you paid", "amount paid",
        "final total", "final payable",
        "invoice total", "billed amount"
    ]

    /// Ambiguous total markers — "total" appears next to line items
    /// AND next to the grand total. We collect ALL matches then take
    /// the largest, on the principle that grand total > line items.
    private static let ambiguousTotalKeywords = [
        "total", "amount", "subtotal", "sub total"
    ]

    /// Payment-method markers — lines like "Cash 280" / "Tendered 200" /
    /// "Change 60". These are NOT bill totals;
    /// confusing them with totals doubles the amount (the bill plus the
    /// cash tendered ≠ the actual bill). We aggressively exclude any
    /// line containing these keywords from amount extraction.
    ///
    /// **Note**: "paid" and "credit" are intentionally EXCLUDED from this
    /// list because they appear in legitimate total labels: "Amount Paid",
    /// "Total Paid", "You Paid", "Credit Card". Those lines carry the
    /// actual total. The `finalTotalKeywords` list takes priority (it
    /// includes "amount paid", "you paid", etc.) so we won't miss them.
    ///
    /// Real bug encountered: a receipt with "Total 140 / Cash 280 /
    /// Change 140" was parsed as ₹280 because cash > bill > change.
    private static let paymentMethodKeywords = [
        "cash", "tendered", "tender", "received",
        "change", "balance due", "return", "card payment",
        "wallet"
    ]

    /// True when the line is a payment-method/cash-flow line that should
    /// be ignored when scanning for the bill's grand total. Used as a
    /// filter in extractAmount and extractLineItems.
    private static func isPaymentMethodLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return paymentMethodKeywords.contains(where: { lower.contains($0) })
    }

    private static func extractAmount(from lines: [String]) -> Double? {
        // Phase 1: unambiguous final-total markers. First match wins
        // because these markers are specific enough that they only
        // appear next to the grand total.
        //
        // **Look back AND forward**: column-layout receipts often print
        // the value above the label (visual layout: number on one line,
        // label "Grand Total:" on the next). Vision's reading order
        // sometimes splits them across multiple text observations. We
        // check the same line first, then the line BEFORE (most common
        // for this layout), then the line AFTER.
        for (index, line) in lines.enumerated() {
            guard !isPaymentMethodLine(line) else { continue }
            let lower = line.lowercased()
            guard finalTotalKeywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = currencyValue(in: line) { return amount }
            // Peek backward — fixes column receipts where the value
            // visually sits above its label.
            if index > 0,
               !isPaymentMethodLine(lines[index - 1]),
               let amount = currencyValue(in: lines[index - 1]) {
                return amount
            }
            // Peek forward — fixes receipts where label is on its own
            // line and the value sits below.
            if index + 1 < lines.count,
               !isPaymentMethodLine(lines[index + 1]),
               let amount = currencyValue(in: lines[index + 1]) {
                return amount
            }
            // **Digit recovery pass**: OCR sometimes mis-reads digits as
            // visually similar letters (1→I/l/|, 0→O, 5→S, 8→B). When
            // we matched a final-total KEYWORD but couldn't find a
            // number nearby, retry the SAME lines with substitutions
            // applied. Costs nothing on receipts where OCR is clean
            // (the original pass already returned). Recovers real-world
            // cases like "I40.00" (140 misread) or "5O.OO" (50.00).
            let candidates: [String] = {
                var out = [line]
                if index > 0, !isPaymentMethodLine(lines[index - 1]) {
                    out.append(lines[index - 1])
                }
                if index + 1 < lines.count, !isPaymentMethodLine(lines[index + 1]) {
                    out.append(lines[index + 1])
                }
                return out
            }()
            for candidate in candidates {
                if let amount = currencyValue(in: applyOCRDigitRecovery(candidate)) {
                    return amount
                }
            }
        }

        // Phase 2: ambiguous markers ("total"). Collect ALL matches —
        // EXCLUDING payment-method lines — then pick the best candidate.
        // Same look-back/look-forward applies here too.
        //
        // **Selection upgrade**: instead of always picking the largest,
        // we cross-check each candidate against the sum of plausible
        // line-item values. The "right" total is the one whose value
        // approximately equals the items sum (within 10% to allow for
        // tax). When no candidate matches the sum well, fall back to
        // largest-wins (the previous behavior).
        var totalMarkedAmounts: [Double] = []
        for (index, line) in lines.enumerated() {
            guard !isPaymentMethodLine(line) else { continue }
            let lower = line.lowercased()
            guard ambiguousTotalKeywords.contains(where: { lower.contains($0) }) else { continue }
            if let amount = currencyValue(in: line) {
                totalMarkedAmounts.append(amount)
            }
            if index > 0,
               !isPaymentMethodLine(lines[index - 1]),
               let amount = currencyValue(in: lines[index - 1]) {
                totalMarkedAmounts.append(amount)
            }
            if index + 1 < lines.count,
               !isPaymentMethodLine(lines[index + 1]),
               let amount = currencyValue(in: lines[index + 1]) {
                totalMarkedAmounts.append(amount)
            }
        }

        if !totalMarkedAmounts.isEmpty {
            // Sum cross-validation: compute the sum of all "small" line
            // amounts (those that look like item prices, not totals).
            // The right total should approximately equal this sum.
            let itemSum = estimateItemSum(from: lines, excluding: totalMarkedAmounts)
            if itemSum > 0 {
                // Pick the candidate closest to itemSum within a 10%
                // tax-tolerance band on either side (some bills have
                // GST added, some don't). If multiple candidates fall
                // in the band, prefer the LARGER one (most likely the
                // tax-inclusive grand total).
                let withinBand = totalMarkedAmounts.filter { value in
                    let ratio = value / itemSum
                    return ratio >= 0.95 && ratio <= 1.25  // 0% tax to ~25% tax
                }
                if let match = withinBand.max() {
                    return match
                }
            }
            // No item sum signal or no candidate matched. Fall back
            // to largest-wins — the previous behavior.
            if let largest = totalMarkedAmounts.max() {
                return largest
            }
        }

        // Phase 3: no keyword match at all. Take the largest plausible-
        // amount number on the receipt, excluding payment lines AND
        // lines that contain noise identifiers (bill numbers, order
        // IDs, phone numbers, GSTIN, etc.). These lines carry numbers
        // that aren't monetary values.
        let noiseLabels = [
            "bill no", "invoice no", "inv no", "order no", "order id",
            "order #", "gstin", "gst no", "gst in", "fssai", "tin no",
            "phone", "mobile", "tel", "contact", "pin code", "pincode",
            "table no", "kot no", "token", "receipt no", "ref no",
            "transaction id", "txn id", "utr", "rrn"
        ]
        let allAmounts = lines
            .filter { line in
                let lower = line.lowercased()
                if isPaymentMethodLine(line) { return false }
                if noiseLabels.contains(where: { lower.contains($0) }) { return false }
                return true
            }
            .compactMap { currencyValue(in: $0) }
        return allAmounts.max()
    }

    /// Estimate the sum of probable line items in the receipt. Used by
    /// the amount-extraction Phase 2 to cross-validate candidate totals
    /// against actual item prices. The "right" total is the one whose
    /// value approximately equals the sum of items.
    ///
    /// **Heuristic for what counts as an item**:
    /// - Lines containing a currency value
    /// - NOT payment-method lines (cash, change, etc.)
    /// - NOT total-marker lines (subtotal, grand total, etc.)
    /// - Currency value < ₹50,000 (filters out outlier values that are
    ///   clearly totals, not items)
    /// - The currency value isn't in the `excluding` set (so we don't
    ///   sum the candidate totals themselves into the validation)
    ///
    /// Returns 0 when no items could be identified — caller falls back
    /// to largest-wins. Approximate by design; precision isn't required
    /// because we only use it for ratio comparison with a 25% tolerance.
    private static func estimateItemSum(from lines: [String],
                                         excluding totalCandidates: [Double]) -> Double {
        let totalMarkerKeywords = ambiguousTotalKeywords + finalTotalKeywords
        var sum: Double = 0
        var count: Int = 0
        for line in lines {
            let lower = line.lowercased()
            // Skip payment-method lines and total-marker lines.
            if isPaymentMethodLine(line) { continue }
            if totalMarkerKeywords.contains(where: { lower.contains($0) }) { continue }
            guard let value = currencyValue(in: line) else { continue }
            // Skip outliers (clearly totals, not items).
            if value > 50_000 { continue }
            // Skip values that match a total candidate within ₹1.
            if totalCandidates.contains(where: { abs($0 - value) < 1 }) { continue }
            sum += value
            count += 1
        }
        // Require at least 2 items for a meaningful sum — a single
        // matched line might just be a sub-total, not a real item list.
        return count >= 2 ? sum : 0
    }

    /// Apply common OCR mis-read substitutions to recover digit values.
    /// Used only as a secondary pass when keyword extraction matched a
    /// label but no number was found on adjacent lines — assumes that
    /// the matched lines DID contain the amount, OCR just garbled it.
    ///
    /// **Substitutions applied** (all uppercase letters → digits):
    ///   I, l, | → 1   (vertical strokes commonly confused with one)
    ///   O       → 0   (round letter commonly confused with zero)
    ///   S       → 5   (curved similar shapes; happens on thermal print)
    ///   B       → 8   (closed-loop similar shapes; rarer)
    ///
    /// **Why limited to specific positions**: blindly substituting these
    /// letters across all text would mangle real merchant names ("ICICI"
    /// would become "1C1C1"). We only apply when we ALREADY found a
    /// total-marker keyword on the line, so any nearby characters are
    /// extremely likely to be the amount, not a name.
    ///
    /// **Returns** the transformed line. Caller pipes through
    /// `currencyValue` which then sees normal-looking digits.
    private static func applyOCRDigitRecovery(_ line: String) -> String {
        // Only apply in regions that look numeric. We detect "numeric
        // regions" as runs of characters that are at least 40% digits
        // already — clean text stays untouched, garbled amounts get fixed.
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        let transformed: [String] = words.map { word in
            let str = String(word)
            // Count digits in the word. If the word has at least one
            // digit AND the digit-to-letter ratio is high, treat it as
            // a candidate for substitution. Pure-letter words (merchant
            // names, labels) stay untouched.
            let digitCount = str.filter { $0.isNumber }.count
            let letterCount = str.filter { $0.isLetter }.count
            guard digitCount > 0, digitCount + letterCount > 0 else { return str }
            // Substitute only when the word is at least 40% digits —
            // empirically catches "I40", "5O.OO", "I,250" while leaving
            // alphabetic content alone.
            let ratio = Double(digitCount) / Double(digitCount + letterCount)
            guard ratio >= 0.4 else { return str }
            var out = ""
            out.reserveCapacity(str.count)
            for ch in str {
                switch ch {
                case "I", "l", "|": out.append("1")
                case "O": out.append("0")
                case "S": out.append("5")
                case "B": out.append("8")
                default:  out.append(ch)
                }
            }
            return out
        }
        return transformed.joined(separator: " ")
    }

    /// Extract a single currency value from a line of text. Returns the
    /// largest plausible match if there are multiple numbers on one line.
    private static func currencyValue(in line: String) -> Double? {
        // Regex: optional ₹ or Rs prefix, digits (with optional commas
        // for Indian lakh formatting like 1,00,000), optional .NN decimal.
        // We allow whitespace around the prefix because OCR often
        // mis-spaces these tokens.
        let pattern = #"(?:₹|rs\.?|inr)?\s*(\d{1,3}(?:,\d{2,3})*(?:\.\d{1,2})?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))

        var candidates: [Double] = []
        for match in matches where match.numberOfRanges > 1 {
            let valueRange = match.range(at: 1)
            let raw = nsLine.substring(with: valueRange)
                .replacingOccurrences(of: ",", with: "")
            guard let value = Double(raw) else { continue }

            // **Letter-prefixed rejection**: if the character immediately
            // before this number is a letter, the number is part of an
            // identifier (order ID "OR926", invoice "INV2024", etc.), not
            // a currency value. Real receipts put currency values either
            // at the start of a line or preceded by whitespace / a
            // currency symbol — never glued to letters.
            //
            // Real bug: "Orders : (OR921, OR926)" captured 926 as a
            // candidate and Phase 3 picked it as the receipt total.
            if valueRange.location > 0 {
                let priorRange = NSRange(location: valueRange.location - 1, length: 1)
                let prior = nsLine.substring(with: priorRange)
                if prior.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
                    continue
                }
            }

            // Filter implausible amounts: phone numbers (10+ digits),
            // postal codes (6 digits exact), year-like values (1900-2100).
            if value < 1 || value > 1_000_000 { continue }
            if (1900...2100).contains(Int(value)) && raw.count == 4 { continue }
            candidates.append(value)
        }
        return candidates.max()
    }

    // MARK: - Date extraction
    //
    // **Strategy**: receipts typically print a transaction date in one of
    // a few common formats. We try ISO-like first (most unambiguous),
    // then DD/MM/YYYY which is the Indian default, then verbose formats
    // like "15-Mar-2025" and "March 15, 2025".
    //
    // **DD/MM/YYYY assumption**: this is critical. Indian receipts use
    // DD/MM/YYYY, not MM/DD/YYYY. Without forcing this, a parser sees
    // "03/04/2025" and can't tell March 4 from April 3. We force DD/MM
    // because we know the user is in India (currencyCode defaults to
    // INR, locale typically en-IN).
    //
    // We also clamp parsed dates to the last 5 years to filter out
    // wildly-wrong matches (e.g. "GSTIN 27ABCDE2024" being misread as
    // a date in 2024).

    /// Pull a transaction date from the OCR lines. Returns nil if no
    /// recognizable date is present. Tries common Indian receipt formats.
    private static func extractDate(from lines: [String]) -> Date? {
        let now = Date.now
        let calendar = Calendar.current
        // Sanity-check window: only accept dates between 5 years ago
        // and tomorrow. Anything outside this is almost certainly a
        // misread (GSTIN, ID number, year reference).
        let lowerBound = calendar.date(byAdding: .year, value: -5, to: now) ?? .distantPast
        let upperBound = calendar.date(byAdding: .day, value: 1, to: now) ?? .distantFuture

        // Format patterns in order of preference. Each tuple is
        // (regex pattern, date format string for parsing).
        // Order matters — most specific first.
        let formats: [(String, String)] = [
            // ISO: 2025-03-15
            (#"(\d{4}-\d{2}-\d{2})"#, "yyyy-MM-dd"),
            // DD/MM/YYYY: 15/03/2025 — Indian default
            (#"(\d{2}/\d{2}/\d{4})"#, "dd/MM/yyyy"),
            // DD-MM-YYYY: 15-03-2025
            (#"(\d{2}-\d{2}-\d{4})"#, "dd-MM-yyyy"),
            // DD/MM/YY: 15/03/25 — short year
            (#"(\d{2}/\d{2}/\d{2})"#, "dd/MM/yy"),
            // DD-Mon-YYYY: 15-Mar-2025
            (#"(\d{2}-[A-Za-z]{3}-\d{4})"#, "dd-MMM-yyyy"),
            // DD Mon YYYY: 15 Mar 2025
            (#"(\d{2}\s+[A-Za-z]{3}\s+\d{4})"#, "dd MMM yyyy"),
            // Mon DD, YYYY: Mar 15, 2025
            (#"([A-Za-z]{3}\s+\d{1,2},?\s+\d{4})"#, "MMM d, yyyy")
        ]

        for line in lines {
            for (pattern, format) in formats {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                guard let match = regex.firstMatch(in: line, options: [], range: range),
                      match.numberOfRanges > 1 else { continue }

                let raw = nsLine.substring(with: match.range(at: 1))
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_IN")
                formatter.dateFormat = format
                guard let parsed = formatter.date(from: raw) else { continue }

                // Reject implausible dates (future > tomorrow, or > 5 years old)
                guard parsed >= lowerBound, parsed <= upperBound else { continue }
                return parsed
            }
        }
        return nil
    }


    // MARK: - Line item extraction
    //
    // **Strategy**: a "line item" is a line that contains BOTH alphabetic
    // text (the item name) AND a numeric value (the price). We extract
    // both, then filter to keep only entries that look like real items:
    //
    //   - Item name has at least 2 letters (rejects ID numbers like "B12")
    //   - Price is less than the receipt total (a line item can't exceed
    //     the grand total it sums to — useful sanity check)
    //   - Item name doesn't contain noise words (GSTIN, Phone, etc.)

    private static func extractLineItems(from lines: [String], total: Double?) -> [(name: String, price: Double)] {
        var items: [(name: String, price: Double)] = []

        for line in lines {
            // Skip lines that contain final-total keywords — those are
            // summary lines, not line items. Without this, "Grand Total ₹140"
            // would get parsed as an item named "Grand Total".
            let lower = line.lowercased()
            if finalTotalKeywords.contains(where: { lower.contains($0) }) { continue }
            if ambiguousTotalKeywords.contains(where: { lower.contains($0) }) { continue }

            guard let price = currencyValue(in: line) else { continue }
            // Skip line where the price would exceed the receipt total —
            // can't be a line item. Defensive against OCR noise.
            if let total, price > total { continue }

            let name = extractItemName(from: line)
            guard !name.isEmpty else { continue }

            items.append((name: name, price: price))
        }

        return Array(items.prefix(20))
    }

    /// Extract the human-readable item name from a line by stripping
    /// numeric tokens, currency symbols, and noise. Title-cases the
    /// result so SCREAMING CAPS receipts render readably.
    private static func extractItemName(from line: String) -> String {
        var working = line
        for marker in ["₹", "Rs.", "Rs", "INR", "rs"] {
            working = working.replacingOccurrences(of: marker, with: "")
        }
        working = working.unicodeScalars
            .filter { !CharacterSet.decimalDigits.contains($0) && $0 != "." && $0 != "," }
            .reduce(into: "") { $0.append(Character($1)) }

        let normalized = working
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalized.filter(\.isLetter).count >= 2 else { return "" }

        let lower = normalized.lowercased()
        let noiseMarkers = [
            "gstin", "gst", "cgst", "sgst", "igst", "fssai", "tax",
            "round off", "cash", "card", "change", "tender", "discount"
        ]
        if noiseMarkers.contains(where: { lower.contains($0) }) { return "" }

        return normalized.capitalized
    }

    // MARK: - Merchant extraction
    //
    // Strategy: receipts almost always print the merchant name at the top,
    // in a larger font than body text. We use Vision's observation
    // bounding boxes to find the topmost lines (highest Y in image
    // coordinates → lowest in normalized coords because Vision flips Y),
    // and pick the first line that looks like a name (multiple words,
    // letter-dominant, not a phone/address line).

    private static func extractMerchant(
        from lines: [String],
        observations: [VNRecognizedTextObservation]
    ) -> String? {
        // Sort observations by Y position (top of image first). Vision's
        // boundingBox uses normalized coordinates with origin at bottom-
        // left, so "top of image" = highest Y value.
        let sortedByPosition = observations
            .filter { $0.topCandidates(1).first?.string.isEmpty == false }
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .prefix(6)  // Look at top 6 lines max — merchant is always near top

        for obs in sortedByPosition {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if looksLikeMerchantName(text) {
                return titleCased(text)
            }
        }
        return nil
    }

    /// Heuristic: does this line look like a merchant name? Filters:
    /// - Has at least one alpha character (rejects pure numeric lines)
    /// - Doesn't start with a digit (rejects "Bill #12345", phone numbers)
    /// - Isn't predominantly digits (rejects "GSTIN: 27ABCDE1234F1Z5")
    /// - Doesn't match known address/contact patterns
    /// - Has at least 2 characters of meaningful content
    /// - **Has at least 2 words** (rejects laptop keyboard text like
    ///   "return" / "command" / "option" / "shift" that Vision picks up
    ///   when the receipt is photographed on a laptop). Single-word
    ///   "merchants" are extremely rare on real bills — they're almost
    ///   always context noise.
    private static func looksLikeMerchantName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return false }
        guard trimmed.contains(where: \.isLetter) else { return false }
        guard let first = trimmed.first, !first.isNumber else { return false }

        // Reject lines that are mostly digits (>60% digit characters).
        let digitCount = trimmed.filter(\.isNumber).count
        if Double(digitCount) / Double(trimmed.count) > 0.6 { return false }

        // Reject known noise patterns.
        let lower = trimmed.lowercased()
        let noiseMarkers = [
            "gstin", "gst no", "tin no", "fssai", "pan no", "cin no",
            "address", "phone", "mobile", "tel:", "www.", "http",
            "@", "invoice", "receipt no", "bill no", "date:", "time:",
            "cash bill", "cash memo", "tax invoice"
        ]
        if noiseMarkers.contains(where: { lower.contains($0) }) { return false }

        // Reject keyboard / context-noise words. These appear when the
        // user photographs a receipt on top of a laptop and Vision picks
        // up the key caps. Single-word entries that match these are
        // never merchants.
        let keyboardWords: Set<String> = [
            "return", "command", "option", "shift", "control", "delete",
            "escape", "space", "tab", "enter", "fn", "caps lock"
        ]
        if keyboardWords.contains(lower) { return false }

        // Reject single-word "merchants" entirely. Real business names
        // almost always have at least two words ("Balaram Juice", "Sagar
        // Ratna", "Cafe Coffee Day", "Big Bazaar"). One-word names are
        // overwhelmingly Vision misreads of context (keyboard keys,
        // single header words on a receipt). For the rare genuine
        // single-word merchant ("Starbucks"), the user can fix manually.
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount < 2 { return false }

        return true
    }

    /// Convert SCREAMING CAPS or messy case to Title Case. Receipts often
    /// print merchant names in all caps; we normalize for display.
    private static func titleCased(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.capitalized
    }
}
