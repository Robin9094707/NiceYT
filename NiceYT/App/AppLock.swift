import LocalAuthentication
import SwiftUI

/// Face ID / Touch ID lock for the browser and the media library.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published private(set) var isUnlocked = false
    private var authenticating = false

    var isLocked: Bool { BrowserLibrary.shared.lockWithFaceID && !isUnlocked }

    var biometry: (name: String, icon: String) {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return ("Face ID", "faceid")
        case .touchID: return ("Touch ID", "touchid")
        case .opticID: return ("Optic ID", "opticid")
        default: return ("Code", "lock.fill")
        }
    }

    /// Asks for Face ID (or the device code as fallback).
    @discardableResult
    func authenticate(reason: String = "Browser und Mediathek entsperren") async -> Bool {
        guard !authenticating else { return false }
        authenticating = true
        defer { authenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Abbrechen"
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                withAnimation(.smooth) { isUnlocked = true }
                Haptics.success()
            }
            return ok
        } catch {
            return false
        }
    }

    func lock() {
        guard BrowserLibrary.shared.lockWithFaceID else { return }
        isUnlocked = false
    }

    /// Switching the lock on or off needs a successful check first.
    func setEnabled(_ on: Bool) async {
        guard await authenticate(reason: on ? "Sperre einschalten" : "Sperre ausschalten") else { return }
        BrowserLibrary.shared.lockWithFaceID = on
    }
}

extension View {
    /// Covers the view while the app lock is active.
    func appLocked() -> some View { modifier(AppLockCover()) }
}

private struct AppLockCover: ViewModifier {
    @ObservedObject private var lock = AppLock.shared
    @ObservedObject private var library = BrowserLibrary.shared

    func body(content: Content) -> some View {
        let locked = library.lockWithFaceID && !lock.isUnlocked
        content
            .blur(radius: locked ? 30 : 0)
            .allowsHitTesting(!locked)
            .overlay {
                if locked {
                    VStack(spacing: 18) {
                        Image(systemName: lock.biometry.icon)
                            .font(.system(size: 54, weight: .light))
                            .foregroundStyle(.tint)
                            .frame(width: 110, height: 110)
                            .glassEffect(.regular, in: .circle)
                        Text("Gesperrt").font(.title2.weight(.bold))
                        Text("Browser und Mediathek sind mit \(lock.biometry.name) geschützt.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await lock.authenticate() }
                        } label: {
                            Label("Entsperren", systemImage: lock.biometry.icon).font(.headline).padding(.horizontal, 10)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        Button("Schließen") { BrowserModel.shared.isPresented = false }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.opacity)
                    .task { await lock.authenticate() }
                }
            }
    }
}
