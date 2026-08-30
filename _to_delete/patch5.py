#!/usr/bin/env python3
"""R2 patch: Lock Screen quick-log actions, conditional reminder scheduling,
Live Activity registration and hooks."""
import sys, pathlib

ROOT = pathlib.Path.home() / "mnt" / "Tula"

def patch(relpath, replacements):
    path = ROOT / relpath
    text = path.read_text()
    for label, old, new in replacements:
        n = text.count(old)
        if n != 1:
            print(f"FAIL [{relpath}] {label}: expected 1 match, found {n}")
            sys.exit(1)
        text = text.replace(old, new)
    path.write_text(text)
    print(f"OK   {relpath}  ({len(replacements)} edits)")


# ═══════════════════════ NotificationManager.swift ═══════════════════════

# ── 1. Replace the single repeating reminder with a queued, conditional one ──

OLD_SCHEDULE = '''    static func scheduleLogReminder(
        at hour: Int,
        minute: Int,
        context: ModelContext? = nil
    ) {
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.sound = .default

        // During an open gap, "Time to log your day" is the wrong message —
        // the user is not behind on today, they are behind on last week.
        // Naming the actual days and the effort involved is both more honest
        // and more actionable. Neutral framing throughout: no "you broke
        // your streak", because guilt drives avoidance, which is the churn
        // this is meant to reverse.
        if let context, let gap = unloggedGap(using: context), gap.count >= 2 {
            content.title = "\\(gap.count) days unlogged"
            content.body = "\\(gap.label) still empty. Catching up takes about 30 seconds."
            content.userInfo["route"] = catchUpRoute
        } else {
            content.title = "Time to log your day"
            content.body = "Tap to capture today's expenses in Tula."
        }

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
    }'''

NEW_SCHEDULE = '''    /// Identifier prefix for queued log reminders. Format:
    /// `{prefix}{yyyy-MM-dd}` — one request per night, so a single night can
    /// be cancelled by name the moment its day is closed.
    private static let logReminderPrefix = "tula.daily.reminder."

    /// Nights queued ahead.
    ///
    /// A single repeating trigger cannot be conditional — it fires whether or
    /// not you logged, which is what taught the brain to filter it. A single
    /// re-armed trigger *is* conditional but fails silently: if the app is
    /// never opened and the background task never runs, reminders stop
    /// forever. Queuing a week of individually-addressable requests gets both
    /// properties, and mirrors how `scheduleUpcomingConfirmations` already
    /// pre-queues its notifications.
    private static let logReminderQueueDepth = 7

    /// Queues the next week of nightly log reminders, skipping any night whose
    /// day is already closed.
    ///
    /// Requests use deterministic per-day identifiers, so re-running this
    /// *replaces* rather than duplicates — no cancel-then-add race with the
    /// asynchronous pending-request sweep in `cancelDailyReminder`.
    static func scheduleLogReminder(
        at hour: Int,
        minute: Int,
        context: ModelContext? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        // Retire the pre-R2 single repeating request if it is still pending.
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])

        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)

        let gap = context.flatMap { unloggedGap(using: $0) }
        let todayClosed = context.map { isDayClosed(today, using: $0, calendar: calendar) } ?? false

        for offset in 0..<logReminderQueueDepth {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fireDate = calendar.date(
                      bySettingHour: hour, minute: minute, second: 0, of: day
                  ),
                  fireDate > now
            else { continue }

            let identifier = logReminderPrefix + DayKey.string(from: day, calendar: calendar)

            // Tonight is already handled — remove any request left from an
            // earlier pass today rather than letting it fire.
            if offset == 0, todayClosed {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                continue
            }

            let content = UNMutableNotificationContent()
            content.sound = .default
            content.categoryIdentifier = logCategoryID

            // Only tonight gets data-driven copy. Later nights are scheduled
            // against data that will be stale by the time they fire, and the
            // queue is re-topped on every foreground and background refresh —
            // so tonight is always the accurate one.
            if offset == 0, let gap, gap.count >= 2 {
                // During an open gap, "Time to log your day" is the wrong
                // message: the user is not behind on today, they are behind on
                // last week. Neutral framing throughout — no "you broke your
                // streak", because guilt drives avoidance, which is the churn
                // this is meant to reverse.
                content.title = "\\(gap.count) days unlogged"
                content.body = "\\(gap.label) still empty. Catching up takes about 30 seconds."
                content.userInfo["route"] = catchUpRoute
            } else {
                content.title = "Time to log your day"
                content.body = "Type it right here, or tap to open Tula."
            }

            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: components, repeats: false
            )
            center.add(
                UNNotificationRequest(
                    identifier: identifier, content: content, trigger: trigger
                )
            ) { _ in }
        }
    }

    /// Removes tonight's reminder. Called the moment today is closed — by a
    /// save, or by the "Nothing spent" action.
    static func suppressTodaysLogReminder(calendar: Calendar = .current) {
        let identifier = logReminderPrefix + DayKey.string(from: .now, calendar: calendar)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Whether `day` needs no further attention: it has an expense, or the
    /// user explicitly closed it as no-spend.
    private static func isDayClosed(
        _ day: Date,
        using context: ModelContext,
        calendar: Calendar
    ) -> Bool {
        if NoSpendDayStore(
            raw: UserDefaults.standard.string(forKey: "noSpendDaysRaw") ?? ""
        ).contains(day, calendar: calendar) {
            return true
        }
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
        else { return false }
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }'''

# ── 2. Cancel must sweep the queued requests, not just the legacy one ──

OLD_CANCEL = '''    static func cancelDailyReminder() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [reminderID])
    }'''

NEW_CANCEL = '''    /// Cancels every pending log reminder.
    ///
    /// The prefix sweep is asynchronous, which is safe here because nothing is
    /// being scheduled concurrently — `scheduleLogReminder` deliberately does
    /// not call this, relying on deterministic identifiers to replace instead.
    static func cancelDailyReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderID])
        center.getPendingNotificationRequests { requests in
            let queued = requests.map(\\.identifier)
                .filter { $0.hasPrefix(logReminderPrefix) }
            guard !queued.isEmpty else { return }
            center.removePendingNotificationRequests(withIdentifiers: queued)
        }
    }'''

# ── 3. Lock Screen actions ──

OLD_ACTION_IDS = '''    static let confirmLogActionID = "tula.confirm.log"
    static let confirmSkipActionID = "tula.confirm.skip"'''

NEW_ACTION_IDS = '''    static let confirmLogActionID = "tula.confirm.log"
    static let confirmSkipActionID = "tula.confirm.skip"

    /// Category carried by the nightly log reminder, giving it a text field
    /// and a one-tap "nothing spent" escape.
    static let logCategoryID = "tula.log"
    static let logTextActionID = "tula.log.text"
    static let logNoSpendActionID = "tula.log.nospend"'''

OLD_CATEGORIES = '''        UNUserNotificationCenter.current().setNotificationCategories([confirmCategory, billCategory])'''

NEW_CATEGORIES = '''        // Log reminder: type the expense straight into the notification.
        // Background options (no `.foreground`) are the whole point — the
        // expense saves without the app ever coming to front, which is the
        // difference between logging in twenty seconds and not logging at all.
        let quickLogAction = UNTextInputNotificationAction(
            identifier: logTextActionID,
            title: "Log",
            options: [],
            textInputButtonTitle: "Save",
            textInputPlaceholder: "e.g. coffee 120"
        )
        // Without an honest way to close an empty day, the only way to silence
        // the nag is to ignore it — which is how users learn to ignore all of
        // them. This also protects the logging streak.
        let noSpendAction = UNNotificationAction(
            identifier: logNoSpendActionID,
            title: "Nothing spent",
            options: []
        )
        let logCategory = UNNotificationCategory(
            identifier: logCategoryID,
            actions: [quickLogAction, noSpendAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current()
            .setNotificationCategories([confirmCategory, billCategory, logCategory])'''

patch("Tula/NotificationManager.swift", [
    ("queued conditional log reminder", OLD_SCHEDULE, NEW_SCHEDULE),
    ("prefix-aware cancel", OLD_CANCEL, NEW_CANCEL),
    ("log action identifiers", OLD_ACTION_IDS, NEW_ACTION_IDS),
    ("log notification category", OLD_CATEGORIES, NEW_CATEGORIES),
])


# ═══════════════════════ TulaAppDelegate.swift ═══════════════════════

OLD_ROUTE = '''        // Gap-aware log reminder tapped — take the user straight to catch-up.
        if info["route"] as? String == NotificationManager.catchUpRoute,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                NotificationCenter.default.post(name: .tulaOpenCatchUp, object: nil)
            }
            return
        }'''

NEW_ROUTE = '''        // Lock Screen actions on the nightly log reminder. Handled before the
        // route check so the text field and "Nothing spent" work regardless of
        // which copy variant the reminder was scheduled with.
        if categoryID == NotificationManager.logCategoryID {
            switch response.actionIdentifier {
            case NotificationManager.logTextActionID:
                let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
                await QuickLogNotificationHandler.log(text: typed)
                return
            case NotificationManager.logNoSpendActionID:
                await MainActor.run { QuickLogNotificationHandler.markNoSpendToday() }
                return
            default:
                break   // a plain tap falls through to the route check below
            }
        }

        // Gap-aware log reminder tapped — take the user straight to catch-up.
        if info["route"] as? String == NotificationManager.catchUpRoute,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                NotificationCenter.default.post(name: .tulaOpenCatchUp, object: nil)
            }
            return
        }'''

# Background refresh is the queue's top-up hook: it already wakes periodically
# and already holds a context.
OLD_BG = '''            RecurringEngine.generateMissing(in: context)
            context.safeSave()
            WidgetRefresh.refresh(
                using: context,
                upcomingRecurrings: buildUpcomingRecurrings(in: context)
            )
            task.setTaskCompleted(success: true)'''

NEW_BG = '''            RecurringEngine.generateMissing(in: context)
            context.safeSave()
            WidgetRefresh.refresh(
                using: context,
                upcomingRecurrings: buildUpcomingRecurrings(in: context)
            )
            // Top up the reminder queue and reconcile the Lock Screen while we
            // have a context and a free wake. Without this the queue drains
            // after a week for a user who never opens the app.
            NotificationManager.refreshDailyReminder(using: context)
            LiveActivityManager.refresh(using: context)
            task.setTaskCompleted(success: true)'''

patch("Tula/TulaAppDelegate.swift", [
    ("lock screen log actions", OLD_ROUTE, NEW_ROUTE),
    ("background top-up", OLD_BG, NEW_BG),
])


# ═══════════════════════ ExpenseWriter.swift ═══════════════════════

OLD_WRITER = '''        if options.postSavedNotification {
            NotificationCenter.default.post(name: .tulaExpenseSaved, object: nil)
        }

        return created'''

NEW_WRITER = '''        if options.postSavedNotification {
            NotificationCenter.default.post(name: .tulaExpenseSaved, object: nil)
        }
        if options.refreshLiveActivity {
            LiveActivityManager.refresh(using: context)
        }

        return created'''

OLD_OPTIONS = '''        var learn: Bool = true
        var refreshWidgets: Bool = true
        var refreshReminder: Bool = true
        var evaluateBudgets: Bool = true
        var postSavedNotification: Bool = true

        init(
            learn: Bool = true,
            refreshWidgets: Bool = true,
            refreshReminder: Bool = true,
            evaluateBudgets: Bool = true,
            postSavedNotification: Bool = true
        ) {
            self.learn = learn
            self.refreshWidgets = refreshWidgets
            self.refreshReminder = refreshReminder
            self.evaluateBudgets = evaluateBudgets
            self.postSavedNotification = postSavedNotification
        }'''

NEW_OPTIONS = '''        var learn: Bool = true
        var refreshWidgets: Bool = true
        var refreshReminder: Bool = true
        var evaluateBudgets: Bool = true
        var postSavedNotification: Bool = true
        var refreshLiveActivity: Bool = true

        init(
            learn: Bool = true,
            refreshWidgets: Bool = true,
            refreshReminder: Bool = true,
            evaluateBudgets: Bool = true,
            postSavedNotification: Bool = true,
            refreshLiveActivity: Bool = true
        ) {
            self.learn = learn
            self.refreshWidgets = refreshWidgets
            self.refreshReminder = refreshReminder
            self.evaluateBudgets = evaluateBudgets
            self.postSavedNotification = postSavedNotification
            self.refreshLiveActivity = refreshLiveActivity
        }'''

patch("Tula/ExpenseWriter.swift", [
    ("live activity option", OLD_OPTIONS, NEW_OPTIONS),
    ("live activity hook", OLD_WRITER, NEW_WRITER),
])


# ═══════════════════════ Widget bundle registration ═══════════════════════

patch("Tula Widget/Tula_Widget.swift", [(
    "register live activity",
    '''        TulaQuickActionsWidget()
    }
}''',
    '''        TulaQuickActionsWidget()
        TulaSpendLiveActivity()
    }
}''',
)])


# ═══════════════════════ HomeView foreground hook ═══════════════════════

patch("Tula/HomeView.swift", [(
    "live activity on foreground",
    '''        cachedNextDueDates = nextDates
        cachedOverdueDates = overdueDates
        cachedPredictions = predictions''',
    '''        cachedNextDueDates = nextDates
        cachedOverdueDates = overdueDates
        cachedPredictions = predictions
        LiveActivityManager.refresh(using: context)''',
)])

print("patch5 complete")
