import SwiftUI
import SwiftData

/// Quick account creation cards for onboarding.
/// Three pre-filled account types — tap to create instantly.
struct OnboardingAccountSetup: View {
    @Environment(\.modelContext) private var context
    @AppStorage("primaryCurrencyCode") private var currencyCode: String = "INR"

    @State private var createdKinds: Set<AccountKind> = []

    var hasCreatedAccount: Bool {
        !createdKinds.isEmpty
    }

    private let accountOptions: [(kind: AccountKind, name: String, subtitle: String, icon: String, color: String)] = [
        (.bank, "Bank Account", "Your bank account", "building.columns", "#4A90E2"),
        (.cash, "Cash", "Cash in hand", "banknote", "#34C759"),
        (.creditCard, "Credit Card", "Credit card", "creditcard", "#FF6B6B"),
    ]

    var body: some View {
        VStack(spacing: Spacing.md) {
            ForEach(accountOptions, id: \.kind) { option in
                let isCreated = createdKinds.contains(option.kind)

                Button {
                    guard !isCreated else { return }
                    createAccount(option)
                } label: {
                    HStack(spacing: Spacing.md) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: option.color).opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: option.icon)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Color(hex: option.color))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(option.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if isCreated {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .fill(Color.tulaCardSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                            .strokeBorder(
                                isCreated ? Color.green.opacity(0.4) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                }
                .buttonStyle(.plain)
                .scaleEffect(isCreated ? 0.98 : 1.0)
                .animation(AppAnimation.bouncy, value: isCreated)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(option.name)")
                .accessibilityValue(isCreated ? "Created" : "Not created")
                .accessibilityHint(isCreated ? "" : "Double tap to create this account")
            }

            Text("Add more in Settings later")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, Spacing.xs)
        }
        .padding(.horizontal, Spacing.lg)
    }

    private func createAccount(_ option: (kind: AccountKind, name: String, subtitle: String, icon: String, color: String)) {
        let account = Account(
            name: option.name,
            kind: option.kind,
            currencyCode: currencyCode,
            iconKey: option.icon,
            colorHex: option.color,
            sortOrder: createdKinds.count
        )
        context.insert(account)
        try? context.save()

        Haptics.success()
        withAnimation(AppAnimation.bouncy) {
            createdKinds.insert(option.kind)
        }
    }
}
