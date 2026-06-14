import SwiftUI

/// Continuous progress bar for onboarding. A single track fills
/// smoothly as the user advances through steps.
struct OnboardingProgressBar: View {
    let totalSteps: Int
    let currentStep: Int

    private var progress: CGFloat {
        guard totalSteps > 1 else { return 1 }
        return CGFloat(currentStep) / CGFloat(totalSteps - 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))

                Capsule()
                    .fill(Color.tulaBrandFallback)
                    .frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 4)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: currentStep)
    }
}
