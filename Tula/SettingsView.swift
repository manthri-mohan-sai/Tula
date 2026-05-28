import SwiftUI
import SwiftData

/// Top-level settings screen reached from the Home toolbar.
///
/// Reorganized into clear groups:
///   - **General**: currency, daily reminder
///   - **Alerts**: budget threshold notifications
///   - **Data**: accounts, categories, recurring
///   - **Privacy**: backup/restore
///   - **Tools**: export
///   - **About**: version footer
struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage("primaryCurrencyCode") private var primaryCurrencyCode: String = "INR"
    @AppStorage("reminderEnabled") private var reminderEnabled: Bool = false
    @AppStorage("reminderHour") private var reminderHour: Int = 21
    @AppStorage("reminderMinute") private var reminderMinute: Int = 0
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    @AppStorage("launchAnimationEnabled") private var launchAnimationEnabled: Bool = true

    @State private var showingAccounts = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingCurrencyPicker = false
    @State private var showingReminders = false
    @State private var showingBackup = false
    @State private var showingExport = false
    @State private var showingNotificationDeniedAlert = false

    /// Pretty-printed status for the daily reminder row trailing label.
    /// "Off" when disabled, otherwise the formatted hh:mm.
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
                generalSection
                alertsSection
                dataSection
                voiceSection
                toolsSection
                privacySection
                aboutSection
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
            .sheet(isPresented: $showingExport) { ExportView() }
            .sheet(isPresented: $showingCurrencyPicker) {
                CurrencyPickerView(selectedCode: $primaryCurrencyCode)
            }
            .alert("Notifications are off", isPresented: $showingNotificationDeniedAlert) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Enable Notifications for Tula in iOS Settings to receive budget alerts.")
            }
        }
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section {
            settingsLinkRow(
                title: "Currency",
                icon: "indianrupeesign.circle.fill",
                color: .green,
                trailing: "\(Currency.symbol(for: primaryCurrencyCode)) \(primaryCurrencyCode)"
            ) { showingCurrencyPicker = true }

            settingsLinkRow(
                title: "Daily Reminder",
                icon: "bell.badge.fill",
                color: .red,
                trailing: reminderSummary
            ) { showingReminders = true }

            // The तु calligraphy intro that plays on cold launch.
            // First-time users get the brand moment; long-time users
            // can opt out if they've seen it enough times.
            Toggle(isOn: $launchAnimationEnabled) {
                settingsLabel("Launch Animation", icon: "sparkles", color: Color.tulaBrandFallback)
            }
        } header: {
            Text("General")
        }
    }

    /// Budget threshold alerts — single toggle. When turned on we request
    /// notification permission immediately; if denied we prompt the user
    /// to open iOS Settings (one-tap deep link).
    private var alertsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { budgetAlertsEnabled },
                set: { newValue in toggleBudgetAlerts(to: newValue) }
            )) {
                settingsLabel("Budget Alerts", icon: "chart.pie.fill", color: .orange)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Get a notification when any budget reaches 75% or goes over.")
        }
    }

    private var dataSection: some View {
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
    }

    private var voiceSection: some View {
        Section {
            // Tappable row that opens iOS Settings → Siri & Search → Tula.
            // We can't query Siri's authorization state from the app
            // (no public Apple API), so this row is explicitly a
            // navigation link to where the real toggle lives. The
            // trailing "iOS Settings" label + chevron remove any
            // ambiguity about it being a toggle vs a deep-link.
            Button {
                Haptics.tap()
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack {
                    settingsLabel("Siri & Shortcuts", icon: "mic.fill", color: .indigo)
                    Spacer()
                    Text("iOS Settings")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        } header: {
            Text("Voice")
        } footer: {
            Text("Configure Tula's Siri phrases in iOS Settings. Say \"Hey Siri, log expense in Tula\" to log without opening the app.")
        }
    }

    /// Tools section is for one-shot actions that act *on* the data —
    /// exports, deep links, etc. Backups stay in Privacy since they're
    /// about data safety, not data export.
    private var toolsSection: some View {
        Section {
            settingsLinkRow(title: "Export", icon: "square.and.arrow.up.fill", color: .teal) {
                showingExport = true
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Save your expenses as a CSV spreadsheet or PDF report.")
        }
    }

    private var privacySection: some View {
        Section {
            settingsLinkRow(title: "Backup & Restore", icon: "externaldrive.fill", color: .gray) {
                showingBackup = true
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Encrypted backups with your passphrase. Your data never leaves your device unless you share it.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                settingsLabel("Version", icon: "info.circle.fill", color: .gray)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            HStack {
                Spacer()
                // Tagline. Previously .tertiary which was barely
                // readable — at the bottom of a scroll where the
                // user has visually "arrived," the brand line
                // deserves to be legible, not whispered.
                Text("तुला · Balance your spend")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, Spacing.md)
        }
    }

    /// Version string from the bundle. Falls back to "1.0" if missing —
    /// matches the previous hardcoded value so older test builds still
    /// read sensibly.
    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = dict?["CFBundleVersion"] as? String
        if let build, build != version { return "\(version) (\(build))" }
        return version
    }

    // MARK: - Budget Alerts Toggle

    /// Handles flipping the budget alerts toggle. Requests notification
    /// permission on enable; resets the per-budget "has fired" flags on
    /// disable so re-enabling later starts fresh.
    private func toggleBudgetAlerts(to newValue: Bool) {
        if newValue {
            Task {
                let status = await NotificationManager.currentStatus()
                if status == .denied {
                    showingNotificationDeniedAlert = true
                    return
                }
                let granted = await NotificationManager.requestAuthorization()
                await MainActor.run {
                    if granted {
                        budgetAlertsEnabled = true
                        Haptics.success()
                    } else {
                        showingNotificationDeniedAlert = true
                    }
                }
            }
        } else {
            budgetAlertsEnabled = false
            NotificationManager.resetAllBudgetAlertFlags()
            Haptics.tap()
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
