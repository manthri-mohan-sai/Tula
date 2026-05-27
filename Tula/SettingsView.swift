import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("reminderEnabled") private var reminderEnabled: Bool = false
    @AppStorage("reminderHour") private var reminderHour: Int = 21
    @AppStorage("reminderMinute") private var reminderMinute: Int = 0

    @State private var showingAccounts = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingCurrencyPicker = false
    @State private var showingReminders = false
    @State private var showingBackup = false

    private var reminderSummary: String {
        guard reminderEnabled else { return "Off" }
        var comps = DateComponents()
        comps.hour = reminderHour
        comps.minute = reminderMinute
        let date = Calendar.current.date(from: comps) ?? .now
        return date.formatted(.dateTime.hour().minute())
    }

    var body: some View {
        NavigationStack {
            List {
                // General
                Section {
                    settingsLinkRow(
                        title: "Currency",
                        icon: "indianrupeesign.circle.fill",
                        color: .green,
                        trailing: "\(Currency.symbol(for: primaryCurrencyCode)) \(primaryCurrencyCode)"
                    ) { showingCurrencyPicker = true }

                    settingsLinkRow(
                        title: "Reminders",
                        icon: "bell.badge.fill",
                        color: .red,
                        trailing: reminderSummary
                    ) { showingReminders = true }
                } header: {
                    Text("General")
                }

                // Data
                Section {
                    settingsLinkRow(title: "Accounts", icon: "creditcard.fill", color: .blue) {
                        showingAccounts = true
                    }
                    settingsLinkRow(title: "Categories", icon: "tag.fill", color: .pink) {
                        showingCategories = true
                    }
                    settingsLinkRow(title: "Recurring", icon: "arrow.clockwise.circle.fill", color: .orange) {
                        showingRecurring = true
                    }
                } header: {
                    Text("Data")
                }

                // Voice
                Section {
                    HStack {
                        settingsLabel("Siri & Shortcuts", icon: "mic.fill", color: .indigo)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Say \"Hey Siri, log expense in Tula\" or assign a custom phrase in the Shortcuts app.")
                }

                // Backup
                Section {
                    settingsLinkRow(title: "Backup & Restore", icon: "externaldrive.fill", color: .gray) {
                        showingBackup = true
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Encrypted backups with your passphrase. Your data never leaves your device unless you share it.")
                }

                // About
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showingAccounts) { AccountsView() }
            .sheet(isPresented: $showingCategories) { CategoriesView() }
            .sheet(isPresented: $showingRecurring) { RecurringRulesView() }
            .sheet(isPresented: $showingReminders) { RemindersView() }
            .sheet(isPresented: $showingBackup) { BackupRestoreView() }
            .sheet(isPresented: $showingCurrencyPicker) {
                CurrencyPickerView(selectedCode: $primaryCurrencyCode)
            }
        }
    }

    // MARK: - Row Builders

    private func settingsLinkRow(
        title: String,
        icon: String,
        color: Color,
        trailing: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack {
                settingsLabel(title, icon: icon, color: color)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

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
                    Text("Indian Rupee uses Indian-style grouping (1,25,000); other currencies use Western grouping (125,000).")
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
