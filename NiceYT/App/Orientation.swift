import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// Orientation handling like the YouTube app: the fullscreen button forces landscape
/// (or portrait) until the device is physically turned that way, then normal
/// auto-rotation takes over again. Shorts keep the app in portrait.
@MainActor
enum Orientation {
    static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    static var isLandscape: Bool {
        guard let scene = windowScene else { return false }
        return scene.effectiveGeometry.interfaceOrientation.isLandscape
    }

    /// Mask used while nothing is forced (portrait only while the Shorts tab is visible).
    private static var baseMask: UIInterfaceOrientationMask = .allButUpsideDown
    /// Orientation forced by the fullscreen button, released once the device matches it.
    private static var forced: UIInterfaceOrientationMask?
    private static var observer: NSObjectProtocol?

    private static var windowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Restricts the app to portrait (Shorts) or allows all orientations again.
    static func setPortraitOnly(_ on: Bool) {
        guard isPhone else { return }
        baseMask = on ? .portrait : .allButUpsideDown
        guard forced == nil else { return }
        AppDelegate.orientationLock = baseMask
        refresh()
        if on, isLandscape { request(.portrait) }
    }

    /// Forces landscape (fullscreen) or portrait, independent of the rotation lock.
    static func set(landscape: Bool) {
        guard isPhone else { return }
        startObserving()
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait
        forced = mask
        AppDelegate.orientationLock = mask
        refresh()
        request(landscape ? landscapeTarget : .portrait)
        // If the device is already held that way there is nothing to wait for.
        releaseIfMatched()
    }

    private static var landscapeTarget: UIInterfaceOrientationMask {
        // Rotate towards the side the device is tilted to (like the YouTube app).
        UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            DebugLog.log("Ausrichtung: \(error.localizedDescription)")
        }
    }

    private static func startObserving() {
        guard observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { releaseIfMatched() }
        }
    }

    private static func releaseIfMatched() {
        guard let f = forced else { return }
        let device = UIDevice.current.orientation
        let matches = f == .landscape ? device.isLandscape : device == .portrait
        guard matches else { return }
        forced = nil
        // When returning to portrait, keep the Shorts restriction if it applies.
        AppDelegate.orientationLock = f == .landscape ? .allButUpsideDown : baseMask
        refresh()
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
