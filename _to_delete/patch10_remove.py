#!/usr/bin/env python3
"""Remove the Live Activity.

A Live Activity is for a bounded task whose state changes *without you* —
delivery moving, timer running, score changing. Today's spending only changes
because the user just told the app, so there is nothing to await and no
terminus that matters. It also duplicated `TulaTodayWidget`, which already
ships `.accessoryInline` / `.accessoryCircular` / `.accessoryRectangular` —
Lock Screen widgets that own this job without the lifecycle, the staleness, or
the extra target dependency.

Everything it introduced comes out. The Lock Screen quick-log on the
*notification* is unaffected — that is a separate mechanism and it stays.
"""
import sys, pathlib, shutil

ROOT = pathlib.Path.home() / "mnt" / "Tula"
GRAVE = ROOT / "_to_delete" / "removed-live-activity"


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


GRAVE.mkdir(parents=True, exist_ok=True)


# ── 1. Widget bundle registration ──
patch("Tula Widget/Tula_Widget.swift", [(
    "unregister live activity",
    '''        TulaQuickActionsWidget()
        TulaSpendLiveActivity()
    }
}''',
    '''        TulaQuickActionsWidget()
    }
}''',
)])


# ── 2. ExpenseWriter: drop the option and both hooks ──
patch("Tula/ExpenseWriter.swift", [
    ("options field", '''        var postSavedNotification: Bool = true
        var refreshLiveActivity: Bool = true
''', '''        var postSavedNotification: Bool = true
'''),
    ("init param", '''            postSavedNotification: Bool = true,
            refreshLiveActivity: Bool = true
        ) {''', '''            postSavedNotification: Bool = true
        ) {'''),
    ("init assignment", '''            self.postSavedNotification = postSavedNotification
            self.refreshLiveActivity = refreshLiveActivity
''', '''            self.postSavedNotification = postSavedNotification
'''),
    ("commit hook", '''        if options.postSavedNotification {
            NotificationCenter.default.post(name: .tulaExpenseSaved, object: nil)
        }
        if options.refreshLiveActivity {
            LiveActivityManager.refresh(using: context)
        }
''', '''        if options.postSavedNotification {
            NotificationCenter.default.post(name: .tulaExpenseSaved, object: nil)
        }
'''),
    ("revert hook", '''        context.safeSave()
        WidgetRefresh.refresh(using: context)
        LiveActivityManager.refresh(using: context)
    }''', '''        context.safeSave()
        WidgetRefresh.refresh(using: context)
    }'''),
])


# ── 3. HomeView: drop both refresh calls ──
patch("Tula/HomeView.swift", [
    ("onReceive hook", '''                showToast("Expense saved")
                // Catches save paths that do not yet route through
                // ExpenseWriter — AddExpenseView chiefly. Idempotent, so
                // double-firing with a writer commit costs nothing.
                LiveActivityManager.refresh(using: context)
            }''', '''                showToast("Expense saved")
            }'''),
    ("cache refresh hook", '''        cachedPredictions = predictions
        LiveActivityManager.refresh(using: context)''', '''        cachedPredictions = predictions'''),
])


# ── 4. QuickLogNotificationHandler ──
patch("Tula/QuickLogNotificationHandler.swift", [(
    "lock screen log hook",
    '''        // The day is closed — tonight's reminder would now be wrong.
        NotificationManager.suppressTodaysLogReminder()
        LiveActivityManager.refresh(using: context)''',
    '''        // The day is closed — tonight's reminder would now be wrong.
        NotificationManager.suppressTodaysLogReminder()''',
)])


# ── 5. TulaAppDelegate background hook ──
patch("Tula/TulaAppDelegate.swift", [(
    "background hook",
    '''            // Top up the reminder queue and reconcile the Lock Screen while we
            // have a context and a free wake. Without this the queue drains
            // after a week for a user who never opens the app.
            NotificationManager.refreshDailyReminder(using: context)
            LiveActivityManager.refresh(using: context)''',
    '''            // Top up the reminder queue while we have a context and a free
            // wake. Without this the queue drains after a week for a user who
            // never opens the app.
            NotificationManager.refreshDailyReminder(using: context)''',
)])


# ── 6. RemindersView: drop the toggle ──
patch("Tula/RemindersView.swift", [
    ("storage", '''    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    /// Mirrors `LiveActivityManager.enabledKey`. Default true — the activity
    /// appears only after something is logged today and clears itself when the
    /// day ends, so it reflects work already done rather than nagging.
    @AppStorage(LiveActivityManager.enabledKey) private var liveActivityEnabled: Bool = true''',
     '''    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false'''),
    ("section", '''                Section {
                    Toggle("Today on Lock Screen", isOn: $liveActivityEnabled)
                        .onChange(of: liveActivityEnabled) { _, enabled in
                            Haptics.tap()
                            // Switching off should clear the Lock Screen now,
                            // not at the next save.
                            if !enabled { LiveActivityManager.endAll() }
                        }
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Shows today's spending on your Lock Screen and in the Dynamic Island once you've logged something. Disappears at the end of each day.")
                }

                if permissionDenied {''', '''                if permissionDenied {'''),
])


# ── 7. Retire the source files (device bridge cannot delete) ──
for rel in [
    "Tula/LiveActivityManager.swift",
    "Tula/TulaActivityAttributes.swift",
    "Tula Widget/Tula_WidgetLiveActivity.swift",
]:
    src = ROOT / rel
    if src.exists():
        shutil.move(str(src), str(GRAVE / src.name))
        print(f"OK   moved {rel} -> _to_delete/removed-live-activity/")


# ── 8. Revert the widget-target membership addition ──
proj = ROOT / "Tula.xcodeproj" / "project.pbxproj"
text = proj.read_text()
OLD = "\t\t\t\tTulaActivityAttributes.swift,\n"
if OLD in text:
    proj.write_text(text.replace(OLD, "", 1))
    print("OK   project.pbxproj: widget membership reverted")
else:
    print("SKIP project.pbxproj: entry already absent")


# ── 9. Drop the now-unused plist key ──
plist = ROOT / "Tula" / "Info.plist"
ptext = plist.read_text()
KEY = "\t<key>NSSupportsLiveActivities</key>\n\t<true/>\n"
if KEY in ptext:
    plist.write_text(ptext.replace(KEY, "", 1))
    print("OK   Info.plist: NSSupportsLiveActivities removed")
else:
    print("SKIP Info.plist: key already absent")

print("removal complete")
