import AppIntents
import Foundation
import SwiftData

/// Removes expenses created by Siri or automation in a recent window.
///
/// Exists because building automations means occasionally pointing the wrong
/// action at the wrong text and generating a pile of junk — one malformed
/// bank alert through the free-text parser can create half a dozen bogus
/// expenses, and deleting them by hand in a 377-row list is miserable.
///
/// **Preview by default.** The parameter is `previewOnly = true` unless
/// explicitly turned off, so the destructive path is never the accidental
/// one. Manually entered expenses are never touched regardless.
struct CleanUpAutomationEntriesIntent: AppIntent {

    static var title: LocalizedStringResource = "Clean Up Automation Entries"

    static var description = IntentDescription(
        """
        Deletes expenses created by Siri or by bank-alert automation within \
        the last N hours. Runs as a preview first, reporting what would be \
        removed. Never touches manually entered expenses.
        """,
        categoryName: "Automation"
    )

    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @Parameter(title: "Within last (hours)", default: 24)
    var hours: Int

    @Parameter(title: "Preview only", default: true)
    var previewOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Clean up automation entries from the last \(\.$hours) hours") {
            \.$previewOnly
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let container = RecurringConfirmationHandler.sharedContainer() else {
            return .result(value: 0, dialog: IntentDialog("Couldn't reach your data."))
        }
        let context = ModelContext(container)

        let window = TimeInterval(max(1, hours) * 3600)
        let cutoff = Date.now.addingTimeInterval(-window)

        // `createdAt`, not `date`: a bank alert carries the *transaction*
        // date, which may be days old, while what we want to undo is
        // everything written in the last N hours.
        let descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate { $0.createdAt >= cutoff }
        )
        let recent = (try? context.fetch(descriptor)) ?? []
        let targets = recent.filter { $0.source == .siri || $0.source == .automation }

        guard !targets.isEmpty else {
            return .result(value: 0, dialog: IntentDialog("Nothing to clean up."))
        }

        let total = targets.reduce(0.0) { $0 + $1.amount }
        let code = UserDefaults.standard.string(forKey: "primaryCurrencyCode") ?? "INR"
        let formatted = Currency.format(total, code: code)

        if previewOnly {
            let message = "Would delete \(targets.count) entries totalling \(formatted). "
                + "Turn off Preview to remove them."
            return .result(value: targets.count, dialog: IntentDialog(stringLiteral: message))
        }

        ExpenseWriter.revert(targets, in: context)

        let message = "Deleted \(targets.count) automation entries totalling \(formatted)."
        return .result(value: targets.count, dialog: IntentDialog(stringLiteral: message))
    }
}
