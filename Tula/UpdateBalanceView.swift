import SwiftUI
import SwiftData

/// Re-anchors an account's balance to what the user's bank/card shows now.
/// Records a `BalanceAdjustment` via `BalanceReconciler`. Works for any
/// account kind; credit cards are the headline case.
struct UpdateBalanceView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Bindable var account: Account
    @State private var targetValue: Double
    @FocusState private var fieldFocused: Bool

    init(account: Account) {
        self.account = account
        _targetValue = State(initialValue: max(0, account.derivedBalance))
    }

    private var prompt: String {
        account.kind == .creditCard
            ? "What do you currently owe on this card?"
            : "What's the real balance now?"
    }

    private var difference: Double { targetValue - account.derivedBalance }

    /// Human-readable, sign-aware description of a balance value. For credit
    /// cards a positive value means "owed" and a negative value means the
    /// card is "in credit" (overpaid) — surfacing this is what stops the
    /// sheet from looking like a bare, confusing number.
    private func balanceDescription(_ value: Double) -> String {
        let magnitude = Currency.format(abs(value), code: currencyCode)
        if account.kind == .creditCard {
            if value > 0.01 { return "\(magnitude) owed" }
            if value < -0.01 { return "\(magnitude) in credit" }
            return "nothing owed"
        }
        return Currency.format(value, code: currencyCode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    VStack(spacing: Spacing.xs) {
                        Text("Tula shows")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Currency.format(account.displayAmount, code: currencyCode))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text(account.displayLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, Spacing.lg)

                    VStack(spacing: Spacing.sm) {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        FormattedAmountField(
                            value: $targetValue,
                            currencyCode: currencyCode,
                            placeholder: "0",
                            font: .system(size: 44, weight: .bold, design: .rounded),
                            alignment: .center
                        )
                        .focused($fieldFocused)
                        .frame(maxWidth: .infinity)
                    }

                    if abs(difference) >= 0.01 {
                        Text("This sets it to \(balanceDescription(targetValue)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("Already matches — nothing to adjust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Update Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(abs(difference) < 0.01)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    fieldFocused = true
                }
            }
        }
    }

    private func save() {
        BalanceReconciler.reconcile(
            account: account,
            to: targetValue,
            source: .manual,
            in: context
        )
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }
}
