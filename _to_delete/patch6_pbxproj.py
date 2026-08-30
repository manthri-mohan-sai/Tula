#!/usr/bin/env python3
"""Add TulaActivityAttributes.swift to the widget extension target.

`ActivityAttributes` must be one type shared by the app (which calls
`Activity.request`) and the widget (which renders it). The Tula folder is a
synchronized root group whose files join the *app* target automatically; other
targets pull specific files in through `membershipExceptions`, which for the
widget currently lists only Currency / SharedAppearance / WidgetSnapshot.

This is the one project.pbxproj edit in the whole change: a single filename
added to an existing list, anchored on the exact surrounding block so it cannot
land in the wrong target's list.
"""
import sys, pathlib, shutil

PROJ = pathlib.Path.home() / "mnt" / "Tula" / "Tula.xcodeproj" / "project.pbxproj"
text = PROJ.read_text()

OLD = '''			membershipExceptions = (
				Currency.swift,
				SharedAppearance.swift,
				WidgetSnapshot.swift,
			);'''

NEW = '''			membershipExceptions = (
				Currency.swift,
				SharedAppearance.swift,
				TulaActivityAttributes.swift,
				WidgetSnapshot.swift,
			);'''

n = text.count(OLD)
if n != 1:
    print(f"FAIL: expected exactly 1 widget membershipExceptions block, found {n}")
    sys.exit(1)

if "TulaActivityAttributes.swift" in text:
    print("SKIP: already present")
    sys.exit(0)

backup = PROJ.with_suffix(".pbxproj.pre-r2")
shutil.copy2(PROJ, backup)

PROJ.write_text(text.replace(OLD, NEW))

# Structural sanity: balanced braces/parens and the archive terminator intact.
after = PROJ.read_text()
checks = {
    "braces": after.count("{") - after.count("}"),
    "parens": after.count("(") - after.count(")"),
}
ok = all(v == 0 for v in checks.values()) and after.rstrip().endswith("}")
print("OK   project.pbxproj patched" if ok else "WARN structure looks off")
print(f"     balance: {checks}, ends with '}}': {after.rstrip().endswith('}')}")
print(f"     backup:  {backup.name}")
