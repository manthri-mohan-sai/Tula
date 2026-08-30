import Foundation

/// Stable `yyyy-MM-dd` identity for a calendar day.
///
/// Derived from `Calendar` components rather than a shared `DateFormatter`:
/// a cached formatter captures its time zone at first use and silently keeps
/// producing keys in the old zone after the user travels, which would make
/// day-level state (no-spend markers, streaks) drift by a day. Component
/// arithmetic re-reads the calendar every call and is allocation-free.
enum DayKey {

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// Start of the keyed day in `calendar`'s time zone, or nil if malformed.
    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }
}

/// The set of days the user explicitly closed as "nothing spent".
///
/// Backed by a comma-joined string in `@AppStorage`, following the existing
/// `dismissedInsightIDs` pattern in `HomeView`. A SwiftData model was
/// considered and rejected: this value is low-stakes, trivially re-derivable,
/// and a model would require registering in the `Schema` and handling in
/// `BackupManager` for no proportional gain.
///
/// **Known tradeoff:** markers are per-device and are not carried by
/// backup/restore, so a restored user sees a few extra unlogged days. Promote
/// to a `@Model` only if this ever needs to sync across devices.
struct NoSpendDayStore: Equatable {

    /// Keys older than this are dropped on write so the backing string stays
    /// bounded (~11 bytes/day, so roughly 1 KB at steady state).
    static let retentionDays = 90

    private(set) var keys: Set<String>

    init(raw: String) {
        keys = raw.isEmpty
            ? []
            : Set(raw.split(separator: ",").map(String.init))
    }

    var rawValue: String { keys.sorted().joined(separator: ",") }

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        keys.contains(DayKey.string(from: date, calendar: calendar))
    }

    mutating func set(_ marked: Bool, for date: Date, calendar: Calendar = .current) {
        let key = DayKey.string(from: date, calendar: calendar)
        if marked {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
    }

    /// Drops markers older than `retentionDays`. Call on write, not on read —
    /// reads happen every render.
    mutating func prune(now: Date = .now, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(
            byAdding: .day, value: -Self.retentionDays,
            to: calendar.startOfDay(for: now)
        ) else { return }
        keys = keys.filter { key in
            guard let date = DayKey.date(from: key, calendar: calendar) else { return false }
            return date >= cutoff
        }
    }
}
