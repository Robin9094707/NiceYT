import UIKit

/// Short haptic cues for interactions (likes, subscriptions, long presses …).
/// Can be switched off under Einstellungen → Bedienung.
@MainActor
enum Haptics {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notificationGenerator = UINotificationFeedbackGenerator()

    private static var enabled: Bool { AppSettings.hapticsEnabled }

    /// Light tick: play/pause, seeking, small toggles.
    static func tap() {
        guard enabled else { return }
        lightGenerator.impactOccurred()
    }

    /// Noticeable bump: like, favourite, long press.
    static func impact() {
        guard enabled else { return }
        mediumGenerator.impactOccurred()
    }

    /// Soft bump: entering/leaving fullscreen, opening sheets.
    static func soft() {
        guard enabled else { return }
        softGenerator.impactOccurred()
    }

    /// Crisp bump for a "like" that is set (not removed).
    static func like() {
        guard enabled else { return }
        rigidGenerator.impactOccurred(intensity: 0.9)
    }

    static func selection() {
        guard enabled else { return }
        selectionGenerator.selectionChanged()
    }

    static func success() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.success)
    }

    static func warning() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.warning)
    }

    static func error() {
        guard enabled else { return }
        notificationGenerator.notificationOccurred(.error)
    }
}
