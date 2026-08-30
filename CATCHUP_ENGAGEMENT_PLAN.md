# Tula Gap-Aware Catch-Up — Design & Implementation Plan

Status: **implemented** (R1, phases P0–P3). Not yet compiled — see "Build status" below.
Goal: make returning after a gap the *cheapest and most rewarding* action in the app, so a few busy days stop turning into abandonment.

---

## Build status

**R1 compiles.** R2 is written and syntax-verified (`swiftc -parse`) but **not compiled** — the device shell is a Linux VM with no Swift or Xcode toolchain, so type checking and SwiftUI/SwiftData resolution happen on your machine.

```bash
open Tula.xcodeproj    # ⌘B
```

New files land in the `Tula` target automatically — the project uses Xcode 16 synchronized file groups (`objectVersion = 77`, `PBXFileSystemSynchronizedRootGroup`), so no `project.pbxproj` edit was needed. They do **not** leak into `Tula WidgetExtension` or `TulaShare`, which use explicit inclusion lists.

Two things still need you:

1. **`TulaTests/` has no Xcode target.** Files are on disk and ready; see `TulaTests/README.md` for the 30-second target creation. Adding a `PBXNativeTarget` by script was rejected as too easy to get subtly wrong and impossible to verify without a macOS build.
2. **Delete `_to_delete/`.** It holds pre-patch backups of every modified file plus the four patch scripts. The device bridge cannot delete files, so it was renamed rather than removed.

Note: `Tula Widget/Tula_Widget.swift`, `BillReminderEngine.swift`, `RecurringEngine.swift`, `RecurringRulesView.swift` and the `formatDeltaPercent` change in `Insights.swift` were already modified in your working tree before this work started — those are yours, not part of this change.

### Shipped

| File | Status |
|---|---|
| `Tula/DayKey.swift` | new — day keys + `NoSpendDayStore` |
| `Tula/LoggingStreak.swift` | new |
| `Tula/ExpenseWriter.swift` | new |
| `Tula/CatchUp/CatchUpState.swift` | new |
| `Tula/CatchUp/CatchUpDetector.swift` | new |
| `Tula/CatchUp/CatchUpCard.swift` | new |
| `Tula/CatchUp/CatchUpSheet.swift` | new |
| `Tula/HomeView.swift` | +246 — state, card, sheet, helpers, hero streak chip, deep-link observer |
| `Tula/Insights.swift` | +73 — under-budget streak bug fix |
| `Tula/NotificationManager.swift` | +105 — gap-aware reminder, dead `loggingStreak` replaced by `unloggedGap` |
| `Tula/ExpenseParser.swift` | +17 — `relativeTo:` overload |
| `Tula/ExpenseInterpreter.swift` | +13 — `referenceDate` |
| `Tula/TulaApp.swift` | +8 — `.tulaOpenCatchUp` |
| `Tula/TulaAppDelegate.swift` | +9 — catch-up route |
| `TulaTests/*` | new — 4 suites, target pending |

### Deviation from the plan, found during implementation

**An unlogged *today* must not break either streak.** The plan's §4.4 said the logging streak "counts back from today inclusive", and the §1 bug fix gated every day on being *known*. Together those meant opening the app at 9am, before the day's first spend, reported a **0-day streak** after a fortnight of daily logging — reintroducing exactly the arbitrary-feeling number the fix was meant to remove.

Both now treat today as a possible *contribution*, never a *break*: the walk starts at yesterday when today is not yet closed, and today adds one once it is. Yesterday unlogged is still a real miss. Covered by `LoggingStreakTests.unloggedTodayDoesNotBreak`, `closingTodayExtends`, `yesterdayGapIsZero`, and applied to `computeUnderBudgetStreak` in patch 4.

---

## R2 — implemented

Scope: Lock Screen quick-log, Live Activity, Info.plist cleanup. The Control widget was cut — both it and the Live Activity template turned out to be **dead code** (`Tula_WidgetBundle.swift` is entirely commented out and the active `TulaWidgetBundle` in `Tula_Widget.swift` never listed either), so there was no user-visible cruft to fix.

### R2.1 Lock Screen quick-log — the answer to "couldn't initiate"

`UNTextInputNotificationAction` on the nightly reminder. Type "coffee 120" into the notification, it parses through `ExpenseInterpreter` and saves — **the app never opens**. A second action, "Nothing spent", closes the day honestly instead of forcing the user to ignore the nag.

Deliberately no AI round-trip on this path: it has to work offline, on the Lock Screen, in the couple of seconds before iOS suspends the process.

Failure is *not* silent. Unparseable input posts a soundless notification titled with the text you typed, so nothing you wrote is lost.

### R2.2 Conditional reminder scheduling

The repeating trigger is gone. The design problem: a repeating trigger cannot be conditional (fires whether you logged or not — the habituation cause), while a single re-armed trigger *is* conditional but **fails silently** — if the app is never opened and the background task never runs, reminders stop forever, which is worse than noisy.

Resolution: queue **7 individually-addressable nights**, identifiers `tula.daily.reminder.{yyyy-MM-dd}`. A single night is cancellable by name the moment its day closes; a week of runway survives a dormant app. This mirrors how `scheduleUpcomingConfirmations` already pre-queues.

Because identifiers are deterministic, re-running *replaces* rather than duplicates — so there is no cancel-then-add race against the asynchronous pending-request sweep in `cancelDailyReminder`. Only tonight gets data-driven copy; later nights would be scheduled against data that is stale by the time they fire, and the queue is re-topped on every foreground and background refresh.

The existing `com.app.Tula.widgetRefresh` `BGAppRefreshTask` tops up the queue — no new task ID, no `UIBackgroundModes` change.

### R2.3 Live Activity — built, then removed

**Outcome: removed.** Recorded here so it does not get proposed again.

A Live Activity is for a bounded task whose **state changes without you** — a delivery moving, a timer running down, a score changing, a flight departing. The sharp form of Apple's criteria is exactly that: something you are *waiting on*.

Today's spending fails it. The number changes only because the user just told the app they spent ₹120 — they already know, they typed it. There is no external event, nothing to await, and no terminus that matters; it is a 16-hour "task" with no state transitions the user does not personally cause.

Worse, it duplicated a surface that already existed. `TulaTodayWidget` ships `.accessoryInline`, `.accessoryCircular` and `.accessoryRectangular` — Lock Screen widgets — and `TulaQuickActionsWidget` ships `.accessoryCircular` with a Lock Screen add button. Today's spend on the Lock Screen, in three sizes, plus one-tap add, all shipping before this work started. The Live Activity put the same information on the same screen with a start/stop lifecycle, a staleness problem between pushes, a foreground-only start restriction, an extra widget-target dependency, and a Settings toggle.

Three iterations of visual polish failed to make it feel worthwhile, which was the signal: the premise was wrong, not the layout.

**If a Live Activity is ever revisited**, the shape that genuinely fits is a *bounded spending event* — a trip, a wedding, a festival weekend: "Goa · ₹12,400 of ₹20,000 · day 2 of 4". Real beginning and end, decisions made against it in the moment, and a natural terminus. That needs a trip/event model that does not exist today, so it is a feature, not a fix.

Everything introduced for it was reverted: the three source files, all six call sites, the `refreshLiveActivity` option, the Settings toggle, `NSSupportsLiveActivities`, and the `project.pbxproj` widget-membership addition. Retired sources are under `_to_delete/removed-live-activity/`. The Lock Screen quick-log on the *notification* is a separate mechanism and is unaffected.

<details>
<summary>Original R2.3 design, for reference</summary>

`TulaSpendActivityAttributes` carries only plain `Codable` scalars, resolved app-side — the widget process has no store access. It is the one file that had to join both targets, which is the single `project.pbxproj` edit in this whole change (one filename added to the widget's `membershipExceptions`; backup at `project.pbxproj.pre-r2`).

`LiveActivityManager.refresh(using:)` is **idempotent**: no "first expense of the day" special case, no start/update/end state machine for callers to get wrong. It reads the day and reconciles whatever is on screen. Calling it twice is harmless; calling it after a backfill of past days correctly ends rather than starts an activity, because today is still empty.

Lock Screen shows today's total, transaction count, top category, remaining daily pace and a mic button (`tula://voice`). Dynamic Island gets compact/expanded/minimal presentations.

**Known limitation:** iOS only permits *starting* a Live Activity from the foreground. Calls from the background task or a notification action can update an existing activity but cannot create one — `Activity.request` throws `ActivityAuthorizationError.visibility`, which is swallowed by `try?`. In practice the activity starts the next time you open the app. Acceptable, since the point is presence during the day you are already using the phone.

Default **on**, with a "Today on Lock Screen" toggle in Reminders settings. Justification for the default: unlike a notification it needs no permission prompt, appears only *after* you have logged something today, and clears itself at day end — it reflects work done rather than nagging about work outstanding.

</details>

### R2.4 Info.plist

- Removed `NSExtensionPointIdentifier` from the **app** target — that key declares a target as an extension point and was a copy-paste artifact from the widget plist. This one stands.
- `NSSupportsLiveActivities` was added, then removed again with the feature.

### R2 file manifest

| File | Status |
|---|---|
| `Tula/QuickLogNotificationHandler.swift` | new — Lock Screen quick-log actions |
| `Tula/NotificationManager.swift` | queued conditional reminders, log category with text input |
| `Tula/TulaAppDelegate.swift` | Lock Screen action routing, background queue top-up |
| `Tula/ExpenseWriter.swift` | `commit(built:)` overload; `budgetAlertsEnabled` gate |
| `Tula/HomeView.swift` | four save paths migrated onto `ExpenseWriter` |
| `Tula/Info.plist` | see R2.4 |
| ~~`Tula/TulaActivityAttributes.swift`~~ | removed with R2.3 |
| ~~`Tula/LiveActivityManager.swift`~~ | removed with R2.3 |
| ~~`Tula Widget/Tula_WidgetLiveActivity.swift`~~ | removed with R2.3 |
| ~~`Tula/RemindersView.swift`~~ | toggle added then removed |
| ~~`Tula.xcodeproj/project.pbxproj`~~ | widget membership added then reverted |

### R2.5 Save-path consolidation (fallout from R2.3)

Chasing the Live Activity surfaced the real defect underneath it: `HomeView` had **four** hand-rolled insert → learn → save → refresh blocks — quick-log, voice single, voice multi, and `saveParsedExpenses` — that had drifted from each other and from `AddExpenseView`. All four now route through `ExpenseWriter.commit(built:)`, a new overload for surfaces that construct their own `Expense` (`VoiceInputOverlay` and `QuickLogBar` both hand back uninserted objects by design). Net −60 lines.

It also exposed a live bug: `ExpenseWriter` fired `evaluateBudgetThresholds` without checking `budgetAlertsEnabled`. `HomeView.evaluateBudgetAlerts()` gated it; `ExpenseWriter` did not — so migrating call sites would have started pushing budget alerts to users who had switched them off. The gate now lives in `ExpenseWriter`, which is where `evaluateBudgetThresholds`' own documentation says it belongs.

This consolidation is the part of R2.3 worth keeping.

### Still open

The Control widget / Action Button. `Tula_WidgetControl.swift` remains the `StartTimerIntent` template with a stale `kind` (`com.app.alpha.Tula.Tula Widget` — wrong bundle ID, contains a space). It is unregistered, so it is inert. Note that `LogExpenseIntent` takes a **required** `expenseDescription` parameter and therefore cannot drive a one-tap control directly; a parameterless opener intent would be needed.

---

## 1. The actual problem

The reported failure is not "I lost motivation." It is:

> "I went home and was quite busy. I knew Tula needed a log but couldn't initiate. Some days I forgot."

Two distinct failures, and the app currently handles neither.

| Failure | What the app does today |
|---|---|
| **Couldn't initiate** — had 20 seconds, not 2 minutes | Logging requires opening the app. `LogExpenseIntent`, `SpeechRecognizer`, and a Quick Actions widget all exist, but `Tula_WidgetControl.swift` is still the Xcode `StartTimerIntent` template and `Tula_WidgetLiveActivity.swift` still renders `Text("Hello \(context.state.emoji)")`. The zero-friction surfaces are stubbed, not built. |
| **Forgot, then a gap opened** | Nothing detects the gap. `HomeView.scrollContent` (line 809) renders hero → quick-log → contexts → recent. After four days away it shows *today*, as if nothing happened. There is no path back. |

**The compounding defect: the one visible streak rewards not logging.**

This is a live bug, not a design quibble. `Insights.computeUnderBudgetStreak` (Insights.swift:454) builds a day→total map and then walks backwards:

```swift
// Insights.swift:484 — an unlogged day has no entry, so daySpend == 0
let daySpend = spendByDay[cursor] ?? 0
guard daySpend <= dailyBudget else { break }
streak += 1
```

A day you didn't log is indistinguishable from a day you spent nothing, and `0 <= dailyBudget` always holds. **So every day of the gap counts toward the streak.** Stop logging entirely and the number climbs forever. The only metric currently surfaced to the user is one that rewards the exact behaviour we're trying to fix.

Meanwhile the streak that would actually reward the habit — `loggingStreak` (NotificationManager.swift:220) — is `private`, never rendered, and starts its walk at *yesterday*:

```swift
// NotificationManager.swift:222 — today can never count toward the streak
var checkDate = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
```

So: the user comes back, sees no acknowledgement of the gap, has no way to fill it, and the one number that could reward them is either measuring the wrong thing or invisible. That is the churn moment.

### Why the nightly reminder doesn't save it

```swift
// NotificationManager.swift:37
static func scheduleLogReminder(at hour: Int, minute: Int) {
    content.title = "Time to log your day"
    content.body  = "Tap to capture today's expenses in Tula."
    let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
}
```

Static copy, unconditional repeat, no `categoryIdentifier`, and `reminderEnabled` defaults to `false` (SettingsView.swift:21). It fires identically whether you logged eight expenses or none. Identical copy every night is filtered by the brain inside a week.

Note the irony: `dailySummaryContent(using:)` builds genuinely good contextual copy ("You usually spend about ₹640/day. Did today really cost zero?") — but it is wired to the **summary**, not the **reminder**.

---

## 2. Design principle

> **Reduce the cost of returning. Do not increase the pressure to not leave.**

Engagement mechanics that add pressure make a personal-finance app worse: guilt drives avoidance, and avoidance is exactly the churn we are fixing. Every mechanic below is judged on whether it makes *re-entry* cheaper, not whether it makes *absence* more costly.

This rules out, explicitly and permanently:

- Points, badges, levels, XP
- Leaderboards or any social comparison
- Loss-framed copy ("you broke your streak", "you're falling behind")
- Streaks that cannot be repaired

The existing code already gets this right — `NotificationManager.swift:131` reads *"Gentle nudge — no streak pressure."* Do not lose that when the streak mechanic lands.

---

## 3. Scope decision

### Shipping in this release (R1)

| # | Item | Why it's in |
|---|---|---|
| 1 | **Gap detection + Home catch-up card** | The core. Nothing else works without the app noticing. |
| 2 | **Multi-day backfill sheet** | The path back. Day chips + per-day quick entry. |
| 3 | **One-tap "nothing spent"** | **Hard dependency, not a nice-to-have.** Some days you genuinely spent nothing. Without it the card can never be cleared and becomes a permanent nag — which is worse than no card. |
| 4 | **Bulk-confirm overdue recurring** | Cheapest possible gap-filling: one tap reconstructs most of a typical week. Reuses the existing `cachedOverdueDates`. |
| 5 | **Logging streak, with repair via backfill** | Converts backfill from homework into reward. See §4.4 — repair falls out for free from correct derivation. |
| 6 | **Catch-up-aware reminder copy** | A "log your day" nudge during a 3-day gap is the wrong message. |
| 7 | **`ExpenseWriter` service** | Required by #2 (batch save), and pays down a real DRY debt. See §4.1. |
| 8 | **Fix the under-budget streak bug** | §1. Unlogged days currently extend the streak. Small fix, and shipping a *second* streak next to a broken one would make both untrustworthy. |

### Deferred to R2 (worth doing, not this release)

- **Live Activity** (replace the template) — all-day Lock Screen presence, no per-event permission cost.
- **`Tula_WidgetControl` → `LogExpenseIntent`** — Action Button / Control Center one-press voice log.
- **`UNTextInputNotificationAction`** on the reminder — log from the Lock Screen without opening the app. This is the highest-value answer to "couldn't initiate," but it needs the reminder rewrite (conditional scheduling + `BGAppRefreshTask`) underneath it, which is its own release.
- **Conditional/escalating reminder** — nightly re-evaluated single-fire that suppresses itself once you've logged.

### Cut, with reasons

- **Windowed recurring API** (`RecurringEngine.occurrences(for:in:)`). The explorer pass flagged that `nextOccurrence(strictlyAfter:rule:calendar:)` is `private` (RecurringEngine.swift:199) and there's no arbitrary-window function. **We don't need one.** `overdueDates(for:)` (line 447) is hardcoded to exactly the window we want — `(lastGeneratedDate ?? startDate, now]`. Don't widen an API for a requirement that doesn't exist.
- **Per-day receipt/photo backfill.** Drags in a whole camera flow for a long-tail case. Text and voice cover it.
- **Backfilling more than 7 days.** See §4.2 — a 40-day gap card is demoralising and useless.

---

## 4. Architecture

New files under a `CatchUp/` group, plus one shared service. Everything decision-making is a pure function with no `ModelContext` — the SwiftData dependency stays at the edges.

```
Tula/
├── ExpenseWriter.swift          ← shared save service (not CatchUp-specific)
├── LoggingStreak.swift          ← streak derivation
└── CatchUp/
    ├── CatchUpState.swift       ← value types
    ├── CatchUpDetector.swift    ← pure: expenses → CatchUpState
    ├── CatchUpCard.swift        ← Home surface
    └── CatchUpSheet.swift       ← the backfill flow
```

### 4.1 `ExpenseWriter` — collapse the save ritual

There is currently **no shared "save an expense" helper**. Fourteen call sites each hand-roll the same five steps, and they have drifted — `AddExpenseView.save()` (line 2193) runs learning + budget evaluation + reminder refresh; `LogExpenseIntent.perform()` (line 105) runs neither reminder refresh nor budget evaluation. Same DRY-violation-becomes-correctness-violation pattern already documented in `PARSING_REWRITE_PLAN.md` §1.

Backfill forces the issue: writing 12 expenses through the current pattern means 12 saves and 12 widget refreshes.

```swift
/// Single commit path for creating expenses. Collapses the insert → learn →
/// save → refresh ritual that is currently duplicated across ~14 call sites
/// with divergent side effects.
///
/// Batches share one `safeSave()` and one widget refresh, which is what makes
/// multi-day backfill viable — the per-expense pattern costs 12 saves for a
/// 12-expense catch-up.
@MainActor
enum ExpenseWriter {

    /// Side effects to run after the batch commits. Backfill of *past* days
    /// suppresses `evaluateBudgets` — see Hazard 4.
    struct Options {
        var learn: Bool = true
        var refreshWidgets: Bool = true
        var refreshReminder: Bool = true
        var evaluateBudgets: Bool = true
        var postSavedNotification: Bool = true

        static let backfill = Options(evaluateBudgets: false)
    }

    @discardableResult
    static func commit(
        _ drafts: [ExpenseDraft],
        source: ExpenseSource,
        in context: ModelContext,
        options: Options = .init(),
        budgets: [Budget] = []
    ) -> [Expense]
}
```

`ExpenseDraft` (EditableExpenseCard.swift:12) is already the right seam — it carries `amount`, `date`, `merchant`, `note`, `items`, `category`, `account`, `rawInput`, `confidence`. Use `context.safeSave()` (SharedStorage.swift:191), never bare `try? save()`; nothing in the app does.

**Adoption is incremental.** R1 only requires `CatchUpSheet` to use it. Migrating the other 13 call sites is a follow-up refactor — do not couple it to this release.

### 4.2 `CatchUpDetector` — pure gap detection

```swift
struct CatchUpState: Equatable {

    enum DayStatus: Equatable {
        case unlogged
        case logged(count: Int, total: Double)
        case noSpend            // user explicitly closed the day
    }

    struct Day: Identifiable, Equatable {
        let date: Date          // always calendar.startOfDay
        let status: DayStatus
        var id: Date { date }
        var needsAttention: Bool { status == .unlogged }
    }

    /// Oldest → newest. Excludes today: today is not "missed" yet.
    let days: [Day]
    /// Overdue occurrences from confirmation-required / bill rules only.
    let pendingRecurring: [PendingOccurrence]
    let truncatedOlderDays: Int   // days beyond the lookback window

    var unloggedCount: Int { days.filter(\.needsAttention).count }
    var isClear: Bool { unloggedCount == 0 && pendingRecurring.isEmpty }
}

struct PendingOccurrence: Identifiable, Equatable {
    let ruleID: UUID
    let ruleName: String
    let dueDate: Date
    let predictedAmount: Double
    var id: String { "\(ruleID)_\(Int(dueDate.timeIntervalSince1970))" }
}

enum CatchUpDetector {
    /// Maximum days shown. A 40-day gap is demoralising and unactionable;
    /// beyond this the UI offers "dismiss older" instead of chips.
    static let maxLookbackDays = 7

    /// Pure. No `ModelContext` — `HomeView` already holds `allExpenses`
    /// via `@Query`, so this costs no extra fetch.
    static func state(
        expenses: [Expense],           // reverse-sorted by date (as @Query provides)
        noSpendDays: Set<String>,      // "yyyy-MM-dd" keys
        recurring: [RecurringRule],
        overdueCache: [UUID: [Date]],  // HomeView.cachedOverdueDates
        now: Date = .now,
        calendar: Calendar = .current
    ) -> CatchUpState
}
```

Three non-obvious rules this must enforce:

1. **Clamp the window start to the user's first expense.** Otherwise a day-two user opens the app and is told they missed 7 days. `expenses.last?.date` gives it (the `@Query` is `.reverse`).
2. **Iterate with early break.** `allExpenses` is the full reverse-sorted array; we only need ~7 days. Walk from index 0 and stop once `date < windowStart`. O(k), not O(n).
3. **Expense presence beats a no-spend marker.** If a day is marked `noSpend` and later gains an expense, the expense wins and the marker is pruned. Derivation is one-directional.

**`noSpendDays` persistence — decision:** `@AppStorage("noSpendDays")`, comma-joined `yyyy-MM-dd`, following the existing `dismissedInsightIDsRaw` pattern (HomeView.swift:101). Prune keys older than 90 days to bound the string.

Rejected: a `@Model DayLog`. It would need registering in the `Schema([...])` at TulaAppDelegate.swift:235 and handling in `BackupManager`, for a value that is trivially re-derivable and low-stakes if lost. KISS. The tradeoff is explicit — markers are per-device and not carried by backup/restore; a restored user sees a few extra unlogged days. Acceptable. Upgrade to a model only if this ever needs to sync.

### 4.3 Date anchoring — the one real parser gap

`ExpenseParser.extractRelativeDate(from:)` (ExpenseParser.swift:898) resolves "yesterday" / "kal" / "parso" against a hardcoded `Date.now`. In the backfill sheet the user has *already told us the day* by selecting a chip. Typing "chai 30" while Monday is selected must land on Monday, not today.

Open/Closed — add an overload, delegate the old signature, break nothing:

```swift
// ExpenseParser.swift
static func extractRelativeDate(
    from text: String,
    relativeTo reference: Date
) -> (date: Date, remaining: String)

static func extractRelativeDate(from text: String) -> (date: Date, remaining: String) {
    extractRelativeDate(from: text, relativeTo: .now)
}
```

Then thread it through — `ExpenseInterpreter` gains a defaulted property, so all existing construction sites compile unchanged:

```swift
struct ExpenseInterpreter {
    let accounts: [Account]
    let categories: [Category]
    let merchantRules: [MerchantRule]
    let defaultAccount: Account?
    var referenceDate: Date = .now      // NEW

    func interpret(_ rawInput: String) -> [ExpenseDraft] {
        // line 63:
        let date = ExpenseParser.extractRelativeDate(from: segment,
                                                     relativeTo: referenceDate).date
    }
}
```

**For the LLM path (`SmartExpenseParser`), do not thread a reference date — override the result.** `SmartParseResult.date` is a `"yyyy-MM-dd"` string the model resolved against its own notion of today, and `SmartExpenseParser` takes no reference-date parameter at any entry point. In backfill mode the selected chip is an explicit user statement; explicit beats inferred. Discard `result.date` and stamp the anchor. This is simpler *and* more correct than trying to steer the model via `contextBlock`.

### 4.4 `LoggingStreak` — repair for free

```swift
/// Consecutive days, ending today, on which the user either logged at least
/// one expense or explicitly closed the day as no-spend.
///
/// This measures *logging*, which is the habit we want, rather than
/// `Insights.underBudgetStreak`, which measures underspending — a metric that
/// breaks on a legitimately expensive day and so teaches the user the number
/// is arbitrary.
///
/// Repair needs no machinery: the streak is derived from expense dates, so a
/// backfilled expense with a past date recomputes the streak upward on the
/// next render. Filling a gap restores the streak as a direct consequence.
enum LoggingStreak {
    static func current(
        expenses: [Expense],
        noSpendDays: Set<String>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Int
}
```

Counts back from **today inclusive** — this is the fix for the `-1` bug at NotificationManager.swift:222.

`NotificationManager.loggingStreak` (line 220) is then deleted and its call sites repointed here. One definition, one behaviour.

**This is the mechanic that makes the whole feature work.** Backfill without it is a chore. Backfill that visibly restores a 14-day streak is a reward, and the return trip becomes something the user wants rather than something they avoid.

---

## 5. File-by-file changes

### New

| File | Contents |
|---|---|
| `Tula/ExpenseWriter.swift` | §4.1. ~90 lines. |
| `Tula/LoggingStreak.swift` | §4.4. ~50 lines. |
| `Tula/CatchUp/CatchUpState.swift` | `CatchUpState`, `PendingOccurrence`. ~60 lines. |
| `Tula/CatchUp/CatchUpDetector.swift` | §4.2. ~120 lines. |
| `Tula/CatchUp/CatchUpCard.swift` | Home card. ~140 lines. |
| `Tula/CatchUp/CatchUpSheet.swift` | Backfill flow. ~380 lines — split if it passes 400. |

### Modified

**`Tula/HomeView.swift`**

- **Insert the card in `scrollContent` (line 809)**, between `offlineBanner` and `quickLogSection`. A gap is unfinished business and outranks today's quick-log; it sits below the hero so the balance stays the anchor.

  ```swift
  heroSection
  if !networkMonitor.isConnected { offlineBanner }
  if !catchUpState.isClear && !catchUpDismissed {   // NEW
      CatchUpCard(state: catchUpState) { showingCatchUp = true }
          .offset(y: appeared ? 0 : 16)
          .opacity(appeared ? 1 : 0)
          .animation(AppAnimation.gentle.delay(0.04), value: appeared)
  }
  quickLogSection
  ```

  **Bespoke section, not a `HomeContext` case, and not an `Insight`.** `otherContexts` (line 1930) renders only `insights.first`, so an `Insight`-modelled catch-up card would suppress every other insight. And any new `HomeContext` case falls through `measuredCardHeight`'s `default: return baseH` (line 1700) and clips at 64pt. A standalone section avoids both traps and is free to own its own layout.

- **New state** (~line 138): `@State private var catchUpState: CatchUpState = .clear`, `@State private var showingCatchUp = false`, `@AppStorage("noSpendDaysRaw") private var noSpendDaysRaw: String = ""`, `@AppStorage("catchUpDismissedThrough") private var catchUpDismissedThrough: Double = 0`.

  Dismissal is stored as the newest gap day's timestamp, not a bool — so a *new* gap re-surfaces the card automatically. Note the precedent to avoid: `dismissedUpcomingKeys` (line 103) is plain `@State` and silently resets each launch. Catch-up dismissal must persist.

- **Recompute on foreground.** `mainScrollViewCore` already has the hook at line 780:

  ```swift
  .onChange(of: scenePhase) { _, newPhase in
      if newPhase == .active {
          refreshRecurringCaches()
          refreshCatchUpState()        // NEW — must run after the cache refresh
          ...
      }
  }
  ```

  Also call from `.onAppear` (764) and `.refreshable` (760), and after any save that could close a day.

- **New sheet** alongside the existing block (569-731): `.sheet(isPresented: $showingCatchUp) { CatchUpSheet(...) }`.

- **Hero streak chip.** `heroSection` (line 1032) gains a chip driven by `LoggingStreak.current(...)`. Suppress below 2 days — a "1-day streak" is noise.

**`Tula/ExpenseParser.swift`** — add the `relativeTo:` overload (§4.3). ~15 lines, no behaviour change to existing callers.

**`Tula/ExpenseInterpreter.swift`** — add `var referenceDate: Date = .now`; use it at line 63. Defaulted, so all existing construction sites compile untouched.

**`Tula/Insights.swift`** — fix the unlogged-day bug in `computeUnderBudgetStreak` (line 454). A day with no entry must not count as under-budget. Gate on known days only:

```swift
// A day is only "under budget" if we actually know what happened on it:
// it has expenses, or the user explicitly closed it as no-spend. An
// unlogged day breaks the streak rather than silently extending it.
let isKnownDay = spendByDay[cursor] != nil || noSpendDays.contains(dayKey(cursor))
guard isKnownDay else { break }
```

This needs `noSpendDays` threaded into `underBudgetStreak(expenses:dailyBudget:)` (line 446) and `InsightEngine.generate` (line 82) — a defaulted parameter keeps every existing call site compiling. Retitle the `.streak` insight copy so it clearly reads as *budget*, not *logging*, and the two numbers don't look contradictory side by side.

**`Tula/NotificationManager.swift`**

- Delete `loggingStreak` (220-238); repoint to `LoggingStreak.current`.
- `refreshDailyReminder(using:)` (line 86) consults `CatchUpDetector`. When `unloggedCount >= 2`, swap to catch-up framing and set `userInfo["route"] = "catchUp"`:

  > **2 days unlogged** — Sat and Sun are still empty. Catch up in about 30 seconds.

  Neutral, specific, actionable. No loss framing.

**`Tula/TulaAppDelegate.swift`** — handle the `catchUp` route in `userNotificationCenter(_:didReceive:)` so the tap opens the sheet, not just the app.

---

## 6. The catch-up flow (UX spec)

**Card** (collapsed, Home):

```
┌────────────────────────────────────────────┐
│ ⏳  3 days unlogged                      →  │
│     Thu, Fri, Sat · 2 bills due            │
└────────────────────────────────────────────┘
```

Match `contextRowBody`'s container so it reads as part of the family: `RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.tulaCardSurface)`, 38pt icon disc at `color.opacity(0.15)`, `minHeight: 64`, `PressableScaleStyle(scale: 0.98)`.

**Sheet:**

1. **Recurring first** — highest value per tap. "2 recurring expenses were due while you were away" + per-row amount (prefilled from `SmartAmountPredictor.predict(for:on:)`) + a single **Confirm all** button.
2. **Day chips** — horizontal scroller, oldest → newest, each showing weekday + state (empty ring / count / dash for no-spend). Tapping selects; the entry field below anchors to that day.
3. **Per-day entry** — the existing quick-log field plus the mic. Text goes through `ExpenseInterpreter` with `referenceDate` set to the chip. Drafts render as `EditableExpenseCard(draft:accounts:categories:currencyCode:animateIn:)` — it already exposes a date control, so a mis-anchored draft is fixable inline.
4. **"Nothing spent this day"** — one tap, marks and advances to the next unlogged chip.
5. **Commit** — one `ExpenseWriter.commit(drafts, source: .manual, options: .backfill)` for the whole session.
6. **Close** — streak recomputes and the sheet exits on the restored number: *"14-day streak restored."* Earned, not congratulatory filler.

**Empty/edge:** if the only gap is recurring, skip straight to step 1 with no chips. If `truncatedOlderDays > 0`, show a quiet footer row: "12 older days — dismiss".

---

## 7. Sequencing

| Phase | Contents | Ships independently? |
|---|---|---|
| **P0** | `ExpenseWriter`, `LoggingStreak`, `CatchUpState`, `CatchUpDetector`, `extractRelativeDate(relativeTo:)`, `ExpenseInterpreter.referenceDate` | Yes — pure logic, nothing renders. Zero user-visible risk. |
| **P1** | `CatchUpCard` + `scrollContent` insertion + `refreshCatchUpState()` on foreground | Yes — detection visible, tap is a no-op stub. Validates the detector against real data before building the flow. |
| **P2** | `CatchUpSheet`: chips, per-day entry, no-spend close, recurring bulk confirm | Yes — the feature. |
| **P3** | Hero streak chip, notification gating, `catchUp` deep-link route | Yes — the retention loop closes. |

P0 and P1 are worth landing separately: if the detector is wrong (phantom gaps for new users, timezone drift), you find out with a card that does nothing rather than with a sheet full of bad drafts.

---

## 8. Correctness hazards

These are the things that will bite. Each was confirmed against source.

1. **`lastGeneratedDate` must advance after bulk-confirming recurring.** RecurringEngine.swift:504-514 documents it as "last *handled*", and `generateMissing` (line 70) walks forward from it. Confirm an occurrence without advancing and the next launch generates it again. Follow `TulaAppDelegate.swift:259`:

   ```swift
   if rule.lastGeneratedDate == nil || rule.lastGeneratedDate! < dueDate {
       rule.lastGeneratedDate = dueDate
   }
   ```

   Also `NotificationManager.cancelConfirmation(ruleID:dueDate:)` (line 627) per occurrence, or a stale banner fires later.

2. **`createTransaction` inserts without saving and fires no side effects** (RecurringEngine.swift:404-440). Every caller saves and refreshes itself. Bulk confirm does *one* `safeSave()` + one `WidgetRefresh.refresh(using:)` after the loop.

3. **Backfilled expenses shift account balances immediately.** `Account.derivedBalance` (Models.swift:69) sums all expenses regardless of date. This is correct — the money did leave — but **do not call `BalanceReconciler.reconcile` after a backfill**; it would bake the backfilled delta into a `BalanceAdjustment` and double-count. `BalanceReconciler` is not on any expense-save path today (only balance-update and bill-pay UI); keep it that way.

4. **Do not fire budget alerts on backfill.** `evaluateBudgetThresholds` (NotificationManager.swift:346) would push "you're over budget" for a period that already closed. Hence `Options.backfill` sets `evaluateBudgets = false`. If a backfill lands inside the *current* budget window, re-evaluate once after the batch — not per draft.

5. **New-user phantom gap.** Clamp window start to `expenses.last?.date` (§4.2 rule 1). Without it, day two shows "7 days unlogged."

6. **Timezone and DST.** Every day boundary via `calendar.startOfDay(for:)` and `calendar.date(byAdding: .day, ...)`. Never `86400` arithmetic — the user is in `Asia/Kolkata` today and travels.

7. **`@Query` ordering.** `allExpenses` is `sort: \Expense.date, order: .reverse`. The detector's early-break depends on that; if it ever changes, the detector silently under-reports. Assert the invariant in the detector rather than trusting the call site.

8. **Don't double-count `generateMissing`.** Rules with `confirmationRequired == false` are **already auto-materialised at launch** (`TulaApp.swift:150`, `TulaAppDelegate.swift:81`). `pendingRecurring` must therefore include *only* `confirmationRequired` rules and overdue `isBill` rules — otherwise the sheet offers to create expenses that already exist.

---

## 9. Testing

**There is no test target.** `Tula.xcodeproj` has exactly two products: `Tula` and `TulaShare`. Every type in §4 was deliberately designed as a pure function taking injected `now` and `calendar` precisely so this is fixable cheaply — add a `TulaTests` unit-test target and cover:

| Suite | Cases |
|---|---|
| `CatchUpDetectorTests` | clean streak → `isClear`; 3-day gap; gap clamped by first-expense date; no-spend marker honoured; marker overridden by a later expense; `maxLookbackDays` truncation; DST boundary crossing; empty expense set. |
| `LoggingStreakTests` | today counts (regression on the `-1` bug); no-spend days bridge; a gap terminates; backfilling a gap day restores the count. |
| `ExpenseParserDateTests` | `relativeTo:` overload — "yesterday" anchored to a past reference; unchanged default behaviour for every existing call site. |
| `ExpenseWriterTests` | batch commits once; `Options.backfill` suppresses budget evaluation; drafts with `isValid == false` are rejected. |
| `UnderBudgetStreakTests` | regression on §1 — an unlogged day breaks the streak instead of extending it; a no-spend-marked day still extends it; `dailyBudget == nil` returns 0. |

`ExpenseWriter` needs an in-memory `ModelContainer` (`isStoredInMemoryOnly: true`); the other three suites need no container at all.

---

## 10. What "working" looks like

Instrument these before shipping P3, or you cannot tell whether the mechanic worked:

- **Return-rate after a 2+ day gap** — the headline metric. Everything here is aimed at it.
- **Catch-up card → sheet-open rate.** Low means the card is wrong (placement, copy, or false-positive gaps).
- **Sheet-open → any-day-closed rate.** Low means the flow is too heavy; suspect the per-day entry field first.
- **Share of days closed via "nothing spent"** vs. an expense. If it dominates, the real gap is smaller than detected and the lookback should shrink.
- **Median taps to clear a 3-day gap.** Target under 10, including bulk recurring confirm.

Keep it local-only — this is a private finance app and there is no analytics stack in the project today. `UserLearningEngine`'s `UserDefaults` pattern is the precedent to follow if you want counters without adding a dependency.

---

## Appendix — API surfaces this plan depends on

Verified against source. Nothing below is inferred.

```swift
// EditableExpenseCard.swift:12  — the draft seam
struct ExpenseDraft: Equatable {
    var amount: Double; var date: Date; var merchant: String?; var note: String?
    var items: [String] = []; var category: Category?; var account: Account?
    var rawInput: String; var confidence: ParseConfidence
    var isValid: Bool { amount > 0 && account != nil }
}

// EditableExpenseCard.swift:46 — memberwise init, no callbacks, mutates via binding
EditableExpenseCard(draft: $draft, accounts:, categories:, currencyCode:, animateIn:)

// EditableExpenseCard.swift:461
struct ResultActionBar {
    var canSave: Bool; var showEdit: Bool = true; var saveTitle: String = "Save"
    var onDiscard, onStartOver, onEdit, onSave: () -> Void
}

// Models.swift:213 — note: tax/discount/receiptImageData/rawInput/items/recurringRule set post-init
Expense(amount:date:merchant:note:source:category:account:)

// ExpenseInterpreter.swift:34 — sync, no ModelContext, returns drafts
func interpret(_ rawInput: String) -> [ExpenseDraft]

// ExpenseParser.swift:898 — hardcodes Date.now; §4.3 adds the overload
static func extractRelativeDate(from text: String) -> (date: Date, remaining: String)

// RecurringEngine.swift:447 / :404 / :478
static func overdueDates(for rule: RecurringRule) -> [Date]      // window (lastGenerated, now]
static func createTransaction(rule:date:in:fallbackName:customAmount:)  // inserts, does NOT save
static func nextDueDate(for rule: RecurringRule) -> Date?

// SmartAmountPredictor.swift:62
static func predict(for rule: RecurringRule, on date: Date) -> Prediction

// SharedStorage.swift:191 — house save idiom
extension ModelContext { func safeSave(file: String = #file, line: Int = #line) }

// WidgetRefresh.swift:15
static func refresh(using context: ModelContext, upcomingRecurrings: [...] = [])

// Theme.swift — Spacing.{xs 4, sm 8, md 12, lg 16, xl 20, xxl 24, xxxl 32}
//               CornerRadius.{small 10, medium 16, large 22, xLarge 28}
//               AppAnimation.{snappy, gentle, bouncy, cardPhysics, press}
//               PressableScaleStyle(scale:), SectionHeader(title:trailing:)
// Context-stack cards hardcode cornerRadius 14, not CornerRadius.medium.
```
