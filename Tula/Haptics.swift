import UIKit

/// Centralized haptic feedback. Use these throughout instead of instantiating
/// UIImpactFeedbackGenerator directly so the whole app speaks with one voice.
enum Haptics {

    /// Light selection — tap a chip, pick an option, change a toggle.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Medium impact — drill into a detail screen, expand a section.
    static func impact() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Light impact — softer than .impact, for subtle confirmations.
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Soft success — save an expense, complete a transfer.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Warning — delete confirmation, error states.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Error — failed save, validation failure.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
