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

// MARK: - Theme Presets

struct ThemePreset: Identifiable, Equatable {
    let id: String
    let name: String
    let lightHex: String
    let darkHex: String
    /// Alternate app icon name registered in Info.plist. `nil` = primary icon.
    let iconName: String?

    var lightColor: Color { Color(hex: lightHex) }
    var darkColor: Color { Color(hex: darkHex) }
    var color: Color { Color(light: Color(hex: lightHex), dark: Color(hex: darkHex)) }
}

enum TulaTheme {
    static let themeKey = "themePresetID"

    static let presets: [ThemePreset] = [
        ThemePreset(id: "saffron", name: "Saffron",  lightHex: "D97706", darkHex: "F59E0B", iconName: nil),
        ThemePreset(id: "ocean",   name: "Ocean",    lightHex: "2563EB", darkHex: "3B82F6", iconName: "AppIcon-Ocean"),
        ThemePreset(id: "emerald", name: "Emerald",  lightHex: "059669", darkHex: "10B981", iconName: "AppIcon-Emerald"),
        ThemePreset(id: "rose",    name: "Rose",     lightHex: "E11D48", darkHex: "FB7185", iconName: "AppIcon-Rose"),
        ThemePreset(id: "violet",  name: "Violet",   lightHex: "7C3AED", darkHex: "8B5CF6", iconName: "AppIcon-Violet"),
        ThemePreset(id: "teal",    name: "Teal",     lightHex: "0D9488", darkHex: "14B8A6", iconName: "AppIcon-Teal"),
        ThemePreset(id: "coral",   name: "Coral",    lightHex: "EA580C", darkHex: "FB923C", iconName: "AppIcon-Coral"),
        ThemePreset(id: "slate",   name: "Slate",    lightHex: "475569", darkHex: "94A3B8", iconName: "AppIcon-Slate"),
    ]

    static var current: ThemePreset {
        let id = UserDefaults(suiteName: WidgetStorage.appGroupID)?.string(forKey: themeKey)
            ?? UserDefaults.standard.string(forKey: themeKey)
            ?? "saffron"
        return presets.first { $0.id == id } ?? presets[0]
    }

    static func select(_ preset: ThemePreset) {
        UserDefaults.standard.set(preset.id, forKey: themeKey)
        UserDefaults(suiteName: WidgetStorage.appGroupID)?.set(preset.id, forKey: themeKey)
    }
}

extension Color {

    /// Tula's primary accent — reads from the user's selected theme.
    static var tulaBrandFallback: Color {
        TulaTheme.current.color
    }

    /// Fullscreen color for the launch animation, derived from the theme.
    static var tulaLaunchBackground: Color {
        let preset = TulaTheme.current
        let darkLaunch = Color(uiColor: {
            let ui = UIColor(Color(hex: preset.lightHex))
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return UIColor(hue: h, saturation: min(s * 1.1, 1), brightness: b * 0.5, alpha: a)
        }())
        return Color(light: Color(hex: preset.lightHex), dark: darkLaunch)
    }

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
