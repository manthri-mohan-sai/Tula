import SwiftUI
import SwiftData
import AVFoundation
import Speech
import UserNotifications

/// Redesigned first-launch onboarding. Seven pages:
///
/// 0. **Welcome** — Devanagari "तुला" with parallax float + tagline
/// 1. **Feature Demo** — Interactive quick-log parsing animation
/// 2. **Currency** — Currency selection (moved up — affects all subsequent displays)
/// 3. **First Account** — Quick account creation (Bank/Cash/Card one-tap)
/// 4. **Permissions** — Mic + notifications with enhanced copy
/// 5. **Budget** — Optional monthly budget setup
/// 6. **Ready** — Preview of populated home screen + celebration
///
/// Dismissal sets `@AppStorage("onboardingComplete") = true`.
/// Progress shown via `OnboardingProgressBar` replacing page dots.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

    @Query private var allAccounts: [Account]

    @State private var page: Int = 0
    @State private var monthlyBudgetAmount: Double = 0
    @State private var pageAppeared: Set<Int> = [0]

    // Permissions state
    @State private var micGranted: Bool = false
    @State private var notificationsGranted: Bool = false
    @State private var micRequested: Bool = false
    @State private var notificationsRequested: Bool = false

    // Motion for parallax
    @State private var motion = MotionManager.shared

    private let totalPages = 7

    /// Whether the Continue button should be enabled on the current page.
    private var canContinue: Bool {
        if page == 3 {
            // Account page: require at least one account
            return !allAccounts.isEmpty
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar
            OnboardingProgressBar(totalSteps: totalPages, currentStep: page)
                .padding(.horizontal, Spacing.xl)
                .padding(.top, Spacing.md)

            // Skip button
            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    finishOnboarding()
                } label: {
                    Text("Skip")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(page < totalPages - 1 ? 1 : 0)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xs)

            TabView(selection: $page) {
                welcomePage.tag(0)
                featureDemoPage.tag(1)
                currencyPage.tag(2)
                accountSetupPage.tag(3)
                permissionsPage.tag(4)
                budgetPage.tag(5)
                readyPage.tag(6)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: page) { _, newPage in
                Haptics.selection()
                pageAppeared.insert(newPage)
            }

            actionButton
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.lg)
        }
        .background(Color(uiColor: .systemBackground))
        .interactiveDismissDisabled()
        .onAppear {
            motion.start()
        }
        .onDisappear {
            motion.stop()
        }
    }

    // MARK: - Page 0: Welcome

    private var welcomePage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text("तुला")
                .font(.system(size: 120, weight: .bold))
                .foregroundStyle(Color.tulaBrandFallback)
                .offset(x: motion.rollOffset * 6, y: motion.pitchOffset * 6)
                .scaleEffect(1.0 + sin(Date().timeIntervalSince1970 * 1.2) * 0.008)
                .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: motion.rollOffset)

            VStack(spacing: Spacing.xs) {
                Text("Welcome to Tula")
                    .font(.title.weight(.bold))
                Text("Balance your spend")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .entranceAnimation(visible: pageAppeared.contains(0), delay: 0.2)

            Text("A focused, private expense tracker rooted in mindful spending. Your data lives only on your device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
                .padding(.top, Spacing.md)
                .entranceAnimation(visible: pageAppeared.contains(0), delay: 0.4)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 1: Feature Demo

    private var featureDemoPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.xs) {
                Text("Watch the magic")
                    .font(.title2.weight(.bold))
                Text("Type naturally — Tula understands.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .entranceAnimation(visible: pageAppeared.contains(1), delay: 0.1)

            OnboardingFeatureDemo()
                .entranceAnimation(visible: pageAppeared.contains(1), delay: 0.3)

            // Feature pills
            HStack(spacing: Spacing.md) {
                featurePill(icon: "sparkles", label: "Quick Log")
                featurePill(icon: "mic.fill", label: "Voice")
                featurePill(icon: "doc.text.viewfinder", label: "Receipt")
            }
            .entranceAnimation(visible: pageAppeared.contains(1), delay: 0.5)

            Spacer()
            Spacer()
        }
    }

    private func featurePill(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .foregroundStyle(.secondary)
    }

    // MARK: - Page 2: Currency

    private static let currencyFlags: [String: String] = [
        "INR": "🇮🇳", "USD": "🇺🇸", "EUR": "🇪🇺", "GBP": "🇬🇧",
        "AED": "🇦🇪", "SGD": "🇸🇬", "AUD": "🇦🇺", "CAD": "🇨🇦", "JPY": "🇯🇵"
    ]

    private var currencyPage: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.sm) {
                Text("Your currency")
                    .font(.title2.weight(.bold))
                Text("This is how every amount will be displayed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.lg)
            .multilineTextAlignment(.center)
            .padding(.top, Spacing.lg)
            .entranceAnimation(visible: pageAppeared.contains(2), delay: 0.1)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Currency.supported, id: \.self) { code in
                        Button {
                            Haptics.selection()
                            primaryCurrencyCode = code
                        } label: {
                            HStack {
                                Text(Self.currencyFlags[code] ?? "")
                                    .font(.title2)
                                    .frame(width: 32, alignment: .center)
                                Text(Currency.symbol(for: code))
                                    .font(.title3.weight(.medium))
                                    .frame(width: 30, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Currency.longName(for: code))
                                        .foregroundStyle(.primary)
                                    Text(code)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if code == primaryCurrencyCode {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.tulaBrandFallback)
                                        .fontWeight(.semibold)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm + 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainRowButtonStyle())
                        if code != Currency.supported.last {
                            Divider().padding(.leading, 80)
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
        }
    }

    // MARK: - Page 3: Account Setup

    private var accountSetupPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.xs) {
                Text("Where does your money live?")
                    .font(.title2.weight(.bold))
                Text("Tap to create — you can add more later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.lg)
            .entranceAnimation(visible: pageAppeared.contains(3), delay: 0.1)

            OnboardingAccountSetup()
                .entranceAnimation(visible: pageAppeared.contains(3), delay: 0.3)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 4: Permissions

    private var permissionsPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            Text("Two quick permissions")
                .font(.title2.weight(.bold))
                .entranceAnimation(visible: pageAppeared.contains(4), delay: 0.1)

            Text("Both are optional — you can change them anytime in iOS Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.lg)
                .entranceAnimation(visible: pageAppeared.contains(4), delay: 0.2)

            VStack(spacing: Spacing.md) {
                permissionTile(
                    icon: "mic.fill",
                    color: .red,
                    title: "Say what you spent",
                    detail: "Voice logging with on-device recognition.",
                    isGranted: micGranted,
                    isRequested: micRequested,
                    action: requestMicrophone
                )
                permissionTile(
                    icon: "bell.badge.fill",
                    color: .indigo,
                    title: "Never miss a bill",
                    detail: "Budget alerts, bill reminders, and daily nudges.",
                    isGranted: notificationsGranted,
                    isRequested: notificationsRequested,
                    action: requestNotifications
                )
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .entranceAnimation(visible: pageAppeared.contains(4), delay: 0.3)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 5: Budget

    private var budgetPage: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()

            VStack(spacing: Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.tulaBrandFallback.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: "target")
                        .font(.largeTitle.weight(.medium))
                        .foregroundStyle(Color.tulaBrandFallback)
                }

                Text("Set a monthly budget")
                    .font(.title2.weight(.bold))

                Text("How much do you want to spend each month?\nYou can always change this later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)
            }
            .entranceAnimation(visible: pageAppeared.contains(5), delay: 0.1)

            VStack(spacing: Spacing.sm) {
                HStack {
                    Text(Currency.symbol(for: primaryCurrencyCode))
                        .font(.title.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("0", value: $monthlyBudgetAmount, format: .number)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 200)
                }
                .frame(maxWidth: .infinity)

                Text("per month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Spacing.lg)
            .entranceAnimation(visible: pageAppeared.contains(5), delay: 0.3)

            HStack(spacing: Spacing.sm) {
                ForEach([10000, 25000, 50000, 100000], id: \.self) { suggestion in
                    Button {
                        Haptics.selection()
                        monthlyBudgetAmount = Double(suggestion)
                    } label: {
                        Text(Currency.format(Double(suggestion), code: primaryCurrencyCode))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                monthlyBudgetAmount == Double(suggestion)
                                    ? Color.tulaBrandFallback
                                    : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                            .foregroundStyle(monthlyBudgetAmount == Double(suggestion) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Skip this step if you prefer not to set a budget yet.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.sm)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 6: Ready

    @State private var showCelebration = false

    private var readyPage: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()

            VStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(Color.tulaBrandFallback.opacity(0.15))
                        .frame(width: 88, height: 88)
                        .scaleEffect(showCelebration ? 1.0 : 0.5)
                        .opacity(showCelebration ? 1 : 0)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.tulaBrandFallback)
                        .scaleEffect(showCelebration ? 1.0 : 0.3)
                        .opacity(showCelebration ? 1 : 0)
                }
                .animation(AppAnimation.bouncy.delay(0.2), value: showCelebration)

                Text("You're all set!")
                    .font(.title.weight(.bold))
                    .entranceAnimation(visible: showCelebration, delay: 0.4)
            }

            // Preview card of what they've set up
            VStack(alignment: .leading, spacing: Spacing.md) {
                if !allAccounts.isEmpty {
                    previewRow(
                        icon: "creditcard.fill",
                        color: .blue,
                        title: "\(allAccounts.count) account\(allAccounts.count == 1 ? "" : "s") created",
                        detail: allAccounts.map(\.name).joined(separator: ", ")
                    )
                }

                if monthlyBudgetAmount > 0 {
                    previewRow(
                        icon: "target",
                        color: Color.tulaBrandFallback,
                        title: "Monthly budget",
                        detail: Currency.format(monthlyBudgetAmount, code: primaryCurrencyCode)
                    )
                }

                previewRow(
                    icon: "dollarsign.circle.fill",
                    color: .green,
                    title: "Currency",
                    detail: "\(Self.currencyFlags[primaryCurrencyCode] ?? "") \(primaryCurrencyCode)"
                )
            }
            .padding(Spacing.lg)
            .background(Color.tulaCardSurface, in: RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous))
            .padding(.horizontal, Spacing.xl)
            .entranceAnimation(visible: showCelebration, delay: 0.5)

            Spacer()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                showCelebration = true
                Haptics.success()
            }
        }
    }

    private func previewRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Shared Components

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
        .accessibilityElement(children: .combine)
        .accessibilityValue(isGranted ? "Granted" : (isRequested ? "Skipped" : "Not requested"))
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

    // MARK: - Permission Requests

    private func requestMicrophone() {
        Haptics.tap()
        Task {
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

    // MARK: - Action Button

    private var actionButton: some View {
        Button {
            Haptics.tap()
            if page < totalPages - 1 {
                withAnimation(AppAnimation.gentle) { page += 1 }
            } else {
                finishOnboarding()
            }
        } label: {
            Text(page < totalPages - 1 ? "Continue" : "Get Started")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                        .fill(canContinue ? Color.tulaBrandFallback : Color.secondary.opacity(0.3))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canContinue)
        .accessibilityHint(page < totalPages - 1 ? "Advances to the next onboarding step" : "Completes setup and opens the app")
        .animation(AppAnimation.snappy, value: canContinue)
    }

    // MARK: - Finish

    private func finishOnboarding() {
        // Create the overall monthly budget if the user set one
        if monthlyBudgetAmount > 0 {
            let budget = Budget(amount: monthlyBudgetAmount, category: nil, period: .monthly)
            context.insert(budget)
            try? context.save()
        }
        onboardingComplete = true
        Haptics.success()
        dismiss()
    }
}

// MARK: - Entrance Animation Modifier

private struct EntranceAnimationModifier: ViewModifier {
    let visible: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 20)
            .animation(AppAnimation.gentle.delay(delay), value: visible)
    }
}

extension View {
    fileprivate func entranceAnimation(visible: Bool, delay: Double = 0) -> some View {
        modifier(EntranceAnimationModifier(visible: visible, delay: delay))
    }
}
