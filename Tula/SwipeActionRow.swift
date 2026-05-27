import SwiftUI

/// A row with iOS-style trailing swipe actions, built from scratch so it
/// works inside our custom card containers (not just plain Lists).
///
/// Swipe left to reveal Edit + Delete buttons. Swipe-and-flick reveals fully
/// in one motion; partial drags snap to nearest state. Tapping the row when
/// closed runs `onTap`; tapping when open snaps closed first.
///
/// All animations use a calibrated spring for natural feel. Haptics fire
/// at meaningful transitions: opening, closing, and action invocation.
struct SwipeActionRow<Content: View>: View {
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var hasReachedOpenThreshold = false

    private let actionWidth: CGFloat = 76
    private var maxReveal: CGFloat { actionWidth * 2 }

    /// Threshold at which a partial drag commits to "open" on release.
    private var openThreshold: CGFloat { -actionWidth * 0.65 }

    var body: some View {
        ZStack(alignment: .trailing) {
            actionsBackground
            foreground
        }
        // Critical for clean swipes inside scroll containers — the parent's
        // shape gets passed down so action buttons clip cleanly.
        .contentShape(Rectangle())
    }

    // MARK: - Background actions

    private var actionsBackground: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            // Edit (blue)
            Button {
                Haptics.tap()
                close()
                // Defer the action slightly so the close animation feels intentional
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    onEdit()
                }
            } label: {
                actionLabel(icon: "pencil", title: "Edit")
                    .background(Color.blue)
            }

            // Delete (red)
            Button {
                Haptics.warning()
                close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    onDelete()
                }
            } label: {
                actionLabel(icon: "trash", title: "Delete")
                    .background(Color.red)
            }
        }
    }

    private func actionLabel(icon: String, title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(width: actionWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Foreground content

    private var foreground: some View {
        content()
            .background(Color.tulaCardSurface)
            .offset(x: offset)
            .onTapGesture {
                if offset != 0 {
                    close()
                } else {
                    onTap()
                }
            }
            .simultaneousGesture(swipeGesture)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        // minimumDistance > 0 prevents this from stealing taps. The
        // simultaneousGesture attachment lets the parent ScrollView still
        // handle vertical scrolls without conflict.
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // Reject predominantly-vertical drags — the parent scroll view
                // should handle those.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                // Clamp: only leftward (negative); rubberband past max reveal.
                let raw = value.translation.width
                if raw < -maxReveal {
                    offset = -maxReveal + (raw + maxReveal) * 0.25
                } else if raw > 0 {
                    offset = raw * 0.20   // gentle rightward resistance when already closed
                } else {
                    offset = raw
                }

                // Crossing into "definitely open" gives a haptic tick.
                if !hasReachedOpenThreshold && offset < openThreshold {
                    hasReachedOpenThreshold = true
                    Haptics.selection()
                }
            }
            .onEnded { value in
                hasReachedOpenThreshold = false
                let velocity = value.predictedEndTranslation.width - value.translation.width
                let projectedOffset = offset + velocity * 0.3

                if projectedOffset < openThreshold {
                    open()
                } else {
                    close()
                }
            }
    }

    private func open() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            offset = -maxReveal
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            offset = 0
        }
    }
}
