import UIKit
import UserNotifications
import SwiftData

/// AppDelegate adapter — exists for one reason: to receive
/// `UNNotificationResponse` callbacks when the user taps Log/Skip on a
/// recurring confirmation notification. SwiftUI's app lifecycle alone
/// doesn't surface these callbacks, hence the bridge.
///
/// The delegate registers itself as `UNUserNotificationCenter.delegate`
/// at launch, sets up the notification category (with the Log/Skip
/// action buttons), and routes tap responses to `handleResponse`.
final class TulaAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationManager.registerCategories()
        return true
    }

    // MARK: - Foreground presentation

    /// Show banners + play sound even when the app is in foreground.
    /// Without this iOS suppresses banners while the app is open, which
    /// hides the Log/Skip action affordance from in-app users.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    // MARK: - Response routing

    /// Called when the user interacts with a notification — either taps
    /// the body, or taps one of the inline action buttons. We only care
    /// about the confirmation category here; anything else gets default
    /// behavior (delivered, no app action).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                  didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo

        guard
            response.notification.request.content.categoryIdentifier == NotificationManager.confirmCategoryID,
            let ruleIDStr = info["ruleID"] as? String,
            let ruleID = UUID(uuidString: ruleIDStr),
            let dueEpoch = info["dueDate"] as? TimeInterval
        else { return }

        let dueDate = Date(timeIntervalSince1970: dueEpoch)

        switch response.actionIdentifier {
        case NotificationManager.confirmLogActionID:
            NotificationManager.NotificationDiagnostics.recordActionTapped(.log, ruleID: ruleID)
            await RecurringConfirmationHandler.logOccurrence(ruleID: ruleID, dueDate: dueDate)
        case NotificationManager.confirmSkipActionID:
            NotificationManager.NotificationDiagnostics.recordActionTapped(.skip, ruleID: ruleID)
            await RecurringConfirmationHandler.skipOccurrence(ruleID: ruleID, dueDate: dueDate)
        case UNNotificationDefaultActionIdentifier:
            // Tapping the notification body (no action button) — also
            // a no-op. We could route to RecurringRulesView later if
            // wanted, but the simpler "two-button-only" UX is clearer.
            NotificationManager.NotificationDiagnostics.recordActionTapped(.body, ruleID: ruleID)
            break
        default:
            break
        }
    }
}

// MARK: - Confirmation handler

/// Executes the "Log it" branch of a confirmation notification — builds
/// a fresh SwiftData container (since the response can arrive when the
/// app isn't running), looks up the rule, and creates the expense.
@MainActor
enum RecurringConfirmationHandler {
    static func logOccurrence(ruleID: UUID, dueDate: Date) async {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
        ])
        let config = ModelConfiguration("Tula", schema: schema)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else { return }

        let context = ModelContext(container)

        // SwiftData's UUID predicate filter — fetch the rule, then
        // route through RecurringEngine.createTransaction which already
        // handles both expense and transfer cases.
        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.id == ruleID }
        )
        guard let rule = (try? context.fetch(descriptor))?.first else { return }

        RecurringEngine.createTransaction(rule: rule, date: dueDate, in: context)
        try? context.save(); WidgetRefresh.refresh(using: context)
    }

    /// Marks an occurrence as skipped without creating an expense.
    /// Called from the notification's Skip action button. Uses a fresh
    /// container since the response can arrive when the app isn't
    /// running. Result is persisted so the next launch's home view
    /// correctly hides the skipped occurrence.
    static func skipOccurrence(ruleID: UUID, dueDate: Date) async {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
        ])
        let config = ModelConfiguration("Tula", schema: schema)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else { return }

        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.id == ruleID }
        )
        guard let rule = (try? context.fetch(descriptor))?.first else { return }

        RecurringEngine.skipOccurrence(rule: rule, dueDate: dueDate)
        try? context.save(); WidgetRefresh.refresh(using: context)
    }
}
