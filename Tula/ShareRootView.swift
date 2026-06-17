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
        .tint(brand)
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
                VStack(spacing: 16) {
                    hero
                    if let warning = session.parseWarning {
                        warningBanner(warning)
                    }
                    primaryCard
                    if !session.items.isEmpty {
                        itemsCard
                    }
                    secondaryCard
                    if case .image(let image) = session.content {
                        receiptPreview(image)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heads Up")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if session.canRetryAIGate {
                Button {
                    session.retryAIGateBypass()
                } label: {
                    Text("Try Again")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(brand)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(brand.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    /// Hero amount block. 68pt rounded — bigger than the main app's
    /// 64pt because the share extension's vertical real estate is
    /// shorter and the amount needs to claim its corner of the screen
    /// proportionally. ✨ glyph appears when smart parser contributed,
    /// signaling "AI did this" without explaining itself.
    private var hero: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(amountString)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(session.amount > 0 ? .primary : .tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: session.amount))
                    .animation(.snappy(duration: 0.35), value: session.amount)
                if session.usedSmartParser {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(brand)
                }
            }
            if session.amount == 0 {
                Text("Couldn't read an amount")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !session.merchant.isEmpty {
                Text(session.merchant)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// Metadata card. Icon + label + value rows with dividers.
    /// Category row uses its actual category icon (mapped from name)
    /// for at-a-glance recognition.
    @State private var showAllItems = false

    private var primaryCard: some View {
        VStack(spacing: 0) {
            editableRow(
                icon: "storefront",
                iconColor: .secondary,
                label: "Merchant",
                placeholder: "Add merchant",
                text: Binding(
                    get: { session.merchant },
                    set: { session.merchant = $0 }
                )
            )
            Divider().padding(.leading, 52)
            categoryPickerRow
            Divider().padding(.leading, 52)
            accountPickerRow
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var secondaryCard: some View {
        VStack(spacing: 0) {
            editableRow(
                icon: "note.text",
                iconColor: .secondary,
                label: "Note",
                placeholder: "Add note",
                text: Binding(
                    get: { session.note },
                    set: { session.note = $0 }
                )
            )
            Divider().padding(.leading, 52)
            metadataRow(
                icon: "calendar",
                iconColor: .secondary,
                label: "Date",
                value: dateString
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var itemsCard: some View {
        let visibleItems = showAllItems ? session.items : Array(session.items.prefix(4))
        let hasMore = session.items.count > 4
        let hasBreakdown = session.discount > 0 || session.tax > 0

        return VStack(spacing: 0) {
            HStack {
                Text("Items")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(session.items.count)")
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ForEach(Array(visibleItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider().padding(.leading, 16)
                }
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if item.quantity > 1 {
                        Text("×\(item.quantity)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(brand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(brand.opacity(0.12))
                            )
                    }
                    Spacer()
                    Text(formatPrice(item.price))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if hasMore {
                Divider().padding(.leading, 16)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        showAllItems.toggle()
                    }
                } label: {
                    HStack {
                        Text(showAllItems ? "Show less" : "\(session.items.count - 4) more items")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(brand)
                        Spacer()
                        Image(systemName: showAllItems ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(brand)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

            if hasBreakdown {
                Divider()
                VStack(spacing: 6) {
                    if session.discount > 0 {
                        summaryRow(label: "Discount", value: "−\(formatPrice(session.discount))", color: .green)
                    }
                    if session.tax > 0 {
                        summaryRow(label: "Tax", value: formatPrice(session.tax), color: .secondary)
                    }
                    summaryRow(
                        label: "Total",
                        value: formatPrice(session.amount),
                        color: .primary,
                        bold: true
                    )
                }
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func summaryRow(label: String, value: String, color: Color, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.semibold) : .footnote)
                .foregroundStyle(bold ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.semibold).monospacedDigit() : .footnote.monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 16)
    }

    private func formatPrice(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return "₹\(Int(value))"
        }
        return String(format: "₹%.2f", value)
    }

    private var categoryPickerRow: some View {
        let icon = categoryIcon(for: session.categoryName)
        return Menu {
            ForEach(session.availableCategories, id: \.self) { name in
                Button {
                    session.categoryName = name
                } label: {
                    HStack {
                        Text(name)
                        if session.categoryName == name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Category")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 4) {
                    Text(session.categoryName ?? "Select")
                        .font(.subheadline)
                        .foregroundStyle(session.categoryName != nil ? .secondary : .tertiary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tint(.primary)
    }

    private var accountPickerRow: some View {
        Menu {
            ForEach(session.availableAccounts, id: \.id) { account in
                Button {
                    session.selectedAccountName = account.name
                } label: {
                    HStack {
                        Text(account.name)
                        if session.selectedAccountName == account.name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text("Account")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 4) {
                    Text(session.selectedAccountName ?? "Default")
                        .font(.subheadline)
                        .foregroundStyle(session.selectedAccountName != nil ? .secondary : .tertiary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tint(.primary)
    }

    /// Map a category name to an outlined icon for the row.
    /// Best-effort visual matching against common labels. The actual
    /// category object gets resolved against SwiftData at save time
    /// (see ShareSession.performSave), so this is purely cosmetic.
    private func categoryIcon(for name: String?) -> String {
        guard let raw = name?.lowercased() else { return "tag" }
        switch true {
        case raw.contains("food") || raw.contains("dining") || raw.contains("restaurant"):
            return "fork.knife"
        case raw.contains("grocer"):
            return "basket"
        case raw.contains("transport") || raw.contains("travel") || raw.contains("taxi"):
            return "car"
        case raw.contains("fuel"):
            return "fuelpump"
        case raw.contains("health") || raw.contains("medical") || raw.contains("pharma"):
            return "cross.case"
        case raw.contains("shop"):
            return "bag"
        case raw.contains("entertain"):
            return "tv"
        case raw.contains("util") || raw.contains("bill"):
            return "bolt"
        case raw.contains("home") || raw.contains("rent"):
            return "house"
        case raw.contains("educ"):
            return "book"
        case raw.contains("personal") || raw.contains("care"):
            return "scissors"
        default:
            return "tag"
        }
    }

    private func editableRow(icon: String, iconColor: Color, label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.words)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metadataRow(icon: String, iconColor: Color, label: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(iconColor)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            Text(value ?? "—")
                .font(.subheadline)
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Receipt photo preview with paperclip caption confirming it'll
    /// be attached on save. Subtle shadow gives a polaroid-like feel.
    /// Capped at 140pt height so portrait receipts don't dominate.
    @State private var showingReceiptFullscreen = false

    private func receiptPreview(_ image: UIImage) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { showingReceiptFullscreen = true }
            HStack(spacing: 4) {
                Image(systemName: "paperclip")
                    .font(.caption2.weight(.semibold))
                Text("Receipt will be saved")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .fullScreenCover(isPresented: $showingReceiptFullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                Button {
                    showingReceiptFullscreen = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .white.opacity(0.3))
                        .padding(16)
                }
            }
        }
    }

    /// Asymmetric action bar — hero Add button + smaller text Cancel.
    /// Glow shadow on Add when enabled (brand amber, subtle) gives it
    /// the "this is the action you want" weight. Cancel is text-only
    /// so it doesn't compete visually.
    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                session.save()
            } label: {
                Text("Add Expense")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(session.amount > 0 ? brand : Color.gray.opacity(0.4))
                    )
            }
            .disabled(session.amount == 0)

            Button {
                session.cancel()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 8)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground).opacity(0), location: 0),
                    .init(color: Color(.systemBackground), location: 0.35)
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
