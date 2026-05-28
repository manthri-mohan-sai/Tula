import SwiftUI

/// Horizontal page-snapping carousel of account cards.
///
/// **Why horizontal:** vertical stacking with drag-to-reorder always
/// fought the parent ScrollView (both wanted the vertical axis). Sliding
/// the browse axis to horizontal makes scroll and swipe **orthogonal** —
/// they can never compete, no matter how aggressive either gesture is.
///
/// **How it works:**
/// - Each card occupies ~85% of the visible width, neighbors peek on the
///   edges signaling "more to swipe through."
/// - `scrollTargetBehavior(.viewAligned)` snaps each card to center
///   when the user releases.
/// - `scrollPosition(id:)` exposes the centered card as a binding so the
///   parent can drive related UI (the active-card transactions section).
/// - `scrollTransition` softly dims/scales off-center cards so the
///   focused one reads as the hero.
///
/// **Gestures:**
/// - Horizontal swipe → switch focused card (native, no custom code).
/// - Tap any card → opens detail.
/// - No drag-to-reorder, no expanded mode, no thresholds, no state.
struct CardsCarousel: View {
    let accounts: [Account]
    let namespace: Namespace.ID
    let onTap: (Account) -> Void
    /// Long-press context menu actions. Default no-ops keep older
    /// CardsCarousel call sites compiling without forcing them to
    /// supply the new handlers immediately.
    var onEdit: (Account) -> Void = { _ in }
    var onArchive: (Account) -> Void = { _ in }
    /// The currently centered card. Updated by the system as the user
    /// swipes; can also be set programmatically to scroll to a card.
    @Binding var activeID: UUID?

    /// Card height. Width derived via aspect ratio so the card always
    /// reads as card-like across phone sizes.
    private let cardHeight: CGFloat = 200
    /// Real-world card aspect (85.6mm × 54mm ≈ 1.586). Keeps the card
    /// feeling physical even though it's far larger than a real card.
    private let cardAspect: CGFloat = 1.586
    /// Horizontal margin on each side of the carousel — this is the peek
    /// amount visible for neighboring cards.
    private let edgeInset: CGFloat = 36
    /// Spacing between adjacent cards in the HStack.
    private let interCardSpacing: CGFloat = 14

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: interCardSpacing) {
                ForEach(accounts, id: \.id) { account in
                    AccountCardView(account: account)
                        .frame(width: cardHeight * cardAspect, height: cardHeight)
                        .matchedTransitionSource(id: account.id, in: namespace)
                        // Off-center cards dim & scale down slightly. As
                        // the user swipes, .interactive lets this happen
                        // continuously rather than only at snap points.
                        .scrollTransition(.interactive) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1.0 : 0.92)
                                .opacity(phase.isIdentity ? 1.0 : 0.55)
                        }
                        .onTapGesture {
                            Haptics.tap()
                            onTap(account)
                        }
                        // Long-press → standard iOS context menu with
                        // Edit and Archive. Matches the gesture pattern
                        // of Photos / Mail thumbnails — primary tap
                        // navigates, long-press surfaces secondary
                        // actions without cluttering the visible UI.
                        .contextMenu {
                            Button {
                                Haptics.tap()
                                onEdit(account)
                            } label: {
                                Label("Edit Account", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                Haptics.warning()
                                onArchive(account)
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                        }
                        .id(account.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $activeID, anchor: .center)
        .contentMargins(.horizontal, edgeInset, for: .scrollContent)
        // Let card drop shadows render outside the carousel's vertical
        // bounds — otherwise the bottom shadow gets clipped at the frame
        // edge, which reads as a hard line instead of soft depth.
        .scrollClipDisabled()
        .frame(height: cardHeight)
        // Reserve extra space below for the shadow to "land" without
        // colliding with the page indicator that follows.
        .padding(.bottom, 18)
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
                .contentTransition(.numericText(value: account.derivedBalance))
                .animation(.snappy(duration: 0.35), value: account.derivedBalance)

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
