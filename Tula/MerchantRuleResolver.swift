import Foundation
import SwiftData

/// Helpers for resolving an expense's category from the user's
/// `MerchantRule` table BEFORE invoking Foundation Models. The on-device
/// LLM can categorize correctly given good prompts, but it's still
/// slower (200-500ms per call) and occasionally inconsistent. When the
/// user has already taught Tula that "BPCL" → Transport via 50 prior
/// expenses, we should use that learned mapping deterministically.
///
/// **Order of preference for category resolution:**
/// 1. Exact merchant-pattern match in `MerchantRule` (user-defined)
/// 2. Substring match in `MerchantRule` (default-shipped patterns)
/// 3. FM-suggested category (fallback when neither above hits)
///
/// **Why a separate helper**: `SmartExpenseParser` is intentionally
/// pure text-in-text-out — no SwiftData access. The MerchantRule check
/// needs a `ModelContext`, so it lives in the calling layer. This file
/// holds the lookup logic so each caller doesn't reinvent it.
enum MerchantRuleResolver {

    /// Look up a category for the given merchant name. Returns nil
    /// when no rule matches — caller falls back to FM's suggestion
    /// (or "Other" as last resort).
    ///
    /// **Matching strategy**: lowercase the merchant, then test each
    /// rule's `pattern` (which is stored lowercased) for substring
    /// containment in EITHER direction. Real example: pattern "swiggy"
    /// matches merchant "Swiggy Bowls"; pattern "ramachandra restaurant"
    /// matches merchant "Ramachandra". User-defined rules outrank
    /// default-shipped ones when both match.
    ///
    /// **Why both-directions substring**: merchants come in many forms
    /// — "SWIGGY*BANGALORE", "Swiggy Foods Pvt Ltd", just "Swiggy". A
    /// pattern of "swiggy" should match all three. Conversely, a
    /// pattern of "ramachandra restaurant" should match a merchant of
    /// just "Ramachandra" when that's what OCR returned.
    ///
    /// **Threading**: caller is responsible for invoking on the actor
    /// that owns the `ModelContext`. For the main app that's MainActor.
    /// For the share extension it's whatever actor the ShareSession
    /// helper is running on (also wraps in MainActor.run).
    static func category(for merchant: String?,
                          in context: ModelContext) -> Category? {
        guard let merchant, !merchant.isEmpty else { return nil }
        let lowered = merchant.lowercased()

        // Fetch without a sort descriptor — SortDescriptor on Bool can
        // hit compiler keypath-inference issues in some Swift versions,
        // and there are typically only a few dozen MerchantRule records
        // so an in-memory sort is trivial.
        let descriptor = FetchDescriptor<MerchantRule>()
        guard let rules = try? context.fetch(descriptor) else { return nil }

        // Sort in Swift: user-defined rules first so they outrank
        // default-shipped ones when both would match.
        let ordered = rules.sorted { a, b in
            if a.isUserDefined != b.isUserDefined {
                return a.isUserDefined && !b.isUserDefined
            }
            return false
        }

        for rule in ordered {
            guard !rule.pattern.isEmpty else { continue }
            // Bidirectional substring — pattern can be a fragment of
            // merchant OR vice versa.
            if lowered.contains(rule.pattern) || rule.pattern.contains(lowered) {
                return rule.category
            }
        }
        return nil
    }

    /// Convenience for callers that just want the category NAME (e.g.,
    /// the share extension which doesn't have direct Category refs in
    /// its UI flow). Returns nil when no rule matches OR when the
    /// matched rule has no category (shouldn't happen but defensive).
    static func categoryName(for merchant: String?,
                              in context: ModelContext) -> String? {
        category(for: merchant, in: context)?.name
    }
}
