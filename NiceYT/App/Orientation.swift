import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Forces landscape / portrait for the player, independent of the rotation lock.
@MainActor
enum Orientation {
    static var isLandscape: Bool {
        guard let scene = windowScene else { return false }
        return scene.effectiveGeometry.interfaceOrientation.isLandscape
    }

    private static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    static func set(landscape: Bool) {
        AppDelegate.orientationLock = landscape ? .landscape : .portrait
        refresh()
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { error in
            DebugLog.log("Ausrichtung: \(error.localizedDescription)")
        }
        if !landscape {
            // Give rotation back to the device shortly after returning to portrait.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if AppDelegate.orientationLock == .portrait {
                    AppDelegate.orientationLock = .allButUpsideDown
                    refresh()
                }
            }
        }
    }

    private static func refresh() {
        guard let scene = windowScene else { return }
        for window in scene.windows {
            var vc = window.rootViewController
            while let current = vc {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                vc = current.presentedViewController
            }
        }
    }
}
