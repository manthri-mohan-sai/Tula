import SwiftUI

// MARK: - Reveal Text
//
// A calm, premium reveal: the real text fades and sharpens into place (blur →
// crisp with a slight rise), never showing random glyphs. Used when a parsed
// value first appears (merchant, item, account) so the transition from "AI is
// thinking" to "here's the answer" feels smooth and legible, not noisy.
//
// Pure SwiftUI, no timer — a single spring drives the whole reveal, so there's
// nothing to clean up and no per-frame churn.

/// A text view that reveals its content with a soft blur-fade (Apple-standard),
/// resolving cleanly to the final string. Name kept for source compatibility.
struct ScrambleText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .regular
    var color: Color = .primary
    /// Reveal duration.
    var duration: Double = 0.45
    /// Retained for API compatibility; no longer used (no glyph cycling).
    var charset: String = ""

    @State private var shown = false

    var body: some View {
        Text(text)
            .font(font.weight(weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 5)
            .offset(y: shown ? 0 : 4)
            .onAppear { reveal() }
            .onChange(of: text) { _, _ in reveal() }
    }

    private func reveal() {
        shown = false
        withAnimation(.easeOut(duration: duration)) { shown = true }
    }
}

// MARK: - Shimmer

/// A diagonal light sweep used to signal "AI is working on this". Apply to any
/// view; the sweep only runs while `active` is true, so it costs nothing at rest.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    var tint: Color = .white

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        let width = geo.size.width
                        LinearGradient(
                            colors: [.clear, tint.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.6)
                        .offset(x: phase * width * 1.6)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                    }
                    .mask { content }
                }
            }
            .onAppear { startIfNeeded() }
            .onChange(of: active) { _, _ in startIfNeeded() }
    }

    private func startIfNeeded() {
        guard active else { return }
        phase = -1
        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

extension View {
    /// Sweeps a soft light band across the view while `active`.
    func shimmering(active: Bool, tint: Color = .white) -> some View {
        modifier(ShimmerModifier(active: active, tint: tint))
    }
}

// MARK: - Rolling Amount

/// A currency amount that counts up to its value on appear, then animates
/// smoothly to any new value. Pairs with the scramble reveal so the hero number
/// "lands" rather than popping in.
struct RollingAmount: View {
    let value: Double
    let currencyCode: String
    var font: Font = .system(size: 48, weight: .heavy, design: .rounded)
    var color: Color = .primary
    /// Count-up time on first appearance.
    var rollIn: Double = 0.6

    @State private var shown: Double = 0
    @State private var didAppear = false

    var body: some View {
        Text(Currency.format(shown, code: currencyCode))
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText(value: shown))
            .onAppear {
                guard !didAppear else { return }
                didAppear = true
                withAnimation(.easeOut(duration: rollIn)) { shown = value }
            }
            .onChange(of: value) { _, newValue in
                withAnimation(.snappy) { shown = newValue }
            }
    }
}
