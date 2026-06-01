import SwiftUI
import UIKit

/// Root view shown inside the Tula share extension. Compact, branded,
/// Apple-quality preview of a parsed expense before the user commits it.
///
/// **Design principles**:
/// - Hero amount dominates — it's the irreducible truth of the expense
/// - Brand amber for active/AI states, system gray for everything else
/// - ✨ sparkle = AI contributed; no sparkle = pure regex/OCR
/// - Category visualization via icon + color, not just text
/// - Primary action (Add) is the hero button; cancel demotes to text link
/// - Loading state has personality — animated text, not just a spinner
struct ShareRootView: View {
    @ObservedObject var session: ShareSession

    /// Brand amber matches the main app's #D97706. Hard-coded here
    /// because Theme.swift isn't in the TulaShare target by default
    /// and the extension is small enough that this duplication is
    /// cheaper than adding the dependency.
    private let brand = Color(red: 0.85, green: 0.46, blue: 0.02)

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Header

    /// Compact branded header. ✕ left, "Tula" wordmark + sparkle center,
    /// invisible spacer right for symmetry. The wordmark gives brand
    /// presence without requiring an icon asset bundled in the extension.
    private var headerBar: some View {
        HStack {
            Button {
                session.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(brand)
                Text("Tula")
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content router

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .loading, .parsing:
            loadingView
        case .preview:
            previewView
        case .saving:
            savingView
        case .saved:
            savedView
        case .failed(let reason):
            failedView(reason: reason)
        }
    }

    // MARK: - Loading

    /// Animated loading state. Branded breathing-dots animation plus
    /// phase-aware status text. Avoids the dull system spinner since
    /// this is the visible moment where Tula's AI is "thinking" and
    /// the user is judging trust.
    private var loadingView: some View {
        VStack(spacing: 28) {
            ReceiptScanAnimation(color: brand)
            VStack(spacing: 8) {
                Text(loadingText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: loadingText)
                    .id(loadingText)
                BreathingDotsView(color: brand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private var loadingText: String {
        if !session.parsingStatus.isEmpty {
            return session.parsingStatus
        }
        switch session.phase {
        case .loading: return "Reading what you shared…"
        case .parsing: return "Understanding the receipt…"
        default: return ""
        }
    }

    // MARK: - Preview

    /// Hero amount + metadata + optional receipt + actions. Sized to
    /// fit a standard share-sheet height (~620pt on iPhone 15) without
    /// scroll in the common case. Long item lists fall back to scroll.
    private var previewView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    if let warning = session.parseWarning {
                        warningBanner(warning)
                    }
                    metadataCard
                    if case .image(let image) = session.content {
                        receiptPreview(image)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            actionBar
        }
    }

    /// Soft warning banner shown when the parse confidence is medium
    /// or low. Color: amber (matches Tula brand) but at low saturation —
    /// not alarming, just attention-getting. Icon: exclamation-tinted-
    /// triangle. Text comes from `ParseResult.confidenceReason` so the
    /// user knows specifically what looked off.
    ///
    /// We deliberately don't BLOCK saving here — the user might know
    /// the parsed values are correct even when our heuristics are
    /// uncertain. The banner is a heads-up, not a gate.
    private func warningBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// Hero amount block. 68pt rounded — bigger than the main app's
    /// 64pt because the share extension's vertical real estate is
    /// shorter and the amount needs to claim its corner of the screen
    /// proportionally. ✨ glyph appears when smart parser contributed,
    /// signaling "AI did this" without explaining itself.
    private var hero: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(amountString)
                    .font(.system(size: 68, weight: .semibold, design: .rounded))
                    .foregroundStyle(session.amount > 0 ? .primary : .tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: session.amount))
                    .animation(.snappy(duration: 0.35), value: session.amount)
                if session.usedSmartParser {
                    Image(systemName: "sparkles")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(brand)
                        .accessibilityLabel("Filled by Apple Intelligence")
                }
            }
            if session.amount == 0 {
                Text("Couldn't read an amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    /// Metadata card. Icon + label + value rows with dividers.
    /// Category row uses its actual category icon (mapped from name)
    /// for at-a-glance recognition.
    @State private var showAllItems = false

    private var metadataCard: some View {
        VStack(spacing: 0) {
            metadataRow(
                icon: "storefront.fill",
                iconColor: .secondary,
                label: "Merchant",
                value: session.merchant.isEmpty ? nil : session.merchant
            )
            Divider().padding(.leading, 44)
            categoryRow
            if !session.items.isEmpty {
                Divider().padding(.leading, 44)
                itemsSection
            } else if !session.note.isEmpty {
                Divider().padding(.leading, 44)
                metadataRow(
                    icon: "text.alignleft",
                    iconColor: .secondary,
                    label: "Note",
                    value: session.note
                )
            }
            Divider().padding(.leading, 44)
            metadataRow(
                icon: "calendar",
                iconColor: .secondary,
                label: "Date",
                value: dateString
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var itemsSection: some View {
        let visibleItems = showAllItems ? session.items : Array(session.items.prefix(3))
        let hasMore = session.items.count > 3

        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "list.bullet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("Items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(session.items.count) item\(session.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ForEach(Array(visibleItems.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("₹\(Int(item.price))")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.leading, 36)
                .padding(.vertical, 4)
            }

            if hasMore {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showAllItems.toggle()
                    }
                } label: {
                    Text(showAllItems ? "Show less" : "Show all \(session.items.count) items")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(brand)
                }
                .padding(.top, 4)
                .padding(.bottom, 6)
            } else {
                Spacer().frame(height: 6)
            }
        }
    }

    /// Category gets a richer treatment than other rows: when a category
    /// was detected, its mapped icon AND tinted color show, matching how
    /// the main app's category grid items render. When no category was
    /// detected, falls back to a neutral tag with brand tint.
    private var categoryRow: some View {
        let (icon, color) = categoryIconAndColor(for: session.categoryName)
        return metadataRow(
            icon: icon,
            iconColor: color,
            label: "Category",
            value: session.categoryName
        )
    }

    /// Map a category name to an icon + color for preview purposes.
    /// Best-effort visual matching against common labels. The actual
    /// category object gets resolved against SwiftData at save time
    /// (see ShareSession.performSave), so this is purely cosmetic.
    private func categoryIconAndColor(for name: String?) -> (icon: String, color: Color) {
        guard let raw = name?.lowercased() else { return ("tag.fill", .secondary) }
        switch true {
        case raw.contains("food") || raw.contains("dining") || raw.contains("restaurant"):
            return ("fork.knife", .orange)
        case raw.contains("grocer"):
            return ("basket.fill", .green)
        case raw.contains("transport") || raw.contains("travel") || raw.contains("taxi"):
            return ("car.fill", .blue)
        case raw.contains("health") || raw.contains("medical") || raw.contains("pharma"):
            return ("cross.case.fill", .red)
        case raw.contains("shop"):
            return ("bag.fill", .purple)
        case raw.contains("entertain"):
            return ("tv.fill", .pink)
        case raw.contains("util") || raw.contains("bill"):
            return ("bolt.fill", .yellow)
        case raw.contains("home"):
            return ("house.fill", .teal)
        case raw.contains("educ"):
            return ("book.fill", .indigo)
        default:
            return ("tag.fill", brand)
        }
    }

    private func metadataRow(icon: String, iconColor: Color, label: String, value: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .font(.subheadline.weight(value == nil ? .regular : .medium))
                .foregroundStyle(value == nil ? .tertiary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// Receipt photo preview with paperclip caption confirming it'll
    /// be attached on save. Subtle shadow gives a polaroid-like feel.
    /// Capped at 140pt height so portrait receipts don't dominate.
    private func receiptPreview(_ image: UIImage) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                    .font(.caption2.weight(.semibold))
                Text("Receipt will be saved")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Asymmetric action bar — hero Add button + smaller text Cancel.
    /// Glow shadow on Add when enabled (brand amber, subtle) gives it
    /// the "this is the action you want" weight. Cancel is text-only
    /// so it doesn't compete visually.
    private var actionBar: some View {
        VStack(spacing: 12) {
            Button {
                session.save()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Add Expense")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(session.amount > 0 ? brand : Color.gray.opacity(0.4))
                )
                .shadow(
                    color: session.amount > 0 ? brand.opacity(0.3) : .clear,
                    radius: 10,
                    y: 4
                )
            }
            .disabled(session.amount == 0)

            Button {
                session.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground).opacity(0), location: 0),
                    .init(color: Color(.systemBackground), location: 0.4)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Saving / Saved

    private var savingView: some View {
        VStack(spacing: 20) {
            BreathingDotsView(color: brand)
            Text("Saving to Tula…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    /// Brand-amber checkmark with bounce + glow, "Logged in Tula"
    /// confirmation, amount echo. The 600ms display window is brief
    /// but enough to register before dismiss.
    private var savedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(brand)
                .symbolEffect(.bounce, value: session.phase == .saved)
                .shadow(color: brand.opacity(0.3), radius: 12, y: 4)
            VStack(spacing: 4) {
                Text("Logged in Tula")
                    .font(.title3.weight(.semibold))
                if session.amount > 0 {
                    Text(amountString)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: - Failed

    private func failedView(reason: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange.opacity(0.8))
            VStack(spacing: 6) {
                Text("Couldn't add")
                    .font(.headline)
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Close") {
                session.cancel()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(brand)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: - Formatting

    private var amountString: String {
        let value = session.amount
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "₹\(Int(value))"
        }
        return String(format: "₹%.2f", value)
    }

    private var dateString: String {
        let cal = Calendar.current
        if cal.isDateInToday(session.date) { return "Today" }
        if cal.isDateInYesterday(session.date) { return "Yesterday" }
        return session.date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Receipt Scan Animation

private struct ReceiptScanAnimation: View {
    let color: Color
    @State private var scanOffset: CGFloat = 0
    @State private var appeared = false

    private let receiptWidth: CGFloat = 80
    private let receiptHeight: CGFloat = 100

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
                .frame(width: receiptWidth, height: receiptHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(color.opacity(0.3), lineWidth: 1)
                )
                .overlay(receiptLines)

            RoundedRectangle(cornerRadius: 1)
                .fill(color.opacity(0.6))
                .frame(width: receiptWidth - 8, height: 2)
                .shadow(color: color.opacity(0.5), radius: 6, y: 0)
                .offset(y: scanOffset)
        }
        .frame(width: receiptWidth, height: receiptHeight)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                scanOffset = (receiptHeight / 2) - 8
            }
        }
    }

    private var receiptLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 40, height: 4)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 55, height: 3)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 48, height: 3)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.1))
                .frame(width: 52, height: 3)
            Spacer()
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 30, height: 4)
            }
        }
        .padding(12)
    }
}

// MARK: - Loading Animation

/// Three-dot breathing animation. Each dot pulses opacity + scale with
/// a staggered phase offset, creating a wave that signals "Tula is
/// working" more personally than a system progress spinner.
///
/// Implementation note: uses a single `phase` state that drives all
/// three dots via offset sin curves. One animation, three visual
/// outputs — cheaper and smoother than three separate animations
/// each managing their own state.
private struct BreathingDotsView: View {
    let color: Color
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .scaleEffect(scale(for: index))
                    .opacity(opacity(for: index))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func scale(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let t = (phase + offset).truncatingRemainder(dividingBy: 1)
        return 0.7 + 0.5 * sin(t * .pi)
    }

    private func opacity(for index: Int) -> Double {
        let offset = Double(index) * 0.15
        let t = (phase + offset).truncatingRemainder(dividingBy: 1)
        return 0.4 + 0.6 * sin(t * .pi)
    }
}
