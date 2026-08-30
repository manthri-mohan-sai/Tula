#!/usr/bin/env python3
"""Add the `.automation` expense source.

Safe as an additive enum case: nothing switches exhaustively over
`ExpenseSource`, and `BackupManager` already decodes with
`ExpenseSource(rawValue:) ?? .manual`, so an older build restoring a newer
backup degrades to `.manual` rather than failing.
"""
import sys, pathlib

PATH = pathlib.Path.home() / "mnt" / "Tula" / "Tula" / "Models.swift"
text = PATH.read_text()

OLD = '''    case imported     // Imported from a CSV file
}'''
NEW = '''    case imported     // Imported from a CSV file
    case automation   // Parsed from a bank/card alert via Shortcuts
}'''

n = text.count(OLD)
if n != 1:
    print(f"FAIL: expected 1 match, found {n}")
    sys.exit(1)

PATH.write_text(text.replace(OLD, NEW))
print("OK   Models.swift: ExpenseSource.automation added")
