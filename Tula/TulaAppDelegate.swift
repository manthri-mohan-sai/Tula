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
            NotificationManager.NotificationDiagnostics.recordActionTapped(.body, ruleID: ruleID)
            break
        default:
            break
        }

        // After handling, reschedule upcoming confirmations so the
        // notification queue stays topped up. Without this, the pre-queued
        // 14 notifications would eventually run out if the user never
        // opens the app — each action response is a free wake that lets
        // us replenish the queue.
        await RecurringConfirmationHandler.rescheduleAll()
    }
}

// MARK: - Confirmation handler

/// Executes the "Log it" branch of a confirmation notification — builds
/// a fresh SwiftData container (since the response can arrive when the
/// app isn't running), looks up the rule, and creates the expense.
@MainActor
enum RecurringConfirmationHandler {

    /// Builds a ModelContainer pointing at the shared App Group store.
    /// Falls back to the default local store if the group isn't configured.
    private static func makeContainer() -> ModelContainer? {
        let schema = Schema([
            Account.self, Category.self, Expense.self, Transfer.self,
            RecurringRule.self, MerchantRule.self, Budget.self,
        ])
        if let storeURL = SharedStorage.sharedStoreURL {
            let config = ModelConfiguration("Tula", schema: schema, url: storeURL)
            return try? ModelContainer(for: schema, configurations: [config])
        }
        let config = ModelConfiguration("Tula", schema: schema)
        return try? ModelContainer(for: schema, configurations: [config])
    }

    static func logOccurrence(ruleID: UUID, dueDate: Date) async {
        guard let container = makeContainer() else { return }
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.id == ruleID }
        )
        guard let rule = (try? context.fetch(descriptor))?.first else { return }

        RecurringEngine.createTransaction(rule: rule, date: dueDate, in: context)
        // Advance the boundary so nextDueDate() doesn't have to walk
        // from startDate through every past occurrence.
        if rule.lastGeneratedDate == nil || rule.lastGeneratedDate! < dueDate {
            rule.lastGeneratedDate = dueDate
        }
        try? context.save(); WidgetRefresh.refresh(using: context)
        NotificationManager.refreshDailyReminder(using: context)
    }

    /// Marks an occurrence as skipped without creating an expense.
    /// Called from the notification's Skip action button.
    static func skipOccurrence(ruleID: UUID, dueDate: Date) async {
        guard let container = makeContainer() else { return }
        let context = ModelContext(container)

        let descriptor = FetchDescriptor<RecurringRule>(
            predicate: #Predicate { $0.id == ruleID }
        )
        guard let rule = (try? context.fetch(descriptor))?.first else { return }

        RecurringEngine.skipOccurrence(rule: rule, dueDate: dueDate)
        try? context.save(); WidgetRefresh.refresh(using: context)
    }

    /// Re-runs the confirmation scheduling logic for all active rules.
    /// Called after each notification action so the queue stays topped up
    /// even if the user never fully opens the app.
    static func rescheduleAll() async {
        guard let container = makeContainer() else { return }
        let context = ModelContext(container)
        RecurringEngine.generateMissing(in: context)
    }
}
