//
//  FuzzyMatcher.swift
//  Tula
//
//  Created by Mohan Manthri on 28/05/26.
//


import Foundation

/// Fuzzy matcher for merchant → category lookup.
///
/// **Three-stage match strategy**, in priority order. Returns the category
/// from the first rule that hits at any stage.
///
/// 1. **Exact substring** — `"swiggy app"` matches rule `"swiggy"`. Same as the
///    old behavior. Fast, deterministic.
/// 2. **Whitespace-normalized** — strips spaces / hyphens / apostrophes from
///    both sides before comparison. `"icecream"` matches `"ice cream"`,
///    `"djones"` matches `"d-jones"`, `"levis"` matches `"levi's"`.
/// 3. **Edit-distance** — Levenshtein on tokens within the merchant string,
///    against each rule pattern. Accepts distance ≤ 1 for short patterns
///    (< 6 chars) and ≤ 2 for longer patterns. Skips when the merchant token
///    is too short (< 4 chars) to avoid false positives like `"car"` → `"chai"`.
///
/// **Why not just one big edit-distance pass?** Three reasons:
///   - Exact match is by far the most common case and we want it instant.
///   - Whitespace normalization handles the most common Indian-typing
///     variation (compound words written together).
///   - Edit-distance is genuinely fuzzy and can produce wrong matches;
///     we only fall to it when the cleaner strategies failed.
///
/// **Performance.** With ~500 rules and a typical 1-3 token merchant string,
/// the worst case is roughly 1500 edit-distance computations on short strings.
/// Levenshtein is O(n*m) for strings of length n and m, both <20 chars here,
/// so this is sub-millisecond on device. Called once per Quick Log parse.
enum FuzzyMatcher {

    /// Returns the best-matching category for the given merchant string,
    /// or nil if no rule matches at any stage.
    ///
    /// - Parameters:
    ///   - merchant: Lowercased merchant string. Caller is responsible for
    ///     case-normalization (this saves redundant work since the parser
    ///     already lowercases upstream).
    ///   - rules: All MerchantRule entries, user-defined first (caller
    ///     orders them — they win in tie-break since they appear earlier).
    static func matchCategory(for merchant: String,
                              in rules: [MerchantRule]) -> Category? {
        guard !merchant.isEmpty else { return nil }

        // Stage 1: Exact substring. Fast path for the common case.
        for rule in rules {
            if merchant.contains(rule.pattern) {
                return rule.category
            }
        }

        // Stage 2: Whitespace-normalized substring.
        // "icecream" / "ice-cream" / "ice cream" all normalize to "icecream".
        let normalizedMerchant = normalize(merchant)
        guard !normalizedMerchant.isEmpty else { return nil }

        for rule in rules {
            let normalizedPattern = normalize(rule.pattern)
            guard !normalizedPattern.isEmpty else { continue }
            if normalizedMerchant.contains(normalizedPattern) {
                return rule.category
            }
        }

        // Stage 3: Edit-distance. Token-level — split merchant on whitespace
        // and check each token against each pattern. Catches "swigy" → "swiggy"
        // and "byjus" → "byju's" (the latter would also be caught by stage 2,
        // but stage 3 gives us a second net).
        let merchantTokens = merchant
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        for rule in rules {
            let pattern = rule.pattern
            // Edit-distance only against single-word patterns to avoid
            // matching "ice cream" against a single token "icecre". Multi-word
            // patterns were already covered by stages 1-2.
            guard !pattern.contains(" "),
                  !pattern.contains("-") else { continue }

            // Pattern must be long enough that edit distance is meaningful.
            // For 3-char patterns, distance-1 means matching ~33% of chars,
            // which produces too many false positives.
            guard pattern.count >= 4 else { continue }

            let maxDistance = pattern.count < 6 ? 1 : 2

            for token in merchantTokens where token.count >= 4 {
                // Tokens far from pattern length can't be in range; skip cheaply.
                if abs(token.count - pattern.count) > maxDistance { continue }

                if editDistance(token, pattern) <= maxDistance {
                    return rule.category
                }
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Strips spaces, hyphens, apostrophes, and other non-alphanumeric
    /// characters. Useful for matching "icecream" against "ice cream"
    /// or "levis" against "levi's". Lowercased input expected.
    private static func normalize(_ s: String) -> String {
        s.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    // MARK: - Levenshtein edit distance

    /// Classic dynamic-programming Levenshtein distance.
    /// Inputs are short (< 25 chars) so the O(n*m) cost is negligible.
    /// Returns the minimum number of single-character edits (insertions,
    /// deletions, or substitutions) required to transform `a` into `b`.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let aLen = aChars.count
        let bLen = bChars.count

        if aLen == 0 { return bLen }
        if bLen == 0 { return aLen }

        // Two-row rolling DP — only previous + current rows needed.
        var prev = Array(0...bLen)
        var curr = Array(repeating: 0, count: bLen + 1)

        for i in 1...aLen {
            curr[0] = i
            for j in 1...bLen {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    curr[j - 1] + 1,        // insertion
                    prev[j] + 1,            // deletion
                    prev[j - 1] + cost      // substitution
                )
            }
            swap(&prev, &curr)
        }

        return prev[bLen]
    }
}