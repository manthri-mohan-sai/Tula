import SwiftUI

/// An Apple-Fitness-style activity ring.
///
/// - Sweeps continuously past 100%, overlapping itself lap after lap.
/// - The leading cap casts a soft, forward-only shadow onto the lap beneath it,
///   giving the "ring on top" elevation from the Fitness app.
/// - Conic gradient runs light → dark around each lap; each deeper lap is
///   slightly darker, so overlaps read as stacked depth.
/// - Respects Reduce Motion, restarts the sweep when `progress` changes.
struct ActivityRingView: View {

    // MARK: - Configuration

    /// 1.0 = one full lap. Values > 1 overlap (e.g. 2.42 = 242%).
    var progress: Double
    var ringColor: Color
    var lineWidth: CGFloat = 16

    /// Optional explicit gradient endpoints for lap 0. Defaults: start = a
    /// darkened variant of `ringColor`, end = `ringColor` (dark → light).
    /// Supplying a *lighter* start than end flips the whole chain's direction.
    var gradientStartColor: Color? = nil
    var gradientEndColor: Color? = nil

    var trackOpacity: Double = 0.15

    /// Per-lap brightness step ratio (×0.78 darkening, ÷0.78 lightening).
    /// Lower = stronger visible gradient per lap.
    var lapDarkening: Double = 0.78

    /// Subtle hue rotation per lap (fraction of the color wheel, negative = cooler)
    /// so consecutive laps stay distinguishable.
    var lapHueShift: Double = -0.035

    /// Brightness band the lap chain ping-pongs inside. The sweep keeps
    /// lightening lap after lap until the *next* step would leave the top of
    /// this band, then reverses toward dark from that exact color — and turns
    /// back toward light before sinking below the bottom. Never too light,
    /// never too dark, always moving.
    var brightnessRange: ClosedRange<Double> = 0.30...0.95

    /// Explicit sweep duration. When nil, duration scales with progress
    /// (more laps = a longer, more dramatic sweep), capped at 4s.
    var animationDuration: Double? = nil
    var isAnimated: Bool = true
    var startDelay: Double = 0.15

    // MARK: - State

    @State private var animationStart: Date?
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: Double {
        animationDuration ?? min(max(progress, 0.35) * 1.4, 4.0)
    }

    var body: some View {
        TimelineView(.animation(paused: finished)) { timeline in
            Canvas { context, size in
                drawRing(in: context, size: size, progress: currentProgress(at: timeline.date))
            }
        }
        .onAppear(perform: scheduleStart)
        .onChange(of: progress) { _, _ in restart() }
        .accessibilityElement()
        .accessibilityLabel("Activity ring")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    // MARK: - Animation Driver

    private func scheduleStart() {
        guard isAnimated, !reduceMotion else {
            finished = true
            return
        }
        // Already animated — keep showing final state on re-appear
        guard animationStart == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + startDelay) {
            animationStart = Date()
        }
    }

    private func restart() {
        finished = false
        animationStart = nil
        scheduleStart()
    }

    private func currentProgress(at date: Date) -> Double {
        guard isAnimated, !reduceMotion else { return progress }
        guard let start = animationStart else { return 0 }

        let elapsed = date.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }

        let t = min(elapsed / duration, 1.0)
        if t >= 1.0, !finished {
            DispatchQueue.main.async { finished = true }
        }
        return progress * (1 - pow(1 - t, 3)) // cubic ease-out
    }

    // MARK: - Core Rendering

    private func drawRing(in context: GraphicsContext, size: CGSize, progress p: Double) {
        let w = lineWidth
        let r = min(size.width, size.height) / 2 - w / 2
        guard r > 0 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let val = max(p, 0)

        let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

        // 1. Background track
        context.stroke(circle,
                       with: .color(ringColor.opacity(trackOpacity)),
                       style: StrokeStyle(lineWidth: w))

        guard val > 0.0001 else { return }

        var laps = Int(val)
        var fraction = val.truncatingRemainder(dividingBy: 1.0)
        if fraction == 0 { laps -= 1; fraction = 1.0 } // exact multiples: treat as full lap
        let overlapping = laps > 0

        // 2. The single lap directly beneath the tip.
        //    (Deeper laps are fully covered — drawing them is wasted work.)
        if overlapping {
            let below = lapGradient(laps - 1)
            context.stroke(circle,
                           with: shading(start: below.start, end: below.end, center: c),
                           style: StrokeStyle(lineWidth: w))
        }

        // 3. Current lap arc (butt caps; rounded ends are drawn as explicit cap circles)
        let lap = lapGradient(laps)
        let lapStart = lap.start
        let lapEnd = lap.end
        let arc = arcPath(center: c, radius: r, fraction: fraction)
        context.stroke(arc,
                       with: shading(start: lapStart, end: lapEnd, center: c),
                       style: StrokeStyle(lineWidth: w, lineCap: .butt))

        // 4. Rounded start cap at 12 o'clock — first lap only.
        //    On later laps the lap below hides the seam, and a cap here would double-bulge.
        if !overlapping {
            context.fill(capPath(at: -.pi / 2, center: c, radius: r, width: w),
                         with: .color(lapStart))
        }

        // 5. Leading tip + forward-only elevation shadow
        let tipAngle = -Double.pi / 2 + 2 * .pi * fraction
        let tipColor = interpolated(from: lapStart, to: lapEnd, t: fraction)
        let tip = capPath(at: tipAngle, center: c, radius: r, width: w)

        // Shadow strength: full while overlapping; fades in as the first lap
        // closes on its own start cap, so it never pops.
        let closing = max(0, min(1, (fraction - 0.92) / 0.08))
        let shadowStrength = overlapping ? 1.0 : closing

        if shadowStrength > 0 {
            // The color sitting directly UNDER the tip right now: the lap
            // below sampled at the same angle (or our own start cap on lap 0).
            let underTip: Color = overlapping
                ? {
                    let below = lapGradient(laps - 1)
                    return interpolated(from: below.start, to: below.end, t: fraction)
                }()
                : lapStart

            // Contrast guarantee: when the tip color and the color beneath it
            // converge (it happens around the chain's ping-pong reversals —
            // the descending lap must cross back through the ascending one),
            // pure color can't separate them. Measure the actual luminance
            // gap each frame and let the shadow pick up the slack: near-zero
            // contrast → deep, wide shadow; strong contrast → subtle,
            // Apple-like shadow. The tip is always clearly visible, for any
            // ring color, at any progress.
            let gap = abs(luminance(of: tipColor) - luminance(of: underTip))
            let boost = 1.0 - min(gap / 0.25, 1.0) // 0 (plenty of contrast) … 1 (identical colors)
            let shadowOpacity = (0.40 + 0.35 * boost) * shadowStrength
            let shadowRadius = w * (0.35 + 0.25 * boost)

            // Clip to a wedge *ahead* of the tip so the shadow is cast only
            // forward onto the lap below — never backwards along the arc.
            var wedge = Path()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: r + w,
                         startAngle: .radians(tipAngle - 0.02),
                         endAngle: .radians(tipAngle + .pi / 2),
                         clockwise: false)
            wedge.closeSubpath()

            let offset = w * (0.15 + 0.10 * boost) // nudge the shadow along the direction of travel
            context.drawLayer { ctx in
                ctx.clip(to: wedge)
                // Intersect with the ring band itself — the shadow may only land
                // on the lap beneath, never spill onto the (transparent) background.
                ctx.clip(to: circle.strokedPath(StrokeStyle(lineWidth: w)))
                ctx.addFilter(.shadow(color: .black.opacity(shadowOpacity),
                                      radius: shadowRadius,
                                      x: -sin(tipAngle) * offset,
                                      y: cos(tipAngle) * offset))
                ctx.fill(tip, with: .color(tipColor))
            }
        }

        // Pristine tip cap rendered cleanly on top of the shadow layer
        context.fill(tip, with: .color(tipColor))
    }

    // MARK: - Geometry Helpers

    private func arcPath(center: CGPoint, radius: CGFloat, fraction: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(-.pi / 2),
                    endAngle: .radians(-.pi / 2 + 2 * .pi * fraction),
                    clockwise: false)
        return path
    }

    private func capPath(at angle: Double, center: CGPoint, radius: CGFloat, width: CGFloat) -> Path {
        let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)),
                            y: center.y + radius * CGFloat(sin(angle)))
        return Path(ellipseIn: CGRect(x: point.x - width / 2, y: point.y - width / 2,
                                      width: width, height: width))
    }

    // MARK: - Color Engine

    /// 12 o'clock color of lap 0 — a darkened variant of the ring color.
    private var baseStart: Color {
        gradientStartColor ?? shifted(ringColor, brightnessFactor: 0.62, hue: 0)
    }

    /// Tip color of lap 0 — the ring color itself, fully lit.
    private var baseEnd: Color { gradientEndColor ?? ringColor }

    /// The chained, ping-ponging lap gradient.
    ///
    /// Lap N always *starts* with exactly the color lap N-1 *ended* with, so
    /// the sweep is continuous across 12 o'clock. The brightness direction is
    /// carried lap to lap: the ring keeps getting lighter until the next step
    /// would leave the top of `brightnessRange`, then reverses (light → dark)
    /// from that exact color — and turns back toward light again before it
    /// would sink past the bottom. The gradient never washes out, never goes
    /// black, and never stops moving.
    private func lapGradient(_ lap: Int) -> (start: Color, end: Color, lightening: Bool) {
        guard lap > 0 else {
            // Direction inferred from lap 0's endpoints, so custom
            // gradientStart/EndColor overrides flip the whole chain naturally.
            return (baseStart, baseEnd, brightness(of: baseEnd) >= brightness(of: baseStart))
        }

        let previous = lapGradient(lap - 1)
        let start = previous.end // seamless handoff at 12 o'clock

        var lightening = previous.lightening
        let b = brightness(of: start)
        if lightening, b / lapDarkening > brightnessRange.upperBound {
            lightening = false // next step would be too light — turn back toward dark
        } else if !lightening, b * lapDarkening < brightnessRange.lowerBound {
            lightening = true // next step would be too dark — turn back toward light
        }

        let factor = lightening ? 1.0 / lapDarkening : lapDarkening
        return (start, shifted(start, brightnessFactor: factor, hue: lapHueShift), lightening)
    }

    private func brightness(of color: Color) -> Double {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(b)
    }

    /// Perceptual luminance (Rec. 709) — how light a color actually *looks*,
    /// which is what tip-vs-background visibility depends on.
    private func luminance(of color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0.5 }
        return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
    }

    /// Applies one brightness step (and a subtle hue drift) to a color.
    private func shifted(_ color: Color, brightnessFactor factor: Double, hue shift: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        var newHue = (Double(h) + shift).truncatingRemainder(dividingBy: 1.0)
        if newHue < 0 { newHue += 1 }

        return Color(hue: newHue,
                     saturation: min(Double(s) * 1.05, 1.0),
                     brightness: min(max(Double(b) * factor, 0.0), 1.0))
    }

    private func interpolated(from start: Color, to end: Color, t: Double) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard UIColor(start).getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              UIColor(end).getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return start }
        let f = CGFloat(t)
        return Color(red: Double(r1 + (r2 - r1) * f),
                     green: Double(g1 + (g2 - g1) * f),
                     blue: Double(b1 + (b2 - b1) * f))
    }

    private func shading(start: Color, end: Color, center: CGPoint) -> GraphicsContext.Shading {
        .conicGradient(Gradient(stops: [.init(color: start, location: 0),
                                        .init(color: end, location: 1)]),
                       center: center,
                       angle: .degrees(-90))
    }
}

// MARK: - Previews

#Preview("65% — partial lap") {
    ActivityRingView(progress: 0.65, ringColor: Color(red: 0.98, green: 0.15, blue: 0.45), lineWidth: 24)
        .frame(width: 160, height: 160)
        .padding()
}

#Preview("100% — ring just closed") {
    ActivityRingView(progress: 1.0, ringColor: .green, lineWidth: 24)
        .frame(width: 160, height: 160)
        .padding()
}

#Preview("242% — multi-lap overlap") {
    ActivityRingView(progress: 2.42, ringColor: Color(red: 0.7, green: 0.1, blue: 0.1), lineWidth: 24)
        .frame(width: 160, height: 160)
        .padding()
}

#Preview("Custom gradient + slow sweep") {
    ActivityRingView(progress: 1.8,
                     ringColor: .cyan,
                     lineWidth: 24,
                     gradientStartColor: .cyan,
                     gradientEndColor: .blue,
                     animationDuration: 3.0)
        .frame(width: 180, height: 180)
        .padding()
}
