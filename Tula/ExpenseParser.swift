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
    /// True when the account was matched directly from the input text
    /// (word-boundary or substring match) rather than defaulted.
    var accountExplicitlyMatched: Bool = false
    var category: Category?
    var rawInput: String = ""
    /// Resolved date from relative expressions in the input ("yesterday",
    /// "last Friday", "kal"). Defaults to .now when no date reference is
    /// found. The save paths use this instead of always stamping .now.
    var date: Date = .now

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
        "for", "on", "at", "in", "the", "a", "an", "and",
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

        // 0. Apply learned merchant corrections from UserLearningEngine.
        // If the user previously corrected "swigy" → "Swiggy", apply that
        // correction so downstream matching sees the canonical form.
        // O(k) where k = number of corrections (capped at 500). ~0.1ms.
        let corrections = UserLearningEngine.allMerchantCorrections
        for (raw, corrected) in corrections {
            if remaining.contains(raw) {
                remaining = remaining.replacingOccurrences(
                    of: raw, with: corrected.lowercased()
                )
            }
        }

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

        // 1e. Extract and resolve relative date references ("yesterday",
        // "last Friday", "kal"). Strips matched tokens from the text so
        // they don't pollute merchant extraction downstream. Sets the
        // expense date to the resolved value; defaults to .now when no
        // date reference is found.
        let dateResult = Self.extractRelativeDate(from: remaining)
        remaining = dateResult.remaining
        result.date = dateResult.date

        // 1f. Collapse speech abbreviation artifacts ("s b i" → "sbi",
        // "S.B.I." → "sbi") so account/merchant matching can recognize
        // abbreviated names that the speech recognizer spelled out.
        remaining = Self.normalizeAbbreviations(in: remaining)

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
            result.accountExplicitlyMatched = true
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
                        .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                        .filter { !$0.isEmpty }
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
            // Fallback path — no place marker found.
            // Separate tokens into "likely merchant" vs "likely item" so
            // that "350 chai" routes "chai" through category detection
            // instead of creating merchant="Chai" with no category.
            let tokens = remaining
                .replacingOccurrences(of: #"[^a-zA-Z0-9 ]"#,
                                       with: " ",
                                       options: .regularExpression)
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty && !fillerWords.contains($0) }

            if !tokens.isEmpty {
                var merchantTokens: [String] = []
                var itemTokens: [String] = []

                for token in tokens {
                    // Known merchant patterns are always merchant tokens.
                    let isKnownMerchant = ReceiptMeta.knownMerchantCategories.keys
                        .contains(where: { key in
                            key.contains(token) || token.contains(key)
                        })

                    if isKnownMerchant {
                        merchantTokens.append(token)
                    } else if isCategoryKeyword(token) && !merchantTokens.isEmpty {
                        // Category keywords become item tokens only when we
                        // already have a merchant. Otherwise they serve as
                        // both merchant and category signal (e.g. "350 chai"
                        // → merchant "Chai", category via hint).
                        itemTokens.append(token)
                    } else {
                        merchantTokens.append(token)
                    }
                }

                if !merchantTokens.isEmpty {
                    result.merchant = merchantTokens.joined(separator: " ").capitalized
                }
                if !itemTokens.isEmpty {
                    result.note = itemTokens.joined(separator: " ").capitalized
                }
            }
        }

        // 5b. High-precision keyword classification. Owns unambiguous item
        // lists ("onions tomatoes ginger garlic paste" → Groceries) and stays
        // silent on ambiguous input, so the fuzzy/hint steps below still run.
        if result.category == nil {
            let text = [result.merchant, result.note, itemContext]
                .compactMap { $0 }
                .joined(separator: " ")
            if let classified = CategoryClassifier.classify(text, into: activeCategories) {
                result.category = classified
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

        // 7. Keyword-based category matching via CategoryHint. When
        // neither direct name match (step 4) nor MerchantRule/FuzzyMatcher
        // (step 6) found a category, check if the merchant or item text
        // contains words that semantically belong to a category.
        // "fruits" → Groceries, "fuel" → Transport, "lunch" → Food, etc.
        // Uses the same keyword descriptions that power FM prompts, so
        // both the rule parser and the AI model share one vocabulary.
        if result.category == nil {
            var searchText = result.merchant?.lowercased() ?? ""
            if !itemContext.isEmpty {
                searchText = searchText.isEmpty
                    ? itemContext.lowercased()
                    : searchText + " " + itemContext.lowercased()
            }
            if !searchText.isEmpty {
                let entries = activeCategories.map { ($0, $0.iconKey) }
                if let match = CategoryHint.matchCategory(
                    text: searchText,
                    categories: entries
                ) {
                    result.category = match
                }
            }
        }

        // 8. Learned category affinity from UserLearningEngine.
        // If we still don't have a category but we have a merchant, check
        // what category the user usually assigns to this merchant. This
        // resolves categories from historical behavior without any keyword
        // or rule match — e.g. a novel local restaurant that has no rules.
        if result.category == nil, let merchant = result.merchant {
            if let preferred = UserLearningEngine.preferredCategory(
                for: merchant
            ) {
                let match = activeCategories.first {
                    $0.name.lowercased() == preferred.lowercased()
                }
                if let match { result.category = match }
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
    static func matchAccount(
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

    /// Resolve an FM-returned account name string to an actual Account
    /// using multi-tier fuzzy matching. Falls back to `defaultAccount`
    /// only when no match is found at any tier.
    static func resolveAccount(
        named fmName: String?,
        in candidates: [Account],
        defaultAccount: Account?
    ) -> Account? {
        guard let name = fmName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return defaultAccount
        }
        // Normalize abbreviation artifacts from FM output ("S B I" → "sbi")
        let lowered = normalizeAbbreviations(in: name).lowercased()
        let active = candidates.filter { !$0.isArchived }

        // Tier 0: Exact name match
        if let exact = active.first(where: { $0.name.lowercased() == lowered }) {
            return exact
        }

        // Tier 1: Substring containment — prefer the account whose name
        // length is closest to the search string (highest coverage ratio).
        // This avoids a longest-name bias where "credit card" would match
        // "Mayur Credit Card" over "SBI Credit Card" just because Mayur is
        // longer.
        let tier1Matches = active.compactMap { acct -> (Account, Double)? in
            let n = acct.name.lowercased()
            guard !n.isEmpty else { return nil }
            guard n.contains(lowered) || lowered.contains(n) else { return nil }
            let overlap = Double(min(n.count, lowered.count))
            let span    = Double(max(n.count, lowered.count))
            return (acct, overlap / span)   // higher = tighter match
        }
        if let best = tier1Matches.max(by: { $0.1 < $1.1 }) {
            return best.0
        }

        // Tier 2: Word-level match (reuses matchAccount scoring)
        if let match = matchAccount(in: lowered, candidates: active) {
            return match.account
        }

        // Tier 3: Account kind keyword matching
        // When FM returns "credit card" or "cash" without a specific name,
        // pick the first account of that type.
        let kindMap: [(keys: [String], kind: AccountKind)] = [
            (["credit card", "cc", "credit"], .creditCard),
            (["cash", "naqad"], .cash),
            (["wallet", "upi", "paytm", "phonepe", "gpay"], .wallet),
            (["bank", "savings", "neft", "transfer"], .bank),
        ]
        for entry in kindMap {
            if entry.keys.contains(where: { lowered.contains($0) }) {
                if let match = active.first(where: { $0.kind == entry.kind }) {
                    return match
                }
            }
        }

        return defaultAccount
    }

    // MARK: - Abbreviation Normalization

    /// Collapse speech-recognizer abbreviation artifacts back into
    /// continuous abbreviations so entity matching can recognize them.
    ///
    /// Apple's speech recognizer often spells out abbreviations as
    /// individual letters: "SBI" → "S B I" or "S.B.I." in the transcript.
    /// The word-boundary account matcher then fails because `\bsbi\b`
    /// doesn't match three separate single-letter tokens.
    ///
    /// **Examples:**
    /// - "s b i" → "sbi"
    /// - "h d f c" → "hdfc"
    /// - "S.B.I. credit card" → "sbi credit card"
    /// - "i c i c i bank" → "icici bank"
    /// - "a t m 500" → "atm 500"
    /// - "a nice day" → "a nice day" (unchanged: isolated letters)
    static func normalizeAbbreviations(in text: String) -> String {
        var result = text

        // Step 1: Remove dots after single letters so "S.B.I." becomes
        // "S B I " — ready for the letter-run collapse in step 2.
        result = result.replacingOccurrences(
            of: #"(?<=\b[A-Za-z])\.\s*"#,
            with: " ",
            options: .regularExpression
        )

        // Step 2: Collapse runs of 2+ consecutive single-letter words
        // into one token: "s b i" → "sbi", "h d f c" → "hdfc".
        let tokens = result.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        var collapsed: [String] = []
        var letterRun: [String] = []

        for token in tokens {
            let stripped = token.trimmingCharacters(in: .punctuationCharacters)
            if stripped.count == 1, stripped.first?.isLetter == true {
                letterRun.append(stripped)
            } else {
                if letterRun.count >= 2 {
                    collapsed.append(letterRun.joined())
                } else {
                    collapsed.append(contentsOf: letterRun)
                }
                letterRun = []
                collapsed.append(token)
            }
        }
        if letterRun.count >= 2 {
            collapsed.append(letterRun.joined())
        } else {
            collapsed.append(contentsOf: letterRun)
        }

        return collapsed.joined(separator: " ")
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
    static func normalizeIndianNumbers(in text: String) -> String {
        SmartExpenseParser.normalizeIndianNumbers(in: text)
    }

    /// Folds Indian-English number compounds ("two fifty" → "250") into a
    /// single digit token. A *ones* word (one–nine) immediately followed by
    /// a *tens or teen* word (ten–ninety) becomes ones×100 + tens.
    ///
    /// Only word-form numbers are merged here — split numeric digits like
    /// "2 50" are intentionally left for the regex pass in `parseSingle`
    /// (step 1d) and for the FM path's `normalizeIndianNumbers`, so this
    /// helper stays narrow and predictable. Multipliers (hundred, thousand,
    /// lakh) are also left alone; the accumulator in `normalizeNumberWords`
    /// already handles "two hundred fifty", "five lakh", etc.
    private static func mergeIndianCompounds(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < tokens.count {
            let current = tokens[i].trimmingCharacters(in: .punctuationCharacters).lowercased()
            if i + 1 < tokens.count {
                let next = tokens[i + 1].trimmingCharacters(in: .punctuationCharacters).lowercased()
                if let ones = numberWords[current], ones >= 1, ones <= 9,
                   let tens = numberWords[next], tens >= 10, tens <= 90 {
                    result.append(String(ones * 100 + tens))
                    i += 2
                    continue
                }
            }
            result.append(tokens[i])
            i += 1
        }
        return result
    }

    static func normalizeNumberWords(in text: String) -> String {
        // Indian-English compound pre-pass — MUST run before the general
        // accumulator below. A ones word (one–nine) immediately followed by
        // a tens/teen word means ones×100 + tens, NOT ones + tens:
        //   "two fifty"   → 250   (the accumulator alone would give 52)
        //   "one twenty"  → 120
        //   "five fifteen"→ 515
        // Standard tens-first phrasing ("twenty five" → 25) is left untouched
        // here and handled correctly by the accumulator. This is the same
        // semantics `SmartExpenseParser.normalizeIndianNumbers` applies on the
        // FM path, so the rule path and FM path now agree on compounds.
        let tokens = mergeIndianCompounds(text.components(separatedBy: .whitespaces))
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

    // MARK: - Relative Date Extraction

    /// Detects and strips relative date references from input text,
    /// returning the resolved date and cleaned text. Handles common
    /// English and Hindi patterns:
    ///   - "yesterday" / "kal" → previous day
    ///   - "day before yesterday" / "parso" → 2 days ago
    ///   - "last Monday" (any weekday) → most recent past occurrence
    ///   - "today" / "aaj" → today (strip token, keep .now)
    ///   - "this morning" / "today morning" → today (strip token)
    ///
    /// When no date reference is found, returns .now and the text unchanged.
    static func extractRelativeDate(
        from text: String
    ) -> (date: Date, remaining: String) {
        let calendar = Calendar.current
        let now = Date.now
        var cleaned = text

        // "day before yesterday" / "parso" — must check before "yesterday"
        // to avoid partial matches.
        let dbYesterdayPatterns = [
            "day before yesterday", "parso", "parson"
        ]
        for pattern in dbYesterdayPatterns {
            if let range = cleaned.range(of: pattern, options: .caseInsensitive) {
                cleaned.replaceSubrange(range, with: " ")
                let date = calendar.date(byAdding: .day, value: -2, to: now) ?? now
                return (date, cleaned.trimmingCharacters(in: .whitespaces))
            }
        }

        // "yesterday" / "kal"
        let yesterdayPatterns = ["yesterday", "\\bkal\\b"]
        for pattern in yesterdayPatterns {
            if let range = cleaned.range(of: pattern,
                                         options: [.caseInsensitive, .regularExpression]) {
                cleaned.replaceSubrange(range, with: " ")
                let date = calendar.date(byAdding: .day, value: -1, to: now) ?? now
                return (date, cleaned.trimmingCharacters(in: .whitespaces))
            }
        }

        // "last <weekday>" / "pichle <weekday>"
        let weekdayNames = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7
        ]
        let lastDayPattern = #"(?:last|pichle|pichli)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)"#
        if let match = cleaned.range(of: lastDayPattern,
                                     options: [.caseInsensitive, .regularExpression]) {
            let matchedText = String(cleaned[match]).lowercased()
            // Extract the weekday name from the matched text
            for (name, targetWeekday) in weekdayNames {
                if matchedText.contains(name) {
                    let currentWeekday = calendar.component(.weekday, from: now)
                    var daysBack = currentWeekday - targetWeekday
                    if daysBack <= 0 { daysBack += 7 }
                    cleaned.replaceSubrange(match, with: " ")
                    let date = calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
                    return (date, cleaned.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        // "today" / "aaj" / "this morning" / "today morning" — strip token,
        // keep .now (the expense happened today, just clean the text).
        let todayPatterns = [
            "today morning", "this morning", "today evening",
            "this evening", "today", "\\baaj\\b"
        ]
        for pattern in todayPatterns {
            if let range = cleaned.range(of: pattern,
                                         options: [.caseInsensitive, .regularExpression]) {
                cleaned.replaceSubrange(range, with: " ")
                return (now, cleaned.trimmingCharacters(in: .whitespaces))
            }
        }

        return (now, text)
    }

    // MARK: - Category Keyword Detection

    /// Quick check whether a token is a category keyword (from CategoryHint
    /// descriptions). Used to distinguish item words from merchant words
    /// in preposition-free inputs like "350 chai" vs "350 swiggy".
    static func isCategoryKeyword(_ token: String) -> Bool {
        let lowered = token.lowercased()
        guard lowered.count >= 3 else { return false }
        let allHintIcons = [
            "fork.knife", "basket.fill", "fuelpump.fill", "car.fill",
            "cross.case.fill", "tshirt.fill", "film.fill", "bolt.fill",
            "house.fill", "book.fill", "scissors", "repeat.circle.fill",
            "suitcase.fill", "pawprint.fill", "figure.child"
        ]
        for icon in allHintIcons {
            guard let hint = CategoryHint.description(forIcon: icon) else { continue }
            let hintTokens = hint.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            if hintTokens.contains(lowered) { return true }
            // Prefix match for plurals
            for h in hintTokens where h.count >= 4 && lowered.count >= 4 {
                if h.hasPrefix(lowered) || lowered.hasPrefix(h) { return true }
            }
        }
        return false
    }
}
