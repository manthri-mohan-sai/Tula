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
    private static func splitIntoSegments(_ input: String) -> [String] {
        let pattern = #"\s+(?:and|then|also|plus)\s+|\s*[,;]\s*|\s*\+\s*"#
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

        // 2. Extract the first numeric token as amount.
        // No number = no expense — skip this segment.
        guard let amountRange = remaining.range(of: #"\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        let numStr = String(remaining[amountRange])
        result.amount = Double(numStr) ?? 0
        remaining.removeSubrange(amountRange)
        guard result.amount > 0 else { return nil }

        // 3. Match account — longest name first so "hdfc cc" beats "hdfc".
        let activeAccounts = accounts.filter { !$0.isArchived }
            .sorted { $0.name.count > $1.name.count }
        for account in activeAccounts {
            let nameLower = account.name.lowercased()
            if remaining.contains(nameLower) {
                result.account = account
                remaining = remaining.replacingOccurrences(of: nameLower, with: " ")
                break
            }
        }

        // 4. Match category by direct name (word-boundary) — "food",
        // "groceries", "transport" should match Food, Groceries, Transport.
        // Longest first to avoid partial matches.
        let activeCategories = categories.filter { !$0.isArchived }
            .sorted { $0.name.count > $1.name.count }
        for category in activeCategories {
            let nameLower = category.name.lowercased()
            let escaped = NSRegularExpression.escapedPattern(for: nameLower)
            let pattern = #"\b"# + escaped + #"\b"#
            if remaining.range(of: pattern, options: .regularExpression) != nil {
                result.category = category
                remaining = remaining.replacingOccurrences(
                    of: pattern, with: " ", options: .regularExpression
                )
                break
            }
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

        // 7. Apply default account fallback (per-segment; shared-context
        // logic happens in applySharedAccountContext at the array level).
        if result.account == nil { result.account = defaultAccount }

        return result
    }

    // MARK: - Shared Context

    /// When user writes "350 food and 400 groceries hdfc cc", they almost
    /// always mean both should go on HDFC CC. This pass shares an account
    /// across segments when ALL segments that have an explicit account
    /// share the same one, OR when only one segment has an explicit account.
    /// If segments specify different accounts, keep them as the user wrote.
    private static func applySharedAccountContext(
        _ parsed: [ParsedExpense],
        defaultAccount: Account?
    ) -> [ParsedExpense] {
        guard parsed.count > 1 else { return parsed }

        // Find unique accounts that were *explicitly* specified (i.e.
        // appeared in the text, not the default fallback). We can't
        // distinguish "explicit" from "fallback default" perfectly, but if
        // there's only one unique non-nil account and it matches default,
        // user probably typed it in only one segment.
        let nonDefaultAccounts = parsed.compactMap { $0.account }
            .filter { $0.id != defaultAccount?.id }

        // If exactly one unique non-default account appeared, share it.
        let uniqueAccountIDs = Set(nonDefaultAccounts.map { $0.id })
        if uniqueAccountIDs.count == 1, let shared = nonDefaultAccounts.first {
            return parsed.map { p in
                var copy = p
                if copy.account?.id == defaultAccount?.id || copy.account == nil {
                    copy.account = shared
                }
                return copy
            }
        }

        return parsed
    }
}
