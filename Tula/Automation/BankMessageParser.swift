import Foundation

/// Extracts a transaction from a bank or card alert.
///
/// **Structure-driven, not template-driven.** There is no per-bank template
/// list. Indian bank SMS varies enormously in wording but is remarkably
/// consistent in *shape*: a currency-marked amount, a direction verb, an
/// account token carrying masked digits, a merchant after a preposition, and
/// a reference. Matching those invariants generalises to banks nobody has
/// tested, where a template library silently fails on the first unseen format.
///
/// Pure and synchronous — no `ModelContext`, no network, no AI. This path has
/// to run from a Shortcuts automation in the background, in the second or two
/// iOS allows, offline.
enum BankMessageParser {

    // MARK: - Entry point

    static func parse(_ message: String) -> BankTransaction? {
        let text = message.replacingOccurrences(of: "\n", with: " ")
        let lower = text.lowercased()

        guard let amount = extractAmount(from: text, lower: lower) else { return nil }

        let direction = extractDirection(from: lower)
        let last4 = extractAccountLast4(from: text)
        let rawMerchant = extractMerchant(from: text)
        let reference = extractReference(from: text)

        return BankTransaction(
            amount: amount,
            direction: direction,
            accountLast4: last4,
            merchantRaw: rawMerchant,
            merchant: rawMerchant.map(normalizeMerchant),
            reference: reference,
            date: extractDate(from: text),
            currencyCode: extractCurrency(from: lower)
        )
    }

    // MARK: - Amount

    /// Words that mean the number next to them is a *balance*, not the
    /// transaction. Nearly every alert ends with "Avl Bal Rs.12,345", and
    /// naively taking the first or largest currency figure logs the balance
    /// as a purchase — the single most damaging failure this parser can have.
    private static let balanceMarkers = [
        "bal", "balance", "avl", "avbl", "available", "limit", "lmt",
        "outstanding", "due", "remaining",
    ]

    private static let amountPattern =
        #"(?:rs\.?|inr|₹)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#

    private static func extractAmount(from text: String, lower: String) -> Double? {
        let candidates = matches(of: amountPattern, in: lower, options: [.caseInsensitive])
        guard !candidates.isEmpty else { return nil }

        for match in candidates {
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: lower)
            else { continue }

            if isBalanceContext(lower, matchStart: match.range.location) { continue }

            let digits = String(lower[valueRange]).replacingOccurrences(of: ",", with: "")
            if let value = Double(digits), value > 0 { return value }
        }
        return nil
    }

    /// Looks back a short window for a balance word. A window rather than the
    /// whole string because "Avl Bal" always sits immediately before its
    /// figure, while the transaction amount appears earlier and unqualified.
    private static func isBalanceContext(_ lower: String, matchStart: Int) -> Bool {
        let windowSize = 24
        let start = max(0, matchStart - windowSize)
        let nsLower = lower as NSString
        guard start < nsLower.length else { return false }
        let window = nsLower.substring(with: NSRange(location: start, length: matchStart - start))
        return balanceMarkers.contains { window.contains($0) }
    }

    private static func extractCurrency(from lower: String) -> String? {
        if lower.contains("inr") || lower.contains("rs.") || lower.contains("rs ")
            || lower.contains("₹") {
            return "INR"
        }
        if lower.contains("usd") || lower.contains("$") { return "USD" }
        return nil
    }

    // MARK: - Direction

    private static let debitWords = [
        "debited", "debit", "spent", "withdrawn", "withdrawal", "paid",
        "purchase", "deducted", "charged", "sent to", "transferred to",
        "payment of",
    ]
    private static let creditWords = [
        "credited", "credit of", "received", "refund", "refunded", "reversed",
        "reversal", "cashback", "deposited",
    ]

    /// Whichever keyword appears **first** wins.
    ///
    /// Many UPI alerts contain both — "debited from your A/c and credited to
    /// merchant" — and the leading verb is the one describing what happened to
    /// *the user's* money. Scanning for the earliest occurrence rather than
    /// any occurrence gets this right without special-casing.
    private static func extractDirection(from lower: String) -> TransactionDirection {
        let debitAt = earliestIndex(of: debitWords, in: lower)
        let creditAt = earliestIndex(of: creditWords, in: lower)

        switch (debitAt, creditAt) {
        case (nil, nil): return .unknown
        case (_, nil): return .debit
        case (nil, _): return .credit
        case let (d?, c?): return d <= c ? .debit : .credit
        }
    }

    private static func earliestIndex(of words: [String], in lower: String) -> Int? {
        var best: Int?
        let nsLower = lower as NSString
        for word in words {
            let range = nsLower.range(of: word)
            guard range.location != NSNotFound else { continue }
            if best == nil || range.location < best! { best = range.location }
        }
        return best
    }

    // MARK: - Account

    /// Ordered most-specific first: a labelled account or card token beats a
    /// bare masked number, which could be anything.
    /// Word boundaries matter here: without `\b`, `ac` matches inside
    /// "transaction", "account" and "contact", so an unrelated four-digit run
    /// could be read as the card number.
    private static let accountPatterns = [
        #"\b(?:a/c|ac|acct|account)\b\s*(?:no\.?)?\s*[xX*]{0,}(\d{4})"#,
        #"\bcard\b\s*(?:no\.?)?\s*(?:ending\s*)?[xX*]{0,}(\d{4})"#,
        #"\bending\b\s*(?:with|in)?\s*[xX*]{0,}(\d{4})"#,
        #"[xX*]{2,}\s?(\d{4})"#,
    ]

    private static func extractAccountLast4(from text: String) -> String? {
        for pattern in accountPatterns {
            let found = matches(of: pattern, in: text, options: [.caseInsensitive])
            for match in found where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let digits = String(text[range])
                if digits.count == 4 { return digits }
            }
        }
        return nil
    }

    // MARK: - Merchant

    /// Tokens that introduce a payee. Order matters: `vpa` and `to` are more
    /// reliable than the very general `for`.
    private static let merchantPatterns = [
        #"(?:vpa|upi/[a-z]*/)\s*([a-zA-Z0-9._-]+@[a-zA-Z]+)"#,
        #"\bat\s+([A-Za-z0-9][A-Za-z0-9 .*&'/_-]{2,40}?)(?=\s+on\b|\s+ref\b|\s*[.;,]|$)"#,
        #"\bto\s+([A-Za-z0-9][A-Za-z0-9 .*&'/_-]{2,40}?)(?=\s+on\b|\s+ref\b|\s*[.;,]|$)"#,
        #"\btowards\s+([A-Za-z0-9][A-Za-z0-9 .*&'/_-]{2,40}?)(?=\s+on\b|\s+ref\b|\s*[.;,]|$)"#,
        // ICICI and others write "... on 28-Aug-26 on ATHER ENERGY LI."
        // The capture must start with a *letter* so the date after the first
        // "on" cannot match; the regex then moves on to the real payee.
        #"\bon\s+([A-Za-z][A-Za-z0-9 .*&'/_-]{2,40}?)(?=\s+on\b|\s+avl\b|\s+ref\b|\s*[.;,]|$)"#,
        #"\bfor\s+([A-Za-z0-9][A-Za-z0-9 .*&'/_-]{2,40}?)(?=\s+on\b|\s+ref\b|\s*[.;,]|$)"#,
    ]

    private static func extractMerchant(from text: String) -> String? {
        for pattern in merchantPatterns {
            let found = matches(of: pattern, in: text, options: [.caseInsensitive])
            for match in found where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let candidate = String(text[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlausibleMerchant(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Rejects fragments that are grammar rather than a payee — "your account",
    /// "the transaction" — and anything that is only digits or a date.
    private static let merchantStopWords: Set<String> = [
        "your", "the", "a", "an", "this", "that", "account", "acct", "card",
        "bank", "transaction", "txn", "payment", "you", "us", "be", "avoid",
        "block", "report", "call", "know", "more", "info", "details",
    ]

    private static func isPlausibleMerchant(_ candidate: String) -> Bool {
        guard candidate.count >= 3 else { return false }
        let letters = candidate.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }

        let firstWord = candidate
            .lowercased()
            .components(separatedBy: .whitespaces)
            .first ?? ""
        return !merchantStopWords.contains(firstWord)
    }

    /// Turns a machine merchant string into something a human recognises.
    ///
    /// `PAYTM*UBER` → `Uber`. `SWIGGY BANGALORE IND` → `Swiggy`.
    /// `zomato@ybl` → `Zomato`. The aggregator prefix and the trailing
    /// location noise carry no meaning for categorisation and make the
    /// expense list unreadable.
    static func normalizeMerchant(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // UPI handle: keep the name, drop the PSP.
        if let atIndex = value.firstIndex(of: "@") {
            value = String(value[value.startIndex..<atIndex])
        }

        // Aggregator prefixes: the segment after the separator is the actual
        // merchant.
        for separator in ["*", "/"] where value.contains(separator) {
            let parts = value
                .components(separatedBy: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 }
            if let last = parts.last, !last.isEmpty { value = last }
        }

        value = value.replacingOccurrences(of: "_", with: " ")
        value = value.replacingOccurrences(of: ".", with: " ")

        // Trailing-only, so a brand that merely *starts* with one of these is
        // untouched. "li" and "lt" appear because banks truncate the merchant
        // field mid-word — "ATHER ENERGY LI" is "…LIMITED" cut short.
        let noise: Set<String> = [
            "li", "lt", "ltd", "limited", "llp", "co",
            "ind", "india", "in", "pvt", "private", "bangalore",
            "bengaluru", "mumbai", "delhi", "chennai", "hyderabad", "pune",
            "kolkata", "gurgaon", "noida", "payment", "payments", "pay",
        ]
        var words = value
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        // Trailing noise only — a leading token is usually the brand itself.
        while let last = words.last, noise.contains(last.lowercased()), words.count > 1 {
            words.removeLast()
        }

        let cleaned = words
            .map { word -> String in
                let lowered = word.lowercased()
                guard let first = lowered.first else { return lowered }
                return String(first).uppercased() + lowered.dropFirst()
            }
            .joined(separator: " ")

        return cleaned.isEmpty ? raw : cleaned
    }

    // MARK: - Reference

    /// References are only accepted when a keyword introduces them.
    ///
    /// An earlier version also matched any bare 12-digit run. That looked
    /// harmless and was the most dangerous line in this file: every alert from
    /// a given bank carries the same dispute helpline number, so two unrelated
    /// purchases both "referenced" 180012345678 and the second was silently
    /// discarded as a duplicate. Real spending disappearing with no error is
    /// far worse than a missed deduplication — without a reference the caller
    /// falls back to amount plus account inside a short window, which is safe.
    private static let referencePatterns = [
        #"(?:upi\s*)?(?:ref(?:erence)?|rrn|utr)\s*(?:no\.?|id)?\s*[:.\-]?\s*([A-Za-z0-9]{6,25})"#,
        #"txn\s*(?:no\.?|id)?\s*[:.\-]?\s*([A-Za-z0-9]{6,25})"#,
    ]

    static func extractReference(from text: String) -> String? {
        for pattern in referencePatterns {
            let found = matches(of: pattern, in: text, options: [.caseInsensitive])
            for match in found where match.numberOfRanges > 1 {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                if value.count >= 6 { return value.uppercased() }
            }
        }
        return nil
    }

    // MARK: - Date

    private static func extractDate(from text: String) -> Date? {
        let time = extractTime(from: text)

        let numeric = #"\b(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})\b"#
        if let match = matches(of: numeric, in: text, options: []).first,
           match.numberOfRanges > 3 {
            let parts = (1...3).compactMap { index -> Int? in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                return Int(text[range])
            }
            if parts.count == 3 {
                return makeDate(day: parts[0], month: parts[1], year: parts[2], time: time)
            }
        }

        let alpha = #"\b(\d{1,2})[-\s]([A-Za-z]{3})[-\s](\d{2,4})\b"#
        if let match = matches(of: alpha, in: text, options: [.caseInsensitive]).first,
           match.numberOfRanges > 3,
           let dayRange = Range(match.range(at: 1), in: text),
           let monthRange = Range(match.range(at: 2), in: text),
           let yearRange = Range(match.range(at: 3), in: text),
           let day = Int(text[dayRange]),
           let year = Int(text[yearRange]),
           let month = monthNumber(String(text[monthRange])) {
            return makeDate(day: day, month: month, year: year, time: time)
        }

        return nil
    }

    /// Clock time from the alert, when present.
    ///
    /// Worth extracting rather than defaulting every transaction to noon:
    /// `UserLearningEngine` learns which categories occur at which hour, so a
    /// whole day of purchases stamped 12:00 teaches it nothing and quietly
    /// degrades category suggestions.
    private static func extractTime(from text: String) -> (hour: Int, minute: Int)? {
        let pattern = #"\b(\d{1,2}):(\d{2})(?::\d{2})?\s*([ap]\.?m\.?)?"#
        let found = matches(of: pattern, in: text, options: [.caseInsensitive])
        guard let match = found.first, match.numberOfRanges > 2 else { return nil }

        guard let hourRange = Range(match.range(at: 1), in: text),
              let minuteRange = Range(match.range(at: 2), in: text),
              var hour = Int(text[hourRange]),
              let minute = Int(text[minuteRange])
        else { return nil }

        var meridiem: String?
        if match.numberOfRanges > 3, let range = Range(match.range(at: 3), in: text) {
            meridiem = String(text[range]).lowercased()
        }

        if let meridiem, meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
        if let meridiem, meridiem.hasPrefix("a"), hour == 12 { hour = 0 }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static let monthNames = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    private static func monthNumber(_ name: String) -> Int? {
        guard let index = monthNames.firstIndex(of: name.lowercased()) else { return nil }
        return index + 1
    }

    /// Rejects a parse that lands in the future — a two-digit year read the
    /// wrong way round, or a DD/MM message misread as MM/DD, should fall back
    /// to "now" rather than filing the expense in next year.
    private static func makeDate(
        day: Int,
        month: Int,
        year: Int,
        time: (hour: Int, minute: Int)?
    ) -> Date? {
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }
        var components = DateComponents()
        components.day = day
        components.month = month
        components.year = year < 100 ? 2000 + year : year
        // Noon when the alert carried no clock time — a neutral point that
        // cannot slip into the neighbouring day across a DST shift.
        components.hour = time?.hour ?? 12
        components.minute = time?.minute ?? 0
        guard let date = Calendar.current.date(from: components) else { return nil }
        return date > Date.now.addingTimeInterval(86_400) ? nil : date
    }

    // MARK: - Regex helper

    private static func matches(
        of pattern: String,
        in text: String,
        options: NSRegularExpression.Options
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range)
    }
}
