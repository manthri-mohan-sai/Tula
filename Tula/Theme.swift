import SwiftUI

/// Design tokens for Tula. Centralized so visual changes happen in one place
/// rather than scattered across views.

extension Color {
    /// Tula's brand accent — a warm saffron-amber that's culturally rooted
    /// without being loud. Used for primary actions, hero accents, selected
    /// states. Renders slightly brighter in dark mode.
    static let tulaBrand = Color("TulaBrand", bundle: nil)

    /// Fallback if the asset catalog color isn't defined yet. Resolves to
    /// a saffron amber in both modes.
    static let tulaBrandFallback = Color(
        light: Color(red: 0.85, green: 0.46, blue: 0.10),  // #D97706
        dark:  Color(red: 0.96, green: 0.62, blue: 0.24)   // #F59E0B
    )

    /// Soft surface for cards/tiles, slightly elevated from background.
    static let tulaCardSurface = Color(uiColor: .secondarySystemGroupedBackground)

    /// Initialize with separate light and dark variants — saves having to
    /// create an asset catalog entry for one-off colors.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}

/// Spacing scale. Use these constants rather than magic numbers so spacing
/// stays consistent and is easy to tune globally.
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

/// Corner radius scale. Slightly larger than iOS default for a softer,
/// more premium feel.
enum CornerRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 14
    static let large: CGFloat = 20
}

/// Reusable card container — applies the standard rounded background + padding.
struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.lg
    var cornerRadius: CGFloat = CornerRadius.medium
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
    }
}

/// Section header used throughout the app for consistency.
struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.leading, 4)
    }
}

/// Spring animations used across the app. Centralized so the whole UI moves
/// with the same physical feel.
enum AppAnimation {
    static let snappy: Animation = .spring(response: 0.3, dampingFraction: 0.85)
    static let gentle: Animation = .spring(response: 0.45, dampingFraction: 0.85)
    static let bouncy: Animation = .spring(response: 0.4, dampingFraction: 0.65)
}
