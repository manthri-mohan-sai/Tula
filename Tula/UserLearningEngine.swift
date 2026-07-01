//
//  UserLearningEngine.swift
//  Tula
//
//  Persistent learning engine that captures user correction patterns
//  and feeds them back into both rule-based and FM parsing paths.
//
//  Storage: UserDefaults (lightweight, no SwiftData dependency).
//  Thread safety: All reads are value-type snapshots; writes are
//  atomic via UserDefaults synchronization.
//

import Foundation

enum UserLearningEngine {

    // MARK: - Storage Keys

    /// Existing key — shared with FMContextBuilder and SpeechRecognizer.
    private static let merchantMapKey = "merchantCorrectionMap"
    /// Merchant → [Category: count]. Learned from every save.
    private static let categoryAffinityKey = "ule_categoryAffinity"
    /// Hour (0-23) → [Category: count]. Time-of-day patterns.
    private static let hourCategoryKey = "ule_hourCategoryDist"

    // MARK: - Merchant Normalization

    /// Lookup corrected merchant name. Returns nil if no correction exists.
    /// Called by ExpenseParser as Step 0 BEFORE any other processing.
    ///
    /// O(1) dictionary lookup — zero impact on parsing latency.
    static func correctedMerchant(for raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        guard let map = UserDefaults.standard.dictionary(
            forKey: merchantMapKey) as? [String: String] else { return nil }
        return map[raw.lowercased()]
    }

    /// Record a merchant correction. Overwrites previous correction for
    /// the same raw input. Called from AddExpenseView when user edits
    /// a parsed merchant.
    static func learnMerchantCorrection(raw: String, corrected: String) {
        guard !raw.isEmpty, !corrected.isEmpty,
              raw.lowercased() != corrected.lowercased() else { return }
        var map = UserDefaults.standard.dictionary(
            forKey: merchantMapKey) as? [String: String] ?? [:]
        map[raw.lowercased()] = corrected
        // Cap at 500 entries to prevent unbounded growth.
        if map.count > 500 {
            let keysToRemove = Array(map.keys.prefix(100))
            keysToRemove.forEach { map.removeValue(forKey: $0) }
        }
        UserDefaults.standard.set(map, forKey: merchantMapKey)
    }

    /// Returns the full correction map. Used by FMContextBuilder and
    /// SpeechRecognizer contextual phrases.
    static var allMerchantCorrections: [String: String] {
        UserDefaults.standard.dictionary(
            forKey: merchantMapKey) as? [String: String] ?? [:]
    }

    // MARK: - Category Affinity per Merchant

    /// Returns the most frequent category for a given merchant, or nil.
    /// Structure: [lowercased_merchant: [category_name: count]]
    static func preferredCategory(for merchant: String) -> String? {
        guard !merchant.isEmpty else { return nil }
        guard let all = UserDefaults.standard.dictionary(
            forKey: categoryAffinityKey) as? [String: [String: Int]] else { return nil }
        guard let affinities = all[merchant.lowercased()] else { return nil }
        return affinities.max(by: { $0.value < $1.value })?.key
    }

    /// Record that merchant X was saved with category Y.
    /// Called on every expense save (not just corrections).
    private static func recordCategoryChoice(merchant: String, category: String) {
        guard !merchant.isEmpty, !category.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(
            forKey: categoryAffinityKey) as? [String: [String: Int]] ?? [:]
        var counts = all[merchant.lowercased()] as? [String: Int] ?? [:]
        counts[category, default: 0] += 1
        all[merchant.lowercased()] = counts
        // Cap at 300 merchants to prevent unbounded growth.
        if all.count > 300 {
            // Remove merchants with lowest total counts.
            let sorted = all.sorted { lhs, rhs in
                let lhsTotal = (lhs.value as? [String: Int])?.values.reduce(0, +) ?? 0
                let rhsTotal = (rhs.value as? [String: Int])?.values.reduce(0, +) ?? 0
                return lhsTotal < rhsTotal
            }
            for entry in sorted.prefix(50) {
                all.removeValue(forKey: entry.key)
            }
        }
        UserDefaults.standard.set(all, forKey: categoryAffinityKey)
    }

    // MARK: - Time-of-Day Category Distribution

    /// Returns categories ranked by frequency for the given hour.
    /// Structure: [hour_string: [category_name: count]]
    static func categoriesForHour(_ hour: Int) -> [(name: String, count: Int)] {
        guard let all = UserDefaults.standard.dictionary(
            forKey: hourCategoryKey) as? [String: [String: Int]] else { return [] }
        let bucket = String(hour)
        guard let counts = all[bucket] else { return [] }
        return counts.sorted { $0.value > $1.value }
            .map { (name: $0.key, count: $0.value) }
    }

    /// Record a category usage at a specific hour.
    private static func recordHourCategory(hour: Int, category: String) {
        guard !category.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(
            forKey: hourCategoryKey) as? [String: [String: Int]] ?? [:]
        let bucket = String(hour)
        var counts = all[bucket] as? [String: Int] ?? [:]
        counts[category, default: 0] += 1
        all[bucket] = counts
        UserDefaults.standard.set(all, forKey: hourCategoryKey)
    }

    // MARK: - Batch Learn

    /// Single call point for all learning signals. Called from every save
    /// path (QuickLog, AddExpenseView, Siri intent) so learning happens
    /// regardless of input method.
    static func learn(merchant: String?, category: String?,
                      amount: Double, hour: Int) {
        if let merchant, !merchant.isEmpty {
            if let category, !category.isEmpty {
                recordCategoryChoice(merchant: merchant, category: category)
            }
        }
        if let category, !category.isEmpty {
            recordHourCategory(hour: hour, category: category)
        }
    }
}
