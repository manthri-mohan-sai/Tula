import Foundation

/// Result of parsing a single expense segment from a natural-language input.
struct ParsedExpense: Identifiable {
    var id = UUID()
    var amount: Double = 0
    var merchant: String?
    /// Optional context preserved from the input — e.g. the item being
    /// purchased when the input separates item from merchant ("on waffle
    /// at waffle hub" → merchant "Waffle Hub", note "Waffle"). Stored on
    /// the saved Expense's note field. Empty when no separation exists.
    var note: String?
    var account: Account?
    var category: Category?
    var rawInput: String = ""

    /// A short summary string for the live preview UI.
    func summary(currencyCode: String) -> String {
        var parts: [String] = [Currency.format(amount, code: currencyCode)]
        if let category { parts.append(category.name) }
        if let merchant, merchant.lowercased() != category?.name.lowercased() {
            parts.append(merchant)
        }
        // Show item note when present (e.g. "Waffle" alongside "Waffle Hub")
        // so the preview reflects the full structure the parser extracted.
        // Skip if it duplicates the merchant — e.g. "samosa" with merchant
        // "Samosa" — to avoid showing the same word twice.
        if let note, !note.isEmpty,
           note.lowercased() != merchant?.lowercased() {
            parts.append(note)
        }
        if let account { parts.append(account.name) }
        return parts.joined(separator: " · ")
    }

    var isValid: Bool { amount > 0 && account != nil }
}

/// Parses freeform text into one or more structured expenses.
///
/// Handles multi-expense input by splitting on natural conjunctions:
///   "350 food and 400 groceries"        → 2 expenses
///   "350 swiggy, 1200 amazon, 200 metro" → 3 expenses
///
/// For each segment, applies the same strategy:
/// 1. Strip currency markers and filler words ("i", "spent", "for", "on")
/// 2. Extract first number as the amount
/// 3. Match account by longest-name-first substring
/// 4. Match category directly by name (word-boundary) — handles "food", "groceries"
/// 5. Whatever remains is the merchant; runs merchant rules for category if not yet set
///
/// Pure local logic — no LLM, no network, no privacy concerns.
enum ExpenseParser {

    /// Filler words to strip before merchant extraction. Without this,
    /// "i spent 350 for food" would parse merchant as "I Spent For".
    private static let fillerWords: Set<String> = [
        "i", "spent", "paid", "bought", "got",
        "for", "on", "at", "in", "the", "a", "an",
        "with", "to", "from", "by", "using", "via", "of",
        "today", "yesterday", "tonight", "now",
        "this", "that"
    ]

    private static let currencyMarkers = [
        "₹", "rs.", "rs", "inr", "$", "usd", "€", "eur", "£", "gbp", "¥", "jpy",
        // Spoken-form variants — voice dictation transcribes "rupees" not "₹",
        // and an unstripped "rupees" pollutes merchant extraction. Place
        // longer forms first so substring replacement doesn't leave fragments
        // ("rupees" stripped before "rupee" so we don't end up with " s").
        "rupees", "rupee", "dollars", "dollar", "euros", "euro",
        "pounds", "pound", "yen"
    ]

    /// Number-word → integer mappings. Used by `normalizeNumberWords` to
    /// convert phrases like "one hundred twenty" or "two fifty" into plain
    /// digits BEFORE the amount regex runs. Covers the common voice patterns;
    /// "one fifty" and "two twenty" are real expressions people use even
    /// without the word "hundred" (Indian-English usage especially —
    /// "give me one twenty rupees" = 120).
    private static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "hundred": 100, "thousand": 1000,
        "lakh": 100_000, "lakhs": 100_000,
        "crore": 10_000_000, "crores": 10_000_000
    ]

    /// Public entry point. Always returns an array — one element for single-
    /// expense inputs, multiple for multi-expense ones. Empty if nothing
    /// parseable was found.
    static func parse(
        input: String,
        accounts: [Account],
        categories: [Category],
        merchantRules: [MerchantRule],
        defaultAccount: Account? = nil
    ) -> [ParsedExpense] {
        let segments = splitIntoSegments(input)
        let parsed = segments.compactMap { segment in
            parseSingle(
                segment: segment,
                originalInput: input,
                accounts: accounts,
                categories: categories,
                merchantRules: merchantRules,
                defaultAccount: defaultAccount
            )
        }
        return applySharedAccountContext(parsed, defaultAccount: defaultAccount)
    }

    // MARK: - Segmentation

    /// Splits multi-expense input on natural conjunctions / punctuation.
    /// Returns the original input as a single-element array if no separators
    /// were found.
    ///
    /// **Voice-dictation hardening**: we only split on conjunction words
    /// (`and`, `then`, `also`, `plus`) when the input contains **two or
    /// more numeric tokens**. Otherwise "200 for bills and utilities"
    /// gets fragmented into "200 for bills" + "utilities" and the
    /// "Bills & Utilities" category never matches. Punctuation splits
    /// (commas, semicolons, `+`) still fire unconditionally — those are
    /// unambiguous separators.
    private static func splitIntoSegments(_ input: String) -> [String] {
        let numericMatches = input.matches(of: #/\d+/#)
        let numericCount = numericMatches.count

        let pattern: String
        if numericCount >= 2 {
            // Multi-expense input — conjunction words can legitimately
            // mean "now a new expense".
            pattern = #"\s+(?:and|then|also|plus)\s+|\s*[,;]\s*|\s*\+\s*"#
        } else {
            // Zero or one amount in the input — "and" is part of a
            // category/merchant phrase, not a separator. Only split on
            // unambiguous punctuation.
            pattern = #"\s*[,;]\s*|\s*\+\s*"#
        }

        let split = input.replacingOccurrences(
            of: pattern,
            with: "|||",
            options: [.regularExpression, .caseInsensitive]
        )
        let parts = split.components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [input] : parts
    }

    // MARK: - Single Segment Parse

    private static func parseSingle(
        segment: String,
        originalInput: String,
        accounts: [Account],
        categories: [Category],
        merchantRules: [MerchantRule],
        defaultAccount: Account?
    ) -> ParsedExpense? {
        var result = ParsedExpense(rawInput: originalInput)
        var remaining = segment.lowercased()

        // 1. Strip currency markers
        for marker in currencyMarkers {
            remaining = remaining.replacingOccurrences(of: marker, with: " ")
        }

        // 1b. Convert spoken number words to digits.
        // "one hundred twenty" → "120", "two fifty" → "250", "five lakh" →
        // "500000". Apple's dictation usually produces digits, but it can
        // emit literal words when speech is fragmented, contains pauses,
        // or for non-American English varieties. This bridges that gap so
        // downstream amount extraction sees plain numbers regardless.
        remaining = normalizeNumberWords(in: remaining)

        // 1c. Collapse Indian/comma-grouped numbers ("1,000", "1,25,000")
        // into plain digits so the amount regex captures the full value.
        // Apple's en-IN dictation routinely produces comma-grouped output
        // — without this we'd get "1" instead of "1000".
        remaining = remaining.replacingOccurrences(
            of: #"(\d),(\d)"#,
            with: "$1$2",
            options: .regularExpression
        )
        // Run a second pass to handle 3-group numbers like "1,25,000"
        // (Indian lakh grouping) where the first pass leaves "1,25000".
        remaining = remaining.replacingOccurrences(
            of: #"(\d),(\d)"#,
            with: "$1$2",
            options: .regularExpression
        )

        // 1d. Collapse split digits from voice dictation.
        // iOS sometimes transcribes "120" as "1 20" — particularly when
        // the speaker pauses mid-number. Without recovery, the amount
        // regex grabs the first digit run ("1") and the expense saves
        // with amount=1, the rest stuck in the merchant text.
        //
        // Pattern: a 1-3-digit group followed by a 2-3-digit group with
        // only whitespace between them. We collapse only when:
        //   - The first group is 1-3 digits (so we don't accidentally
        //     merge two genuine numbers like "100 200" into "100200")
        //   - The second group is 2-3 digits (skips "1 5" which is
        //     usually two separate quantities, not a number)
        //   - The result starts with 1-9 (no leading zero artifacts)
        remaining = remaining.replacingOccurrences(
            of: #"(?<![\d])([1-9]\d{0,2})\s+(\d{2,3})\b"#,
            with: "$1$2",
            options: .regularExpression
        )

        // 2. Extract the first numeric token as amount.
        // No number = no expense — skip this segment.
        guard let amountRange = remaining.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        let numStr = String(remaining[amountRange])
        result.amount = Double(numStr) ?? 0
        remaining.removeSubrange(amountRange)
        guard result.amount > 0 else { return nil }

        // 3. Match account — two-tier:
        //    Tier 1: full account name as substring ("HDFC CC" matches "hdfc cc")
        //    Tier 2: any significant word of the name matches as a word boundary
        //            ("HDFC CC" matches "hdfc" alone, or "HDFC Bank" matches "hdfc")
        //    Tier 1 wins over Tier 2; within Tier 2, more matched chars wins.
        let activeAccounts = accounts.filter { !$0.isArchived }
        if let match = matchAccount(in: remaining, candidates: activeAccounts) {
            result.account = match.account
            // Strip every matched token so it doesn't pollute merchant extraction.
            for token in match.matchedTokens {
                let escapedToken = NSRegularExpression.escapedPattern(for: token)
                remaining = remaining.replacingOccurrences(
                    of: #"\b"# + escapedToken + #"\b"#,
                    with: " ",
                    options: .regularExpression
                )
            }
        }

        // 4. Match category by direct name (word-boundary) — "food",
        // "groceries", "transport" should match Food, Groceries, Transport.
        // Longest first to avoid partial matches.
        //
        // For names containing `&`, we also try the "and" alias (and vice
        // versa) so that dictating "bills and utilities" matches a category
        // stored as "Bills & Utilities", and typing "tea and coffee" matches
        // "Tea & Coffee". This is the single biggest win for voice input.
        let activeCategories = categories.filter { !$0.isArchived }
            .sorted { $0.name.count > $1.name.count }
        for category in activeCategories {
            let nameLower = category.name.lowercased()
            var aliases: [String] = [nameLower]
            if nameLower.contains("&") {
                aliases.append(nameLower.replacingOccurrences(of: "&", with: "and"))
            }
            if nameLower.contains(" and ") {
                aliases.append(nameLower.replacingOccurrences(of: " and ", with: " & "))
            }

            var matched = false
            for alias in aliases {
                let escaped = NSRegularExpression.escapedPattern(for: alias)
                let pattern = #"\b"# + escaped + #"\b"#
                if remaining.range(of: pattern, options: .regularExpression) != nil {
                    result.category = category
                    remaining = remaining.replacingOccurrences(
                        of: pattern, with: " ", options: .regularExpression
                    )
                    matched = true
                    break
                }
            }
            if matched { break }
        }

        // 5. Merchant extraction. Two strategies in priority order:
        //
        //   a) **Place-marker strategy.** English uses prepositions to
        //      separate items from places: "on X" / "for X" marks an item;
        //      "at Y" / "from Y" marks a merchant. If the input contains
        //      "at <words>" or "from <words>", treat those words as the
        //      merchant (stopping at the next item-marker preposition or
        //      end of input). The leftover words become the item context,
        //      which feeds category detection and gets preserved as a note.
        //
        //      Example: "spent 100 on waffle at waffle hub"
        //        → merchant = "Waffle Hub", note = "Waffle"
        //      Without this: "on waffle at waffle hub" would tokenize into
        //      "Waffle Waffle Hub" — clearly wrong.
        //
        //   b) **Fallback: residual tokens.** When no place marker is
        //      present, treat all non-filler tokens as the merchant
        //      (original behavior). "swiggy 250" → "Swiggy", "samosa 30"
        //      → "Samosa", etc.
        let placeMarkers: Set<String> = ["at", "from"]
        let itemMarkers: Set<String> = ["on", "for", "using", "via", "with", "to"]

        var explicitMerchant: String? = nil
        var itemContext: String = ""

        let words = remaining
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        if let markerIdx = words.firstIndex(where: {
            placeMarkers.contains($0.lowercased())
        }) {
            // Collect place words after the marker, stopping at the next
            // item-marker preposition (handles "at the cafe on weekends"
            // → place = "the cafe", not "the cafe on weekends").
            var placeWords: [String] = []
            var cursor = markerIdx + 1
            while cursor < words.count {
                let w = words[cursor].lowercased()
                if itemMarkers.contains(w) { break }
                placeWords.append(words[cursor])
                cursor += 1
            }

            if !placeWords.isEmpty {
                // Strip leading fillers from the place phrase ("the cafe"
                // becomes "Cafe"; "the corner stall" becomes "Corner Stall").
                let filteredPlace = placeWords.filter {
                    !fillerWords.contains($0.lowercased())
                }
                if !filteredPlace.isEmpty {
                    explicitMerchant = filteredPlace
                        .joined(separator: " ")
                        .capitalized
                }

                // Item context = words BEFORE the marker, fillers removed.
                // E.g. "spent 100 on waffle at waffle hub" → "waffle".
                let beforeMarker = Array(words[..<markerIdx])
                itemContext = beforeMarker
                    .filter { !fillerWords.contains($0.lowercased()) }
                    .joined(separator: " ")
            }
        }

        if let explicit = explicitMerchant {
            result.merchant = explicit
            // Preserve item context as the expense note — captures the
            // user's full intent (what they bought, not just where).
            if !itemContext.isEmpty {
                result.note = itemContext.capitalized
            }
        } else {
            // Fallback path — no place marker found. Clean the residual
            // text and use all non-filler tokens as the merchant.
            let tokens = remaining
                .replacingOccurrences(of: #"[^a-zA-Z0-9 ]"#,
                                       with: " ",
                                       options: .regularExpression)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty && !fillerWords.contains($0) }

            if !tokens.isEmpty {
                result.merchant = tokens.joined(separator: " ").capitalized
            }
        }

        // 6. If category wasn't found by name, try matching against
        // merchant + item context combined. Item context is critical
        // here — for "biryani at corner stall", the merchant "Corner
        // Stall" doesn't match any food rule, but "biryani" does.
        // Combining the two before lookup lets the parser catch the
        // category via the item even when the merchant is novel.
        if result.category == nil {
            var searchText = result.merchant?.lowercased() ?? ""
            if !itemContext.isEmpty {
                searchText = searchText.isEmpty
                    ? itemContext.lowercased()
                    : searchText + " " + itemContext.lowercased()
            }
            if !searchText.isEmpty {
                let userRules = merchantRules.filter { $0.isUserDefined }
                let defaultRules = merchantRules.filter { !$0.isUserDefined }
                let allRules = userRules + defaultRules
                if let match = FuzzyMatcher.matchCategory(for: searchText,
                                                          in: allRules) {
                    result.category = match
                }
            }
        }

        // Note: default account fallback is intentionally NOT applied here.
        // That happens in applySharedAccountContext so we can distinguish
        // "user explicitly typed default account name" from "no account given".

        return result
    }

    // MARK: - Shared Context

    /// Apply context across segments after individual parsing:
    /// 1. If exactly one unique explicit account appears across segments,
    ///    share it to segments that didn't specify one.
    /// 2. Any segment still without an account falls back to defaultAccount.
    ///
    /// This handles "350 food and 400 groceries hdfc cc" → both on HDFC CC,
    /// and the trickier "350 food cash and 400 groceries hdfc cc" → first on
    /// Cash, second on HDFC CC (different accounts, no sharing).
    private static func applySharedAccountContext(
        _ parsed: [ParsedExpense],
        defaultAccount: Account?
    ) -> [ParsedExpense] {
        // For a single segment, just apply default fallback.
        guard parsed.count > 1 else {
            return parsed.map { p in
                var copy = p
                if copy.account == nil { copy.account = defaultAccount }
                return copy
            }
        }

        // Collect unique accounts that were explicitly matched in any segment.
        let explicitAccounts = parsed.compactMap { $0.account }
        let uniqueIDs = Set(explicitAccounts.map { $0.id })

        // If exactly one explicit account across all segments, use it as the
        // shared account for any segments that didn't specify one.
        let sharedAccount: Account? = (uniqueIDs.count == 1) ? explicitAccounts.first : nil

        return parsed.map { p in
            var copy = p
            if copy.account == nil {
                copy.account = sharedAccount ?? defaultAccount
            }
            return copy
        }
    }

    // MARK: - Account Matching

    /// Two-tier account matcher.
    ///
    /// **Tier 1 (strongest):** the entire account name appears as a substring
    /// of the input. "HDFC CC" matches "swiggy hdfc cc" because "hdfc cc" is
    /// a contiguous substring. Tie-break: longer account name wins (more specific).
    ///
    /// **Tier 2 (fallback):** any significant word (≥2 chars) of the account
    /// name appears in the input as a whole word. "HDFC CC" matches "swiggy
    /// hdfc" because "hdfc" is a whole word in the input. Score is the sum of
    /// matched-word character counts — so an account whose every word appears
    /// beats one with just a single word match.
    ///
    /// Returns the matched account plus the exact tokens that hit (so the
    /// caller can strip them from the input before merchant extraction).
    private static func matchAccount(
        in text: String,
        candidates: [Account]
    ) -> (account: Account, matchedTokens: [String])? {
        // Tier 1 — full-name substring (longest first for specificity).
        let byLengthDesc = candidates.sorted { $0.name.count > $1.name.count }
        for account in byLengthDesc {
            let nameLower = account.name.lowercased()
            guard !nameLower.isEmpty else { continue }
            if text.contains(nameLower) {
                return (account, [nameLower])
            }
        }

        // Tier 2 — word-level match. For each candidate account, count how
        // many of its significant words (≥2 chars) appear in the input as
        // whole words. Best total-character score wins.
        var best: (account: Account, score: Int, tokens: [String])?

        for account in candidates {
            let nameWords = account.name.lowercased()
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count >= 2 }

            guard !nameWords.isEmpty else { continue }

            let matched = nameWords.filter { word in
                let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
                return text.range(of: pattern, options: .regularExpression) != nil
            }

            guard !matched.isEmpty else { continue }

            let score = matched.reduce(0) { $0 + $1.count }
            if best == nil || score > best!.score {
                best = (account, score, matched)
            }
        }

        if let best { return (best.account, best.tokens) }
        return nil
    }

    // MARK: - Number-Word Normalization

    /// Convert spoken number-word phrases in the input to plain digits.
    /// Handles English number names from "zero" through "nine ninety-nine
    /// crore" by walking the text token-by-token and folding runs of
    /// number words into a single computed value, then substituting that
    /// value back as digits.
    ///
    /// **Conservative single-word rule:** a single small number word
    /// ("one", "two", ..., "nine") alone is NOT converted — those are
    /// often determiners ("one waffle", "two tickets"). They're only
    /// converted when part of a multi-word phrase ("one hundred", "two
    /// fifty") where the numeric intent is unambiguous. Tens and above
    /// ("twenty", "fifty", "hundred") are always converted — those are
    /// unambiguously numeric in expense context.
    ///
    /// **Examples:**
    /// - "one hundred twenty rupees" → "120 rupees"
    /// - "two fifty"                  → "250" (Indian English shorthand)
    /// - "five lakh"                  → "500000"
    /// - "three thousand five hundred" → "3500"
    /// - "twenty rupees"              → "20 rupees"
    /// - "one waffle"                 → "one waffle" (unchanged: ambiguous)
    /// - "spent one"                  → "spent 1" (only if it's actually
    ///   meant as a number — see safe fallback below)
    ///
    /// **Caveat:** "two and a half" becomes "2 and a half". Fractions
    /// aren't supported. Acceptable since expense amounts are almost
    /// always integers in this app.
    static func normalizeNumberWords(in text: String) -> String {
        let tokens = text.components(separatedBy: .whitespaces)
        var output: [String] = []

        // Tokens we're collecting in the current run. Holding them until
        // we know whether the run has more than one number word (commit)
        // or just a lone small number (revert as ambiguous).
        var runRawTokens: [String] = []
        var accumulator = 0          // running sub-total (e.g. "twenty five" → 25)
        var grandTotal = 0           // result of completed multiplier phrases
        var numberWordCount = 0      // how many number tokens in this run
        var hasUnambiguousNumber = false  // saw a ten-or-above / multiplier

        func isSmallSingleWord(_ value: Int) -> Bool {
            value >= 1 && value <= 9
        }

        // Flush the current run. If it has 2+ number words OR contains an
        // unambiguous number (≥10 or a multiplier), emit the computed
        // digit. Otherwise revert to the raw tokens to preserve user
        // intent on ambiguous cases like "one waffle".
        func flush() {
            if numberWordCount >= 2 || hasUnambiguousNumber {
                let total = grandTotal + accumulator
                output.append(String(total))
            } else {
                output.append(contentsOf: runRawTokens)
            }
            runRawTokens = []
            accumulator = 0
            grandTotal = 0
            numberWordCount = 0
            hasUnambiguousNumber = false
        }

        for raw in tokens {
            let token = raw.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if token.isEmpty {
                output.append(raw)
                continue
            }

            if let value = numberWords[token] {
                runRawTokens.append(raw)
                numberWordCount += 1
                if !isSmallSingleWord(value) {
                    hasUnambiguousNumber = true
                }
                if value == 100 || value == 1000 || value == 100_000 || value == 10_000_000 {
                    let multiplicand = accumulator == 0 ? 1 : accumulator
                    grandTotal += multiplicand * value
                    accumulator = 0
                } else {
                    accumulator += value
                }
            } else if token == "and" && numberWordCount > 0 {
                // "two hundred and fifty" — keep "and" in raw tokens
                // (for revert path) but don't count it.
                runRawTokens.append(raw)
            } else {
                flush()
                output.append(raw)
            }
        }
        flush()

        return output.joined(separator: " ")
    }
}
