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
    @AppStorage("smartParsingEnabled") private var smartParsingEnabled: Bool = true
    @AppStorage("selectedAIProvider", store: UserDefaults(suiteName: "group.com.app.Tula"))
    private var selectedProviderRaw: String = AIProvider.appleFM.rawValue

    /// Result of the most recent "Test smart parsing" tap in Settings —
    /// nil while idle, populated after a test parse. Surfaces what
    /// Foundation Models actually returned (or an error reason).
    @State private var smartTestResult: String? = nil
    @State private var smartTestInFlight: Bool = false

    // Cloud AI config editing state
    @State private var cloudEndpoint: String = ""
    @State private var cloudAPIKey: String = ""
    @State private var cloudModel: String = ""
    @State private var showingCloudConfig: Bool = false

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
                smartParsingSection
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

    /// Apple Foundation Models integration — opt-out toggle for letting
    /// Tula's parser fall back to on-device Apple Intelligence for
    /// inputs the rule-based parser can't categorize. Grayed out on
    /// devices without Apple Intelligence support, with a status footer
    /// explaining why.
    private var smartParsingSection: some View {
        Section {
            if #available(iOS 26.0, *) {
                let available = SmartExpenseParser.isAvailable || selectedProvider == .openAI
                Toggle(isOn: $smartParsingEnabled) {
                    settingsLabel("Smart parsing",
                                  icon: SFSymbols.appleIntelligence,
                                  color: Color.tulaBrandFallback)
                }
                .tint(Color.tulaBrandFallback)

                // Provider picker — shown when smart parsing is enabled
                if smartParsingEnabled {
                    providerPickerSection
                }

                // Test row: actually fires the selected provider with a
                // sample sentence so the user gets a definitive yes/no.
                Button {
                    runSmartParseTest()
                } label: {
                    HStack {
                        settingsLabel("Test smart parsing",
                                      icon: "play.circle.fill",
                                      color: .indigo)
                        Spacer()
                        if smartTestInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!smartParsingEnabled || smartTestInFlight)

                if let result = smartTestResult {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .textSelection(.enabled)
                }
            } else {
                Toggle(isOn: .constant(false)) {
                    settingsLabel("Smart parsing",
                                  icon: "sparkles",
                                  color: .gray)
                }
                .disabled(true)
            }
        } header: {
            Text("Smart Parsing")
        } footer: {
            smartParsingFooter
        }
    }

    // MARK: - Provider Picker

    private var selectedProvider: AIProvider {
        get { AIProvider(rawValue: selectedProviderRaw) ?? .appleFM }
        nonmutating set { selectedProviderRaw = newValue.rawValue }
    }

    private var providerPickerSection: some View {
        Group {
            // Provider selection list
            ForEach(AIProvider.allCases) { provider in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedProviderRaw = provider.rawValue
                        smartTestResult = nil
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: providerIcon(provider))
                            .font(.subheadline)
                            .foregroundStyle(provider == selectedProvider ? Color.tulaBrandFallback : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(provider.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if provider == selectedProvider {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.tulaBrandFallback)
                                .font(.subheadline)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Cloud config row — shown when OpenAI is selected
            if selectedProvider == .openAI {
                cloudConfigRow
            }
        }
    }

    private func providerIcon(_ provider: AIProvider) -> String {
        if #available(iOS 26.0, *) {
            return provider.icon
        }
        return provider.iconFallback
    }

    // MARK: - Cloud Config

    private var cloudConfigRow: some View {
        Group {
            Button {
                let config = CloudAIConfig.load()
                cloudEndpoint = config.endpoint
                cloudAPIKey = config.apiKey
                cloudModel = config.model
                showingCloudConfig = true
            } label: {
                HStack {
                    settingsLabel("Configure API",
                                  icon: "key.fill",
                                  color: .orange)
                    Spacer()
                    if CloudAIConfig.load().apiKey.isEmpty {
                        Text("Not set")
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Configured")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingCloudConfig) {
                cloudConfigSheet
            }
        }
    }

    private var cloudConfigSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Endpoint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("https://api.openai.com/v1/chat/completions", text: $cloudEndpoint)
                            .font(.subheadline)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        SecureField("sk-...", text: $cloudAPIKey)
                            .font(.subheadline)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("gpt-4o-mini", text: $cloudModel)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("OpenAI-Compatible API")
                } footer: {
                    Text("Works with OpenAI, Azure OpenAI, and any OpenAI-compatible endpoint (Ollama, LM Studio, etc.). Your key is stored locally in the App Group.")
                }
            }
            .navigationTitle("Cloud AI Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingCloudConfig = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let config = CloudAIConfig(
                            endpoint: cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                            apiKey: cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "gpt-4o-mini"
                                : cloudModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        config.save()
                        showingCloudConfig = false
                        smartTestResult = nil
                    }
                    .fontWeight(.semibold)
                    .disabled(cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Fires the selected AI provider with a sample expense sentence and
    /// displays the result inline. Gives the user a deterministic
    /// way to verify parsing works on their device / with their key.
    private func runSmartParseTest() {
        guard #available(iOS 26.0, *) else { return }
        smartTestInFlight = true
        smartTestResult = nil
        Haptics.tap()

        let sample = "spent 350 on lunch with team at sagar ratna"
        let categories: [CategoryEntry] = [
            CategoryEntry(name: "Food", iconKey: "fork.knife"),
            CategoryEntry(name: "Groceries", iconKey: "basket.fill"),
            CategoryEntry(name: "Transport", iconKey: "car.fill"),
            CategoryEntry(name: "Shopping", iconKey: "bag.fill"),
            CategoryEntry(name: "Entertainment", iconKey: "tv.fill"),
            CategoryEntry(name: "Bills & Utilities", iconKey: "bolt.fill"),
            CategoryEntry(name: "Rent", iconKey: "house.fill"),
            CategoryEntry(name: "Health", iconKey: "cross.case.fill"),
            CategoryEntry(name: "Education", iconKey: "book.fill"),
            CategoryEntry(name: "Travel", iconKey: "suitcase.fill"),
            CategoryEntry(name: "Personal Care", iconKey: "scissors"),
            CategoryEntry(name: "Other", iconKey: "tag.fill")
        ]
        let startedAt = Date()

        Task {
            let parsed = await SmartExpenseParser.parse(
                sample,
                categories: categories
            )
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)

            await MainActor.run {
                smartTestInFlight = false
                if let parsed {
                    let amount = String(format: "%.0f", parsed.amount)
                    let merchant = parsed.merchant ?? "—"
                    let category = parsed.category ?? "—"
                    let providerLabel = selectedProvider.displayName
                    smartTestResult = """
                    ✓ Provider: \(providerLabel)
                    Input: "\(sample)"
                    Amount: ₹\(amount) · Merchant: \(merchant) · Category: \(category)
                    Round-trip: \(elapsed)ms
                    """
                    Haptics.success()
                } else {
                    let reason: String
                    switch selectedProvider {
                    case .appleFM:
                        reason = SmartExpenseParser.unavailableReason
                            ?? "Foundation Models call failed. Check Settings → Apple Intelligence."
                    case .openAI:
                        let config = CloudAIConfig.load()
                        if config.apiKey.isEmpty {
                            reason = "API key not configured. Tap 'Configure API' above."
                        } else {
                            reason = "Cloud AI call failed. Check your endpoint, key, and model."
                        }
                    }
                    smartTestResult = "✗ \(reason)"
                    Haptics.warning()
                }
            }
        }
    }

    /// Footer copy explains current status: on, off, or unavailable
    /// (with a reason). Honest about limitations — users on iPhone 14
    /// shouldn't be left wondering why the toggle is gray.
    @ViewBuilder
    private var smartParsingFooter: some View {
        if #available(iOS 26.0, *) {
            if smartParsingEnabled {
                switch selectedProvider {
                case .appleFM:
                    if let reason = SmartExpenseParser.unavailableReason {
                        Text(reason)
                    } else {
                        Text("Using on-device Apple Intelligence. Inputs never leave your device. Adds ~200-500ms for complex entries only.")
                    }
                case .openAI:
                    if CloudAIConfig.load().apiKey.isEmpty {
                        Text("Cloud AI selected but API key not configured. Tap 'Configure API' to set up.")
                    } else {
                        Text("Using cloud AI (\(CloudAIConfig.load().model)). Expense text is sent to the configured endpoint for parsing.")
                    }
                }
            } else {
                Text("Tula will use only its built-in rule-based parser. No AI is invoked.")
            }
        } else {
            Text("Smart parsing requires iOS 26 with Apple Intelligence enabled, or a cloud AI provider.")
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
