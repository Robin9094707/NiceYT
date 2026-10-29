import AVKit
import SwiftUI
import UIKit

/// Full AVKit player (Liquid Glass controls on iOS 26, PiP, AirPlay, speed menu).
struct SystemPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var settings: AppSettings

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = model.player
        vc.delegate = model
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = settings.autoPiP
        vc.updatesNowPlayingInfoCenter = false
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = false
        vc.videoGravity = .resizeAspect
        vc.view.backgroundColor = .black
        vc.speeds = [AVPlaybackSpeed(rate: 0.5, localizedName: "0,5×"),
                     AVPlaybackSpeed(rate: 0.75, localizedName: "0,75×"),
                     AVPlaybackSpeed(rate: 1, localizedName: "1×"),
                     AVPlaybackSpeed(rate: 1.25, localizedName: "1,25×"),
                     AVPlaybackSpeed(rate: 1.5, localizedName: "1,5×"),
                     AVPlaybackSpeed(rate: 1.75, localizedName: "1,75×"),
                     AVPlaybackSpeed(rate: 2, localizedName: "2×")]
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        vc.canStartPictureInPictureAutomaticallyFromInline = settings.autoPiP
    }
}

/// Bare video layer, used for the mini player and Shorts.
final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoLayer: UIViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}
