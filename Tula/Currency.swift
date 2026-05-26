import Foundation
import SwiftUI

// MARK: - Currency

/// Lightweight currency descriptor. v1 of Tula is single-currency (the user
/// picks one at first launch via @AppStorage("primaryCurrencyCode") and all
/// money displays use it), but this helper centralizes formatting so any
/// future move to per-account currencies (v2) requires no changes at call sites.
enum Currency {

    /// Currencies offered in the picker. Indian first since this is an
    /// India-focused product, then common international currencies.
    static let supported: [String] = [
        "INR", "USD", "EUR", "GBP", "AED", "SGD", "AUD", "CAD", "JPY"
    ]

    /// User-visible name for the picker. Format: "₹ Indian Rupee (INR)".
    static func displayName(for code: String) -> String {
        "\(symbol(for: code)) \(longName(for: code)) (\(code))"
    }

    static func symbol(for code: String) -> String {
        switch code {
        case "INR": return "₹"
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "AED": return "د.إ"
        case "SGD": return "S$"
        case "AUD": return "A$"
        case "CAD": return "C$"
        case "JPY": return "¥"
        default:    return code
        }
    }

    static func longName(for code: String) -> String {
        switch code {
        case "INR": return "Indian Rupee"
        case "USD": return "US Dollar"
        case "EUR": return "Euro"
        case "GBP": return "British Pound"
        case "AED": return "UAE Dirham"
        case "SGD": return "Singapore Dollar"
        case "AUD": return "Australian Dollar"
        case "CAD": return "Canadian Dollar"
        case "JPY": return "Japanese Yen"
        default:    return code
        }
    }

    /// Locale chosen per currency so grouping looks native:
    /// - INR → en_IN (Indian grouping: 1,25,000)
    /// - Others → en_US (Western grouping: 125,000)
    /// Using English variants keeps the rest of the UI in English while only
    /// the number grouping/symbol adapts.
    static func locale(for code: String) -> Locale {
        switch code {
        case "INR": return Locale(identifier: "en_IN")
        case "JPY": return Locale(identifier: "ja_JP")
        default:    return Locale(identifier: "en_US")
        }
    }

    /// Format a money amount with full grouping for the given currency.
    /// e.g. format(125000, code: "INR") → "₹1,25,000"
    ///      format(125000, code: "USD") → "$125,000"
    static func format(_ amount: Double, code: String, showDecimals: Bool = false) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = locale(for: code)
        f.maximumFractionDigits = showDecimals ? 2 : 0
        f.minimumFractionDigits = showDecimals ? 2 : 0
        return f.string(from: NSNumber(value: amount)) ?? "\(symbol(for: code))\(Int(amount))"
    }

    /// Compact format for tight spaces. Uses Indian Lakh/Crore for INR,
    /// Western K/M/B for everything else.
    /// e.g. compact(125000, code: "INR") → "₹1.3L"
    ///      compact(125000, code: "USD") → "$125K"
    static func compact(_ amount: Double, code: String) -> String {
        let sym = symbol(for: code)
        let abs = Swift.abs(amount)

        if code == "INR" {
            if abs >= 10_000_000 { return String(format: "%@%.1fCr", sym, amount / 10_000_000) }
            if abs >= 100_000    { return String(format: "%@%.1fL", sym, amount / 100_000) }
            if abs >= 1_000      { return "\(sym)\(Int(amount / 1_000))K" }
            return "\(sym)\(Int(amount))"
        } else {
            if abs >= 1_000_000_000 { return String(format: "%@%.1fB", sym, amount / 1_000_000_000) }
            if abs >= 1_000_000     { return String(format: "%@%.1fM", sym, amount / 1_000_000) }
            if abs >= 1_000         { return "\(sym)\(Int(amount / 1_000))K" }
            return "\(sym)\(Int(amount))"
        }
    }
}

// MARK: - View Helper

/// The active primary currency, sourced from @AppStorage.
/// Use as `@PrimaryCurrency var currencyCode` in any view that needs to format money.
@propertyWrapper
struct PrimaryCurrency: DynamicProperty {
    @AppStorage("primaryCurrencyCode") private var stored: String = "INR"

    var wrappedValue: String {
        get { stored }
        nonmutating set { stored = newValue }
    }
}
