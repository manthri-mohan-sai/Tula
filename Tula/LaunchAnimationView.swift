import SwiftUI

/// **Equilibrium** — Tula's launch animation.
///
/// Two white dots enact the meaning of तुला (scales / balance): they
/// emerge from a single point, drift apart, oscillate like a physical
/// balance beam finding equilibrium, settle level. A subtle तुला
/// wordmark fades in below. Then — the closing gesture — the dots
/// converge back to center forming a single circle, which grows
/// outward as a circular portal, **revealing the home view through
/// it**. The portal expands beyond the screen and the user is in
/// the app.
///
/// **Why no glyph, no calligraphy, no headline.** Tula means
/// equilibrium. The animation should *be* equilibrium, not narrate
/// it via text. Two dots finding balance is the literal mechanism
/// the word names — the same way Apple's Camera aperture animation
/// references a lens. Brand idea expressed as motion, not typography.
///
/// **Why the circular reveal at the end.** It closes the visual
/// loop the animation opened: started as a single point (the seed
/// of equilibrium), ends as a single point (the same dot, becoming
/// a portal). The home view emerges *from within* the equilibrium —
/// not behind it, not below it, but *through* it. The brand idea
/// (balance) literally contains the product (the app).
///
/// **Timeline (~2.95s):**
///   • 0.00 – 0.18s — single dot fades in at center
///   • 0.22 – 0.62s — dot splits, drifts apart; beam draws between
///   • 0.68 – 1.46s — three damped oscillations finding balance
///   • 1.46s        — settled; quiet haptic
///   • 1.46 – 1.68s — तुला wordmark fades in below
///   • 1.68 – 1.92s — dwell
///   • 1.92 – 2.14s — convergence: dots return to center
///   • 2.14 – 2.26s — dot compresses (elastic tension)
///   • 2.26 – 2.46s — spring release with velocity
///   • 2.46s        — portal opens with spring physics, dot fades
///   • 2.46 – 2.90s — portal grows: home view revealed
///   • 2.95s        — onComplete fires; overlay removed
///
/// **Tap anywhere** to skip to home immediately.
struct LaunchAnimationView: View {

    let onComplete: () -> Void

    // MARK: - Dot state

    @State private var dotOpacity: Double = 0
    @State private var leftDotX: CGFloat = 0
    @State private var rightDotX: CGFloat = 0
    @State private var leftDotY: CGFloat = 0
    @State private var rightDotY: CGFloat = 0

    // MARK: - Beam state

    @State private var beamWidth: CGFloat = 0
    @State private var beamOpacity: Double = 0

    // MARK: - Wordmark state

    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkOffset: CGFloat = 4

    // MARK: - Portal reveal state

    /// Radius of the circular portal that grows out of the merged
    /// dot, "punching" a hole in the amber to reveal the home view
    /// behind it. Starts at 0 (no portal) and grows to ~1500 (much
    /// larger than any iPhone screen, ensuring full coverage).
    @State private var portalRadius: CGFloat = 0

    /// Scale of the dot group. Stays 1.0 through the balance
    /// animation, compresses after convergence to build spring
    /// tension, then bounces back before the portal opens.
    @State private var dotScale: CGFloat = 1.0

    @State private var hasStarted = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // ─── Layer 1: amber with circular portal ────────────
                //
                // The amber background fills the screen. A Circle of
                // increasing radius is overlaid with .destinationOut
                // blend mode, which "erases" the amber where the
                // circle is. `.compositingGroup()` confines the blend
                // to just this group — so it eats the amber but does
                // NOT eat the dots, beam, or wordmark rendered above.
                //
                // What appears in the hole: whatever is behind THIS
                // entire view in TulaApp's parent ZStack — i.e., the
                // home view. So as portalRadius grows, more of the
                // home view is revealed through the expanding circle.
                Color.tulaLaunchBackground
                    .ignoresSafeArea()
                    .overlay {
                        Circle()
                            .fill(.white)
                            .frame(
                                width: portalRadius * 2,
                                height: portalRadius * 2
                            )
                            .position(
                                x: geo.size.width / 2,
                                y: geo.size.height * 0.46
                            )
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    .ignoresSafeArea()

                // ─── Layer 2: dots + connecting beam ────────────────
                //
                // Positioned at the same anchor (46% from top) as the
                // portal so when the dots converge back to center
                // they sit exactly where the portal opens — visual
                // continuity is preserved (the dot doesn't "jump"
                // before becoming a portal).
                ZStack {
                    Rectangle()
                        .fill(.white.opacity(0.55))
                        .frame(width: beamWidth, height: 1.5)
                        .rotationEffect(beamRotation)
                        .opacity(beamOpacity)

                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .offset(x: leftDotX, y: leftDotY)
                        .opacity(dotOpacity)

                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .offset(x: rightDotX, y: rightDotY)
                        .opacity(dotOpacity)
                }
                .scaleEffect(dotScale)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.46)

                // ─── Layer 3: तुला wordmark + tagline at ~85% ────────
                // Wordmark on top, tagline beneath. Both fade together
                // via the same wordmarkOpacity/offset state so they
                // arrive as one unit, not two staggered elements.
                VStack(spacing: 6) {
                    Text("तुला")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Balance your spend")
                        .font(.system(size: 11, weight: .regular))
                        .tracking(2)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.62))
                }
                .opacity(wordmarkOpacity)
                .offset(y: wordmarkOffset)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.83)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            runTimeline()
        }
    }

    /// Beam tilt computed from the dots' vertical offsets. Beam pivots
    /// around its center, so an asymmetry in y-positions shows up as
    /// a rotation that reads as "tilt."
    private var beamRotation: Angle {
        // 160 = horizontal span between dot centers (from -80 to +80).
        .radians(atan2(Double(rightDotY - leftDotY), 160))
    }

    private func runTimeline() {
        // 0.00 – 0.18s — single dot fades in
        withAnimation(.easeOut(duration: 0.18)) {
            dotOpacity = 1.0
        }

        // 0.22 – 0.62s — split + beam draw
        // Smooth deceleration curve; beam shares it exactly.
        let splitCurve = Animation.timingCurve(0.25, 0.1, 0.25, 1.0, duration: 0.40).delay(0.22)
        withAnimation(splitCurve) {
            leftDotX = -80
            rightDotX = 80
            beamWidth = 160
            beamOpacity = 1.0
        }

        // 0.68 – 1.42s — three damped oscillations
        // Softer easing (easeInOut feel) so tilt flows naturally.
        let swings: [(delay: Double, leftY: CGFloat, rightY: CGFloat, dur: Double)] = [
            (0.68, -22,  22, 0.28),
            (0.96,  12, -12, 0.24),
            (1.20,  -5,   5, 0.16),
            (1.36,   0,   0, 0.10),
        ]
        for swing in swings {
            withAnimation(.timingCurve(0.42, 0.0, 0.58, 1.0, duration: swing.dur).delay(swing.delay)) {
                leftDotY = swing.leftY
                rightDotY = swing.rightY
            }
        }

        // 1.46s — haptic at equilibrium
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.46) {
            Haptics.tap()
        }

        // 1.46 – 1.68s — तुला wordmark appears
        withAnimation(.easeOut(duration: 0.22).delay(1.46)) {
            wordmarkOpacity = 1.0
            wordmarkOffset = 0
        }

        // 1.92 – 2.14s — CONVERGENCE.
        // Same smooth curve as split, reversed.
        withAnimation(.timingCurve(0.25, 0.0, 0.25, 1.0, duration: 0.22).delay(1.92)) {
            leftDotX = 0
            rightDotX = 0
            beamWidth = 0
            beamOpacity = 0
            wordmarkOpacity = 0
        }

        // 2.14 – 2.26s — COMPRESS.
        withAnimation(.easeIn(duration: 0.12).delay(2.14)) {
            dotScale = 0.4
        }

        // 2.26s — SPRING RELEASE.
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 200, damping: 10, initialVelocity: 10).delay(2.26)) {
            dotScale = 1.5
        }

        // Haptic at peak of first overshoot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.38) {
            Haptics.impact()
        }

        // 2.46s — PORTAL OPENS with spring physics.
        withAnimation(.easeIn(duration: 0.20).delay(2.46)) {
            dotOpacity = 0
        }
        withAnimation(.spring(response: 1.0, dampingFraction: 0.82).delay(2.46)) {
            portalRadius = 1500
        }

        // 3.50s — Hand off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.50) {
            onComplete()
        }
    }

    /// Skip flow — instantly opens the portal to full size. Total
    /// duration ~0.5s. The dot fades quickly as the portal grows.
    private func skip() {
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.12)) {
            dotOpacity = 0
            wordmarkOpacity = 0
            leftDotX = 0
            rightDotX = 0
            leftDotY = 0
            rightDotY = 0
            beamWidth = 0
            dotScale = 1.0
        }
        withAnimation(.easeInOut(duration: 0.45)) {
            portalRadius = 1500
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            onComplete()
        }
    }
}

#Preview {
    LaunchAnimationView(onComplete: {})
}
