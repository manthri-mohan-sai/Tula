import Foundation
import NaturalLanguage

/// The single, user-data-driven parsing pipeline shared by quick-log, voice,
/// and scan. Replaces the three divergent resolution chains that used to live
/// in `VoiceInputOverlay` and `HomeView`.
///
/// **Design (validated in the P0 prototype before this port):**
/// - *Deterministic-first.* Amount, account, date, items and category are
///   resolved by rules the parser is actually good at. The LLM (when enabled)
///   only fills fields left low-confidence — it never overrides a high-
///   confidence deterministic field (that reconciliation lives in the caller).
/// - *Nothing user-specific is hardcoded.* Accounts and categories are injected
///   at construction; matching is always against the user's own list. Only
///   generic language knowledge (number words, markers, an item→category-bucket
///   lexicon via `CategoryClassifier`) ships with the app.
/// - *Field ownership:* markers decide roles — `at`/`from` marks a **place**
///   (merchant), `using`/`paid`/`via` marks a **payment method** (account). This
///   is what lets an account literally named "Milk" not steal the grocery word
///   "milk": the account is whatever follows the payment marker, never a stray
///   token.
struct ExpenseInterpreter {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?

    private var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }

    // MARK: - Public entry

    /// Parse free text into one or more editable drafts with per-field
    /// confidence. Always deterministic; safe to call with no AI available.
    func interpret(_ rawInput: String) -> [ExpenseDraft] {
        let normalized = Self.normalize(rawInput)
        let segments = Self.segment(normalized)

        // Whole-utterance fallbacks: a shared category / item list stated once
        // ("apples, tomatoes … 140 SBI and 40 cash") applies to every expense.
        let sharedCategory = CategoryClassifier.classify(normalized, into: categories)
        let sharedItems = Self.extractItems(normalized)

        return segments.compactMap { segment in
            buildDraft(segment: segment, whole: normalized,
                       sharedCategory: sharedCategory, sharedItems: sharedItems,
                       rawInput: rawInput)
        }
    }

    // MARK: - Per-segment draft

    private func buildDraft(segment: String, whole: String,
                            sharedCategory: Category?, sharedItems: [String],
                            rawInput: String) -> ExpenseDraft? {
        guard let amount = Self.firstAmount(in: segment), amount > 0 else { return nil }

        let (account, accountConfidence) = resolveAccount(segment: segment, whole: whole)
        let segmentCategory = CategoryClassifier.classify(segment, into: categories)
        let category = segmentCategory ?? sharedCategory
        let merchant = resolveMerchant(in: segment)
        let segItems = Self.extractItems(segment)
        let items = segItems.isEmpty ? sharedItems : segItems
        let date = ExpenseParser.extractRelativeDate(from: segment).date

        let confidence = ParseConfidence(
            amount: .high,                                   // regex over digits — exact
            merchant: merchant == nil ? .low : .high,        // named place / NER hit
            category: category == nil ? .low
                : (segmentCategory != nil ? .high : .medium),// segment match > shared guess
            account: accountConfidence
        )

        return ExpenseDraft(
            amount: amount,
            date: date,
            merchant: merchant,
            note: nil,
            items: items,
            category: category,
            account: account ?? defaultAccount,
            rawInput: rawInput,
            confidence: confidence
        )
    }

    // MARK: - Account (marker precedence)

    /// The account is whatever a payment marker points at. We look **after** the
    /// last `using`/`paid`/`via`/`from` in the segment; only if none is present
    /// do we scan the whole utterance (shared account like "… from cash"), and
    /// only then a bare token — flagged medium/low so the review card confirms.
    private func resolveAccount(segment: String, whole: String) -> (Account?, FieldConfidence) {
        if let idx = Self.lastPaymentMarkerIndex(in: segment) {
            if let hit = matchAccountName(in: String(segment[idx...])) { return (hit, .high) }
            if let kind = matchAccountKind(in: String(segment[idx...])) { return (kind, .high) }
            return (nil, .low)   // marker present but nothing recognisable after it
        }
        // No marker in this segment — try the whole utterance (shared account).
        if let idx = Self.lastPaymentMarkerIndex(in: whole),
           let hit = matchAccountName(in: String(whole[idx...])) {
            return (hit, .medium)
        }
        // Last resort: a bare account-name token anywhere in the segment.
        if let hit = matchAccountName(in: segment) { return (hit, .medium) }
        return (nil, .low)
    }

    /// Match a user account by name, resolving prefix collisions deterministically.
    ///
    /// Scores each account by how many of ITS name words appear in the text. The
    /// account with the MOST matched words wins; ties break toward the *fewer*
    /// total words (the more exact name). So with both "IndusInd" and "IndusInd
    /// Rupay":
    ///   - "…indusind rupay" → IndusInd Rupay (2 matched > 1)
    ///   - "…indusind"       → IndusInd (both match 1, but IndusInd is exact)
    /// And "flipkart axis card" → "Flipkart Axis" (2 matched) over a plain "Axis".
    /// Falls back to the substring/phonetic matcher when no name word matches.
    private func matchAccountName(in text: String) -> Account? {
        let words = Set(Self.tokens(text))
        var best: (account: Account, matched: Int, total: Int)?
        for account in activeAccounts {
            let nameWords = account.name.lowercased()
                .split(separator: " ").map(String.init).filter { $0.count >= 2 }
            guard !nameWords.isEmpty else { continue }
            let matched = nameWords.filter { words.contains($0) }.count
            guard matched > 0 else { continue }
            let better = best == nil
                || matched > best!.matched
                || (matched == best!.matched && nameWords.count < best!.total)
            if better { best = (account, matched, nameWords.count) }
        }
        if let best { return best.account }
        // Fallback for substring/phonetic hits (e.g. account name written solid).
        return ExpenseParser.matchAccount(in: text.lowercased(), candidates: activeAccounts)?.account
    }

    /// Match by payment-type keyword when no name matched ("credit card", "cash").
    private func matchAccountKind(in text: String) -> Account? {
        let words = Set(Self.tokens(text))
        let map: [(keys: Set<String>, kind: AccountKind)] = [
            (["cash", "naqad"], .cash),
            (["wallet", "upi", "paytm", "phonepe", "gpay"], .wallet),
            (["credit", "cc"], .creditCard),
            (["bank", "savings", "debit"], .bank)
        ]
        for entry in map where !words.isDisjoint(with: entry.keys) {
            if let match = activeAccounts.first(where: { $0.kind == entry.kind }) { return match }
        }
        return nil
    }

    // MARK: - Merchant (place marker → NER)

    /// Merchant = the words after `at`/`from` up to the next marker. If there's
    /// no place marker, fall back to on-device NER (organization/place names).
    /// Returns nil rather than guessing from leftover item words — a named place
    /// or nothing, never "Chocolate Dark Chocolate".
    private func resolveMerchant(in segment: String) -> String? {
        // `at` is an unambiguous place marker.
        if let name = Self.merchantAfter(markers: ["at"], in: segment) { return name }
        // `from` is ambiguous ("from Haldiram" = place, "from cash" = payment).
        // Accept it as a merchant only when it doesn't name one of the user's
        // accounts.
        if let name = Self.merchantAfter(markers: ["from"], in: segment),
           matchAccountName(in: name) == nil, matchAccountKind(in: name) == nil {
            return name
        }
        return Self.nerMerchant(in: segment)
    }

    // MARK: - Static text helpers (generic knowledge only)

    private static let paymentMarkers = ["using", "paid", "via", "from"]
    /// Words that end a merchant/item span.
    private static let stopWords: Set<String> =
        ["at", "from", "using", "paid", "via", "with", "for", "on"]
    private static let fillers: Set<String> = [
        "the", "a", "an", "of", "spent", "bought", "paid", "got", "on", "for",
        "at", "from", "using", "via", "with", "to", "and", "rupees", "rupee",
        "rs", "inr", "card", "wallet"
    ]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// First numeric token in a segment as its amount.
    private static func firstAmount(in segment: String) -> Double? {
        guard let range = segment.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression)
        else { return nil }
        return Double(segment[range])
    }

    /// Index just past the last payment marker, or nil if none.
    private static func lastPaymentMarkerIndex(in text: String) -> String.Index? {
        var best: String.Index?
        let lower = text.lowercased()
        for marker in paymentMarkers {
            var searchStart = lower.startIndex
            while let r = lower.range(of: "\\b\(marker)\\b", options: .regularExpression,
                                      range: searchStart..<lower.endIndex) {
                best = r.upperBound
                searchStart = r.upperBound
            }
        }
        // Map the lowercased index back onto the original (same length/encoding).
        guard let b = best else { return nil }
        let offset = lower.distance(from: lower.startIndex, to: b)
        return text.index(text.startIndex, offsetBy: offset)
    }

    /// Merchant span after the given marker, stopping at the next marker.
    /// Fillers dropped unless capitalised (proper nouns kept).
    private static func merchantAfter(markers: [String], in text: String) -> String? {
        let alternation = markers.joined(separator: "|")
        guard let match = text.range(
            of: #"\b(\#(alternation))\s+(.+)"#, options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        // Drop the marker word itself.
        let after = text[match].split(separator: " ").dropFirst().map(String.init)
        var words: [String] = []
        for w in after {
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if stopWords.contains(bare) { break }
            words.append(w)
        }
        let kept = words.filter {
            let bare = $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !fillers.contains(bare) || ($0.first?.isUppercase ?? false)
        }
        let name = kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
        return name.isEmpty ? nil : name.capitalized
    }

    /// On-device NER fallback for a merchant stated without a place marker.
    /// Joins adjacent organization/place-name tokens into one name.
    private static func nerMerchant(in text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var current: [String] = []
        var result: String?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            if tag == .organizationName || tag == .placeName {
                current.append(String(text[range]))
            } else if !current.isEmpty {
                result = current.joined(separator: " ")
                return false
            }
            return true
        }
        if result == nil, !current.isEmpty { result = current.joined(separator: " ") }
        return result?.capitalized
    }

    /// Words that end an ITEM span. Note "on"/"for" are NOT here — they *start*
    /// item spans ("for chicken biryani", "on milk"), so they mustn't also
    /// terminate one.
    private static let itemStopWords: Set<String> =
        ["at", "using", "paid", "via", "with", "from"]

    /// Number words to strip from item text so "three fifty for chicken biryani"
    /// never yields an item like "three".
    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "lakh", "crore"
    ]

    /// Item list: the span after `for`/`on` (or a spend verb), split on commas
    /// and "and", with fillers, number words, digits, and stray brackets/quotes
    /// removed. "for chicken biryani at X" → ["chicken biryani"];
    /// "on milk and curd at X" → ["milk", "curd"].
    private static func extractItems(_ text: String) -> [String] {
        // "for"/"on" mark items — but only when NOT followed by a number
        // ("for 55" is a price, not an item). Fall back to a spend verb.
        let markerRange = text.range(
            of: #"\b(?:on|for)\s+(?![\d₹])(.+)"#, options: [.regularExpression, .caseInsensitive]
        ) ?? text.range(
            of: #"\b(?:bought|spent|ordered|purchased|got|ate|had|drank|took)\s+(.+)"#,
            options: [.regularExpression, .caseInsensitive]
        )
        guard let markerRange else { return [] }

        let after = text[markerRange].split(separator: " ").dropFirst().map(String.init)
        var span: [String] = []
        for w in after {
            if itemStopWords.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters)) { break }
            span.append(w)
        }
        // Strip currency, digits and stray array-literal punctuation ([, ], ").
        let joined = span.joined(separator: " ")
            .replacingOccurrences(of: #"[₹\d\[\]\""']"#, with: "", options: .regularExpression)

        return joined
            .components(separatedBy: CharacterSet(charactersIn: ","))
            .flatMap { (s: String) -> [String] in s.components(separatedBy: " and ") }
            .map { part in
                part.split(separator: " ")
                    .map(String.init)
                    .filter {
                        let bare = $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
                        return !fillers.contains(bare) && !numberWords.contains(bare)
                    }
                    .joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .,₹\"'[]"))
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    // MARK: - Normalization + segmentation

    /// Clean the raw text before parsing: collapse spelled-out abbreviations
    /// ("s b i" → "sbi"), word numbers ("three fifty" → 350), and number
    /// compounds / split digits ("one 80" → 180, "1 20" → 120).
    static func normalize(_ raw: String) -> String {
        var text = ExpenseParser.normalizeAbbreviations(in: raw)
        text = ExpenseParser.normalizeNumberWords(in: text)
        text = normalizeNumberCompounds(text)
        return text
    }

    /// "one 80" / "1 20" → a single 3-digit number: ONES×100 + TENS. Only fires
    /// on an unambiguous ones-word/digit (1–9) immediately followed by a
    /// tens-word or 2-digit number (10–99).
    static func normalizeNumberCompounds(_ text: String) -> String {
        let ones: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                    "six": 6, "seven": 7, "eight": 8, "nine": 9]
        let tens: [String: Int] = ["ten": 10, "twenty": 20, "thirty": 30, "forty": 40,
                                    "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
                                    "ninety": 90, "fifteen": 15]
        var out: [String] = []
        let toks = text.split(separator: " ").map(String.init)
        var i = 0
        while i < toks.count {
            let a = toks[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,₹"))
            let aVal = ones[a] ?? (Int(a).flatMap { (1...9).contains($0) ? $0 : nil })
            if let aVal, i + 1 < toks.count {
                let b = toks[i + 1].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,₹"))
                let bVal = tens[b] ?? (Int(b).flatMap { (10...99).contains($0) ? $0 : nil })
                if let bVal {
                    out.append(String(aVal * 100 + bVal))
                    i += 2
                    continue
                }
            }
            out.append(toks[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// Split into expense segments only when there are 2+ amounts (so "bills and
    /// utilities" or "milk and curd" — one amount — stays a single expense).
    /// Segments without an amount are dropped (their words survive as the
    /// shared category/item context computed on the whole utterance).
    static func segment(_ text: String) -> [String] {
        let numberCount = text.matches(of: #/\d+/#).count
        guard numberCount >= 2 else { return [text] }
        let parts = text.replacingOccurrences(
            of: #"\s+(?:and|then|also|plus)\s+|\s*[,;]\s*|\s*\+\s*"#,
            with: "|||",
            options: [.regularExpression, .caseInsensitive]
        )
        .components(separatedBy: "|||")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.range(of: #"\d"#, options: .regularExpression) != nil }
        return parts.isEmpty ? [text] : parts
    }
}
