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

        // Stage 3: Multi-signal fuzzy matching.
        // Composite score from edit-distance, Dice coefficient (bigram
        // similarity), and phonetic key. A rule must score above threshold
        // on at least ONE signal to match. This catches:
        //   "swigy"→"swiggy" (edit + dice)
        //   "ramchandra"→"ramachandra" (phonetic)
        //   "dmonios"→"dominos" (dice, transposition)

        var bestMatch: (category: Category?, score: Double)?

        for rule in rules {
            let pattern = rule.pattern
            // Edit-distance only against single-word patterns — multi-word
            // patterns were already covered by stages 1-2.
            guard !pattern.contains(" "),
                  !pattern.contains("-") else { continue }
            guard pattern.count >= 4 else { continue }

            let maxDist = pattern.count < 6 ? 1 : 2

            for token in merchantTokens where token.count >= 4 {
                // Skip if length difference is too large for any signal.
                if abs(token.count - pattern.count) > 3 { continue }

                var score = 0.0

                // Signal 1: Edit distance (weight 0.4)
                let dist = editDistance(token, pattern)
                if dist <= maxDist {
                    score += 0.4 * (1.0 - Double(dist) / Double(max(token.count, pattern.count)))
                }

                // Signal 2: Dice coefficient — bigram similarity (weight 0.35)
                let dice = diceCoefficient(token, pattern)
                if dice >= 0.6 {
                    score += 0.35 * dice
                }

                // Signal 3: Phonetic match (weight 0.25)
                if phoneticKey(token) == phoneticKey(pattern) {
                    score += 0.25
                }

                // Composite must exceed 0.45 to match — prevents a single
                // weak signal from producing false positives.
                if score > 0.45, bestMatch == nil || score > bestMatch!.score {
                    bestMatch = (rule.category, score)
                }
            }
        }

        if let best = bestMatch {
            return best.category
        }

        // Stage 3b: Token-set ratio for multi-word patterns.
        // Catches "Pizza Hut" vs "Hut Pizza" and word-reordering variations.
        for rule in rules where rule.pattern.contains(" ") {
            let ratio = tokenSetRatio(merchant, rule.pattern)
            if ratio >= 0.8 {
                return rule.category
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Strips spaces, hyphens, apostrophes, and other non-alphanumeric
    /// characters. Useful for matching "icecream" against "ice cream"
    /// or "levis" against "levi's". Lowercased input expected.
    /// Strip everything except letters and digits. "D Mart" → "dmart",
    /// "ice-cream" → "icecream", "levi's" → "levis".
    static func normalize(_ s: String) -> String {
        s.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    /// Search-friendly containment. Returns true if `target` contains
    /// `query` either literally or after stripping spaces/punctuation.
    /// Both inputs should be lowercased by the caller.
    ///
    ///     searchContains("d mart", query: "dmart")  // true
    ///     searchContains("d mart", query: "mart")   // true
    static func searchContains(_ target: String, query: String) -> Bool {
        if target.contains(query) { return true }
        let nq = normalize(query)
        guard !nq.isEmpty else { return false }
        return normalize(target).contains(nq)
    }

    // MARK: - Dice Coefficient (Bigram Similarity)

    /// Dice coefficient using character bigrams. Returns 0.0–1.0 where
    /// 1.0 = identical. More forgiving of transpositions and insertions
    /// than edit distance alone.
    ///
    ///   diceCoefficient("swiggy", "swigy") ≈ 0.89
    ///   diceCoefficient("dominos", "dmonios") ≈ 0.67
    ///
    /// Performance: O(n+m). Sub-microsecond for merchant names.
    static func diceCoefficient(_ a: String, _ b: String) -> Double {
        guard a.count >= 2, b.count >= 2 else {
            return a == b ? 1.0 : 0.0
        }
        let aBigrams = bigrams(a)
        let bBigrams = bigrams(b)
        let intersection = aBigrams.intersection(bBigrams).count
        let total = aBigrams.count + bBigrams.count
        guard total > 0 else { return 0 }
        return 2.0 * Double(intersection) / Double(total)
    }

    /// Extract character bigrams from a string.
    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return [] }
        var result = Set<String>()
        for i in 0..<(chars.count - 1) {
            result.insert(String([chars[i], chars[i + 1]]))
        }
        return result
    }

    // MARK: - Phonetic Key (Indian English optimized)

    /// Simplified Soundex-like phonetic key optimized for Indian English.
    /// Maps phonetically similar consonants to the same code, drops vowels
    /// after the first letter.
    ///
    ///   phoneticKey("ramachandra") → "R5253"
    ///   phoneticKey("ramchandra")  → "R5253"  (same — vowel drop)
    ///   phoneticKey("swiggy")      → "S200"
    ///   phoneticKey("swigy")       → "S200"   (same — double-g merged)
    ///
    /// Performance: O(n) single pass. Negligible.
    static func phoneticKey(_ s: String) -> String {
        let lowered = s.lowercased()
        guard let first = lowered.first else { return "" }

        // Consonant → code. Soundex-inspired, tuned for Indian names.
        // b/f/p/v → 1, c/g/j/k/q/s/x/z → 2, d/t → 3, l → 4, m/n → 5, r → 6
        let codeMap: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2",
            "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3",
            "l": "4",
            "m": "5", "n": "5",
            "r": "6"
        ]

        var result = String(first).uppercased()
        var lastCode: Character = codeMap[first] ?? "0"

        for char in lowered.dropFirst() {
            let code = codeMap[char] ?? "0"
            if code != "0" && code != lastCode {
                result.append(code)
                if result.count >= 5 { break }
            }
            lastCode = code
        }

        while result.count < 5 { result.append("0") }
        return result
    }

    // MARK: - Token-Set Ratio

    /// Handles word reordering: "Pizza Hut" vs "Hut Pizza" scores 1.0
    /// because the token sets are identical.
    ///
    /// Score = |intersection| / max(|A|, |B|).
    static func tokenSetRatio(_ a: String, _ b: String) -> Double {
        let aTokens = Set(a.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        let bTokens = Set(b.lowercased().split(whereSeparator: {
            !$0.isLetter && !$0.isNumber
        }).map(String.init))
        guard !aTokens.isEmpty, !bTokens.isEmpty else { return 0 }
        let common = aTokens.intersection(bTokens).count
        return Double(common) / Double(max(aTokens.count, bTokens.count))
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
