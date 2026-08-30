import Foundation

/// Resolves which of the user's accounts a transaction belongs to.
///
/// Lifted out of `ShareSession`, where the same three-strategy ladder was
/// written for receipt scans and locked inside a private method. Automation
/// needs exactly the same logic against bank-SMS fields, and a second copy
/// would be the fourth instance of the drift pattern this codebase keeps
/// paying for.
enum AccountMatcher {

    /// Confidence in the match, so callers can decide whether to trust it or
    /// flag the expense for review.
    enum Match: Equatable {
        /// Masked digits matched exactly. Effectively certain.
        case exact(Account)
        /// Partial digits plus a name hint, or a strong name-word score.
        case probable(Account)
        /// Nothing matched; caller should fall back to a default.
        case none

        var account: Account? {
            switch self {
            case .exact(let account), .probable(let account): return account
            case .none: return nil
            }
        }

        var isConfident: Bool {
            if case .exact = self { return true }
            return false
        }
    }

    /// Words too common to identify an account. "HDFC Bank Card" and "HDFC
    /// Savings" share two of three tokens, so scoring on them picks the wrong
    /// one about half the time.
    private static let genericWords: Set<String> = [
        "bank", "card", "credit", "debit", "cash", "wallet",
        "account", "savings", "current", "the", "my", "upi",
    ]

    /// - Parameters:
    ///   - last4: masked digits from the message, if any.
    ///   - hint: free text that may name the account — for SMS, the whole
    ///     message, which usually contains the issuer name.
    static func match(
        accounts: [Account],
        last4: String?,
        hint: String?
    ) -> Match {
        let active = accounts.filter { !$0.isArchived }
        guard !active.isEmpty else { return .none }

        // Strategy 1 — exact masked-digit match. Strongest signal available.
        if let last4, last4.count == 4 {
            let hit = active.first { account in
                guard let digits = account.last4Digits, digits.count >= 4 else { return false }
                return digits.suffix(4) == last4
            }
            if let hit { return .exact(hit) }
        }

        let hintLower = hint?.lowercased() ?? ""

        // Strategy 2 — partial digits plus a name word. Neither alone is
        // enough; together they are.
        if let last4, last4.count >= 2, last4.count < 4, !hintLower.isEmpty {
            for account in active {
                guard let digits = account.last4Digits, digits.count >= 2 else { continue }
                guard digits.hasSuffix(last4) else { continue }
                if distinctiveWords(in: account.name).contains(where: { hintLower.contains($0) }) {
                    return .probable(account)
                }
            }
        }

        // Strategy 3 — name-word scoring against the hint.
        guard !hintLower.isEmpty else { return .none }
        var best: Account?
        var bestScore = 0
        for account in active {
            let words = distinctiveWords(in: account.name)
            var score = words.filter { hintLower.contains($0) }.count
            if let last4, last4.count >= 2,
               let digits = account.last4Digits,
               digits.hasSuffix(last4) {
                score += 2
            }
            if score > bestScore {
                bestScore = score
                best = account
            }
        }
        if let best { return .probable(best) }
        return .none
    }

    private static func distinctiveWords(in name: String) -> [String] {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !genericWords.contains($0) }
    }
}
