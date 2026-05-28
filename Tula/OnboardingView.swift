import SwiftUI
import AVFoundation
import Speech
import UserNotifications

/// First-launch onboarding. Four pages:
/// 1. Brand intro — Devanagari "तुला" + tagline
/// 2. Pillar features — Quick log, Voice, Recurring
/// 3. Permissions — proactively requests mic + notifications so first
///    use isn't interrupted by surprise iOS dialogs. Skippable.
/// 4. Currency selection — locks in the user's primary currency
///
/// Dismissal sets @AppStorage("onboardingComplete") = true so this never
/// appears again. Built as a TabView with .page style for swipe navigation.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    @State private var page: Int = 0

    /// Total number of swipeable pages. Drives the "Continue" vs
    /// "Get Started" label on the action button.
    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                introPage.tag(0)
                featuresPage.tag(1)
                permissionsPage.tag(2)
                currencyPage.tag(3)
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
                    color: .red,
                    title: "Voice",
                    detail: "Tap the mic or use Siri to add expenses hands-free."
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

    /// Page 3 — proactively request mic + notification permissions so the
    /// user isn't surprised by iOS dialogs the first time they tap the
    /// mic or enable budget alerts. Both are independent and skippable.
    @State private var micGranted: Bool = false
    @State private var notificationsGranted: Bool = false
    @State private var micRequested: Bool = false
    @State private var notificationsRequested: Bool = false

    private var permissionsPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text("Two quick permissions")
                .font(.title2.weight(.bold))

            Text("Both are optional and you can change them later in iOS Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)

            VStack(spacing: Spacing.md) {
                permissionTile(
                    icon: "mic.fill",
                    color: .red,
                    title: "Microphone",
                    detail: "Required for voice expense logging.",
                    isGranted: micGranted,
                    isRequested: micRequested,
                    action: requestMicrophone
                )
                permissionTile(
                    icon: "bell.badge.fill",
                    color: .indigo,
                    title: "Notifications",
                    detail: "Budget alerts and daily reminders.",
                    isGranted: notificationsGranted,
                    isRequested: notificationsRequested,
                    action: requestNotifications
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

    /// Permission tile — same layout as feature rows but with a trailing
    /// "Allow" button that morphs into a green checkmark once granted
    /// (or a gray "Denied" pill if the user refused).
    private func permissionTile(icon: String, color: Color,
                                  title: String, detail: String,
                                  isGranted: Bool, isRequested: Bool,
                                  action: @escaping () -> Void) -> some View {
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
            Spacer(minLength: 8)

            permissionAction(isGranted: isGranted, isRequested: isRequested, action: action)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                .fill(Color.tulaCardSurface)
        )
    }

    @ViewBuilder
    private func permissionAction(isGranted: Bool, isRequested: Bool,
                                    action: @escaping () -> Void) -> some View {
        if isGranted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("On")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        } else if isRequested {
            Text("Skipped")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        } else {
            Button(action: action) {
                Text("Allow")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.tulaBrandFallback, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Permission requests

    private func requestMicrophone() {
        Haptics.tap()
        Task {
            // Mic is meaningful only with speech recognition, so request
            // both together and gate the green state on both being on.
            let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
            }
            let micGrantedNow = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
            }
            await MainActor.run {
                micGranted = micGrantedNow && speechStatus == .authorized
                micRequested = true
                if micGranted { Haptics.success() }
            }
        }
    }

    private func requestNotifications() {
        Haptics.tap()
        Task {
            let granted = await NotificationManager.requestAuthorization()
            await MainActor.run {
                notificationsGranted = granted
                notificationsRequested = true
                if granted { Haptics.success() }
            }
        }
    }

    // MARK: - Action

    private var actionButton: some View {
        Button {
            Haptics.tap()
            if page < totalPages - 1 {
                withAnimation { page += 1 }
            } else {
                onboardingComplete = true
                Haptics.success()
                dismiss()
            }
        } label: {
            Text(page < totalPages - 1 ? "Continue" : "Get Started")
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
