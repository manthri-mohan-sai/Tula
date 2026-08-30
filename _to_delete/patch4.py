#!/usr/bin/env python3
"""Patch 4: an unlogged *today* must not break a streak.

Found while reviewing the patch-1 diff. `computeUnderBudgetStreak` already
skipped today when today was over budget, but a today with no data at all fell
into the new known-day gate and broke the streak outright — so a user who had
logged for a fortnight would see "0" simply for opening the app before their
first spend of the day. That is the same arbitrary-feeling number the bug fix
was meant to eliminate.
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


OLD = '''        // Today might not be over yet — if no spending so far, it still counts.
        // Unlike past days, an unlogged today is not treated as a break: the
        // day is still in progress.
        let todaySpend = spendByDay[cursor] ?? 0
        if todaySpend > dailyBudget {
            // Today already over budget — check from yesterday
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }'''

NEW = '''        // Today is still in progress, so it is never a *break* — only a
        // possible contribution. Two cases move the cursor back a day without
        // ending the walk: today is already over budget, or today has no data
        // yet (no expenses and no no-spend marker). The second case matters
        // most: opening the app before the day's first spend must not read
        // "0-day streak" after a fortnight of daily logging.
        let todayIsKnown = knownDaySpend(
            cursor, spendByDay: spendByDay,
            noSpendDays: noSpendDays, calendar: calendar
        ) != nil
        let todaySpend = spendByDay[cursor] ?? 0
        if !todayIsKnown || todaySpend > dailyBudget {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }'''

patch("Insights.swift", [("today never breaks the streak", OLD, NEW)])
print("patch4 complete")
