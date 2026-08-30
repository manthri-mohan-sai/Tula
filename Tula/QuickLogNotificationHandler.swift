import Foundation
import SwiftData
import UserNotifications

/// Executes the Lock Screen actions on the daily log reminder.
///
/// This is the answer to "I had twenty seconds, not two minutes": the text
/// action is a background action, so typing "coffee 120" into the notification
/// saves the expense without ever opening the app. Extracted from
/// `TulaAppDelegate` to keep the delegate a router rather than a place where
/// business logic accumulates.
///
/// Builds its own container the same way `RecurringConfirmationHandler` does —
/// a notification response can arrive when the app is not running.
@MainActor
enum QuickLogNotificationHandler {

    /// Parses `text` and saves whatever it yields.
    ///
    /// Silent on success: the Live Activity and widgets update, which is
    /// feedback enough on the surface the user is already looking at. A
    /// failure *does* notify, because otherwise the entry vanishes with no
    /// indication it was lost.
    static func log(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let container = RecurringConfirmationHandler.sharedContainer() else {
            await notifyFailure(text: trimmed, reason: .unavailable)
            return
        }
        let context = ModelContext(container)

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<Category>())) ?? []
        let merchantRules = (try? context.fetch(FetchDescriptor<MerchantRule>())) ?? []

        guard let account = resolveDefaultAccount(from: accounts) else {
            await notifyFailure(text: trimmed, reason: .noAccount)
            return
        }

        // Same deterministic pipeline as Siri, voice and quick-log. No AI
        // round-trip: this path has to work offline, on the Lock Screen, in
        // the couple of seconds before iOS suspends the process again.
        let drafts = ExpenseInterpreter(
            accounts: accounts,
            categories: categories,
            merchantRules: merchantRules,
            defaultAccount: account
        ).interpret(trimmed)

        let valid = drafts.filter(\.isValid)
        guard !valid.isEmpty else {
            await notifyFailure(text: trimmed, reason: .unparsed)
            return
        }

        let created = ExpenseWriter.commit(valid, source: .nlp, in: context)
        guard !created.isEmpty else {
            await notifyFailure(text: trimmed, reason: .unparsed)
            return
        }

        // The day is closed — tonight's reminder would now be wrong.
        NotificationManager.suppressTodaysLogReminder()
    }

    /// Closes today as an explicit no-spend day.
    ///
    /// This is what makes the reminder dismissible *honestly*: without it the
    /// only way to silence a nag on a genuinely empty day is to ignore it,
    /// which is how users learn to ignore all of them.
    static func markNoSpendToday(calendar: Calendar = .current) {
        var store = NoSpendDayStore(
            raw: UserDefaults.standard.string(forKey: "noSpendDaysRaw") ?? ""
        )
        store.set(true, for: .now, calendar: calendar)
        store.prune(calendar: calendar)
        UserDefaults.standard.set(store.rawValue, forKey: "noSpendDaysRaw")

        NotificationManager.suppressTodaysLogReminder(calendar: calendar)
    }

    // MARK: - Default account

    /// Last account used, falling back to the first non-archived one.
    /// Mirrors `HomeView.defaultAccount`; `lastUsedAccountID` is written by
    /// every save path into `UserDefaults.standard`.
    private static func resolveDefaultAccount(from accounts: [Account]) -> Account? {
        let active = accounts.filter { !$0.isArchived }
        let stored = UserDefaults.standard.string(forKey: "lastUsedAccountID") ?? ""
        if !stored.isEmpty, let uuid = UUID(uuidString: stored),
           let match = active.first(where: { $0.id == uuid }) {
            return match
        }
        return active.first
    }

    // MARK: - Failure feedback

    private enum FailureReason {
        case unparsed
        case noAccount
        case unavailable

        var body: String {
            switch self {
            case .unparsed:
                return "Couldn't find an amount in that. Tap to log it in Tula."
            case .noAccount:
                return "No account set up yet. Tap to add one."
            case .unavailable:
                return "Couldn't reach your data just now. Tap to log it in Tula."
            }
        }
    }

    /// Echoes the user's text back so nothing they typed is lost — they can
    /// copy it, or tap through and retype knowing exactly what was missing.
    private static func notifyFailure(text: String, reason: FailureReason) async {
        let content = UNMutableNotificationContent()
        content.title = "Not logged: \"\(text)\""
        content.body = reason.body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "tula.log.failed.\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
