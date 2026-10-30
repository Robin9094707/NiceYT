import Photos
import SwiftUI
import UIKit

/// A destructive action waiting for confirmation (deleting downloads …). Menus can't
/// show dialogs themselves, so they hand the question to whichever screen is on top.
struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    var message: String?
    let actionTitle: String
    let action: () -> Void
}

@MainActor
final class ConfirmCenter: ObservableObject {
    static let shared = ConfirmCenter()
    @Published var request: ConfirmRequest?

    func ask(_ title: String, message: String? = nil, action actionTitle: String = "Löschen", perform: @escaping () -> Void) {
        Haptics.warning()
        request = ConfirmRequest(title: title, message: message, actionTitle: actionTitle, action: perform)
    }
}

extension View {
    /// Shows pending confirmations while `active` (the topmost screen).
    func confirmations(active: Bool) -> some View {
        modifier(ConfirmationPresenter(active: active))
    }
}

private struct ConfirmationPresenter: ViewModifier {
    @ObservedObject private var center = ConfirmCenter.shared
    let active: Bool

    func body(content: Content) -> some View {
        let shown = active ? center.request : nil
        content.alert(shown?.title ?? "", isPresented: Binding(get: { shown != nil }, set: { if !$0 { center.request = nil } }),
                      presenting: shown) { request in
            Button(request.actionTitle, role: .destructive) {
                request.action()
                center.request = nil
            }
            Button("Abbrechen", role: .cancel) { center.request = nil }
        } message: { request in
            if let m = request.message { Text(m) }
        }
    }
}

/// Saves downloaded files into the Files app (any folder, iCloud …) or into Photos.
@MainActor
enum FileSaver {
    static func saveToFiles(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty, let top = topController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: existing, asCopy: true)
        Haptics.soft()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let host = topController() ?? top
            host.present(picker, animated: true)
        }
    }

    /// Adds a video or picture to the photo library (asks for permission the first time).
    static func saveToPhotos(_ url: URL, toast: @escaping (String) -> Void) {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Haptics.error()
                toast("Kein Zugriff auf Fotos – in den iOS-Einstellungen erlauben")
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(url.pathExtension.lowercased()) {
                        PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
                    } else {
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                }
                Haptics.success()
                toast("In Fotos gesichert")
            } catch {
                Haptics.error()
                toast("Sichern in Fotos fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
