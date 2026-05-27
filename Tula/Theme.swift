import SwiftUI

// MARK: - Brand

extension Color {
    /// Tula's primary accent — saffron amber rooted in Indian visual culture.
    /// Brighter in dark mode for readability against deep grays.
    static let tulaBrandFallback = Color(
        light: Color(red: 0.85, green: 0.46, blue: 0.10),  // #D97706
        dark:  Color(red: 0.96, green: 0.62, blue: 0.24)   // #F59E0B
    )

    /// Primary surface for cards, lists.
    static let tulaCardSurface = Color(uiColor: .secondarySystemGroupedBackground)

    /// Page background, slightly cooler than the cards.
    static let tulaBackground = Color(uiColor: .systemGroupedBackground)

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// Transforms a vibrant brand color into a sophisticated card-surface
    /// tone. Caps brightness ≤ 0.50 and saturation ≤ 0.75 so any input —
    /// even a neon primary — emerges as a deep, refined hue rather than a
    /// cartoony Material-design swatch.
    ///
    /// This is what makes a user-chosen bright blue render as deep navy,
    /// bright green as forest green, bright yellow as muted ochre, etc.,
    /// matching the visual language of real premium credit cards.
    func cardified() -> Color {
        let ui = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Cap brightness around 0.50 — deep but not pitch black.
        // Cap saturation around 0.75 — rich but never neon.
        return Color(
            hue: Double(h),
            saturation: min(Double(s), 0.75),
            brightness: min(Double(b), 0.50),
            opacity: Double(a)
        )
    }
}

// MARK: - Spacing (committed 4pt grid)

/// Strict 4pt grid. Use only these values for vertical/horizontal layout —
/// any custom value usually means the design isn't aligned with the system.
enum Spacing {
    static let xs: CGFloat = 4         // hairline gaps
    static let sm: CGFloat = 8         // intra-element
    static let md: CGFloat = 12        // inter-element within section
    static let lg: CGFloat = 16        // section internal padding
    static let xl: CGFloat = 20        // screen edge padding
    static let xxl: CGFloat = 24       // between major sections
    static let xxxl: CGFloat = 32      // generous breathing room
}

enum CornerRadius {
    static let small: CGFloat = 10
    static let medium: CGFloat = 16        // cards
    static let large: CGFloat = 22         // hero / featured surfaces
    static let xLarge: CGFloat = 28        // sheets, large containers
}

// MARK: - Physics Animations

/// Tuned per interaction context — same defaults always look generic.
enum AppAnimation {
    /// Quick taps — chip selection, toggle. Fast, low overshoot.
    static let snappy: Animation = .spring(response: 0.28, dampingFraction: 0.85)

    /// Layout transitions — sheet content, expansions.
    static let gentle: Animation = .spring(response: 0.45, dampingFraction: 0.85)

    /// Playful — success confirmations, chart selection.
    static let bouncy: Animation = .spring(response: 0.4, dampingFraction: 0.65)

    /// Card-physics: drag with momentum for swipeable surfaces.
    static let cardPhysics: Animation = .interpolatingSpring(
        mass: 1.0, stiffness: 220, damping: 26
    )

    /// Press feedback — subtle scale + opacity on tap.
    static let press: Animation = .spring(response: 0.18, dampingFraction: 0.7)
}

// MARK: - Liquid Glass

/// Standard glass background. On iOS 26+ this participates in the Liquid
/// Glass system automatically via .regularMaterial.
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.medium

    func body(content: Content) -> some View {
        content
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

extension View {
    func tulaGlass(cornerRadius: CGFloat = CornerRadius.medium) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius))
    }
}

// MARK: - Surfaces

/// Standard card container. Default padding is generous (lg = 16pt) and
/// honor the 4pt grid. Use `padding: 0` for list containers and apply
/// padding to inner rows instead.
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

// MARK: - Section Header (refined)

/// Section title used throughout the app. Uppercase, tracked, secondary —
/// quiet enough to defer to the content. Optionally accepts a trailing
/// action (typically "See all" link).
struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 4)
    }
}

/// "See all" trailing link with chevron. Uses tint color (system blue by
/// default, or whatever ancestor `.tint(...)` provides) — restrained, so
/// the page's brand color stays reserved for primary actions like the +
/// FAB and Save buttons.
struct SeeAllLink: View {
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 2) {
                Text("See all")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Press Effect

/// Apple-quality press feedback. Scale + opacity, spring-animated.
struct PressableScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AppAnimation.press, value: configuration.isPressed)
    }
}

// MARK: - Typography Helpers

/// Reusable hero amount style — the biggest number on a screen. Rounded,
/// bold, scales down if needed to avoid truncation.
struct HeroAmountText: View {
    let amount: Double
    let currencyCode: String
    var size: CGFloat = 48

    var body: some View {
        Text(Currency.format(amount, code: currencyCode))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
            .monospacedDigit()
    }
}
