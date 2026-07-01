import SwiftUI
import Combine

// MARK: - Scramble (Decode) Text
//
// The "mind-boggling" reveal: characters cycle through random glyphs and
// resolve left-to-right into the final string, like a decoder locking onto a
// signal. Used when a parsed value first appears (merchant, item, account) so
// the transition from "AI is thinking" to "here's the answer" feels earned.
//
// Pure SwiftUI + a single display-rate timer — no external dependencies, and
// it cleans itself up the moment the text is fully resolved.

/// A text view that animates its content in with a decoding-scramble effect.
struct ScrambleText: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .regular
    var color: Color = .primary
    /// Total time to fully resolve the string.
    var duration: Double = 0.65
    /// Glyphs cycled through for not-yet-resolved positions. Kept quiet and
    /// uniform-width so the reveal reads as "resolving", not "noise".
    var charset: String = "0123456789·•:-"

    @State private var displayed: String = ""
    @State private var elapsed: Double = 0
    @State private var resolved = false

    private let tick = 1.0 / 30.0
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(resolved ? text : displayed)
            .font(font.weight(weight))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.identity)
            .onAppear { restart() }
            .onChange(of: text) { _, _ in restart() }
            .onReceive(timer) { _ in advance() }
    }

    private func restart() {
        elapsed = 0
        resolved = text.isEmpty
        displayed = scramble(progress: 0)
    }

    private func advance() {
        guard !resolved else { return }
        elapsed += tick
        let linear = min(elapsed / max(duration, 0.01), 1)
        if linear >= 1 {
            resolved = true
            displayed = text
        } else {
            // Ease-out: resolve quickly, then settle — mirrors the deceleration
            // of native spring transitions rather than a constant-rate decode.
            let eased = 1 - pow(1 - linear, 2)
            displayed = scramble(progress: eased)
        }
    }

    /// Build the partially-resolved string. Characters before the resolve
    /// frontier are final; the rest are random glyphs (spaces stay spaces so
    /// word shape is preserved during the reveal).
    private func scramble(progress: Double) -> String {
        let chars = Array(text)
        guard !chars.isEmpty else { return "" }
        let frontier = Int(Double(chars.count) * progress)
        var out = ""
        out.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if i < frontier || ch == " " {
                out.append(ch)
            } else {
                out.append(charset.randomElement() ?? "#")
            }
        }
        return out
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
