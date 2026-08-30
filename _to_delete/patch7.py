#!/usr/bin/env python3
"""Live Activity toggle in Reminders settings.

A Lock Screen surface should be user-reversible without digging through iOS
Settings, and discoverable rather than silently on.
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


OLD_STORAGE = '''    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false'''

NEW_STORAGE = '''    @AppStorage("budgetAlertsEnabled") private var budgetAlertsEnabled: Bool = false
    /// Mirrors `LiveActivityManager.enabledKey`. Default true — the activity
    /// appears only after something is logged today and clears itself when the
    /// day ends, so it reflects work already done rather than nagging.
    @AppStorage(LiveActivityManager.enabledKey) private var liveActivityEnabled: Bool = true'''

OLD_SECTION = '''                if permissionDenied {
                    Section {
                        Button("Open iOS Settings") {'''

NEW_SECTION = '''                Section {
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

                if permissionDenied {
                    Section {
                        Button("Open iOS Settings") {'''

patch("RemindersView.swift", [
    ("live activity storage", OLD_STORAGE, NEW_STORAGE),
    ("live activity section", OLD_SECTION, NEW_SECTION),
])

print("patch7 complete")
