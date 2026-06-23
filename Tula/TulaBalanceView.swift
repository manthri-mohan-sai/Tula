import SwiftUI

/// Reusable two-dot-and-beam balance animation — the visual soul of
/// तुला (scales/balance). Used across the app:
///
/// - **Empty states**: breathing animation, scales in perfect balance
/// - **Budget balance**: tilt reflects spent vs remaining
///
/// SwiftUI shapes for crisp rendering. Respects Reduce Motion.
struct TulaBalanceView: View {
    /// -1.0 (fully left-heavy) to +1.0 (fully right-heavy). 0 = balanced.
    var tilt: Double = 0
    /// When true, the entire balance breathes (gentle scale pulse).
    var breathing: Bool = false
    /// Size scaling factor. Default produces ~140pt wide balance.
    var scale: CGFloat = 1.0
    /// Show the तुला label below the beam.
    var showLabel: Bool = false
    /// Optional labels for the two sides (e.g. "Spent" / "Left").
    var leftLabel: String? = nil
    var rightLabel: String? = nil
    /// Tint color for the dots (defaults to brand color).
    var tintColor: Color = .tulaBrandFallback

    @State private var breathePhase: Bool = false

    // MARK: - Layout Constants

    private let dotRadius: CGFloat = 9
    private let beamHalfLength: CGFloat = 60
    private let beamThickness: CGFloat = 2.5

    // MARK: - Body

    var body: some View {
        VStack(spacing: 4) {
            balanceGraphic
            if showLabel {
                Text("तुला")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .scaleEffect(scale * (breathePhase ? 1.04 : 1.0))
        .animation(
            breathing && !AppAnimation.reduceMotion
                ? .easeInOut(duration: 3).repeatForever(autoreverses: true)
                : .default,
            value: breathePhase
        )
        .onAppear {
            if breathing && !AppAnimation.reduceMotion {
                breathePhase = true
            }
        }
        .onChange(of: breathing) { _, newValue in
            if newValue && !AppAnimation.reduceMotion {
                breathePhase = true
            } else {
                breathePhase = false
            }
        }
        .accessibilityHidden(true)
    }

    private var balanceGraphic: some View {
        let clampedTilt = min(max(tilt, -1), 1)
        let angle = Angle.degrees(clampedTilt * 12) // max 12° tilt

        return VStack(spacing: 0) {
            // Beam + dots
            ZStack {
                // Beam line
                Capsule()
                    .fill(tintColor.opacity(0.3))
                    .frame(width: beamHalfLength * 2, height: beamThickness)

                // Left dot + label
                VStack(spacing: 3) {
                    Circle()
                        .fill(tintColor.opacity(clampedTilt < 0 ? 0.85 : 0.35))
                        .frame(width: dotRadius * 2, height: dotRadius * 2)
                    if let leftLabel {
                        Text(leftLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tintColor.opacity(0.8))
                    }
                }
                .offset(x: -beamHalfLength)

                // Right dot + label
                VStack(spacing: 3) {
                    Circle()
                        .fill(tintColor.opacity(clampedTilt > 0 ? 0.85 : 0.35))
                        .frame(width: dotRadius * 2, height: dotRadius * 2)
                    if let rightLabel {
                        Text(rightLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tintColor.opacity(0.8))
                    }
                }
                .offset(x: beamHalfLength)
            }
            .rotationEffect(angle)
            .animation(AppAnimation.gentle, value: tilt)

            // Fulcrum triangle
            Triangle()
                .fill(tintColor.opacity(0.3))
                .frame(width: 16, height: 9)
        }
    }
}

/// Simple triangle shape for the fulcrum.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview("Balanced") {
    TulaBalanceView(tilt: 0, breathing: true, showLabel: true)
}

#Preview("Budget: 70% spent") {
    TulaBalanceView(
        tilt: -0.4,
        leftLabel: "Spent",
        rightLabel: "Left"
    )
}

#Preview("Budget: Over budget") {
    TulaBalanceView(
        tilt: -1.0,
        leftLabel: "Spent",
        rightLabel: "Left",
        tintColor: .red
    )
}
