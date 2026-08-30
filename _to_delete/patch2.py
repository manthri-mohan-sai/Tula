#!/usr/bin/env python3
"""Patch 2: wire catch-up into HomeView, and make the log reminder
gap-aware in NotificationManager."""
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


# ═══════════════════════════ NotificationManager ════════════════════════════

OLD_LOG_REMINDER = '''    static func scheduleLogReminder(at hour: Int, minute: Int) {
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.title = "Time to log your day"
        content.body = "Tap to capture today's expenses in Tula."

        var dateComponents = DateComponents()'''

NEW_LOG_REMINDER = '''    /// Route marker carried in `userInfo` so a tap can open the catch-up
    /// flow directly rather than dropping the user on Home to find it.
    static let catchUpRoute = "catchUp"

    static func scheduleLogReminder(
        at hour: Int,
        minute: Int,
        context: ModelContext? = nil
    ) {
        cancelDailyReminder()

        let content = UNMutableNotificationContent()
        content.sound = .default

        // During an open gap, "Time to log your day" is the wrong message —
        // the user is not behind on today, they are behind on last week.
        // Naming the actual days and the effort involved is both more honest
        // and more actionable. Neutral framing throughout: no "you broke
        // your streak", because guilt drives avoidance, which is the churn
        // this is meant to reverse.
        if let context, let gap = unloggedGap(using: context), gap.count >= 2 {
            content.title = "\\(gap.count) days unlogged"
            content.body = "\\(gap.label) still empty. Catching up takes about 30 seconds."
            content.userInfo["route"] = catchUpRoute
        } else {
            content.title = "Time to log your day"
            content.body = "Tap to capture today's expenses in Tula."
        }

        var dateComponents = DateComponents()'''

OLD_REFRESH = '''            let effectiveHour = (hour == 0 && minute == 0 && !defaults.bool(forKey: "reminderHourExplicitlySet")) ? 21 : hour
            scheduleLogReminder(at: effectiveHour, minute: minute)'''

NEW_REFRESH = '''            let effectiveHour = (hour == 0 && minute == 0 && !defaults.bool(forKey: "reminderHourExplicitlySet")) ? 21 : hour
            scheduleLogReminder(at: effectiveHour, minute: minute, context: context)'''

OLD_STREAK_FN = '''    private static func loggingStreak(calendar: Calendar, context: ModelContext) -> Int {
        var streak = 0
        var checkDate = calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        for _ in 0..<30 {
            let dayStart = calendar.startOfDay(for: checkDate)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let descriptor = FetchDescriptor<Expense>(
                predicate: #Predicate { $0.date >= dayStart && $0.date < dayEnd }
            )
            let count = (try? context.fetchCount(descriptor)) ?? 0
            if count > 0 {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        return streak
    }'''

NEW_STREAK_FN = '''    /// Unlogged days in the recent window, for reminder copy.
    ///
    /// Mirrors `CatchUpDetector`'s window and no-spend handling but works off
    /// a `ModelContext` fetch, because this runs from notification scheduling
    /// where no `@Query` is available. Returns nil when there is no gap.
    private static func unloggedGap(
        using context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> (count: Int, label: String)? {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(
            byAdding: .day, value: -CatchUpDetector.maxLookbackDays, to: today
        ) else { return nil }

        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= windowStart }
        )
        let recent = (try? context.fetch(descriptor)) ?? []

        var loggedKeys: Set<String> = []
        for expense in recent {
            loggedKeys.insert(DayKey.string(from: expense.date, calendar: calendar))
        }
        let noSpend = NoSpendDayStore(
            raw: UserDefaults.standard.string(forKey: "noSpendDaysRaw") ?? ""
        ).keys

        // Never nag about days before the user's first expense.
        let firstEver = (try? context.fetch({
            var d = FetchDescriptor<Expense>(sortBy: [SortDescriptor(\\Expense.date)])
            d.fetchLimit = 1
            return d
        }()))?.first?.date

        var missed: [Date] = []
        var cursor = windowStart
        while cursor < today {
            let key = DayKey.string(from: cursor, calendar: calendar)
            let afterFirst = firstEver.map { cursor >= calendar.startOfDay(for: $0) } ?? false
            if afterFirst, !loggedKeys.contains(key), !noSpend.contains(key) {
                missed.append(cursor)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        guard !missed.isEmpty else { return nil }

        let names = missed.suffix(3).map { date -> String in
            calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1]
        }
        let label: String
        switch names.count {
        case 1: label = "\\(names[0]) is"
        case 2: label = "\\(names[0]) and \\(names[1]) are"
        default: label = names.dropLast().joined(separator: ", ") + " and \\(names[names.count - 1]) are"
        }
        return (missed.count, label)
    }'''

patch("NotificationManager.swift", [
    ("gap-aware log reminder", OLD_LOG_REMINDER, NEW_LOG_REMINDER),
    ("pass context to log reminder", OLD_REFRESH, NEW_REFRESH),
    ("replace dead loggingStreak with unloggedGap", OLD_STREAK_FN, NEW_STREAK_FN),
])


# ═════════════════════════════════ HomeView ═════════════════════════════════

OLD_STATE = '''    @State private var cachedPredictions:
        [UUID: SmartAmountPredictor.Prediction] = [:]
    private var networkMonitor = NetworkMonitor.shared'''

NEW_STATE = '''    @State private var cachedPredictions:
        [UUID: SmartAmountPredictor.Prediction] = [:]

    /// What the user missed while away. Recomputed from stored data on every
    /// foreground rather than accumulated, so it can never drift.
    @State private var catchUpState: CatchUpState = .clear
    @State private var showingCatchUp = false
    /// Days the user explicitly closed as "nothing spent". Comma-joined
    /// `yyyy-MM-dd`, same shape as `dismissedInsightIDs`.
    @AppStorage("noSpendDaysRaw") private var noSpendDaysRaw: String = ""
    /// Timestamp of the newest unlogged day the user dismissed. Stored as a
    /// watermark rather than a flag so a *new* gap re-surfaces the card
    /// automatically — and unlike `dismissedUpcomingKeys`, it survives
    /// relaunch.
    @AppStorage("catchUpDismissedThrough") private var catchUpDismissedThrough:
        Double = 0
    /// Floor set by dismissing the "older days" row.
    @AppStorage("catchUpHorizon") private var catchUpHorizon: Double = 0

    private var networkMonitor = NetworkMonitor.shared'''

OLD_INSIGHTS = '''        var all = InsightEngine.generate(
            expenses: allExpenses,
            accounts: allAccounts,
            currencyCode: currencyCode,
            recurringRules: allRecurringRules,
            dailyBudget: dailyBudget
        )'''

NEW_INSIGHTS = '''        var all = InsightEngine.generate(
            expenses: allExpenses,
            accounts: allAccounts,
            currencyCode: currencyCode,
            recurringRules: allRecurringRules,
            dailyBudget: dailyBudget,
            noSpendDays: noSpendDays
        )'''

# ── scrollContent: insert the card between the offline banner and quick log ──

OLD_SCROLL = '''            quickLogSection
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.05), value: appeared)'''

NEW_SCROLL = '''            if catchUpState.unloggedCount > 0, !catchUpDismissed {
                CatchUpCard(
                    state: catchUpState,
                    streak: loggingStreakDays,
                    action: {
                        Haptics.tap()
                        showingCatchUp = true
                    },
                    onDismiss: dismissCatchUp
                )
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.04), value: appeared)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            quickLogSection
                .offset(y: appeared ? 0 : 16)
                .opacity(appeared ? 1 : 0)
                .animation(AppAnimation.gentle.delay(0.05), value: appeared)'''

# ── sheet presentation ──

OLD_SHEET_ANCHOR = '''            .sheet(isPresented: $showingTransfer) {
                TransferFormView()
            }'''

NEW_SHEET_ANCHOR = '''            .sheet(isPresented: $showingTransfer) {
                TransferFormView()
            }
            .sheet(isPresented: $showingCatchUp) {
                CatchUpSheet(
                    state: catchUpState,
                    accounts: allAccounts,
                    categories: allCategories,
                    merchantRules: allMerchantRules,
                    defaultAccount: defaultAccount,
                    currencyCode: currencyCode,
                    onCommitDrafts: commitCatchUp,
                    onSetNoSpend: setNoSpend,
                    onConfirmRecurring: confirmCatchUpRecurring,
                    onDismissOlder: dismissOlderCatchUpDays
                )
            }'''

# ── refreshRecurringCaches tail: feed catch-up from the freshly computed dict ──

OLD_CACHE_TAIL = '''        cachedNextDueDates = nextDates
        cachedOverdueDates = overdueDates
        cachedPredictions = predictions
    }'''

NEW_CACHE_TAIL = '''        cachedNextDueDates = nextDates
        cachedOverdueDates = overdueDates
        cachedPredictions = predictions
        // Pass the dictionary directly rather than reading `cachedOverdueDates`
        // back: catch-up detection depends on it, and relying on a @State
        // write being visible to a read in the same call is a bug waiting to
        // happen.
        refreshCatchUpState(overdueDates: overdueDates)
    }

    // MARK: - Catch-up

    private var noSpendDays: Set<String> {
        NoSpendDayStore(raw: noSpendDaysRaw).keys
    }

    /// Consecutive days the user closed the books. Distinct from the
    /// under-budget insight, which measures spending level rather than habit.
    private var loggingStreakDays: Int {
        LoggingStreak.current(expenses: allExpenses, noSpendDays: noSpendDays)
    }

    private var catchUpDismissed: Bool {
        guard let newest = catchUpState.newestUnloggedDate else { return false }
        return catchUpDismissedThrough >= newest.timeIntervalSince1970
    }

    /// Recomputes catch-up state from stored data.
    ///
    /// `extra` carries expenses just written in this run loop: `@Query`
    /// results do not refresh until the next view update, so a commit would
    /// otherwise still see the gap it just filled. Day-keyed aggregation makes
    /// any overlap harmless.
    private func refreshCatchUpState(
        overdueDates: [UUID: [Date]]? = nil,
        extra: [Expense] = []
    ) {
        let horizon = catchUpHorizon > 0
            ? Date(timeIntervalSince1970: catchUpHorizon) : nil
        catchUpState = CatchUpDetector.state(
            expenses: extra.isEmpty ? allExpenses : allExpenses + extra,
            noSpendDays: noSpendDays,
            recurringRules: allRecurringRules,
            overdueDates: overdueDates ?? cachedOverdueDates,
            expectedAmount: { rule, date in
                SmartAmountPredictor.predict(for: rule, on: date).amount
            },
            notBefore: horizon
        )
    }

    private func dismissCatchUp() {
        guard let newest = catchUpState.newestUnloggedDate else { return }
        withAnimation(AppAnimation.snappy) {
            catchUpDismissedThrough = newest.timeIntervalSince1970
        }
    }

    /// Moves the detection floor past the truncated days instead of writing
    /// no-spend markers for them — the user is saying "stop counting these",
    /// not "I spent nothing on them".
    private func dismissOlderCatchUpDays() {
        guard let oldestShown = catchUpState.days.first?.date else { return }
        catchUpHorizon = oldestShown.timeIntervalSince1970
        refreshCatchUpState()
    }

    private func setNoSpend(_ date: Date, _ marked: Bool) {
        var store = NoSpendDayStore(raw: noSpendDaysRaw)
        store.set(marked, for: date)
        store.prune()
        noSpendDaysRaw = store.rawValue
        refreshCatchUpState()
    }

    /// Persists a backfill batch and reports the outcome in terms of the
    /// streak it restored — the reason the flow is worth finishing.
    private func commitCatchUp(_ drafts: [ExpenseDraft]) {
        let streakBefore = loggingStreakDays
        let created = ExpenseWriter.commit(
            drafts,
            source: .manual,
            in: context,
            options: .backfill,
            budgets: Array(activeBudgets)
        )
        guard !created.isEmpty else { return }

        if let account = created.last?.account {
            lastUsedAccountID = account.id.uuidString
        }
        Haptics.success()
        triggerSavePulse()
        refreshCatchUpState(extra: created)

        // Budget alerts were suppressed for the batch so a closed period
        // cannot fire a retroactive "over budget" push. Re-evaluate once, in
        // case a backfilled date landed inside the current window.
        evaluateBudgetAlerts()

        let streakAfter = LoggingStreak.current(
            expenses: allExpenses + created,
            noSpendDays: noSpendDays
        )
        let undoTargets = created
        let message = (streakAfter > streakBefore && streakAfter >= 3)
            ? "\\(streakAfter)-day streak restored"
            : (created.count == 1 ? "1 expense added" : "\\(created.count) expenses added")
        showToast(message) {
            ExpenseWriter.revert(undoTargets, in: context)
            refreshCatchUpState()
            Haptics.warning()
        }
    }

    /// Materialises overdue recurring occurrences in one batch.
    private func confirmCatchUpRecurring(_ occurrences: [PendingOccurrence]) {
        guard !occurrences.isEmpty else { return }
        let rulesByID = Dictionary(
            allRecurringRules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var logged = 0
        for occurrence in occurrences {
            guard let rule = rulesByID[occurrence.ruleID] else { continue }
            RecurringEngine.createTransaction(
                rule: rule,
                date: occurrence.dueDate,
                in: context
            )
            // `lastGeneratedDate` means "last handled". Not advancing it here
            // would let `generateMissing` recreate this occurrence on the next
            // launch, silently duplicating the expense.
            if rule.lastGeneratedDate == nil
                || rule.lastGeneratedDate! < occurrence.dueDate
            {
                rule.lastGeneratedDate = occurrence.dueDate
            }
            if rule.isBill {
                rule.lastPaidDate = occurrence.dueDate
            }
            NotificationManager.cancelConfirmation(
                ruleID: rule.id,
                dueDate: occurrence.dueDate
            )
            logged += 1
        }
        guard logged > 0 else { return }

        // createTransaction inserts without saving and fires no side effects —
        // one save and one widget refresh for the whole batch.
        context.safeSave()
        WidgetRefresh.refresh(using: context)
        Haptics.success()
        refreshRecurringCaches()
        showToast(logged == 1 ? "1 payment logged" : "\\(logged) payments logged")
    }'''

# ── hero: logging streak chip ──

OLD_HERO_TODAY = '''                    if totalToday > 0 {
                        todayInline
                    }'''

NEW_HERO_TODAY = '''                    if totalToday > 0 {
                        todayInline
                    }

                    if loggingStreakDays >= 2 {
                        loggingStreakChip
                    }'''

OLD_TOPCAT_FN = '''    /// Explicit "top category" line for the hero: category icon + name + its'''

NEW_TOPCAT_FN = '''    /// Logging streak chip.
    ///
    /// Shows days in a row the user closed the books, which is the habit the
    /// app depends on — deliberately not the under-budget streak, which
    /// measures spending level and so resets on a legitimately expensive day.
    /// Hidden below two days: a "1-day streak" is noise, not encouragement.
    private var loggingStreakChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 14)
            Text("\\(loggingStreakDays)-day logging streak")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\\(loggingStreakDays) day logging streak")
    }

    /// Explicit "top category" line for the hero: category icon + name + its'''

patch("HomeView.swift", [
    ("catch-up state", OLD_STATE, NEW_STATE),
    ("insights noSpendDays", OLD_INSIGHTS, NEW_INSIGHTS),
    ("catch-up card in scrollContent", OLD_SCROLL, NEW_SCROLL),
    ("catch-up sheet", OLD_SHEET_ANCHOR, NEW_SHEET_ANCHOR),
    ("catch-up helpers", OLD_CACHE_TAIL, NEW_CACHE_TAIL),
    ("hero streak chip usage", OLD_HERO_TODAY, NEW_HERO_TODAY),
    ("hero streak chip view", OLD_TOPCAT_FN, NEW_TOPCAT_FN),
])

print("patch2 complete")
