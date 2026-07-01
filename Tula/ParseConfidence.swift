import Foundation

/// Per-field confidence emitted by the parsing pipeline.
///
/// The practical route to "≥90% accurate saved data" is not a smarter model
/// alone — it is *calibrated* confidence plus a one-tap human confirmation on
/// the fields the parser is unsure about. Fields scored `.low` are surfaced in
/// the UI with a review affordance so the user corrects them before saving.
/// Everything scored `.high` is trusted silently. Net effect: what lands in the
/// database is high-accuracy because uncertainty is resolved at the point of
/// capture, not discovered later as rework.
enum FieldConfidence: Int, Comparable, CaseIterable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: FieldConfidence, rhs: FieldConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Normalised weight used when folding fields into an overall score.
    var weight: Double {
        switch self {
        case .low:    return 0.0
        case .medium: return 0.6
        case .high:   return 1.0
        }
    }
}

/// The structured field whose confidence a card may want to flag for review.
enum ExpenseField: String, CaseIterable {
    case amount
    case merchant
    case category
    case account
}

/// Confidence breakdown for a single parsed expense.
///
/// `overall` is a 0...1 score weighted toward the fields that matter most for
/// correctness (amount and account are load-bearing — a wrong amount or the
/// wrong account is the costliest mistake; merchant is cosmetic by comparison).
struct ParseConfidence: Equatable {
    var amount: FieldConfidence
    var merchant: FieldConfidence
    var category: FieldConfidence
    var account: FieldConfidence

    /// Field importance weights. Sum is normalised internally, so these are
    /// relative — amount and account dominate, merchant is the lightest.
    private static let weights: [ExpenseField: Double] = [
        .amount: 0.40,
        .account: 0.30,
        .category: 0.20,
        .merchant: 0.10
    ]

    /// 0...1 weighted confidence across all fields.
    var overall: Double {
        let total = Self.weights.values.reduce(0, +)
        let scored =
            Self.weights[.amount]!  * amount.weight +
            Self.weights[.account]! * account.weight +
            Self.weights[.category]! * category.weight +
            Self.weights[.merchant]! * merchant.weight
        return total > 0 ? scored / total : 0
    }

    /// The accuracy bar the product targets. Below this, the card nudges the
    /// user to confirm before saving.
    static let reviewThreshold = 0.90

    /// True when the parse as a whole is below the accuracy bar.
    var needsReview: Bool { overall < Self.reviewThreshold }

    /// Fields a card should visibly flag (anything not high-confidence).
    var fieldsNeedingReview: [ExpenseField] {
        var fields: [ExpenseField] = []
        if amount   < .high { fields.append(.amount) }
        if account  < .high { fields.append(.account) }
        if category < .high { fields.append(.category) }
        if merchant < .high { fields.append(.merchant) }
        return fields
    }

    func confidence(for field: ExpenseField) -> FieldConfidence {
        switch field {
        case .amount:   return amount
        case .merchant: return merchant
        case .category: return category
        case .account:  return account
        }
    }
}

// MARK: - Scoring

extension ParseConfidence {

    /// Score a rule-only parse (no FM enrichment available).
    ///
    /// Signals:
    /// - **amount** — high when a clean numeric token produced a positive value.
    /// - **account** — high when matched directly from the text, medium when
    ///   defaulted, low when absent.
    /// - **category** — high when matched by explicit name, medium when inferred
    ///   (merchant rule / keyword / learned affinity), low when absent.
    /// - **merchant** — high when an explicit place-marker ("at X") produced it,
    ///   medium for a residual-token guess, low when absent.
    static func fromRule(_ parsed: ParsedExpense) -> ParseConfidence {
        let amount: FieldConfidence = parsed.amount > 0 ? .high : .low

        let account: FieldConfidence = {
            if parsed.account == nil { return .low }
            return parsed.accountExplicitlyMatched ? .high : .medium
        }()

        // A category present alongside a non-empty note/merchant tends to mean
        // it was inferred rather than named; we can't perfectly distinguish the
        // path here, so categories from the rule parser are capped at medium.
        // The richer signal comes from agreement with FM (see `merged`).
        let category: FieldConfidence = parsed.category == nil ? .low : .medium

        let merchant: FieldConfidence = {
            guard let m = parsed.merchant, !m.isEmpty else { return .low }
            return .medium
        }()

        return ParseConfidence(
            amount: amount, merchant: merchant,
            category: category, account: account
        )
    }

    /// Score the *merged* result of rule + FM parsing. Agreement between the two
    /// independent parsers is the strongest signal we have on-device: when the
    /// fast rule parser and the language model land on the same value, that
    /// field is trustworthy. Disagreement or single-source values are demoted.
    ///
    /// - Parameters:
    ///   - rule: the rule-based parse (may be invalid).
    ///   - fm: the FM/cloud result, already resolved into the final draft.
    ///   - resolvedCategory / resolvedAccount: the entities the call site
    ///     actually chose, so we can compare against the rule's choice.
    static func merged(
        rule: ParsedExpense?,
        fmAmount: Double?,
        fmMerchant: String?,
        resolvedCategory: Category?,
        resolvedAccount: Account?,
        accountExplicitlyInText: Bool
    ) -> ParseConfidence {
        // Amount — agreement within ₹1 (rounding) → high. Single source → medium.
        let amount: FieldConfidence = {
            guard let fm = fmAmount, fm > 0 else {
                return (rule?.amount ?? 0) > 0 ? .medium : .low
            }
            if let r = rule?.amount, r > 0, abs(r - fm) < 1 { return .high }
            return .medium
        }()

        // Account — explicit mention in text is the gold signal. A resolved
        // account that wasn't named is a reasonable default (medium). None → low.
        let account: FieldConfidence = {
            guard resolvedAccount != nil else { return .low }
            return accountExplicitlyInText ? .high : .medium
        }()

        // Category — high when both parsers agree on the same category entity.
        let category: FieldConfidence = {
            guard let resolved = resolvedCategory else { return .low }
            if let ruleCat = rule?.category, ruleCat.id == resolved.id { return .high }
            return .medium
        }()

        // Merchant — high when rule and FM agree (case-insensitive), else medium.
        let merchant: FieldConfidence = {
            let fmName = fmMerchant?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let ruleName = rule?.merchant?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let fmName, !fmName.isEmpty {
                if let ruleName, ruleName == fmName { return .high }
                return .medium
            }
            if let ruleName, !ruleName.isEmpty { return .medium }
            return .low
        }()

        return ParseConfidence(
            amount: amount, merchant: merchant,
            category: category, account: account
        )
    }
}
