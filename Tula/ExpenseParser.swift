import Foundation

/// Result of parsing a single expense segment from a natural-language input.
struct ParsedExpense: Identifiable {
    var id = UUID()
    var amount: Double = 0
    var merchant: String?
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
        "₹", "rs.", "rs", "inr", "$", "usd", "€", "eur", "£", "gbp", "¥", "jpy"
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

        // 1b. Collapse Indian/comma-grouped numbers ("1,000", "1,25,000")
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

        // 5. Clean and tokenize remaining text for merchant extraction.
        let tokens = remaining
            .replacingOccurrences(of: #"[^a-zA-Z0-9 ]"#,
                                   with: " ",
                                   options: .regularExpression)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }

        if !tokens.isEmpty {
            result.merchant = tokens.joined(separator: " ").capitalized
        }

        // 6. If category wasn't found by name, try matching the merchant
        // against MerchantRules ("swiggy" → Food).
        if result.category == nil, let merchantLower = result.merchant?.lowercased() {
            let userRules = merchantRules.filter { $0.isUserDefined }
            let defaultRules = merchantRules.filter { !$0.isUserDefined }
            for rule in userRules + defaultRules {
                if merchantLower.contains(rule.pattern) {
                    result.category = rule.category
                    break
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
}
