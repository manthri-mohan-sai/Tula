import Foundation
import SwiftData

/// Builds rich contextual information to inject into Foundation Models
/// prompts. The goal is to give the FM the same situational awareness
/// a human would have when reading the user's input:
///
///   - **Time context**: what time is it, what day, what's the meal
///     period? Helps the FM resolve ambiguous queries like "spent 400
///     on food" → if it's 9pm, it's probably dinner.
///   - **DB context**: who does this user spend money with? What
///     categories do they typically use? This solves transcription
///     errors ("mayur club" mishearing) and category-guess accuracy.
///
/// **Output shape**: a multi-line string suitable for pasting into the
/// FM prompt. Always self-labels with markers like "CONTEXT:" so the
/// FM knows what each block represents.
///
/// **Performance**: builds in <50ms typically. Fetches from SwiftData
/// happen on the caller's actor (caller wraps in MainActor.run when
/// needed). Results are NOT cached across calls — each parse builds
/// fresh context, so changes to the DB are reflected immediately.
/// For very frequent parsing (e.g. live voice), the caller can build
/// context once and reuse the string across calls within a session.
enum FMContextBuilder {

    /// Build a complete context block: time + DB. Pass into the FM
    /// prompt's "CONTEXT" section. **MainActor-isolated** because it
    /// fetches from SwiftData.
    @MainActor
    static func build(modelContext: ModelContext,
                      now: Date = .now,
                      calendar: Calendar = .current) -> String {
        var sections: [String] = []

        sections.append(timeContext(now: now, calendar: calendar))

        if let merchants = topMerchants(in: modelContext) {
            sections.append(merchants)
        }
        if let categories = topCategoryPatterns(in: modelContext, calendar: calendar) {
            sections.append(categories)
        }
        if let recent = recentActivity(in: modelContext, now: now, calendar: calendar) {
            sections.append(recent)
        }

        return sections.joined(separator: "\n\n")
    }

    /// Build a TIME-ONLY context block — no DB access. **Not MainActor-
    /// isolated**, so callers without a live ModelContext (share
    /// extension, tests, off-main-actor pipelines) can use this safely.
    /// The share extension uses this variant because building DB context
    /// from a non-main actor would require crossing back to MainActor
    /// twice per parse — adds latency to the already-budgeted share flow.
    static func buildTimeOnly(now: Date = .now,
                               calendar: Calendar = .current) -> String {
        return timeContext(now: now, calendar: calendar)
    }

    // MARK: - Time context

    /// Build the time-awareness block. Pure function — no actor
    /// isolation needed. Includes:
    ///   - Current date in human form ("Wednesday, 21 May 2026")
    ///   - Current local time ("9:42 PM")
    ///   - Period of day ("Late Evening") — for meal disambiguation
    ///   - Weekday vs. weekend flag — affects spending patterns
    ///
    /// **Why period-of-day matters**: when a user says "spent 300 on
    /// food," whether to label it Breakfast/Lunch/Dinner depends on
    /// when the message was sent. The FM gets this period name as a
    /// strong hint.
    nonisolated static func timeContext(now: Date, calendar: Calendar) -> String {
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEEE, d MMMM yyyy"
        let day = dayFmt.string(from: now)

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        let time = timeFmt.string(from: now)

        let hour = calendar.component(.hour, from: now)
        let period = periodOfDay(hour: hour)

        let weekday = calendar.component(.weekday, from: now)
        let isWeekend = (weekday == 1 || weekday == 7)  // Sun=1, Sat=7

        let mealHint: String = {
            switch period {
            case "Early Morning", "Morning":
                return "If user mentions food, likely BREAKFAST."
            case "Late Morning", "Noon":
                return "If user mentions food, likely BRUNCH or early LUNCH."
            case "Afternoon":
                return "If user mentions food, likely LUNCH or snack."
            case "Late Afternoon":
                return "If user mentions food, likely SNACK or chai/tea."
            case "Evening":
                return "If user mentions food, likely SNACK or early DINNER."
            case "Late Evening", "Night":
                return "If user mentions food, likely DINNER."
            case "Late Night":
                return "If user mentions food, likely LATE-NIGHT SNACK or DINNER."
            default:
                return ""
            }
        }()

        return """
        SITUATIONAL CONTEXT:
        - Today: \(day) (\(isWeekend ? "weekend" : "weekday"))
        - Current time: \(time) — \(period)
        - Meal-time hint: \(mealHint)
        Use this time context when the user's input is ambiguous about \
        when something happened. "Just ate" / "had food" without a meal \
        name → use the meal-time hint above.
        """
    }

    /// Map a 24-hour hour value to a named period-of-day. Calibrated to
    /// Indian routines: late dinners are common (9-10 PM), late-night
    /// snacks happen until midnight.
    private static func periodOfDay(hour: Int) -> String {
        switch hour {
        case 5..<7:   return "Early Morning"
        case 7..<10:  return "Morning"
        case 10..<12: return "Late Morning"
        case 12..<13: return "Noon"
        case 13..<16: return "Afternoon"
        case 16..<18: return "Late Afternoon"
        case 18..<20: return "Evening"
        case 20..<22: return "Late Evening"
        case 22..<24: return "Night"
        default:      return "Late Night"  // 0-5
        }
    }

    // MARK: - DB context: top merchants

    /// Fetch the user's most-used merchants (by frequency) so the FM
    /// can recognize them in transcripts even when speech recognition
    /// mangles the name. "Mayur Club" becoming "may or club" or
    /// "mai you club" — listing the real names lets the FM correct.
    ///
    /// **Strategy**: count merchant occurrences across ALL expenses,
    /// return the top 20. Frequency-sorted so most-used appear first.
    /// Skip merchants with empty/nil values.
    ///
    /// Returns nil when there are no expenses (new install) — no point
    /// emitting an empty list.
    private static func topMerchants(in context: ModelContext) -> String? {
        let descriptor = FetchDescriptor<Expense>()
        guard let expenses = try? context.fetch(descriptor), !expenses.isEmpty else {
            return nil
        }

        var counts: [String: Int] = [:]
        for expense in expenses {
            guard let merchant = expense.merchant?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !merchant.isEmpty else { continue }
            counts[merchant, default: 0] += 1
        }

        let topMerchants = counts.sorted { $0.value > $1.value }
            .prefix(20)
            .map { "\"\($0.key)\" (\($0.value) times)" }

        guard !topMerchants.isEmpty else { return nil }

        return """
        USER'S FREQUENT MERCHANTS (most-used first):
        \(topMerchants.joined(separator: ", "))
        If a transcript mentions something that PHONETICALLY MATCHES one \
        of these names, prefer the exact spelling above. Voice recognition \
        garbles unusual names — "Mayur Club" may transcribe as \
        "mature club" / "may yor club" / "may you're club" / "majoor"; \
        when you see anything close, use the canonical spelling.
        """
    }

    // MARK: - DB context: category patterns

    /// Compute the user's typical category usage by time of day. Some
    /// users always eat out at lunch, some spend on Transport in the
    /// morning. Knowing the pattern lets the FM bias category guesses.
    ///
    /// **Output**: "Categories user typically uses this hour of day: X, Y, Z"
    /// when there's a strong pattern, nil otherwise.
    private static func topCategoryPatterns(in context: ModelContext,
                                              calendar: Calendar) -> String? {
        let descriptor = FetchDescriptor<Expense>()
        guard let expenses = try? context.fetch(descriptor), expenses.count >= 5 else {
            return nil
        }

        // Get current hour for filtering.
        let currentHour = calendar.component(.hour, from: .now)
        // Window: ±2 hours around current hour. Counts category usage
        // in that window across the user's history.
        var counts: [String: Int] = [:]
        for expense in expenses {
            let hour = calendar.component(.hour, from: expense.date)
            let diff = abs(hour - currentHour)
            // Wrap-around: distance from 23 to 0 should be 1, not 23.
            let circularDiff = min(diff, 24 - diff)
            guard circularDiff <= 2 else { continue }
            guard let category = expense.category?.name else { continue }
            counts[category, default: 0] += 1
        }

        let topCategories = counts.sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        guard topCategories.count >= 2 else { return nil }

        return """
        TIME-PATTERN HINT: At this hour of day, user typically logs \
        expenses in these categories: \(topCategories.joined(separator: ", ")).
        Use as a tiebreaker when category is ambiguous; don't override \
        clear merchant/item signals.
        """
    }

    // MARK: - DB context: recent activity

    /// Surface the user's last 1-2 expenses if very recent — gives the
    /// FM a sense of whether this new entry is a follow-up to a recent
    /// one ("oh that was the wrong amount, it was actually 450").
    ///
    /// **Window**: only the last 4 hours. Beyond that the context isn't
    /// useful for the current input.
    private static func recentActivity(in context: ModelContext,
                                         now: Date,
                                         calendar: Calendar) -> String? {
        let fourHoursAgo = calendar.date(byAdding: .hour, value: -4, to: now) ?? now
        var descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.date >= fourHoursAgo },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 3

        guard let recent = try? context.fetch(descriptor), !recent.isEmpty else {
            return nil
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"

        let entries = recent.map { exp -> String in
            let merchant = exp.merchant?.isEmpty == false ? exp.merchant! : "—"
            let categoryName = exp.category?.name ?? "uncategorized"
            return "₹\(Int(exp.amount)) at \(merchant) (\(categoryName), \(timeFmt.string(from: exp.date)))"
        }

        return """
        USER'S RECENT EXPENSES (last 4 hours):
        \(entries.joined(separator: " · "))
        If the current input appears to refer to one of these (e.g. \
        "actually that was 500 not 450"), note that — but the user is \
        usually logging a NEW expense, not editing.
        """
    }
}
