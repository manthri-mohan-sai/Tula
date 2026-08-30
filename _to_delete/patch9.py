#!/usr/bin/env python3
"""Pace-aware Live Activity: compute expected-spend-by-now app-side."""
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


OLD_RETURN = '''        return TulaSpendActivityAttributes.ContentState(
            todayTotal: total,
            expenseCount: expenses.count,
            budgetRemaining: remaining,
            dailyBudget: pace,
            topCategoryName: top?.name,
            topCategoryIcon: top?.iconKey
        )
    }'''

NEW_RETURN = '''        var expected: Double?
        if let pace {
            expected = expectedSpend(by: .now, dailyBudget: pace, calendar: calendar)
        }

        return TulaSpendActivityAttributes.ContentState(
            todayTotal: total,
            expenseCount: expenses.count,
            budgetRemaining: remaining,
            dailyBudget: pace,
            topCategoryName: top?.name,
            topCategoryIcon: top?.iconKey,
            expectedByNow: expected
        )
    }

    // MARK: - Pace

    /// The spending day, in hours. Deliberately not midnight-to-midnight:
    /// almost nobody spends at 4am, so a midnight-based elapsed fraction
    /// badly understates the morning and would report every commuter as
    /// wildly over pace on their way to work.
    private static let dayStartHour = 7
    private static let dayEndHour = 23

    /// What `dailyBudget` implies should have been spent by `moment`.
    ///
    /// Linear across the spending window. A real spend curve is front- or
    /// back-loaded per person, and could be learned from history — but linear
    /// is honest, needs no data, and is right for a new user on day one.
    /// Worth revisiting once there is enough history to fit a curve.
    static func expectedSpend(
        by moment: Date,
        dailyBudget: Double,
        calendar: Calendar = .current
    ) -> Double {
        let hour = calendar.component(.hour, from: moment)
        let minute = calendar.component(.minute, from: moment)
        let elapsedHours = Double(hour) + Double(minute) / 60.0

        let start = Double(dayStartHour)
        let end = Double(dayEndHour)
        guard end > start else { return dailyBudget }

        if elapsedHours <= start { return 0 }
        if elapsedHours >= end { return dailyBudget }

        let fraction = (elapsedHours - start) / (end - start)
        return dailyBudget * fraction
    }'''

patch("LiveActivityManager.swift", [("expected pace", OLD_RETURN, NEW_RETURN)])
print("patch9 complete")
