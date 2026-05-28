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
/// **Timeline (~4.0s):**
///   • 0.00 – 0.30s — single dot fades in at center
///   • 0.40 – 0.85s — dot splits, drifts apart; beam draws between
///   • 0.95 – 1.85s — three damped oscillations finding balance
///   • 1.85s        — settled; quiet haptic
///   • 1.95 – 2.30s — तुला wordmark fades in below
///   • 2.30 – 2.85s — dwell — the settled moment is held
///   • 2.85 – 3.15s — convergence: dots return to center, beam
///                    collapses to zero, wordmark fades
///   • 3.15s        — single dot at center; portal begins to open
///   • 3.15 – 3.95s — portal grows: home view revealed inside the
///                    circle as it expands beyond screen edges
///   • 3.95s        — portal exits screen, home view fully exposed,
///                    onComplete fires; launch overlay is removed
///                    (invisible at that point, no visible change)
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
                Color.tulaBrandFallback
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
                .position(x: geo.size.width / 2, y: geo.size.height * 0.46)

                // ─── Layer 3: तुला wordmark at 85% ──────────────────
                Text("तुला")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .opacity(wordmarkOpacity)
                    .offset(y: wordmarkOffset)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.85)
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
        // 0.00 – 0.30s — single dot fades in
        withAnimation(.easeOut(duration: 0.30)) {
            dotOpacity = 1.0
        }

        // 0.40 – 0.85s — split + beam draw
        withAnimation(.timingCurve(0.34, 0.0, 0.18, 1.0, duration: 0.50).delay(0.40)) {
            leftDotX = -80
            rightDotX = 80
        }
        withAnimation(.easeOut(duration: 0.45).delay(0.45)) {
            beamWidth = 160
            beamOpacity = 1.0
        }

        // 0.95 – 1.85s — three damped oscillations
        let swings: [(delay: Double, leftY: CGFloat, rightY: CGFloat, dur: Double)] = [
            (0.95, -24,  24, 0.32),
            (1.27,  14, -14, 0.30),
            (1.55,  -6,   6, 0.26),
            (1.79,   0,   0, 0.18),
        ]
        for swing in swings {
            withAnimation(.timingCurve(0.45, 0.0, 0.55, 1.0, duration: swing.dur).delay(swing.delay)) {
                leftDotY = swing.leftY
                rightDotY = swing.rightY
            }
        }

        // 1.95s — haptic at equilibrium
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.95) {
            Haptics.tap()
        }

        // 1.95 – 2.30s — तुला wordmark appears
        withAnimation(.easeOut(duration: 0.35).delay(1.95)) {
            wordmarkOpacity = 1.0
            wordmarkOffset = 0
        }

        // 2.85 – 3.15s — CONVERGENCE. The two dots return to center
        // and overlap, forming a single circle. Beam collapses to 0
        // (so it's invisible — no horizontal line is left dangling
        // out from the merged dot). Wordmark fades. By 3.15s the
        // screen is: amber + single white dot at center.
        withAnimation(.easeInOut(duration: 0.30).delay(2.85)) {
            leftDotX = 0
            rightDotX = 0
            beamWidth = 0
            wordmarkOpacity = 0
        }

        // 3.15s — PORTAL OPENS. The portal circle starts growing
        // from the exact position (and initial radius matching) the
        // merged dot. We fade the dot opacity in parallel: by the
        // time the portal is ~30pt radius (slightly larger than the
        // 11pt dot radius), the dot has fully faded — so what the
        // user perceives is the single dot transforming directly
        // into a growing window onto the app.
        withAnimation(.easeIn(duration: 0.18).delay(3.15)) {
            dotOpacity = 0
        }

        // 3.15 – 3.95s — Portal grows. easeInOut(0.80) — gentle start
        // (so the eye registers the moment of "opening"), accelerating
        // through the middle (you feel pulled in), settling at the
        // edges (no jolt when it exits screen). 1500 covers every
        // iPhone screen with margin.
        withAnimation(.easeInOut(duration: 0.80).delay(3.15)) {
            portalRadius = 1500
        }

        // 3.95s — Hand off. The portal has exited the screen; what
        // the user sees IS the home view. Removing the overlay from
        // the hierarchy at this point is visually a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.95) {
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
