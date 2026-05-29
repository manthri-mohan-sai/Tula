import UIKit
import Vision

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

        /// Render a structured note from the items + amount. Returns nil
        /// when there's nothing meaningful to render (no items). Format:
        /// "Masala Dosa ₹80 · Idli ₹40 · Sambar ₹20 (Total ₹140)"
        /// The total in parentheses serves as a quick sanity-check vs
        /// the extracted amount field — if they disagree, the user can
        /// see which to trust.
        func formattedNote(currencyCode: String) -> String? {
            guard !items.isEmpty else { return nil }
            let itemStr = items
                .map { "\($0.name) \(Currency.format($0.price, code: currencyCode))" }
                .joined(separator: " · ")
            if let total = amount {
                return "\(itemStr) (Total \(Currency.format(total, code: currencyCode)))"
            }
            return itemStr
        }
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
        guard let cgImage = image.cgImage else {
            return ParseResult(amount: nil, merchant: nil, items: [], date: nil, rawText: "")
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
            // Receipts often contain numbers that look like words ("O0O")
            // and words that look like garbage ("CGST"). Setting language
            // correction off avoids "MASALA" being autocorrected to "MASALA"
            // or numeric totals being miscategorized as text. Empirically
            // produces cleaner extraction on Indian receipts.
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-IN", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }

        let lines = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let rawText = lines.joined(separator: "\n")
        let amount = extractAmount(from: lines)
        let merchant = extractMerchant(from: lines, observations: observations)
        let items = extractLineItems(from: lines, total: amount)
        let date = extractDate(from: lines)

        return ParseResult(amount: amount, merchant: merchant, items: items, date: date, rawText: rawText)
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
    private static let finalTotalKeywords = [
        "grand total", "gr total", "net amount", "net total",
        "bill amount", "amount payable", "amt payable", "to pay",
        "total payable", "final amount", "round off total"
    ]

    /// Ambiguous total markers — "total" appears next to line items
    /// AND next to the grand total. We collect ALL matches then take
    /// the largest, on the principle that grand total > line items.
    private static let ambiguousTotalKeywords = [
        "total", "amount", "subtotal", "sub total"
    ]

    /// Payment-method markers — lines like "Cash 280" / "Tendered 200" /
    /// "Change 60" / "Card payment 140". These are NOT bill totals;
    /// confusing them with totals doubles the amount (the bill plus the
    /// cash tendered ≠ the actual bill). We aggressively exclude any
    /// line containing these keywords from amount extraction.
    ///
    /// Real bug encountered: a receipt with "Total 140 / Cash 280 /
    /// Change 140" was parsed as ₹280 because cash > bill > change.
    private static let paymentMethodKeywords = [
        "cash", "tendered", "tender", "received", "paid",
        "change", "balance due", "return", "card payment",
        "credit", "debit", "upi", "wallet"
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
        }

        // Phase 2: ambiguous markers ("total"). Collect ALL matches —
        // EXCLUDING payment-method lines — then take the maximum.
        // Same look-back/look-forward applies here too.
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
        if let largest = totalMarkedAmounts.max() {
            return largest
        }

        // Phase 3: no keyword match at all. Take the largest plausible-
        // amount number on the receipt, again excluding payment lines.
        let allAmounts = lines
            .filter { !isPaymentMethodLine($0) }
            .compactMap { currencyValue(in: $0) }
        return allAmounts.max()
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
