import SwiftUI

/// Home surface for an open gap.
///
/// Rendered as a standalone section rather than a `HomeContext` case or an
/// `Insight`. Both alternatives were rejected deliberately:
/// `HomeView.otherContexts` renders only `insights.first`, so an
/// `Insight`-modelled catch-up card would suppress every other insight; and a
/// new `HomeContext` case falls through `measuredCardHeight`'s `default`
/// branch and clips at 64pt. Styling still matches `contextRowBody` so the
/// card reads as part of the same family.
struct CatchUpCard: View {

    let state: CatchUpState
    let streak: Int
    let action: () -> Void
    let onDismiss: () -> Void

    private let accent: Color = .orange

    /// Width reserved on the trailing edge for the dismiss control. The
    /// dismiss button is a sibling of the main button, not nested inside its
    /// label — a `Button` inside another `Button`'s label does not reliably
    /// receive taps.
    private let dismissSlot: CGFloat = 34

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                cardBody
            }
            .buttonStyle(PressableScaleStyle(scale: 0.98))

            dismissButton
                .padding(.trailing, Spacing.sm)
        }
        .shadow(color: Color(.label).opacity(0.06), radius: 4, y: 2)
    }

    private var cardBody: some View {
        HStack(spacing: Spacing.md) {
            iconDisc

            VStack(alignment: .leading, spacing: 2) {
                Text(state.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: Spacing.sm)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, Spacing.md)
        .padding(.trailing, dismissSlot + Spacing.sm)
        .padding(.vertical, Spacing.md)
        .frame(minHeight: 64, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.headline)
        .accessibilityHint("Double tap to catch up on missed days")
    }

    private var dismissButton: some View {
        Button {
            Haptics.tap()
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: dismissSlot, height: dismissSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss catch-up")
    }

    private var iconDisc: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.15))
                .frame(width: 38, height: 38)
            Image(systemName: "clock.arrow.circlepath")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(accent)
        }
    }

    /// Neutral and specific. No loss framing — guilt drives avoidance, which
    /// is the churn this whole feature exists to reverse.
    private var subtitle: String {
        let base = state.detail()
        // Mention the streak only when there is one worth protecting, and
        // frame it as recoverable rather than as already lost.
        if streak >= 3, state.unloggedCount > 0 {
            return base.isEmpty
                ? "Fill them in to keep your \(streak)-day streak."
                : base + " · keeps your \(streak)-day streak"
        }
        return base.isEmpty ? "Tap to catch up." : base
    }
}
