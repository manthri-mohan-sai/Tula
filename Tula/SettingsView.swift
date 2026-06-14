import SwiftUI
import SwiftData
import WidgetKit
import UserNotifications

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
    @AppStorage("summaryEnabled") private var summaryEnabled: Bool = false
    @AppStorage("summaryHour") private var summaryHour: Int = 21
    @AppStorage("summaryMinute") private var summaryMinute: Int = 0
    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    @AppStorage("themePresetID") private var themePresetID: String = "saffron"
    @AppStorage("launchAnimationEnabled") private var launchAnimationEnabled: Bool = true
    @AppStorage("smartParsingEnabled") private var smartParsingEnabled: Bool = true
    @AppStorage("selectedAIProvider", store: UserDefaults(suiteName: "group.com.app.Tula"))
    private var selectedProviderRaw: String = AIProvider.gemini.rawValue

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

    // Gemini config editing state
    @State private var geminiEndpoint: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var geminiModel: String = ""
    @State private var showingGeminiConfig: Bool = false
    @State private var showingAPIKeyTutorial: Bool = false

    @State private var configVersion: Int = 0

    @State private var showingThemePicker = false
    @State private var themeBeforeEdit: String = ""
    @State private var showingThemeRestartAlert = false
    @State private var showingAccounts = false
    @State private var showingCategories = false
    @State private var showingRecurring = false
    @State private var showingCurrencyPicker = false
    @State private var showingReminders = false
    @State private var showingBackup = false
    @State private var showingExport = false

    private var notificationSummary: String {
        let count = [reminderEnabled, summaryEnabled, budgetAlertsEnabled].filter { $0 }.count
        switch count {
        case 0: return "Off"
        case 3: return "All On"
        case 1:
            if reminderEnabled { return "Reminder" }
            if summaryEnabled { return "Summary" }
            return "Budget"
        default:
            var parts: [String] = []
            if reminderEnabled { parts.append("Reminder") }
            if summaryEnabled { parts.append("Summary") }
            if budgetAlertsEnabled { parts.append("Budget") }
            return parts.joined(separator: " & ")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // themeSection — parked for now
                generalSection
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
        }
    }

    // MARK: - Sections

    private var currentThemeName: String {
        TulaTheme.presets.first { $0.id == themePresetID }?.name ?? "Saffron"
    }

    private var themeSection: some View {
        Section {
            Button {
                Haptics.tap()
                themeBeforeEdit = themePresetID
                showingThemePicker = true
            } label: {
                HStack {
                    HStack(spacing: Spacing.md) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.tulaBrandFallback)
                                .frame(width: 28, height: 28)
                            Image(systemName: "paintpalette.fill")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        Text("Theme")
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    Text(currentThemeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingThemePicker, onDismiss: {
                if themePresetID != themeBeforeEdit {
                    showingThemeRestartAlert = true
                }
            }) {
                ThemePickerView(selectedID: $themePresetID)
            }
            .alert("Restart to apply theme", isPresented: $showingThemeRestartAlert) {
                Button("Restart Now") {
                    scheduleReopenAndExit()
                }
                Button("Later", role: .cancel) { }
            } message: {
                Text("Tula will close and reopen with your new theme.")
            }
        } header: {
            Text("Appearance")
        }
    }

    private func scheduleReopenAndExit() {
        let content = UNMutableNotificationContent()
        content.title = "तुला"
        content.body = "Tap to reopen with your new theme."
        content.sound = nil

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(identifier: "theme-restart", content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                exit(0)
            }
        }
    }

    private var generalSection: some View {
        Section {
            settingsLinkRow(
                title: "Currency",
                icon: "indianrupeesign.circle.fill",
                color: .green,
                trailing: "\(Currency.symbol(for: primaryCurrencyCode)) \(primaryCurrencyCode)"
            ) { showingCurrencyPicker = true }

            NavigationLink {
                RemindersView()
            } label: {
                HStack {
                    settingsLabel("Notifications", icon: "bell.badge.fill", color: .red)
                    Spacer()
                    Text(notificationSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

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
                .contentShape(Rectangle())
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
            Toggle(isOn: $smartParsingEnabled) {
                settingsLabel("Smart parsing",
                              icon: "sparkle",
                              color: Color.tulaBrandFallback)
            }
            .tint(Color.tulaBrandFallback)

            if smartParsingEnabled {
                providerPickerSection
                    .id(configVersion)
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
                .contentShape(Rectangle())
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
            // Only Gemini is shown — Apple FM and OpenAI are still in
            // the codebase but hidden from the user for now.
            let visibleProviders: [AIProvider] = [.gemini]
            ForEach(visibleProviders) { provider in
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

            // Cloud config row — shown when a cloud provider is selected
            if selectedProvider == .openAI {
                cloudConfigRow
            }
            if selectedProvider == .gemini {
                geminiConfigRow
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
                    settingsLabel("Configure",
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
                .contentShape(Rectangle())
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
                        configVersion += 1
                    }
                    .fontWeight(.semibold)
                    .disabled(cloudAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Gemini Config

    private var geminiConfigRow: some View {
        Group {
            Button {
                let config = CloudAIConfig.loadGemini()
                geminiEndpoint = config.endpoint
                geminiAPIKey = config.apiKey
                geminiModel = config.model
                showingGeminiConfig = true
            } label: {
                HStack {
                    settingsLabel("Configure",
                                  icon: "key.fill",
                                  color: .blue)
                    Spacer()
                    if CloudAIConfig.loadGemini().apiKey.isEmpty {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingGeminiConfig) {
                geminiConfigSheet
            }

            Button {
                Haptics.tap()
                showingAPIKeyTutorial = true
            } label: {
                HStack {
                    settingsLabel("How to get API key",
                                  icon: "questionmark.circle.fill",
                                  color: .purple)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingAPIKeyTutorial) {
                GeminiAPIKeyTutorialView()
            }
        }
    }

    private var geminiConfigSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        SecureField("AI...", text: $geminiAPIKey)
                            .font(.subheadline)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("gemini-2.5-flash", text: $geminiModel)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Endpoint")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", text: $geminiEndpoint)
                            .font(.subheadline)
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text("Google Gemini API")
                } footer: {
                    Text("Get a free API key at aistudio.google.com/apikey. Gemini 2.5 Flash is recommended for speed and generous free limits.")
                }
            }
            .navigationTitle("Gemini Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingGeminiConfig = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let config = CloudAIConfig(
                            endpoint: geminiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? CloudAIConfig.geminiDefault.endpoint
                                : geminiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                            apiKey: geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                            model: geminiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "gemini-2.5-flash"
                                : geminiModel.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        config.saveAsGemini()
                        showingGeminiConfig = false
                        smartTestResult = nil
                        configVersion += 1
                    }
                    .fontWeight(.semibold)
                    .disabled(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Fires the selected AI provider with a sample expense sentence and
    /// displays the result inline. Gives the user a deterministic
    /// way to verify parsing works on their device / with their key.
    private func runSmartParseTest() {
        guard SmartExpenseParser.isAvailable else {
            smartTestResult = "No AI provider configured. Add your Gemini API key."
            return
        }
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
                    case .gemini:
                        let config = CloudAIConfig.loadGemini()
                        if config.apiKey.isEmpty {
                            reason = "API key not configured. Tap 'Configure API' above."
                        } else {
                            reason = "Gemini call failed. Check your API key and model."
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
                    Text("Cloud AI selected but API key not configured. Tap 'Configure' to set up.")
                } else {
                    Text("Using cloud AI (\(CloudAIConfig.load().model)). Expense text is sent to the configured endpoint for parsing.")
                }
            case .gemini:
                if CloudAIConfig.loadGemini().apiKey.isEmpty {
                    Text("Gemini selected but API key not configured. Tap 'Configure' to set up.")
                } else {
                    Text("Using Google Gemini (\(CloudAIConfig.loadGemini().model)). Expense text/image is sent to Google's servers for parsing.")
                }
            }
        } else {
            Text("Tula will use only its built-in rule-based parser. No AI is invoked.")
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
            if let lastDate = BackupManager.lastAutoBackupDate {
                Text("Auto-backup: \(lastDate.formatted(.relative(presentation: .named))). Keeps last 7 days on device.")
            } else {
                Text("Auto-backup runs daily. Your data never leaves your device unless you share it.")
            }
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
            .contentShape(Rectangle())
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

// MARK: - Theme Picker

struct ThemePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedID: String

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 20) {
                        ForEach(TulaTheme.presets) { preset in
                            Button {
                                Haptics.selection()
                                withAnimation(.snappy(duration: 0.25)) {
                                    selectedID = preset.id
                                    TulaTheme.select(preset)
                                }
                                WidgetCenter.shared.reloadAllTimelines()
                            } label: {
                                VStack(spacing: 8) {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 48, height: 48)
                                        .overlay {
                                            if preset.id == selectedID {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                        .shadow(color: preset.color.opacity(preset.id == selectedID ? 0.5 : 0), radius: 6, y: 2)
                                    Text(preset.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(preset.id == selectedID ? .primary : .secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text("Applies across the entire app and all widgets.")
                }

                Section {
                    HStack {
                        Text("Preview")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(TulaTheme.presets.first { $0.id == selectedID }?.color ?? Color.tulaBrandFallback)
                            .frame(width: 80, height: 32)
                            .overlay {
                                Text("तुला")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                    }
                }
            }
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Gemini API Key Tutorial

/// Step-by-step guide for obtaining a free Gemini API key from
/// Google AI Studio. Each step has a number, title, and description
/// with visual cues. A prominent "Open Google AI Studio" button at
/// the bottom links directly to the key creation page.
struct GeminiAPIKeyTutorialView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, detail: String)] = [
        (
            icon: "globe",
            title: "Open Google AI Studio",
            detail: "Navigate to aistudio.google.com and sign in with your Google account."
        ),
        (
            icon: "key.fill",
            title: "Go to API Keys",
            detail: "Click on \"API Keys\" in the left sidebar menu."
        ),
        (
            icon: "plus.circle.fill",
            title: "Create API Key",
            detail: "Click the \"Create API key\" button at the top of the dashboard."
        ),
        (
            icon: "folder.fill",
            title: "Select a Project",
            detail: "Choose the default Gemini project or pick an existing Google Cloud project."
        ),
        (
            icon: "doc.on.doc.fill",
            title: "Copy Your Key",
            detail: "Give your key a name if prompted, click \"Create key\", then copy the generated key to your clipboard."
        ),
        (
            icon: "checkmark.circle.fill",
            title: "Paste in Tula",
            detail: "Go back to Settings > Smart Parsing > Configure, paste the key, and tap Save."
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    // Header
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "sparkle")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.blue)
                            Text("Get Your Free API Key")
                                .font(.title2.weight(.bold))
                        }
                        Text("Gemini offers a generous free tier. Follow these steps to get your API key in under a minute.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.lg)

                    // Steps
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: Spacing.md) {
                                // Step number with connector line
                                VStack(spacing: 0) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.blue.opacity(0.15))
                                            .frame(width: 36, height: 36)
                                        Text("\(index + 1)")
                                            .font(.subheadline.weight(.bold))
                                            .foregroundStyle(.blue)
                                    }
                                    if index < steps.count - 1 {
                                        Rectangle()
                                            .fill(Color.blue.opacity(0.15))
                                            .frame(width: 2)
                                            .frame(maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 36)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Image(systemName: step.icon)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.blue)
                                            .frame(width: 18)
                                        Text(step.title)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    Text(step.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.bottom, Spacing.lg)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.xl)

                    // Open AI Studio button
                    Button {
                        if let url = URL(string: "https://aistudio.google.com/apikey") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            Image(systemName: "arrow.up.right.square.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("Open Google AI Studio")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.horizontal, Spacing.xl)

                    // Footnote
                    Text("The free tier includes 1,500 requests/day — more than enough for personal expense tracking. Your key is stored only on your device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.xl)
                }
            }
            .background(Color.tulaBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }
}
