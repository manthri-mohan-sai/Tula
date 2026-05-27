import SwiftUI

/// First-launch onboarding. Three pages:
/// 1. Brand intro — Devanagari "तुला" + tagline
/// 2. Pillar features — Quick log, Stats, Recurring (3 feature cards)
/// 3. Currency selection — locks in the user's primary currency
///
/// Dismissal sets @AppStorage("onboardingComplete") = true so this never
/// appears again. Built as a TabView with .page style for swipe navigation.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage.tag(0)
                featuresPage.tag(1)
                currencyPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            actionButton
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
        }
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled()
    }

    // MARK: - Pages

    private var introPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            Text("तुला")
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback)

            VStack(spacing: Spacing.xs) {
                Text("Welcome to Tula")
                    .font(.title.weight(.bold))
                Text("Balance your spend")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("A focused, private expense tracker rooted in mindful spending. Your data lives only on your device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.md)

            Spacer()
            Spacer()
        }
    }

    private var featuresPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text("Designed for speed")
                .font(.title2.weight(.bold))

            Text("Three ways to capture every expense in under five seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)

            VStack(spacing: Spacing.md) {
                featureRow(
                    icon: "sparkles",
                    color: Color.tulaBrandFallback,
                    title: "Quick Log",
                    detail: "Type \"450 swiggy hdfc cc\" — it parses everything."
                )
                featureRow(
                    icon: "mic.fill",
                    color: .indigo,
                    title: "Siri",
                    detail: "Hands-free with \"Log expense in Tula\"."
                )
                featureRow(
                    icon: "arrow.clockwise.circle.fill",
                    color: .orange,
                    title: "Recurring",
                    detail: "Rent, subscriptions, EMIs — auto-logged each month."
                )
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)

            Spacer()
            Spacer()
        }
    }

    private var currencyPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.sm) {
                Text("Pick your currency")
                    .font(.title2.weight(.bold))
                Text("This is how every amount will be displayed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .multilineTextAlignment(.center)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Currency.supported, id: \.self) { code in
                        Button {
                            Haptics.selection()
                            primaryCurrencyCode = code
                        } label: {
                            HStack {
                                Text(Currency.symbol(for: code))
                                    .font(.title3.weight(.medium))
                                    .frame(width: 36, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Currency.longName(for: code))
                                        .foregroundStyle(.primary)
                                    Text(code)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if code == primaryCurrencyCode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.tulaBrandFallback)
                                        .fontWeight(.semibold)
                                }
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm + 2)
                        }
                        .buttonStyle(PlainRowButtonStyle())
                        if code != Currency.supported.last {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Color.tulaCardSurface)
                )
                .padding(.horizontal, Spacing.lg)
            }
            .scrollIndicators(.hidden)

            Spacer()
        }
    }

    private func featureRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: - Action

    private var actionButton: some View {
        Button {
            Haptics.tap()
            if page < 2 {
                withAnimation { page += 1 }
            } else {
                onboardingComplete = true
                Haptics.success()
                dismiss()
            }
        } label: {
            Text(page < 2 ? "Continue" : "Get Started")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(Color.tulaBrandFallback)
                )
        }
        .buttonStyle(.plain)
    }
}
