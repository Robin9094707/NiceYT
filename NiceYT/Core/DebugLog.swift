import Foundation
import UIKit

/// In-app diagnostics log that the user can share from Settings → Diagnose.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: @autoclosure () -> String) {
        shared.append(message())
    }

    private func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        lock.unlock()
        NotificationCenter.default.post(name: .debugLogChanged, object: nil)
    }

    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        NotificationCenter.default.post(name: .debugLogChanged, object: nil)
    }

    @MainActor
    func export() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let header = [
            "\(AppInfo.name) \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)",
            "Angemeldet: \(CookieJar.shared.isSignedIn ? "ja" : "nein") · hl=\(AppSettings.hl) gl=\(AppSettings.gl)",
            "Visitor: \(InnerTube.shared.visitorData == nil ? "nein" : "ja")",
            String(repeating: "-", count: 40)
        ]
        return (header + entries).joined(separator: "\n")
    }

    /// Shortens googlevideo URLs so logs stay readable without leaking full signatures.
    static func short(_ url: URL?) -> String {
        guard let url else { return "nil" }
        let s = url.absoluteString
        return s.count > 140 ? String(s.prefix(110)) + "…" + String(s.suffix(25)) : s
    }
}

extension Notification.Name {
    static let debugLogChanged = Notification.Name("NiceYTDebugLogChanged")
}
