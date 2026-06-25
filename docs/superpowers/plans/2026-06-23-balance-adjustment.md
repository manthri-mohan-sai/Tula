# Account Balance Adjustment (Reconcile) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users re-anchor any account's balance to the real value their bank/card shows, recording each correction as an auditable, deletable `BalanceAdjustment` — without ever touching spending totals.

**Architecture:** A new lightweight SwiftData model (`BalanceAdjustment`) is summed into `Account.derivedBalance`. A pure helper (`BalanceReconciler`) computes the signed delta and inserts the record. Two UI entry points reuse that helper: a standalone "Update balance" sheet, and an optional field in the existing pay-bill (card-payment) flow. Adjustments render in the account history alongside expenses/transfers.

**Tech Stack:** Swift, SwiftUI, SwiftData. iOS app (`Tula` target). Spec: [docs/superpowers/specs/2026-06-23-balance-adjustment-design.md](specs/2026-06-23-balance-adjustment-design.md).

**Before starting:** the repo's default branch is `main`. Create a feature branch:
```bash
git checkout -b feature/balance-adjustment
```

**Testing note:** the project has **no XCTest target**. Pure arithmetic (`BalanceReconciler.delta`) is verified with a standalone `swift` run (Task 3). Model/UI changes are verified by a successful `xcodebuild` and the manual checklist in Task 7. Build command used throughout:
```bash
xcodebuild -project Tula.xcodeproj -scheme Tula -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```
Run it from the repo root (`/Users/mohan.manthri/Documents/personal/projects/Tula`).

---

### Task 1: `BalanceAdjustment` model + schema registration

**Files:**
- Modify: `Tula/Models.swift` (add model after the `TransferKind` enum, ~line 263)
- Modify: `Tula/TulaApp.swift:62-65` (schema)
- Modify: `Tula/LogExpenseIntent.swift:347-355` (schema)
- Modify: `Tula/TulaAppDelegate.swift:235-238` (schema)

- [ ] **Step 1: Add the model + source enum**

In `Tula/Models.swift`, immediately after the `TransferKind` enum (the `}` on ~line 263), insert:

```swift
// MARK: - Balance Adjustment

/// A manual correction that re-anchors an account's balance to the real
/// value the user's bank/card shows. It is NOT spending — never counted in
/// "Spent this month", budgets, or the expense list. Auditable: each
/// reconcile is its own record, shown in the account's history and
/// individually deletable.
@Model
final class BalanceAdjustment {
    var id: UUID = UUID()

    /// Signed correction applied to the account balance: target − previous.
    /// Positive raised the balance, negative lowered it.
    var delta: Double = 0

    /// The balance the user reconciled TO, snapshotted so history rows can
    /// show "Balance updated to ₹X" without recomputing historical state.
    var resultingBalance: Double = 0

    var date: Date = Date()
    var createdAt: Date = Date()
    var note: String? = nil
    var source: AdjustmentSource = AdjustmentSource.manual

    var account: Account?

    init(delta: Double, resultingBalance: Double, account: Account?,
         date: Date = .now, source: AdjustmentSource = .manual, note: String? = nil) {
        self.delta = delta
        self.resultingBalance = resultingBalance
        self.account = account
        self.date = date
        self.source = source
        self.note = note
    }
}

enum AdjustmentSource: String, Codable, CaseIterable {
    case manual        // standalone "Update balance"
    case billPayment   // captured during the pay-bill flow
}
```

- [ ] **Step 2: Register the model in all three Schema lists**

In `Tula/TulaApp.swift`, change lines 62-65 to add `BalanceAdjustment.self`:

```swift
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
            BalanceAdjustment.self,
        ])
```

In `Tula/LogExpenseIntent.swift`, change lines 347-355 to:

```swift
    let schema = Schema([
        Account.self,
        Category.self,
        Expense.self,
        Transfer.self,
        RecurringRule.self,
        MerchantRule.self,
        Budget.self,
        BalanceAdjustment.self,
    ])
```

In `Tula/TulaAppDelegate.swift`, change lines 235-238 to:

```swift
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
            BalanceAdjustment.self,
        ])
```

- [ ] **Step 3: Build to verify it compiles**

Run the build command. Expected: `** BUILD SUCCEEDED **`. (The `Account.adjustments` relationship doesn't exist yet — that's fine; the model compiles standalone because `account` is just an optional reference.)

- [ ] **Step 4: Commit**

```bash
git add Tula/Models.swift Tula/TulaApp.swift Tula/LogExpenseIntent.swift Tula/TulaAppDelegate.swift
git commit -m "feat(accounts): add BalanceAdjustment model + schema registration"
```

---

### Task 2: Wire adjustments into `Account.derivedBalance` + display

**Files:**
- Modify: `Tula/Models.swift` — `Account` (relationship ~line 44, `derivedBalance` ~line 66, `displayAmount` ~line 83, `displayLabel` ~line 96)

- [ ] **Step 1: Add the relationship**

In `Tula/Models.swift`, after the `incomingTransfers` relationship (~line 44), add:

```swift
    @Relationship(deleteRule: .cascade, inverse: \BalanceAdjustment.account)
    var adjustments: [BalanceAdjustment] = []
```

- [ ] **Step 2: Include adjustments in `derivedBalance`**

Replace the `derivedBalance` computed property body with:

```swift
    var derivedBalance: Double {
        let expenseTotal = expenses.reduce(0) { $0 + $1.amount }
        let outgoing = outgoingTransfers.reduce(0) { $0 + $1.amount }
        let incoming = incomingTransfers.reduce(0) { $0 + $1.amount }
        let adjustmentTotal = adjustments.reduce(0) { $0 + $1.delta }

        switch kind {
        case .creditCard:
            return expenseTotal - incoming + adjustmentTotal
        case .bank, .cash, .wallet:
            return openingBalance + incoming - outgoing - expenseTotal + adjustmentTotal
        }
    }
```

- [ ] **Step 3: Handle overpaid (credit-balance) display for credit cards**

This covers the spec's "overpaid card → credit balance" edge case. Replace `displayAmount`'s `.creditCard, .bank` case and the whole `displayLabel` with:

In `displayAmount`, change:
```swift
        case .creditCard, .bank:
            return derivedBalance
```
to:
```swift
        case .creditCard:
            // Show magnitude; the label distinguishes owed vs. credit so we
            // never render a confusing negative "Outstanding".
            return abs(derivedBalance)
        case .bank:
            return derivedBalance
```

Replace `displayLabel` with:
```swift
    var displayLabel: String {
        switch kind {
        case .creditCard: return derivedBalance < 0 ? "Credit balance" : "Outstanding"
        case .bank:       return "Net flow"
        case .cash:
            return derivedBalance < 0 ? "Spent" : "On hand"
        case .wallet:
            return derivedBalance < 0 ? "Spent" : "Balance"
        }
    }
```

(Note: `AccountDetailView.creditLimitBar` reads `account.derivedBalance` directly, not `displayAmount`, so the credit-limit bar is unaffected.)

- [ ] **Step 4: Build to verify**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Tula/Models.swift
git commit -m "feat(accounts): sum balance adjustments into derivedBalance; show CC credit balance"
```

---

### Task 3: `BalanceReconciler` helper (with standalone math verification)

**Files:**
- Create: `Tula/BalanceReconciler.swift`
- Temp test: `/tmp/reconcile_test/main.swift` (deleted after verification)

- [ ] **Step 1: Write the failing standalone test for the pure delta math**

Create `/tmp/reconcile_test/main.swift`:

```swift
import Foundation

enum BalanceReconciler {
    static func delta(target: Double, current: Double) -> Double { target - current }
}

let cases: [(target: Double, current: Double, expected: Double)] = [
    (4000, 10000, -6000),   // user paid down; app was too high
    (12000, 10000,  2000),  // app was too low (missed a purchase)
    (10000, 10000,     0),  // already matches -> no-op upstream
    (-500,  0,      -500),  // overpaid -> credit balance
]
var failures = 0
for c in cases {
    let got = BalanceReconciler.delta(target: c.target, current: c.current)
    let ok = abs(got - c.expected) < 0.0001
    if !ok { failures += 1 }
    print("\(ok ? "✅" : "❌")  delta(target:\(c.target), current:\(c.current)) = \(got)\(ok ? "" : "  expected \(c.expected)")")
}
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run it to confirm the math is right**

Run: `cd /tmp/reconcile_test && swift main.swift`
Expected: all ✅ and `ALL PASS`. (This validates the exact arithmetic the real helper will use.)

- [ ] **Step 3: Create the real helper**

Create `Tula/BalanceReconciler.swift`:

```swift
import Foundation
import SwiftData

/// Re-anchors an account's balance to a user-supplied real value by
/// recording a `BalanceAdjustment`. The arithmetic (`delta`) is a pure
/// function so it can be reasoned about and verified without SwiftData.
enum BalanceReconciler {

    /// The signed correction needed to move `current` to `target`.
    static func delta(target: Double, current: Double) -> Double {
        target - current
    }

    /// Reconcile `account` to `target`. Creates and inserts a
    /// `BalanceAdjustment` for the gap, unless the balance already matches
    /// (within a cent), in which case it is a no-op and returns nil.
    ///
    /// The caller is responsible for saving the context and refreshing
    /// widgets — keeping side effects at the call site mirrors how the
    /// app's other write paths (TransferFormView, HomeView) work.
    @discardableResult
    static func reconcile(account: Account,
                          to target: Double,
                          source: AdjustmentSource,
                          date: Date = .now,
                          note: String? = nil,
                          in context: ModelContext) -> BalanceAdjustment? {
        let d = delta(target: target, current: account.derivedBalance)
        guard abs(d) >= 0.01 else { return nil }

        let adjustment = BalanceAdjustment(
            delta: d,
            resultingBalance: target,
            account: account,
            date: date,
            source: source,
            note: note
        )
        context.insert(adjustment)
        return adjustment
    }
}
```

- [ ] **Step 4: Build, then clean up the temp test**

Run the build command. Expected: `** BUILD SUCCEEDED **`.
Then: `rm -rf /tmp/reconcile_test`

- [ ] **Step 5: Commit**

```bash
git add Tula/BalanceReconciler.swift
git commit -m "feat(accounts): add BalanceReconciler (pure delta + adjustment insert)"
```

---

### Task 4: Show adjustments in the account history (+ delete)

**Files:**
- Modify: `Tula/AccountDetailView.swift` — `TimelineItem` enum (~line 412), `timeline` (~line 51), `timelineRow` (~line 357), state (~line 16), plus a new `AdjustmentRow` view at end of file.

- [ ] **Step 1: Add the `.adjustment` case to `TimelineItem`**

In `Tula/AccountDetailView.swift`, replace the `TimelineItem` enum (lines 412-440) with:

```swift
enum TimelineItem: Identifiable {
    case expense(Expense)
    case transferIn(Transfer)
    case transferOut(Transfer)
    case adjustment(BalanceAdjustment)

    var id: UUID {
        switch self {
        case .expense(let e): return e.id
        case .transferIn(let t): return t.id
        case .transferOut(let t): return t.id
        case .adjustment(let a): return a.id
        }
    }

    var date: Date {
        switch self {
        case .expense(let e): return e.date
        case .transferIn(let t): return t.date
        case .transferOut(let t): return t.date
        case .adjustment(let a): return a.date
        }
    }

    var amount: Double {
        switch self {
        case .expense(let e): return e.amount
        case .transferIn(let t): return t.amount
        case .transferOut(let t): return t.amount
        case .adjustment(let a): return abs(a.delta)
        }
    }
}
```

- [ ] **Step 2: Include adjustments in the `timeline` builder**

In the `timeline` computed property, after the `incomingTransfers` loop (after line 65, before the `switch timelineSort`), add:

```swift
        for adjustment in account.adjustments {
            if let w = window, adjustment.date < w.start || adjustment.date >= w.end { continue }
            items.append(.adjustment(adjustment))
        }
```

(`timelineSpent` only matches `.expense`, so adjustments are correctly excluded from the spending total — no change needed there.)

- [ ] **Step 3: Add deletion state**

In the `@State` block (after line 17, `editingTransfer`), add:

```swift
    @State private var deletingAdjustment: BalanceAdjustment?
```

- [ ] **Step 4: Render the adjustment row + delete confirmation**

In `timelineRow(_:)`, add a new case before the closing `}` of the switch (after the `.transferOut` case, ~line 388):

```swift
        case .adjustment(let adjustment):
            Button {
                Haptics.tap()
                deletingAdjustment = adjustment
            } label: {
                AdjustmentRow(adjustment: adjustment)
                    .padding(.horizontal, Spacing.md)
            }
            .buttonStyle(PlainRowButtonStyle())
```

Then add a confirmation dialog. In `body`, after the `.sheet(item: $editingTransfer)` modifier (line 145), add:

```swift
        .confirmationDialog(
            "Delete this balance adjustment?",
            isPresented: Binding(
                get: { deletingAdjustment != nil },
                set: { if !$0 { deletingAdjustment = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let adjustment = deletingAdjustment {
                    context.delete(adjustment)
                    try? context.save(); WidgetRefresh.refresh(using: context)
                    Haptics.warning()
                }
                deletingAdjustment = nil
            }
            Button("Cancel", role: .cancel) { deletingAdjustment = nil }
        } message: {
            Text("The account balance will recalculate without this adjustment.")
        }
```

- [ ] **Step 5: Add the `AdjustmentRow` view**

At the very end of `Tula/AccountDetailView.swift` (after the `TransferRow` struct closes, line 541), append:

```swift
// MARK: - Adjustment Row

struct AdjustmentRow: View {
    let adjustment: BalanceAdjustment
    @PrimaryCurrency private var currencyCode

    private var deltaPrefix: String { adjustment.delta >= 0 ? "+" : "−" }
    private var deltaColor: Color { adjustment.delta >= 0 ? .green : .orange }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Balance updated to \(Currency.format(adjustment.resultingBalance, code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(adjustment.source == .billPayment ? "After bill payment" : "Manual adjustment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.xs)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(deltaPrefix)\(Currency.format(abs(adjustment.delta), code: currencyCode))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(deltaColor)
                Text(relativeDateString(for: adjustment.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.sm)
    }

    private func relativeDateString(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
```

- [ ] **Step 6: Build to verify**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Tula/AccountDetailView.swift
git commit -m "feat(accounts): show balance adjustments in account history with delete"
```

---

### Task 5: Standalone "Update balance" sheet + entry point

**Files:**
- Create: `Tula/UpdateBalanceView.swift`
- Modify: `Tula/AccountDetailView.swift` — state (~line 16), `actionButtons` (~line 232), `body` sheets (~line 145)

- [ ] **Step 1: Create the sheet**

Create `Tula/UpdateBalanceView.swift`:

```swift
import SwiftUI
import SwiftData

/// Re-anchors an account's balance to what the user's bank/card shows now.
/// Records a `BalanceAdjustment` via `BalanceReconciler`. Works for any
/// account kind; credit cards are the headline case.
struct UpdateBalanceView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @PrimaryCurrency private var currencyCode

    @Bindable var account: Account
    @State private var targetValue: Double
    @FocusState private var fieldFocused: Bool

    init(account: Account) {
        self.account = account
        _targetValue = State(initialValue: max(0, account.derivedBalance))
    }

    private var prompt: String {
        account.kind == .creditCard
            ? "What does your card show as outstanding now?"
            : "What's the real balance now?"
    }

    private var difference: Double { targetValue - account.derivedBalance }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    VStack(spacing: Spacing.xs) {
                        Text("Tula shows")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Currency.format(account.derivedBalance, code: currencyCode))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.top, Spacing.lg)

                    VStack(spacing: Spacing.sm) {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        FormattedAmountField(
                            value: $targetValue,
                            currencyCode: currencyCode,
                            placeholder: "0",
                            font: .system(size: 44, weight: .bold, design: .rounded),
                            alignment: .center
                        )
                        .focused($fieldFocused)
                        .frame(maxWidth: .infinity)
                    }

                    if abs(difference) >= 0.01 {
                        Text("Logs a \(signedString(difference)) adjustment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Already matches — nothing to adjust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Spacing.xl)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Update Balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(abs(difference) < 0.01)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    fieldFocused = true
                }
            }
        }
    }

    private func signedString(_ v: Double) -> String {
        let formatted = Currency.format(abs(v), code: currencyCode)
        return v >= 0 ? "+\(formatted)" : "−\(formatted)"
    }

    private func save() {
        BalanceReconciler.reconcile(
            account: account,
            to: targetValue,
            source: .manual,
            in: context
        )
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
    }
}
```

- [ ] **Step 2: Add state + sheet + button in `AccountDetailView`**

Add state after the `deletingAdjustment` line from Task 4:

```swift
    @State private var showingUpdateBalance = false
```

In `body`, after the confirmation dialog added in Task 4, add:

```swift
        .sheet(isPresented: $showingUpdateBalance) {
            UpdateBalanceView(account: account)
        }
```

In `actionButtons`, add an "Update balance" secondary button at the end (after the existing "Transfer" `secondaryActionButton`, before the closing `}` of the `HStack`, ~line 258):

```swift
            secondaryActionButton(
                title: "Update balance",
                icon: "slider.horizontal.3"
            ) {
                Haptics.tap()
                showingUpdateBalance = true
            }
```

- [ ] **Step 3: Build to verify**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Tula/UpdateBalanceView.swift Tula/AccountDetailView.swift
git commit -m "feat(accounts): standalone Update balance sheet + action button"
```

---

### Task 6: Optional reconcile inside the pay-bill flow

**Files:**
- Modify: `Tula/TransferFormView.swift` — state (~line 26), `body` VStack (~line 108), `save()` (~line 372), new `cardReconcileSection` view.

- [ ] **Step 1: Add state for the optional reconcile**

In `Tula/TransferFormView.swift`, after `@State private var showingDeleteConfirmation = false` (line 26), add:

```swift
    @State private var reconcileAfterPayment = false
    @State private var cardBalanceAfter: Double = 0
```

- [ ] **Step 2: Show the optional section only in pay-bill mode**

In `body`, in the inner `VStack` (lines 105-109), add `cardReconcileSection` after `optionalSection`:

```swift
                VStack(spacing: Spacing.xl) {
                    amountSection
                    routingSection
                    optionalSection
                    cardReconcileSection
                }
```

Then add the new view (place it after `optionalSection`'s definition; if unsure, add it right before the `save()` function, ~line 339):

```swift
    // MARK: - Optional post-payment reconcile (pay-bill mode only)

    @ViewBuilder
    private var cardReconcileSection: some View {
        // Only when paying a card bill for a brand-new transfer — lets the
        // user snap the card's outstanding to whatever their bank app shows
        // after the payment, instead of trusting Tula's derived figure.
        if presetKind == .cardBillPayment, !isEditing {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Toggle(isOn: $reconcileAfterPayment.animation(AppAnimation.snappy)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update card balance")
                            .font(.subheadline.weight(.semibold))
                        Text("Match what your card shows after this payment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.tulaBrandFallback)

                if reconcileAfterPayment {
                    HStack {
                        SectionHeader(title: "Card now shows")
                        Spacer()
                        FormattedAmountField(
                            value: $cardBalanceAfter,
                            currencyCode: currencyCode,
                            placeholder: "0",
                            font: .title3.weight(.semibold),
                            alignment: .trailing
                        )
                        .frame(maxWidth: 160)
                    }
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: CornerRadius.medium, style: .continuous)
                    .fill(Color.tulaCardSurface)
            )
        }
    }
```

- [ ] **Step 3: Reconcile after creating the transfer in `save()`**

In `save()`, replace the new-transfer branch and the trailing save (lines 360-374) with:

```swift
        } else {
            // Create new transfer
            let transfer = Transfer(
                amount: amount,
                fromAccount: fromAccount,
                toAccount: to,
                date: date,
                kind: resolvedKind,
                note: note.isEmpty ? nil : note
            )
            context.insert(transfer)

            // Optional re-anchor: if the user told us what the card shows
            // after this payment, record an adjustment on the destination
            // card so its outstanding matches reality. Runs after insert so
            // `derivedBalance` already reflects this payment.
            if presetKind == .cardBillPayment, reconcileAfterPayment {
                BalanceReconciler.reconcile(
                    account: to,
                    to: cardBalanceAfter,
                    source: .billPayment,
                    in: context
                )
            }
        }
        try? context.save(); WidgetRefresh.refresh(using: context)
        Haptics.success()
        dismiss()
```

- [ ] **Step 4: Build to verify**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Tula/TransferFormView.swift
git commit -m "feat(accounts): optional balance reconcile inside pay-bill flow"
```

---

### Task 7: Full verification + budget sanity check

**Files:** none modified (verification only); if the budget check fails, a follow-up task is added.

- [ ] **Step 1: Confirm budgets are spending-based, not balance-based**

Run: `grep -n "derivedBalance\|displayAmount" Tula/Budget.swift`
Expected: **no matches** (budgets are computed from expenses, so adjustments can't affect them). If there ARE matches, stop and inspect — an adjustment must never change a budget; if it would, the budget calc needs to exclude adjustments, and that becomes an added task.

- [ ] **Step 2: Full clean build**

Run the build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual verification on simulator** (boot the app, or run it via the project's run flow)

Walk through and confirm each:
- Open a credit-card account → tap **Update balance** → current "Outstanding" is pre-filled → enter a lower number → "Logs a −₹X adjustment." appears → **Save**. The hero "Outstanding" snaps to the entered value.
- The account history shows a **"Balance updated to ₹X"** row with the signed delta and "Manual adjustment".
- Tap that row → **Delete** → the outstanding returns to its pre-adjustment value.
- On a card with a balance, tap **Pay Bill** → toggle **Update card balance** on → enter the post-payment figure → **Save**. History shows both the **payment** transfer and an **"After bill payment"** adjustment, and the outstanding equals the figure entered.
- Enter "Update balance" with the value left equal to the current balance → **Save** is disabled / no-op (no stray adjustment is created).
- "Spent this month" on Home is unchanged by any adjustment.
- Overpay a card (reconcile to a value below 0 isn't directly enterable; instead pay a bill larger than outstanding) → hero label reads **"Credit balance"** and shows a positive magnitude.

- [ ] **Step 4: Final commit (if any verification tweaks were needed)**

```bash
git add -A
git commit -m "chore(accounts): verification pass for balance adjustment"
```

---

## Self-review notes (already reconciled against the spec)

- **Spec correction:** the spec referenced `TransferKind.cardPayment`; the real enum case is **`TransferKind.cardBillPayment`** ([Models.swift:259](../../../Tula/Models.swift)). This plan uses the correct name throughout.
- **Coverage:** mechanism (Task 3), data model + balance math (Tasks 1–2), audit log/history + delete (Task 4), standalone entry point (Task 5), pay-bill entry point (Task 6), credit-balance edge case (Task 2 Step 3), no-op edge case (Task 5 disabled Save + reconciler guard), migration is additive (no task needed), budgets-unaffected check (Task 7).
- **Out of scope (unchanged):** statement-cycle modeling, back-dating adjustments, reconcile reminders — per spec "Future work".
- **Known gap:** still no XCTest target; pure math is verified via standalone `swift` run. Adding a real test target remains a separate infra task.
