import SwiftUI

/// App name, version and where updates come from – in one place.
enum AppInfo {
    static let name = "Nova"
    static let repository = "Robin9094707/NiceYT"
    static let ipaName = "NiceYT.ipa"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    /// The CI build number (GitHub run number), compared with the release tags.
    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
}

/// Looks for a newer IPA in the GitHub releases and installs it through AltStore,
/// SideStore or TrollStore with one tap.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Identifiable, Equatable {
        let build: Int
        let title: String
        let notes: String
        let date: Date?
        let ipa: URL
        let page: URL
        var id: Int { build }
    }

    enum Installer: String, CaseIterable, Identifiable {
        case trollStore, sideStore, altStore, download
        var id: String { rawValue }
        var name: String {
            switch self {
            case .trollStore: return "TrollStore"
            case .sideStore: return "SideStore"
            case .altStore: return "AltStore"
            case .download: return "IPA herunterladen"
            }
        }
        var icon: String {
            switch self {
            case .trollStore: return "hammer.fill"
            case .sideStore, .altStore: return "arrow.down.app.fill"
            case .download: return "arrow.down.doc.fill"
            }
        }
        func url(for ipa: URL) -> URL {
            let encoded = ipa.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ipa.absoluteString
            switch self {
            case .trollStore: return URL(string: "apple-magnifier://install?url=\(encoded)")!
            case .sideStore: return URL(string: "sidestore://install?url=\(encoded)")!
            case .altStore: return URL(string: "altstore://install?url=\(encoded)")!
            case .download: return ipa
            }
        }
        var probe: URL? {
            switch self {
            case .trollStore: return URL(string: "apple-magnifier://")
            case .sideStore: return URL(string: "sidestore://")
            case .altStore: return URL(string: "altstore://")
            case .download: return nil
            }
        }
    }

    @Published private(set) var latest: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?
    /// Shown once per new build as a sheet.
    @Published var prompt: Release?
    private var lastCheck: Date?

    var updateAvailable: Bool { (latest?.build ?? 0) > AppInfo.build }

    /// Installers present on this device (plain download always works).
    var installers: [Installer] {
        Installer.allCases.filter { i in i.probe.map { UIApplication.shared.canOpenURL($0) } ?? true }
    }

    func check(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
        guard !isChecking, AppInfo.build > 0 else { return }
        isChecking = true
        defer { isChecking = false }
        lastCheck = Date()
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases?per_page=15")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw YTError.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            let iso = ISO8601DateFormatter()
            let releases: [Release] = JSON(data: data).array.compactMap { r in
                guard r["draft"].bool != true, let tag = r["tag_name"].string, tag.hasPrefix("niceyt-"),
                      let build = Int(tag.dropFirst("niceyt-".count)),
                      let asset = r["assets"].array.first(where: { $0["name"].string?.hasSuffix(".ipa") == true }),
                      let ipa = asset["browser_download_url"].string.flatMap(URL.init(string:)),
                      let page = r["html_url"].string.flatMap(URL.init(string:)) else { return nil }
                return Release(build: build, title: r["name"].string ?? tag, notes: r["body"].string ?? "",
                               date: r["published_at"].string.flatMap { iso.date(from: $0) }, ipa: ipa, page: page)
            }
            latest = releases.max { $0.build < $1.build }
            lastError = nil
            if let latest, latest.build > AppInfo.build, UserDefaults.standard.integer(forKey: "updatePromptedBuild") < latest.build {
                UserDefaults.standard.set(latest.build, forKey: "updatePromptedBuild")
                prompt = latest
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func install(_ release: Release, with installer: Installer) {
        Haptics.impact()
        UIApplication.shared.open(installer.url(for: release.ipa)) { ok in
            if !ok { Task { @MainActor in UIApplication.shared.open(release.ipa) } }
        }
    }
}

/// "Update available" with one button per installed sideloading app.
struct UpdateSheet: View {
    let release: UpdateChecker.Release
    @ObservedObject private var updates = UpdateChecker.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 86, height: 86)
                        .background(LinearGradient(colors: [.accentColor, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .purple.opacity(0.35), radius: 16, y: 8)
                    VStack(spacing: 4) {
                        Text("Update verfügbar").font(.title2.weight(.bold))
                        Text("Build \(release.build) · installiert ist \(AppInfo.build)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 10) {
                        ForEach(updates.installers) { installer in
                            installButton(installer, prominent: installer == updates.installers.first)
                        }
                    }
                    if !release.notes.isEmpty {
                        Text(release.notes)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 18))
                    }
                    Text("Deine Daten, Downloads und Anmeldungen bleiben beim Update erhalten.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Später") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private func installButton(_ installer: UpdateChecker.Installer, prominent: Bool) -> some View {
        let button = Button {
            updates.install(release, with: installer)
            dismiss()
        } label: {
            Label(installer == .download ? installer.name : "Mit \(installer.name) installieren", systemImage: installer.icon)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
        if prominent { button.buttonStyle(.glassProminent) } else { button.buttonStyle(.glass) }
    }
}
