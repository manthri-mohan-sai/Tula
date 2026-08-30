# TulaTests

Unit cover for the gap-aware catch-up work. **The Xcode target does not exist yet** — the project has exactly two products (`Tula`, `TulaShare`), so these files are on disk but not yet compiled.

## Adding the target (one time, ~30 seconds)

1. **File → New → Target → Unit Testing Bundle**
2. Product Name: `TulaTests` · Target to be Tested: `Tula`
3. Xcode creates the target with a `TulaTests` group. Because the project uses Xcode 16 synchronized file groups (`objectVersion = 77`), **delete the placeholder file Xcode generates** and point the group at this existing folder — every file here is picked up automatically.
4. `⌘U`

The target was not added by script on purpose: hand-editing `project.pbxproj` to add a `PBXNativeTarget`, its build phases, and a scheme entry is easy to get subtly wrong and impossible to verify without a macOS build, which is not available in this environment.

## What is covered

| Suite | Covers |
|---|---|
| `LoggingStreakTests` | today counts (regression on the old `-1 day` walk), gaps terminate, no-spend days bridge, **backfill repairs the streak**, order independence, lookback bound |
| `CatchUpDetectorTests` | window clamping to first expense, today excluded, lookback cap and truncation, no-spend resolution, expense-beats-stale-marker, `notBefore` horizon, recurring filters (auto-generated excluded, paused excluded, paid bills excluded) |
| `UnderBudgetStreakTests` | **regression on the unlogged-day bug** — silent days no longer inflate the streak; over-budget still breaks; no-spend days still count |
| `DateAnchoringTests` | the `relativeTo:` overload resolves against the anchor; the original signature's behaviour is unchanged; `DayKey` round-trips; `NoSpendDayStore` marks, persists, prunes |

## Notes

Everything under test takes an injected `now` and `calendar`, so the suites pin a UTC gregorian calendar via `TestCalendar` and cannot pass locally while failing in CI on a time-zone difference.

The one exception is `UnderBudgetStreakTests`: `InsightEngine.underBudgetStreak` reads `Calendar.current` and `Date.now` internally, so those cases build dates the same way. The only theoretical flake is a run that straddles local midnight. If that ever bites, add injected `now`/`calendar` parameters to the public `underBudgetStreak` the way `LoggingStreak.current` has them.

No `ModelContainer` is needed anywhere — SwiftData `@Model` instances are ordinary objects until inserted, and none of these suites insert.
