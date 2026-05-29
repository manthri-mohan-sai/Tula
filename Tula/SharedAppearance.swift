import SwiftUI

// MARK: - Shared Appearance
//
// Minimal Color helpers shared between the main app target (Tula) and the
// widget extension target (TulaWidget). Kept self-contained — no SwiftData,
// no Haptics, no UI helpers — so the widget can include this file without
// dragging in main-app dependencies.
//
// XCODE TARGET MEMBERSHIP (critical):
//   ☑ Tula
//   ☑ TulaWidget
//
// Both boxes MUST be checked. If either is missing, the corresponding
// target won't be able to find Color(hex:) or Color.tulaBrandFallback and
// the build will fail (or icons render blank if Xcode silently uses a
// stale build).

extension Color {

    /// Tula's primary accent — saffron amber rooted in Indian visual culture.
    /// Brighter in dark mode for readability against deep grays.
    static let tulaBrandFallback = Color(
        light: Color(red: 0.85, green: 0.46, blue: 0.10),  // #D97706
        dark:  Color(red: 0.96, green: 0.62, blue: 0.24)   // #F59E0B
    )

    /// Fullscreen amber for the launch animation. Lower luminosity than
    /// the brand accent — the accent is calibrated for small interactive
    /// elements where brightness signals "tap me", but a fullscreen wash
    /// at that intensity blasts the eyes, especially in dark environments
    /// where the user just launched the app. Light mode keeps the bright
    /// saffron (looks vibrant on a bright phone); dark mode drops to a
    /// deeper burnt-amber that feels warm without being aggressive.
    static let tulaLaunchBackground = Color(
        light: Color(red: 0.85, green: 0.46, blue: 0.10),  // same as accent — bright is fine on bright screens
        dark:  Color(red: 0.45, green: 0.22, blue: 0.05)   // #732F0D — deep burnt amber
    )

    /// Adaptive color that swaps between light and dark mode variants.
    /// Used by `tulaBrandFallback` above and available for any future
    /// themed color that needs the same treatment.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// Initialize from a hex string like "#FF6B6B" or "FF6B6B".
    /// Returns gray for any malformed input — never crashes on
    /// user-provided color strings stored in SwiftData records.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&rgb), cleaned.count == 6 else {
            self = .gray
            return
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
