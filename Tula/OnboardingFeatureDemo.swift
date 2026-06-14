import SwiftUI

/// Interactive animation showing quick-log parsing on the onboarding
/// feature demo page. Simulates typing "450 swiggy lunch" and splitting
/// it into parsed parts that assemble into an expense card.
struct OnboardingFeatureDemo: View {
    @State private var phase: DemoPhase = .idle
    @State private var typedText: String = ""
    @State private var showParsed = false
    @State private var showCard = false

    private let fullText = "450 swiggy lunch"

    private enum DemoPhase {
        case idle, typing, parsing, assembled
    }

    var body: some View {
        VStack(spacing: Spacing.lg) {
            // Typing area
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
                .frame(height: 56)
                .overlay {
                    HStack {
                        Text(typedText)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if phase == .typing {
                            Rectangle()
                                .fill(Color.tulaBrandFallback)
                                .frame(width: 2, height: 20)
                                .opacity(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Spacing.md)
                }

            // Parsed parts
            if showParsed {
                HStack(spacing: Spacing.sm) {
                    parsedPill("₹450", icon: "indianrupeesign", color: .green)
                    parsedPill("Swiggy", icon: "building.2", color: .orange)
                    parsedPill("Food", icon: "fork.knife", color: .tulaBrandFallback)
                }
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            // Assembled card
            if showCard {
                HStack(spacing: Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(Color.tulaBrandFallback.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "fork.knife")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.tulaBrandFallback)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Swiggy")
                            .font(.subheadline.weight(.semibold))
                        Text("Food")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("₹450")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.tulaBrandFallback)
                }
                .padding(Spacing.md)
                .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, Spacing.lg)
        .onAppear { startDemo() }
        .onTapGesture { startDemo() }
    }

    private func parsedPill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }

    private func startDemo() {
        // Reset
        phase = .idle
        typedText = ""
        showParsed = false
        showCard = false

        // Start typing after a brief delay
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            phase = .typing

            // Type each character
            for (i, char) in fullText.enumerated() {
                try? await Task.sleep(for: .milliseconds(60))
                typedText = String(fullText.prefix(i + 1))
                if i == 2 || i == 9 { Haptics.tap() }
            }

            // Pause, then parse
            try? await Task.sleep(for: .milliseconds(400))
            phase = .parsing
            Haptics.selection()
            withAnimation(AppAnimation.bouncy) {
                showParsed = true
            }

            // Assemble into card
            try? await Task.sleep(for: .milliseconds(800))
            phase = .assembled
            Haptics.success()
            withAnimation(AppAnimation.gentle) {
                showParsed = false
            }
            withAnimation(AppAnimation.bouncy) {
                showCard = true
            }
        }
    }
}
