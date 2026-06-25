# Account Balance Adjustment (Reconcile) — Design

**Date:** 2026-06-23
**Status:** Approved (design); pending spec review

## Problem

A credit card's balance in Tula is **derived purely from logged data**:
`Outstanding = (expenses on the card) − (payments to the card)` ([Models.swift](../../../Tula/Models.swift) `Account.derivedBalance`).

This can never reliably equal the real card, because real cards work in
**billing cycles** and accrue things Tula can't see. Concrete report that
motivated this:

- User paid their CC bill and recorded it correctly as a Bank → CC transfer.
- Bank app shows **₹4k** — spending in the *current cycle*, after the last
  statement was generated.
- Tula shows **₹10k** — a single running total with no concept of a statement
  cutoff, so it matches neither the statement nor the current spend.

Drift sources (all of which this design absorbs): billing-cycle timing,
unlogged purchases, interest/fees, refunds, and any balance the card already
carried before the user started using Tula.

The same class of problem affects bank/cash accounts (Tula tracks spending
flow, not income, so "Net flow" is not a real balance) — so the mechanism is
designed to work for **any** account kind, with credit cards as the headline
use case.

## Goals

- Let a user **re-anchor** any account to the real balance their bank shows.
- Keep an **auditable log** of every adjustment (no silent overwrites).
- **Never** corrupt spending analytics — "Spent this month", budgets, and the
  expense list are untouched by an adjustment.
- Resolve the existing gap where a credit card's `derivedBalance` ignores any
  starting balance.

## Non-goals (explicitly out of scope)

- Modeling real statement cycles: statement dates, statement generation,
  minimum due, interest accrual, due-date reminders.
- Multi-currency reconciliation.
- Back-dating adjustments to arbitrary historical points (v1 stamps "now";
  see Future work).

## Design

### Core mechanism — a balance *adjustment*

Reconciling means the user asserts "this account really shows **₹T** now." The
app computes the gap against its own current number and records the correction:

```
current = account.derivedBalance      // before this adjustment
delta    = T − current
```

- If `delta == 0` → no-op. Do **not** create a record; tell the user the
  balance already matches.
- Otherwise create a `BalanceAdjustment` with `delta` and a snapshot of the
  resulting balance `T`.

The tile then reads ₹T and tracking continues from there. An adjustment is a
**balance correction, not spending** — it creates no `Expense` and is excluded
from every spending total.

### Data model

New SwiftData model:

```swift
@Model
final class BalanceAdjustment {
    var id: UUID = UUID()
    var delta: Double = 0            // signed correction applied to the balance
    var resultingBalance: Double = 0 // the balance the user reconciled TO (snapshot)
    var date: Date = Date()          // effective date (defaults to now)
    var createdAt: Date = Date()
    var note: String? = nil
    var source: AdjustmentSource = .manual
    var account: Account?            // inverse of Account.adjustments
}

enum AdjustmentSource: String, Codable, CaseIterable {
    case manual       // standalone "Update balance"
    case billPayment  // captured during the pay-bill flow
}
```

`Account` gains:

```swift
@Relationship(deleteRule: .cascade, inverse: \BalanceAdjustment.account)
var adjustments: [BalanceAdjustment] = []
```

`resultingBalance` is stored as a snapshot so history rows can show "Balance
updated to ₹4,000" without recomputing historical state.

### Balance computation change

`Account.derivedBalance` adds the sum of adjustments:

```
adjustmentTotal = adjustments.reduce(0) { $0 + $1.delta }

creditCard:            expenses − payments + adjustmentTotal
bank / cash / wallet:  openingBalance + incoming − outgoing − expenses + adjustmentTotal
```

`displayAmount` / `displayLabel` are unchanged in logic — they read the new
`derivedBalance`.

**Credit-card starting balance.** Rather than overloading `openingBalance` for
credit cards (where it would mean "amount owed", the opposite of its
bank/cash "cash on hand" meaning), a card that already carries a balance is
seeded with an **initial adjustment** (`source = .manual`). This both fixes the
existing "CC ignores opening balance" gap and keeps one mechanism for both
seeding and ongoing correction. `openingBalance` semantics for bank/cash are
unchanged.
*(Implementation note: verify whether the account-creation UI currently
collects a balance for a CC; if so, route it to an initial adjustment.)*

### Entry point A — standalone "Update balance"

From the account detail screen (and the card tile's menu). A sheet that:

1. Shows Tula's current number for the account ("Tula shows ₹10,000").
2. Asks: "What does your bank/card show now?" → numeric field.
3. On confirm, runs the reconcile operation (`source = .manual`).

Works for any account kind; credit cards are the primary case.

### Entry point B — inside the pay-bill flow

After a Bank → CC payment is recorded (`TransferKind.cardPayment`), show an
**optional, skippable** line: "Your card now shows ₹___? (Update)". If filled,
it runs the same reconcile operation with `source = .billPayment`. If skipped,
only the transfer is recorded (today's behavior). This is a thin reuse of the
core mechanism, not a separate code path.

### History display

Adjustments appear in the account's transaction history alongside expenses and
transfers, sorted by date. Row content:

- Icon distinct from expense/transfer (e.g. `slider.horizontal.3`).
- Title: "Balance updated to ₹{resultingBalance}".
- Signed delta (e.g. "−₹6,000"), date, optional note.
- Individually deletable; deleting recomputes the balance naturally because
  `derivedBalance` sums whatever adjustments remain.

## Edge cases

- **No-op reconcile** (`delta == 0`): no record created; user is told it
  already matches.
- **Overpaid card** (resulting outstanding < 0): allowed. Surface as a "credit
  balance" rather than a negative "Outstanding".
- **Deleting an adjustment**: balance recomputes from the remaining set; confirm
  before deleting.
- **Multiple adjustments over time**: all retained and summed; each is its own
  history row.
- **Save side effects**: after creating/deleting an adjustment, save the context
  and trigger `WidgetRefresh` so the home/Accounts tiles and widget stay in sync.

## Impact / not changed

- `Expense`, "Spent this month", and the expense list: unaffected (adjustments
  are not expenses).
- **Budgets**: verify budgets are computed from spending, not from
  `derivedBalance`; if so, they are unaffected (expected). Flag for confirmation
  during implementation.

## Migration

Adding a new `@Model` and a new to-many relationship is an **additive** schema
change; existing stores load with an empty `adjustments` set and require no
custom migration. Verify lightweight migration succeeds against a populated
store before release.

## Testing

- Reconcile math: positive delta, negative delta, no-op, overpaid (negative
  resulting balance).
- `derivedBalance` including adjustments for each account kind.
- Delete-adjustment recomputation.

*Dependency:* the project currently has **no test target** (noted during the
voice-parser work). Either add a unit-test target as part of this work, or
verify the pure balance math via a standalone Swift run until a target exists.

## Future work (not now)

- Back-dating an adjustment to a specific statement date.
- A periodic "reconcile reminder" around the user's statement date.
- Optional statement-cycle modeling if users ask for billed/unbilled split.
