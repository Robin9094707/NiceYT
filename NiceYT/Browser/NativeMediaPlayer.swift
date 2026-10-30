import AVKit
import SwiftUI

extension Notification.Name {
    /// Sent before the native media player starts, so other playback pauses.
    static let novaMediaWillPlay = Notification.Name("novaMediaWillPlay")
}

/// A web video/song (or a file of the media library) for the native player.
struct NativeMediaItem: Identifiable {
    let id = UUID()
    let url: URL
    var kind: MediaKind
    var title: String
    var poster: URL?
    var page: URL?
    var userAgent: String = UserAgents.mobile
    var isPrivate = false
    /// Set when it plays from the media library.
    var file: SavedFile?
    /// Extra request headers (cookies of an extraction).
    var headers: [String: String] = [:]
}

/// Native AVKit player (PiP, AirPlay, speed, fullscreen) for media of web pages and the
/// media library, with download and share actions below the video.
struct NativeMediaSheet: View {
    let item: NativeMediaItem
    @ObservedObject private var files = FileDownloads.shared
    @ObservedObject private var library = BrowserLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var jobId: String?
    @State private var size: Int64?
    @State private var failed: String?
    @State private var statusObserver: NSKeyValueObservation?

    private var isAudio: Bool { item.kind == .audio }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    stage
                    info
                    actions
                }
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(.systemBackground))
            .navigationTitle(isAudio ? "Audio" : "Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                if item.file == nil {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { await start() }
        .onDisappear {
            player?.pause()
            statusObserver = nil
        }
    }

    // MARK: Player

    private var stage: some View {
        ZStack {
            if isAudio {
                artwork.overlay(alignment: .bottom) {
                    if let player { NativePlayerController(player: player, transparent: true).frame(height: 120) }
                }
            } else {
                Color.black
                if let player {
                    NativePlayerController(player: player, transparent: false)
                } else if failed == nil {
                    if let poster = item.poster { RemoteImage(url: poster, contentMode: .fit).opacity(0.5) }
                    ProgressView().tint(.white).controlSize(.large)
                }
            }
            if let failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                    Text(failed).font(.footnote).foregroundStyle(.white).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .aspectRatio(isAudio ? 1 : 16 / 9, contentMode: .fit)
        .frame(maxWidth: isAudio ? 340 : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: isAudio ? 28 : 0, style: .continuous))
        .shadow(color: .black.opacity(isAudio ? 0.3 : 0), radius: 20, y: 10)
        .padding(.top, isAudio ? 12 : 0)
    }

    private var artwork: some View {
        ZStack {
            LinearGradient(colors: [.accentColor, .purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let poster = item.poster {
                RemoteImage(url: poster)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 90, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.variableColor.iterative, isActive: player?.timeControlStatus == .playing)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title.isEmpty ? FileDownloads.displayName(for: item.url) : item.title)
                .font(.title3.weight(.bold))
                .lineLimit(3)
            HStack(spacing: 8) {
                Label(item.kind.label, systemImage: item.kind.icon)
                if let host = (item.page ?? item.url).host?.replacingOccurrences(of: "www.", with: ""), item.file == nil {
                    Text(host)
                }
                if let size = size ?? item.file?.size, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if let file = item.file {
                HStack(spacing: 10) {
                    ShareLink(item: file.url) { actionLabel("Teilen", "square.and.arrow.up") }
                    if file.kind == .video {
                        Button { FileSaver.saveToPhotos(file.url) { files.onToast?($0) } } label: { actionLabel("In Fotos", "photo.on.rectangle") }
                    }
                    Button { FileSaver.saveToFiles([file.url]) } label: { actionLabel("In Dateien", "folder") }
                }
                .buttonStyle(.glass)
            } else {
                downloadButton
                HStack(spacing: 10) {
                    Button {
                        UIPasteboard.general.url = item.url
                        Haptics.success()
                    } label: { actionLabel("Direktlink", "link") }
                    if let page = item.page {
                        Button {
                            dismiss()
                            DownloadAssistant.shared.start(page, page: page, userAgent: item.userAgent, isPrivate: item.isPrivate, autoStart: false)
                        } label: { actionLabel("Assistent", "wand.and.stars") }
                    }
                    Button {
                        player?.pause()
                        if let top = FileSaver.topController(), let player {
                            let vc = AVPlayerViewController()
                            vc.player = player
                            top.present(vc, animated: true) { player.play() }
                        }
                    } label: { actionLabel("Vollbild", "arrow.up.left.and.arrow.down.right") }
                    .disabled(player == nil || isAudio)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var downloadButton: some View {
        let job = jobId.flatMap { files.jobs[$0] }
        let doneId = jobId.flatMap { files.finished[$0] }
        Button {
            guard jobId == nil || (job == nil && doneId == nil) else { return }
            download()
        } label: {
            HStack(spacing: 10) {
                if let job, !job.failed {
                    ProgressRing(value: job.progress).frame(width: 20, height: 20)
                    Text("Wird geladen … \(Int(job.progress * 100)) %").monospacedDigit()
                } else if doneId != nil {
                    Image(systemName: "checkmark.circle.fill")
                    Text("In der Mediathek gespeichert")
                } else if let job, job.failed {
                    Image(systemName: "arrow.clockwise")
                    Text("Erneut versuchen")
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                    Text("Herunterladen · \(library.downloadTarget.label)")
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .contextMenu {
            Picker("Speichern in", selection: $library.downloadTarget) {
                ForEach(DownloadTarget.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
        }
        if let job, job.failed {
            Text(job.status).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
        }
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.headline)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func start() async {
        guard player == nil else { return }
        NotificationCenter.default.post(name: .novaMediaWillPlay, object: nil)
        let asset: AVURLAsset
        if item.url.isFileURL {
            asset = AVURLAsset(url: item.url)
        } else {
            var headers = await BrowserModel.requestHeaders(for: item.url, page: item.page, userAgent: item.userAgent, isPrivate: item.isPrivate)
            for (k, v) in item.headers { headers[k] = v }
            asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            Task { size = await MediaProbe.size(item.url, headers: headers) }
        }
        let playerItem = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: playerItem)
        statusObserver = playerItem.observe(\.status) { observed, _ in
            guard observed.status == .failed else { return }
            let message = observed.error?.localizedDescription ?? "Kann nicht abgespielt werden"
            Task { @MainActor in failed = message }
        }
        player = p
        p.play()
    }

    private func download() {
        let ext = item.url.pathExtension.lowercased()
        let name = (item.title.isEmpty ? FileDownloads.displayName(for: item.url) : item.title)
        let fileExt = item.kind == .stream || ext.isEmpty || ext == "m3u8" ? (isAudio ? "m4a" : "mp4") : ext
        let base = FileDownloads.safe(name)
        let clean = (base as NSString).pathExtension.lowercased() == fileExt ? base : base + "." + fileExt
        jobId = files.download(item.url, name: clean, page: item.page, userAgent: item.userAgent, headers: item.headers,
                               thumbnail: item.poster, target: library.downloadTarget, isPrivate: item.isPrivate)
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    var transparent = false

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = transparent ? .clear : .black
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

/// File size of a remote file without downloading it.
enum MediaProbe {
    static func size(_ url: URL, headers: [String: String]) async -> Int64? {
        guard MediaKind(fileExtension: url.pathExtension) != .stream else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let r = try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse, r.statusCode < 400, r.expectedContentLength > 0 {
            return r.expectedContentLength
        }
        req.httpMethod = "GET"
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let r = try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse,
              let range = r.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else { return nil }
        return total
    }
}
