import SwiftUI
import UserNotifications

struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("reminderEnabled") private var reminderEnabled: Bool = false
    @AppStorage("reminderHour") private var reminderHour: Int = 21
    @AppStorage("reminderMinute") private var reminderMinute: Int = 0

    @AppStorage("summaryEnabled") private var summaryEnabled: Bool = false
    @AppStorage("summaryHour") private var summaryHour: Int = 21
    @AppStorage("summaryMinute") private var summaryMinute: Int = 0

    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    private var reminderTime: Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = reminderHour; c.minute = reminderMinute
        return Calendar.current.date(from: c) ?? .now
    }

    private var summaryTime: Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        c.hour = summaryHour; c.minute = summaryMinute
        return Calendar.current.date(from: c) ?? .now
    }

    private var permissionDenied: Bool { authStatus == .denied }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Log reminder", isOn: $reminderEnabled)
                        .disabled(permissionDenied)
                        .onChange(of: reminderEnabled) { _, enabled in
                            if enabled {
                                requestAndScheduleReminder()
                            } else {
                                NotificationManager.cancelDailyReminder()
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
                                    NotificationManager.scheduleLogReminder(at: reminderHour, minute: reminderMinute)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Log Reminder")
                } footer: {
                    if reminderEnabled {
                        Text("A gentle nudge to log any expenses you might have missed.")
                    } else {
                        Text("Get reminded to log expenses at a specific time each day.")
                    }
                }

                Section {
                    Toggle("Daily summary", isOn: $summaryEnabled)
                        .disabled(permissionDenied)
                        .onChange(of: summaryEnabled) { _, enabled in
                            if enabled {
                                requestAndScheduleSummary()
                            } else {
                                NotificationManager.cancelDailySummary()
                                Haptics.tap()
                            }
                        }

                    if summaryEnabled {
                        DatePicker(
                            "Time",
                            selection: Binding(
                                get: { summaryTime },
                                set: { newDate in
                                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                    summaryHour = comps.hour ?? 21
                                    summaryMinute = comps.minute ?? 0
                                    NotificationManager.scheduleDailySummary(at: summaryHour, minute: summaryMinute)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Daily Summary")
                } footer: {
                    if summaryEnabled {
                        Text("Get a personalized spending summary with insights — top categories, comparisons to your average, and streaks.")
                    } else {
                        Text("Receive a daily summary of what you spent, with smart insights.")
                    }
                }

                if permissionDenied {
                    Section {
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } footer: {
                        Text("Notifications are off for Tula. Open iOS Settings to enable them.")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                authStatus = await NotificationManager.currentStatus()
            }
        }
    }

    private func requestAndScheduleReminder() {
        Task {
            let granted = await NotificationManager.requestAuthorization()
            authStatus = await NotificationManager.currentStatus()
            if granted {
                NotificationManager.scheduleLogReminder(at: reminderHour, minute: reminderMinute)
                Haptics.success()
            } else {
                reminderEnabled = false
                Haptics.warning()
            }
        }
    }

    private func requestAndScheduleSummary() {
        Task {
            let granted = await NotificationManager.requestAuthorization()
            authStatus = await NotificationManager.currentStatus()
            if granted {
                NotificationManager.scheduleDailySummary(at: summaryHour, minute: summaryMinute)
                Haptics.success()
            } else {
                summaryEnabled = false
                Haptics.warning()
            }
        }
    }
}
