#!/usr/bin/env python3
"""Fix: the Live Activity never appeared.

Two causes, both mine.

1. Coverage. `LiveActivityManager.refresh` was wired into `ExpenseWriter`, but
   the three `HomeView` save closures — quick-log, voice single, voice multi —
   plus `saveParsedExpenses` each hand-rolled their own insert/save/refresh
   ritual and never called it. Logging an expense therefore did nothing until
   the app was backgrounded and reopened, which is when
   `refreshRecurringCaches` runs. Migrating those four onto
   `ExpenseWriter.commit(built:)` fixes the bug and removes the quadruplicated
   ritual at the same time.

2. Diagnosability. `try? Activity.request(...)` swallowed the reason, so a
   silent failure was indistinguishable from a wiring problem. Now logged.
"""
import sys, pathlib

ROOT = pathlib.Path.home() / "mnt" / "Tula" / "Tula"

def patch(filename, replacements):
    path = ROOT / filename
    text = path.read_text()
    for label, old, new in replacements:
        n = text.count(old)
        if n != 1:
            print(f"FAIL [{filename}] {label}: expected 1 match, found {n}")
            sys.exit(1)
        text = text.replace(old, new)
    path.write_text(text)
    print(f"OK   {filename}  ({len(replacements)} edits)")


# ═════════════════════ LiveActivityManager: diagnostics ═════════════════════

OLD_IMPORTS = '''import ActivityKit
import Foundation
import SwiftData'''

NEW_IMPORTS = '''import ActivityKit
import Foundation
import OSLog
import SwiftData'''

OLD_REQUEST = '''        // Throws when the user has disabled activities for Tula specifically,
        // when the system budget is exhausted, or — the common one — when the
        // app is in the background: iOS only permits *starting* an activity
        // from the foreground. None of that is actionable, and none of it
        // should disturb a save that already succeeded. The activity then
        // starts on the next foreground refresh.
        _ = try? Activity.request(
            attributes: attributes, content: content, pushType: nil
        )
    }'''

NEW_REQUEST = '''        // Failure is not actionable and must never disturb a save that already
        // succeeded — but it must be *visible*. Swallowing the error with
        // `try?` made a silent no-show indistinguishable from a wiring
        // problem, which is exactly the debugging dead end this avoids.
        //
        // The usual cause is `.visibility`: iOS only permits *starting* an
        // activity from the foreground, so calls from the background task or a
        // notification action can update an existing activity but not create
        // one. That resolves itself on the next foreground refresh.
        do {
            _ = try Activity.request(
                attributes: attributes, content: content, pushType: nil
            )
            lastStartFailure = nil
        } catch {
            lastStartFailure = String(describing: error)
            log.error("Live Activity start failed: \\(String(describing: error), privacy: .public)")
        }
    }

    /// Last `Activity.request` failure, for surfacing in diagnostics. Nil once
    /// an activity has started successfully.
    private(set) static var lastStartFailure: String?

    private static let log = Logger(subsystem: "com.app.Tula", category: "LiveActivity")

    /// One-line description of why nothing is on the Lock Screen right now.
    /// Read this before assuming the feature is broken.
    static func diagnosis(using context: ModelContext) -> String {
        if !isEnabled { return "Off in Settings › Notifications › Live Activity." }
        if !systemAllows {
            return "Live Activities are disabled for Tula in iOS Settings."
        }
        let dayStart = Calendar.current.startOfDay(for: .now)
        if snapshot(using: context, dayStart: dayStart, calendar: .current) == nil {
            return "Nothing logged today — the activity only appears once you log an expense."
        }
        if let lastStartFailure {
            return "Last start attempt failed: \\(lastStartFailure)"
        }
        return running.isEmpty ? "Ready, but no activity running." : "Running."
    }'''

patch("LiveActivityManager.swift", [
    ("OSLog import", OLD_IMPORTS, NEW_IMPORTS),
    ("visible failure + diagnosis", OLD_REQUEST, NEW_REQUEST),
])


# ═════════════════ HomeView: route every save through ExpenseWriter ═════════

# ── voice, single ──
OLD_VOICE_ONE = '''                    onSave: { expense in
                        context.insert(expense)
                        UserLearningEngine.learn(
                            merchant: expense.merchant,
                            category: expense.category?.name,
                            amount: expense.amount,
                            hour: Calendar.current.component(
                                .hour,
                                from: expense.date
                            )
                        )
                        context.safeSave()
                        WidgetRefresh.refresh(using: context)
                        NotificationManager.refreshDailyReminder(using: context)
                        if let acct = expense.account {
                            lastUsedAccountID = acct.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("Expense saved · Voice")
                        evaluateBudgetAlerts()
                    },'''

NEW_VOICE_ONE = '''                    onSave: { expense in
                        ExpenseWriter.commit(
                            built: [expense],
                            in: context,
                            budgets: Array(activeBudgets)
                        )
                        if let acct = expense.account {
                            lastUsedAccountID = acct.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("Expense saved · Voice")
                    },'''

# ── voice, multi ──
OLD_VOICE_MANY = '''                    onSaveMany: { expenses in
                        guard !expenses.isEmpty else { return }
                        for expense in expenses {
                            context.insert(expense)
                            UserLearningEngine.learn(
                                merchant: expense.merchant,
                                category: expense.category?.name,
                                amount: expense.amount,
                                hour: Calendar.current.component(
                                    .hour,
                                    from: expense.date
                                )
                            )
                        }
                        context.safeSave()
                        WidgetRefresh.refresh(using: context)
                        NotificationManager.refreshDailyReminder(using: context)
                        if let last = expenses.last?.account {
                            lastUsedAccountID = last.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("\\(expenses.count) expenses saved · Voice")
                        evaluateBudgetAlerts()
                    },'''

NEW_VOICE_MANY = '''                    onSaveMany: { expenses in
                        guard !expenses.isEmpty else { return }
                        ExpenseWriter.commit(
                            built: expenses,
                            in: context,
                            budgets: Array(activeBudgets)
                        )
                        if let last = expenses.last?.account {
                            lastUsedAccountID = last.id.uuidString
                        }
                        Haptics.success()
                        triggerSavePulse()
                        showToast("\\(expenses.count) expenses saved · Voice")
                    },'''

# ── quick-log bar ──
OLD_QUICKLOG = '''            onSaveDrafts: { expenses in
                guard !expenses.isEmpty else { return }
                for expense in expenses {
                    context.insert(expense)
                    UserLearningEngine.learn(
                        merchant: expense.merchant,
                        category: expense.category?.name,
                        amount: expense.amount,
                        hour: Calendar.current.component(
                            .hour,
                            from: expense.date
                        )
                    )
                }
                context.safeSave()
                WidgetRefresh.refresh(using: context)
                NotificationManager.refreshDailyReminder(using: context)
                if let last = expenses.last?.account {
                    lastUsedAccountID = last.id.uuidString
                }
                Haptics.success()
                triggerSavePulse()
                showToast(
                    expenses.count > 1
                        ? "\\(expenses.count) expenses saved" : "Expense saved"
                )
                evaluateBudgetAlerts()
            },'''

NEW_QUICKLOG = '''            onSaveDrafts: { expenses in
                guard !expenses.isEmpty else { return }
                ExpenseWriter.commit(
                    built: expenses,
                    in: context,
                    budgets: Array(activeBudgets)
                )
                if let last = expenses.last?.account {
                    lastUsedAccountID = last.id.uuidString
                }
                Haptics.success()
                triggerSavePulse()
                showToast(
                    expenses.count > 1
                        ? "\\(expenses.count) expenses saved" : "Expense saved"
                )
            },'''

# ── rule-based fallback path ──
OLD_PARSED = '''        context.safeSave()
        WidgetRefresh.refresh(using: context)
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        let undoTargets = savedExpenses
        showToast(
            valid.count == 1 ? "Expense saved" : "\\(valid.count) expenses saved"
        ) {
            for expense in undoTargets {
                context.delete(expense)
            }
            context.safeSave()
            WidgetRefresh.refresh(using: context)
            Haptics.warning()
        }
        evaluateBudgetAlerts()'''

NEW_PARSED = '''        ExpenseWriter.commit(
            built: savedExpenses,
            in: context,
            budgets: Array(activeBudgets)
        )
        if let last = lastAccount { lastUsedAccountID = last.id.uuidString }
        Haptics.success()
        triggerSavePulse()
        let undoTargets = savedExpenses
        showToast(
            valid.count == 1 ? "Expense saved" : "\\(valid.count) expenses saved"
        ) {
            ExpenseWriter.revert(undoTargets, in: context)
            Haptics.warning()
        }'''

# `savedExpenses` is now built but not inserted — ExpenseWriter owns insertion,
# learning and the save, so the loop must not do them itself.
OLD_PARSED_LOOP = '''            expense.rawInput = parsed.rawInput
            context.insert(expense)
            UserLearningEngine.learn(
                merchant: expense.merchant,
                category: expense.category?.name,
                amount: expense.amount,
                hour: Calendar.current.component(.hour, from: expense.date)
            )
            lastAccount = account
            savedExpenses.append(expense)'''

NEW_PARSED_LOOP = '''            expense.rawInput = parsed.rawInput
            lastAccount = account
            savedExpenses.append(expense)'''

# ── catch-all for save paths outside HomeView (AddExpenseView posts this) ──
OLD_ONRECEIVE = '''            .onReceive(
                NotificationCenter.default.publisher(for: .tulaExpenseSaved)
            ) { _ in
                showToast("Expense saved")
            }'''

NEW_ONRECEIVE = '''            .onReceive(
                NotificationCenter.default.publisher(for: .tulaExpenseSaved)
            ) { _ in
                showToast("Expense saved")
                // Catches save paths that do not yet route through
                // ExpenseWriter — AddExpenseView chiefly. Idempotent, so
                // double-firing with a writer commit costs nothing.
                LiveActivityManager.refresh(using: context)
            }'''

patch("HomeView.swift", [
    ("voice single save", OLD_VOICE_ONE, NEW_VOICE_ONE),
    ("voice multi save", OLD_VOICE_MANY, NEW_VOICE_MANY),
    ("quick-log save", OLD_QUICKLOG, NEW_QUICKLOG),
    ("parsed-expense loop", OLD_PARSED_LOOP, NEW_PARSED_LOOP),
    ("parsed-expense save", OLD_PARSED, NEW_PARSED),
    ("expense-saved catch-all", OLD_ONRECEIVE, NEW_ONRECEIVE),
])

print("patch8 complete")
