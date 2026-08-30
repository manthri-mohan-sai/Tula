#!/usr/bin/env python3
"""Patch 3: deep-link the gap-aware reminder into the catch-up sheet, plus
two robustness fixes found while reviewing the first two patches."""
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


# ───────────────────────────── TulaApp.swift ─────────────────────────────

patch("TulaApp.swift", [(
    "tulaOpenCatchUp name",
    '''    static let tulaExpenseSaved = Notification.Name("tula.expenseSaved")
}''',
    '''    static let tulaExpenseSaved = Notification.Name("tula.expenseSaved")

    /// Posted when the user taps a gap-aware log reminder. HomeView observes
    /// this and opens the catch-up sheet, so the notification lands the user
    /// on the flow instead of on Home to go find it.
    static let tulaOpenCatchUp = Notification.Name("tula.openCatchUp")
}''',
)])


# ─────────────────────────── TulaAppDelegate.swift ───────────────────────────

patch("TulaAppDelegate.swift", [(
    "catch-up route handling",
    '''        let info = response.notification.request.content.userInfo
        let categoryID = response.notification.request.content.categoryIdentifier

        // Handle bill reminder "Pay Now" action''',
    '''        let info = response.notification.request.content.userInfo
        let categoryID = response.notification.request.content.categoryIdentifier

        // Gap-aware log reminder tapped — take the user straight to catch-up.
        if info["route"] as? String == NotificationManager.catchUpRoute,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                NotificationCenter.default.post(name: .tulaOpenCatchUp, object: nil)
            }
            return
        }

        // Handle bill reminder "Pay Now" action''',
)])


# ───────────────────────────── HomeView.swift ─────────────────────────────

patch("HomeView.swift", [(
    "observe catch-up deep link",
    '''            .onReceive(
                NotificationCenter.default.publisher(for: .tulaExpenseSaved)
            ) { _ in
                showToast("Expense saved")
            }''',
    '''            .onReceive(
                NotificationCenter.default.publisher(for: .tulaExpenseSaved)
            ) { _ in
                showToast("Expense saved")
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .tulaOpenCatchUp)
            ) { _ in
                // Recompute first: the notification was composed when it was
                // scheduled, so the gap may already have been filled since.
                refreshCatchUpState()
                if catchUpState.unloggedCount > 0 {
                    showingCatchUp = true
                }
            }''',
)])


# ────────────────────── NotificationManager.swift cleanup ──────────────────────

patch("NotificationManager.swift", [(
    "readable first-expense fetch",
    '''        // Never nag about days before the user's first expense.
        let firstEver = (try? context.fetch({
            var d = FetchDescriptor<Expense>(sortBy: [SortDescriptor(\\Expense.date)])
            d.fetchLimit = 1
            return d
        }()))?.first?.date''',
    '''        // Never nag about days before the user's first expense — otherwise a
        // day-two user is told they missed a week.
        var firstDescriptor = FetchDescriptor<Expense>(
            sortBy: [SortDescriptor(\\Expense.date)]
        )
        firstDescriptor.fetchLimit = 1
        let firstEver = (try? context.fetch(firstDescriptor))?.first?.date''',
)])

print("patch3 complete")
