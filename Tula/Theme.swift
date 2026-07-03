import SwiftUI

// MARK: - Brand
//
// Color(hex:), Color(light:dark:), and Color.tulaBrandFallback live in
// SharedAppearance.swift so both the main app and widget extension can
// share them. This file keeps only main-app-specific surfaces.

extension Color {
    /// Primary surface for cards, lists.
    static let tulaCardSurface = Color(uiColor: .secondarySystemGroupedBackground)

    /// Page background, slightly cooler than the cards.
    static let tulaBackground = Color(uiColor: .systemGroupedBackground)

    /// Transforms a vibrant brand color into a sophisticated card-surface
    /// tone. Caps brightness ≤ 0.50 and saturation ≤ 0.75 so any input —
    /// even a neon primary — emerges as a deep, refined hue rather than a
    /// cartoony Material-design swatch.
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

// MARK: - Adaptive Layout

/// iPad-aware layout constants. On compact (iPhone, iPad Slide Over),
/// content fills as before. On regular (iPad full-screen, large split),
/// content is constrained to a comfortable reading width and centered.
enum AdaptiveLayout {
    /// Maximum content width for main scrollable areas.
    /// ~58% of iPad Pro 12.9" landscape, ~78% portrait.
    static let maxContentWidth: CGFloat = 800

    /// Whether the device is an iPad, regardless of size class.
    /// Useful inside sheets where `horizontalSizeClass` is compact
    /// even on iPad.
    static let isIPad: Bool = UIDevice.current.userInterfaceIdiom == .pad

    /// Category grid columns: 4 on iPhone, 6 on iPad.
    /// Uses device idiom (not size class) so it works correctly
    /// inside sheets where iPad has compact size class.
    static func categoryGridColumns(isRegular: Bool) -> Int {
        (isRegular || isIPad) ? 6 : 4
    }
}

/// Constrains content to `AdaptiveLayout.maxContentWidth` on regular
/// horizontal size class, centering it. On compact, applies standard
/// horizontal padding unchanged.
struct AdaptiveContentWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var compactPadding: CGFloat = Spacing.xl

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: AdaptiveLayout.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.xxl)
        } else {
            content
                .padding(.horizontal, compactPadding)
        }
    }
}

extension View {
    /// Constrains width to a comfortable reading size on iPad,
    /// preserving full-width layout on iPhone.
    func adaptiveContentWidth(compactPadding: CGFloat = Spacing.xl) -> some View {
        modifier(AdaptiveContentWidth(compactPadding: compactPadding))
    }
}

// MARK: - Physics Animations

/// Built on the iOS system spring presets (`.snappy`/`.smooth`/`.bouncy`) so
/// motion matches the platform's own feel — the same curves SwiftUI uses for
/// navigation, sheets, and toolbars. We tune duration/bounce per interaction
/// rather than hand-rolling response/damping, which is what drifts off-platform.
enum AppAnimation {
    /// Quick taps — chip selection, toggle. Crisp, near-zero overshoot.
    static let snappy: Animation = .snappy(duration: 0.3, extraBounce: 0)

    /// Layout transitions — sheet content, expansions. No bounce, natural ease.
    static let gentle: Animation = .smooth(duration: 0.4)

    /// Playful — success confirmations, reveals. Restrained, native-feeling bounce.
    static let bouncy: Animation = .bouncy(duration: 0.5, extraBounce: 0.08)

    /// Card-physics: drag with momentum for swipeable surfaces.
    static let cardPhysics: Animation = .interpolatingSpring(
        mass: 1.0, stiffness: 220, damping: 26
    )

    /// Press feedback — subtle scale + opacity on tap.
    static let press: Animation = .snappy(duration: 0.18, extraBounce: 0)

    /// True when the user has enabled Settings → Accessibility → Reduce Motion.
    /// Cached per process — the value doesn't change while the app is running.
    /// `nonisolated(unsafe)` because the value is set once at process start
    /// and never mutated — safe to read from any isolation context.
    nonisolated static let reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled

    /// Returns a minimal crossfade when Reduce Motion is on, otherwise the
    /// full spring. Every `withAnimation(AppAnimation.adaptive(.bouncy))`
    /// call automatically respects the setting with zero per-site logic.
    static func adaptive(_ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : animation
    }
}

// MARK: - Reduce Motion View Modifier

/// Conditionally applies an animation only when Reduce Motion is off.
/// When Reduce Motion is on, the content transition is instant (no
/// animation at all) or uses a minimal crossfade.
extension View {
    /// Wraps `.animation(_:value:)` with a Reduce Motion check.
    func motionSafeAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(AppAnimation.reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Liquid Glass

/// Standard glass background. Uses iOS 26's `.glassEffect()` modifier for
/// true Liquid Glass — proper background refraction, dynamic light
/// response, and edge highlights rendered by the system. Falls back to
/// a hand-crafted material + border approximation on iOS 18 and below.
struct LiquidGlass: ViewModifier {
    var cornerRadius: CGFloat = CornerRadius.medium

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Native iOS 26 — single line, system-rendered glass.
            content
                .glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            // Backport: material + soft top-edge highlight to suggest the
            // refraction band Liquid Glass renders natively. The 0.15→0.02
            // gradient mimics the brighter top edge of true glass.
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
}

extension View {
    func tulaGlass(cornerRadius: CGFloat = CornerRadius.medium) -> some View {
        modifier(LiquidGlass(cornerRadius: cornerRadius))
    }

    /// Hero card surface — Liquid Glass on iOS 26, standard card background
    /// on older systems. Use this for top-level summary cards (HomeView
    /// hero, StatsView hero, OverallBudgetCard) to get glass when available
    /// without breaking the existing look on older iOS.
    @ViewBuilder
    func tulaHeroSurface(cornerRadius: CGFloat = CornerRadius.large) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
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
            .scaleEffect(AppAnimation.reduceMotion ? 1 : (configuration.isPressed ? scale : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AppAnimation.reduceMotion ? nil : AppAnimation.press, value: configuration.isPressed)
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
            // value-bound transition so SwiftUI can interpolate digits
            // when the amount changes. Pairing with an explicit
            // .animation(value:) ensures the rolling actually happens
            // (without it, transitions need an outer withAnimation).
            .contentTransition(.numericText(value: amount))
            .animation(.snappy(duration: 0.35), value: amount)
            .monospacedDigit()
    }
}

// MARK: - Availability-Safe Navigation Modifiers
//
// SwiftUI's `.navigationSubtitle(_:)` modifier was added in iOS 26. To
// keep the codebase compatible with iOS 17+ (the project's current
// minimum), we route calls through a wrapper that applies the modifier
// only when running on iOS 26 or later. On older systems the subtitle
// is silently skipped — the screen still shows its main title, just
// without the supplementary line.
//
// Usage: replace `.navigationSubtitle(text)` call sites with
// `.tulaNavigationSubtitle(text)`. Same surface area, but compiles
// against earlier deployment targets.
extension View {
    @ViewBuilder
    func tulaNavigationSubtitle(_ text: String) -> some View {
        if #available(iOS 26.0, *) {
            self.navigationSubtitle(text)
        } else {
            self
        }
    }
}

// MARK: - Apple Intelligence Symbol Helper
//
// The "apple.intelligence" SF Symbol is iOS 26+. On earlier OSes it
// renders as a missing-glyph rectangle. We pick a tasteful fallback —
// "sparkles" reads as "AI / magic" and is universal since iOS 13.
//
// Usage: `Image(systemName: SFSymbols.appleIntelligence)`. Keeps the
// brand-correct symbol on devices that have it; degrades cleanly
// elsewhere without ugly placeholders.
enum SFSymbols {
    static var appleIntelligence: String {
        if #available(iOS 26.0, *) {
            return "apple.intelligence"
        }
        return "sparkles"
    }
}
// MARK: - Time-of-Day Ambience

/// Computes a color temperature shift based on the hour of day. Morning
/// light is warm and golden; evening shifts cooler. Applied to the home
/// glow so the app feels subtly alive — different each time you open it.
enum TimeAmbience {
    struct Tint {
        let hueShift: Double          // added to hue (0-1 range)
        let saturationShift: Double
        let brightnessShift: Double
        let opacityMultiplier: Double // glow opacity scale
    }

    static func current(at date: Date = .now) -> Tint {
        let hour = Calendar.current.component(.hour, from: date)
        switch hour {
        case 5..<10:  return Tint(hueShift: 0.03, saturationShift: 0.05,
                                  brightnessShift: 0.08, opacityMultiplier: 1.1)
        case 10..<16: return Tint(hueShift: 0, saturationShift: 0,
                                  brightnessShift: 0, opacityMultiplier: 1.0)
        case 16..<20: return Tint(hueShift: -0.02, saturationShift: 0.05,
                                  brightnessShift: -0.03, opacityMultiplier: 0.95)
        default:      return Tint(hueShift: -0.04, saturationShift: 0.08,
                                  brightnessShift: -0.06, opacityMultiplier: 0.88)
        }
    }

    /// Applies the ambient tint to a color via HSB transform.
    static func apply(_ tint: Tint, to color: Color) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: fmod(Double(h) + tint.hueShift + 1.0, 1.0),
            saturation: min(max(Double(s) + tint.saturationShift, 0), 1),
            brightness: min(max(Double(b) + tint.brightnessShift, 0), 1)
        )
    }
}

// MARK: - Spending Velocity

/// Computes a drift speed multiplier based on today's spending intensity.
/// Heavy spending → faster glow drift (more energetic). Quiet day →
/// slower drift (calmer). The home glow literally breathes with your habits.
enum SpendingVelocity {
    /// Returns a multiplier for drift animation durations.
    /// - 1.0 = normal pace
    /// - <1.0 = faster (heavy spending day, 2x+ daily average)
    /// - >1.0 = slower (quiet day, near zero spending)
    static func driftMultiplier(todayTotal: Double, monthAvgPerDay: Double) -> Double {
        guard monthAvgPerDay > 0 else { return 1.0 }
        let ratio = todayTotal / monthAvgPerDay
        if ratio >= 2.0 { return 0.6 }
        if ratio <= 0.1 { return 1.4 }
        // Linear: ratio 0.1→2.0 maps to 1.4→0.6
        return 1.4 - (ratio - 0.1) * (0.8 / 1.9)
    }
}

