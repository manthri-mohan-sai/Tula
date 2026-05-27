import SwiftUI
import UserNotifications

/// Daily reminder configuration. User can enable/disable + choose time.
/// Stores enabled state and time in @AppStorage for persistence.
struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reminderEnabled") private var reminderEnabled: Bool = false
    @AppStorage("reminderHour") private var reminderHour: Int = 21        // 9 PM default
    @AppStorage("reminderMinute") private var reminderMinute: Int = 0

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingSettingsAlert = false

    private var reminderTime: Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = reminderHour
        components.minute = reminderMinute
        return Calendar.current.date(from: components) ?? .now
    }

    private var permissionDenied: Bool {
        authStatus == .denied
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Daily reminder", isOn: $reminderEnabled)
                        .disabled(permissionDenied)
                        .onChange(of: reminderEnabled) { _, enabled in
                            if enabled {
                                requestAndSchedule()
                            } else {
                                NotificationManager.cancel()
                                Haptics.tap()
                            }
                        }

                    if reminderEnabled {
                        DatePicker(
                            "Time",
                            selection: Binding(
                                get: { reminderTime },
                                set: { newDate in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    reminderHour = comps.hour ?? 21
                                    reminderMinute = comps.minute ?? 0
                                    NotificationManager.scheduleDailyReminder(at: reminderHour, minute: reminderMinute)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Reminder")
                } footer: {
                    if permissionDenied {
                        Text("Notifications are off for Tula. Open iOS Settings to enable them.")
                            .foregroundStyle(.red)
                    } else if reminderEnabled {
                        Text("Tula will nudge you once a day to capture expenses you might have missed.")
                    } else {
                        Text("Enable a daily reminder so you don't forget to log expenses.")
                    }
                }

                if permissionDenied {
                    Section {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                authStatus = await NotificationManager.currentStatus()
            }
        }
    }

    private func requestAndSchedule() {
        Task {
            let granted = await NotificationManager.requestAuthorization()
            authStatus = await NotificationManager.currentStatus()
            if granted {
                NotificationManager.scheduleDailyReminder(at: reminderHour, minute: reminderMinute)
                Haptics.success()
            } else {
                reminderEnabled = false
                Haptics.warning()
            }
        }
    }
}
