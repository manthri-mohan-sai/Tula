import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"

    @State private var showingAccounts = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingCurrencyPicker = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - General
                Section {
                    Button {
                        Haptics.tap()
                        showingCurrencyPicker = true
                    } label: {
                        HStack {
                            settingsLabel("Currency", icon: "indianrupeesign.circle.fill", color: .green)
                            Spacer()
                            Text(Currency.symbol(for: primaryCurrencyCode))
                                .foregroundStyle(.secondary)
                            Text(primaryCurrencyCode)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text("General")
                }

                // MARK: - Data
                Section {
                    settingsRow("Accounts", icon: "creditcard.fill", color: .blue) {
                        showingAccounts = true
                    }
                    settingsRow("Categories", icon: "tag.fill", color: .pink) {
                        showingCategories = true
                    }
                    settingsRow("Recurring", icon: "arrow.clockwise.circle.fill", color: .orange) {
                        showingRecurring = true
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Text("Accounts, categories, and recurring rules can all be managed here.")
                }

                // MARK: - About
                Section {
                    HStack {
                        settingsLabel("Version", icon: "info.circle.fill", color: .gray)
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                } footer: {
                    HStack {
                        Spacer()
                        Text("तुला · Balance your spend")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.top, Spacing.md)
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingAccounts) { AccountsView() }
            .sheet(isPresented: $showingCategories) { CategoriesView() }
            .sheet(isPresented: $showingRecurring) { RecurringRulesView() }
            .sheet(isPresented: $showingCurrencyPicker) {
                CurrencyPickerView(selectedCode: $primaryCurrencyCode)
            }
        }
    }

    /// Helper for a settings row with an action.
    private func settingsRow(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack {
                settingsLabel(title, icon: icon, color: color)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Apple-style colored icon tile + label.
    private func settingsLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(color)
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
            }
            Text(title)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Currency Picker

struct CurrencyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedCode: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Currency.supported, id: \.self) { code in
                        Button {
                            Haptics.selection()
                            selectedCode = code
                            dismiss()
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
                                if code == selectedCode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.tulaBrandFallback)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Changes how amounts are formatted throughout the app. Indian Rupee uses Indian-style grouping (1,25,000); other currencies use Western grouping (125,000).")
                }
            }
            .navigationTitle("Currency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
