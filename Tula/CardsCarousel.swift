import SwiftUI

/// Wallet-style vertical card stack with a clear separation between
/// **tap** (open), **drag** (rearrange — collapsed mode only), and the
/// **toolbar button** (expand/collapse).
///
/// **Resting state:** cards stack top-to-bottom, each peeking 54pt below
/// the previous. The bottommost card is the "active" one — fully visible,
/// and its data drives the section below the stack on CardsView.
///
/// **Tap — always opens detail.**
/// Tapping any card navigates to its detail screen (zoom transition). Same
/// behavior in collapsed and expanded mode. No state-dependent meaning.
///
/// **Drag — rearranges the stack (collapsed mode only).**
/// In collapsed mode, dragging a card down past 60pt commits a change:
/// - Non-bottom card → it slides to the bottom (becomes active).
/// - Bottom card → the stack expands.
///
/// In **expanded mode the drag gesture is intentionally not installed**.
/// This frees the parent ScrollView to handle vertical drags, which is
/// essential because the expanded stack typically exceeds the screen
/// height. To return to collapsed mode, use the toolbar button.
///
/// **Why this trade:** drag-to-collapse was a clever gesture but it broke
/// scrolling in expanded mode (the only mode where scrolling is needed).
/// Trading drag-to-collapse for working scroll is the right call — the
/// toolbar button is clearly visible and one tap.
///
/// The reordered state is held in `orderedIDs` (a binding owned by the
/// parent — usually CardsView); if accounts are added or removed
/// externally, the order is preserved for existing IDs and new entries
/// get appended at the end.
struct CardsCarousel: View {
    let accounts: [Account]
    let namespace: Namespace.ID
    let onTap: (Account) -> Void

    /// When true the stack expands into a vertical list with no overlap.
    /// Driven by the parent (CardsView) so the toolbar button can also
    /// toggle it.
    @Binding var isExpanded: Bool

    /// User-induced ordering, owned by the parent. Empty until the first
    /// tap or drag — once populated, takes precedence over the parent-
    /// provided `accounts` order. Exposed as a binding so the parent can
    /// react to changes (e.g. show the active card's transactions below).
    @Binding var orderedIDs: [UUID]

    /// Index of the card currently being dragged (nil when not dragging).
    @State private var dragIndex: Int? = nil

    /// Vertical translation of the dragged card from its slot.
    @State private var dragOffset: CGFloat = 0

    private let cardHeight: CGFloat = 168
    private let peekAmount: CGFloat = 54
    private let expandedGap: CGFloat = 14
    /// Vertical room reserved below the bottommost card for its drop
    /// shadows. The colored bloom shadow has radius 14 + y-offset 8 = ~22pt
    /// of visual extent below the card edge, plus the black depth shadow
    /// (~9pt). 36pt buffer clears both and keeps a small visual gap before
    /// whatever section sits underneath.
    private let shadowBuffer: CGFloat = 36

    /// Single drag-commit threshold used for **every** drag-triggered
    /// action — lift-to-bottom, expand, collapse. One number to learn;
    /// nothing arbitrary about why one gesture commits sooner than another.
    private let dragCommitThreshold: CGFloat = 60

    /// Merges the local reordering state with the parent's accounts array.
    private var orderedAccounts: [Account] {
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var result: [Account] = []
        var seen: Set<UUID> = []
        for id in orderedIDs {
            if let account = byID[id], !seen.contains(id) {
                result.append(account)
                seen.insert(id)
            }
        }
        for account in accounts where !seen.contains(account.id) {
            result.append(account)
            seen.insert(account.id)
        }
        return result
    }

    /// Slot spacing — peek in collapsed mode, full card height + gap when
    /// expanded so cards don't overlap.
    private var slotSpacing: CGFloat {
        isExpanded ? (cardHeight + expandedGap) : peekAmount
    }

    /// Total height the stack occupies. Driven by the current mode so the
    /// parent layout shrinks/grows as the stack expands.
    private var stackHeight: CGFloat {
        guard !accounts.isEmpty else { return 0 }
        if isExpanded {
            return CGFloat(accounts.count) * (cardHeight + expandedGap) - expandedGap + shadowBuffer
        }
        return CGFloat(accounts.count - 1) * peekAmount + cardHeight + shadowBuffer
    }

    /// Y position for the card at `index`. Slot offset + drag offset if
    /// this card is the one currently being dragged.
    private func cardOffsetY(_ index: Int) -> CGFloat {
        var y = CGFloat(index) * slotSpacing
        if dragIndex == index { y += dragOffset }
        return y
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(orderedAccounts.enumerated()), id: \.element.id) { index, account in
                cardLayer(index: index, account: account)
            }
        }
        .frame(height: stackHeight)
    }

    /// One card's view layer. Pulled out of the body so the gesture
    /// can be conditionally attached — in **expanded mode** the per-card
    /// drag gesture is intentionally NOT installed, so vertical drags pass
    /// straight through to the parent ScrollView and scrolling works
    /// naturally. To collapse from expanded mode, use the toolbar button.
    ///
    /// In **collapsed mode** the drag gesture is the rearrange mechanism
    /// (lift-to-active or expand). It captures input because the stack
    /// fits in the screen and no scrolling is needed for the cards
    /// themselves.
    @ViewBuilder
    private func cardLayer(index: Int, account: Account) -> some View {
        let base = AccountCardView(account: account)
            .frame(height: cardHeight)
            .matchedTransitionSource(id: account.id, in: namespace)
            .offset(y: cardOffsetY(index))
            // Dragged card floats above the stack while held.
            .zIndex(dragIndex == index ? 1000 : Double(index))
            // Subtle scale-up when dragging — feels "picked up".
            .scaleEffect(dragIndex == index ? 1.02 : 1.0)
            .shadow(
                color: .black.opacity(dragIndex == index ? 0.20 : 0),
                radius: dragIndex == index ? 18 : 0,
                y: dragIndex == index ? 12 : 0
            )
            .onTapGesture { handleTap(index: index) }

        if isExpanded {
            // No drag gesture — ScrollView handles vertical input.
            base
        } else {
            base.gesture(dragGesture(forIndex: index))
        }
    }

    // MARK: - Gestures

    /// Per-card drag gesture, **only installed in collapsed mode** (see
    /// `cardLayer(index:account:)`). When the user pulls a card down past
    /// `dragCommitThreshold`:
    ///  - **Non-bottom card** → it lifts to the bottom (becomes active).
    ///  - **Bottom card** → the stack expands (its only valid "down"
    ///    action, since it has nothing below it in the stack).
    ///
    /// Wrong-direction drag rubberbands and snaps back. To collapse from
    /// expanded mode, the user uses the toolbar button — no drag here.
    private func dragGesture(forIndex index: Int) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if dragIndex == nil { dragIndex = index }
                guard dragIndex == index else { return }

                let raw = value.translation.height
                let isBottom = index == orderedAccounts.count - 1
                if isBottom {
                    // Bottom card: downward drag tracks lightly damped so
                    // the user has to commit to expand, not flick.
                    dragOffset = raw > 0 ? raw * 0.7 : raw * 0.15
                } else {
                    // Non-bottom: downward follows finger 1:1, upward
                    // rubberbands (can't escape the top).
                    dragOffset = raw > 0 ? raw : raw * 0.15
                }
            }
            .onEnded { value in
                guard dragIndex == index else { return }
                let translation = value.translation.height
                let isBottom = index == orderedAccounts.count - 1

                if isBottom && translation > dragCommitThreshold {
                    Haptics.impact()
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                        isExpanded = true
                        dragOffset = 0
                    }
                } else if !isBottom && translation > dragCommitThreshold {
                    Haptics.selection()
                    liftToBottom(index)
                } else {
                    snapBack()
                }
                dragIndex = nil
            }
    }

    private func snapBack() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            dragOffset = 0
        }
    }

    /// Tap always opens the card's detail screen. No state-dependent
    /// branching — tap means "open this," whether the card is the active
    /// one or not, whether the stack is collapsed or expanded. To bring a
    /// card to the active (bottom) position without opening it, drag it
    /// down instead.
    private func handleTap(index: Int) {
        Haptics.tap()
        onTap(orderedAccounts[index])
    }

    /// Move the card at `index` to the end of the order so it occupies the
    /// bottom (active) slot. Animates both the array shuffle and the drag
    /// offset reset together so the card glides smoothly to its new slot.
    private func liftToBottom(_ index: Int) {
        var newOrder = orderedAccounts.map(\.id)
        let id = newOrder.remove(at: index)
        newOrder.append(id)

        withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
            orderedIDs = newOrder
            dragOffset = 0
        }
    }
}

// MARK: - Real-World Card View

/// Designed to evoke a real-world payment card:
/// - Deep two-stop gradient for dimensionality
/// - Subtle radial highlight in the top-left corner (light source)
/// - Diagonal sheen across the surface (specular)
/// - Embossed "chip" icon for credit cards
/// - Account icon as brand mark, bottom-right
/// - All-caps tracked labels in the bottom-left corner
struct AccountCardView: View {
    let account: Account
    @PrimaryCurrency private var currencyCode

    /// The card's surface color, deepened via `cardified()` so user-picked
    /// brights become refined card tones. Bright blue → deep navy, bright
    /// yellow → ochre, etc. Matches the language of real premium cards.
    private var color: Color { Color(hex: account.colorHex).cardified() }

    private var accountTypeLabel: String {
        switch account.kind {
        case .creditCard: return "Credit"
        case .bank:       return "Bank"
        case .cash:       return "Cash"
        case .wallet:     return "Wallet"
        }
    }

    private var balanceLabel: String {
        switch account.kind {
        case .creditCard: return "Outstanding"
        case .cash:       return "On Hand"
        case .bank, .wallet: return "Net Flow"
        }
    }

    private var hasChip: Bool { account.kind == .creditCard }

    /// Utilization % for credit cards (used / limit). Returns nil when not
    /// a credit card or no limit set.
    private var utilizationPercent: Int? {
        guard account.kind == .creditCard,
              let limit = account.creditLimit, limit > 0 else { return nil }
        let fraction = min(1.0, max(0, account.derivedBalance / limit))
        return Int((fraction * 100).rounded())
    }

    var body: some View {
        ZStack {
            cardSurface
            cardContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Subtle colored bloom — adds atmosphere without becoming a
        // cartoony halo. Was 0.40 which made cards look like glow sticks
        // and created a "ghost text" effect against the content below.
        .shadow(color: color.opacity(0.18), radius: 14, x: 0, y: 8)
        // Proper depth shadow does the real lifting now.
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
    }

    // MARK: - Surface (gradient + highlights)

    /// Multi-layered card surface, all rendered ON TOP of a solid base color
    /// so the card is fully opaque — no bleed-through from cards below in
    /// the stack. The base color is already `cardified()` (deep + refined),
    /// so the overlays here are gentler than before — heavy darkening would
    /// just turn the cards muddy.
    ///
    /// Layers (bottom up):
    /// 1. **Solid color base** — fully opaque, already a deep tone.
    /// 2. **Black corner shading** — subtle, just for dimension.
    /// 3. **Radial highlight** — top-left light source.
    /// 4. **Diagonal sheen** — narrow specular band.
    private var cardSurface: some View {
        ZStack {
            // 1. Solid base — fully opaque.
            color

            // 2. Mild corner darkening for dimension. Lowered from 0.32 —
            //    the cardified base is already deep, so heavy darkening
            //    just kills the color.
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 3. Top-left light source — gives the card a sense of being
            //    lit from above. Slightly stronger than before to give
            //    contrast against the deeper base.
            RadialGradient(
                colors: [.white.opacity(0.28), .clear],
                center: UnitPoint(x: 0.15, y: 0.10),
                startRadius: 0,
                endRadius: 260
            )

            // 4. Diagonal specular sheen.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: .white.opacity(0.08), location: 0.50),
                    .init(color: .clear, location: 0.70)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Content

    /// Two-tier layout: identifying info up top (name + type + optional
    /// chip), amount hero down bottom. The top tier is the only part
    /// visible when this card is peeking out of the stack, so it has to
    /// carry the recognition.
    ///
    /// Padding is asymmetric — tighter at top (12pt) because that's the
    /// peek region where every pixel of visible card matters; standard
    /// (16pt) on sides and bottom. The visible peek is now ~75% content
    /// instead of ~70%, and the card edge feels closer to a real card's
    /// printed margins.
    private var cardContent: some View {
        VStack(alignment: .leading) {
            topRow
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(.top, Spacing.md)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.lg)
    }

    private var topRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                // Name first — what you actually look for when identifying
                // a card. Type label sits underneath as a quieter qualifier.
                Text(account.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                Text(accountTypeLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            if let percent = utilizationPercent {
                utilizationPill(percent: percent)
            } else if hasChip {
                chipIcon
            }
        }
    }

    /// Status pill: "65% used" — surfaces the most actionable piece of
    /// credit-card information directly on the card face. Color shifts
    /// from white to red as utilization climbs past 70%.
    private func utilizationPill(percent: Int) -> some View {
        let isHigh = percent >= 70
        return HStack(spacing: 4) {
            Image(systemName: isHigh ? "exclamationmark.triangle.fill" : "creditcard.fill")
                .font(.caption2.weight(.bold))
            Text("\(percent)% used")
                .font(.caption2.weight(.bold))
                .tracking(0.3)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.white.opacity(isHigh ? 0.92 : 0.18))
        )
        .foregroundStyle(isHigh ? Color.red : .white)
    }

    /// Bottom-aligned: amount big, label small underneath. Apple-Card-style
    /// hierarchy where the number leads. No trailing icon — the chip up top
    /// already signals "card", and a second icon down here was reading like
    /// a duplicate brand mark in shadow.
    private var bottomRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Currency.format(account.derivedBalance, code: currencyCode))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .shadow(color: .black.opacity(0.20), radius: 1, y: 0.5)

            Text(balanceLabel.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.65))

            if account.kind == .creditCard, let limit = account.creditLimit, limit > 0 {
                creditLimitBar(used: account.derivedBalance, limit: limit)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    private func creditLimitBar(used: Double, limit: Double) -> some View {
        let fraction = min(1, max(0, used / limit))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white.opacity(0.90))
                    .frame(width: max(0, geo.size.width * fraction), height: 3)
            }
        }
        .frame(height: 3)
        .frame(maxWidth: 140)
    }

    // MARK: - Chip Icon

    /// Stylized EMV chip — a small rounded square with horizontal lines
    /// suggesting contact pads. Pure decoration, but conveys "this is a
    /// card" at a glance.
    private var chipIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.83, blue: 0.50),
                            Color(red: 0.78, green: 0.62, blue: 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 28)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)

            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.black.opacity(0.22))
                        .frame(width: 22, height: 1)
                }
            }
        }
    }
}
