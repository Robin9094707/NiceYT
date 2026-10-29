import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Full AVKit player (Liquid Glass controls on iOS 26, PiP, AirPlay, speed menu)
/// plus YouTube-style gestures: double-tap to seek, swipe up for landscape,
/// optional volume/brightness swipes.
struct SystemPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var settings: AppSettings

    func makeCoordinator() -> GestureCoordinator { GestureCoordinator() }

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
        context.coordinator.model = model
        context.coordinator.settings = settings
        context.coordinator.install(on: vc.view)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        vc.canStartPictureInPictureAutomaticallyFromInline = settings.autoPiP
        context.coordinator.model = model
        context.coordinator.settings = settings
    }
}

@MainActor
final class GestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var model: PlayerModel?
    var settings: AppSettings = .shared
    private weak var view: UIView?
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private enum PanMode { case none, volume, brightness, fullscreen }
    private var panMode: PanMode = .none
    private var startValue: Double = 0

    func install(on view: UIView) {
        self.view = view
        view.addSubview(volumeView)
        volumeView.alpha = 0.01

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        view.addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    nonisolated func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard let pan = g as? UIPanGestureRecognizer else { return settings.doubleTapSeek }
            let v = pan.velocity(in: pan.view)
            return abs(v.y) > abs(v.x) * 1.4
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard settings.doubleTapSeek, let view, let model else { return }
        let x = g.location(in: view).x / max(view.bounds.width, 1)
        if x < 0.4 {
            model.gestureSeek(forward: false)
        } else if x > 0.6 {
            model.gestureSeek(forward: true)
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view, let model else { return }
        let size = view.bounds.size
        switch g.state {
        case .began:
            let x = g.location(in: view).x / max(size.width, 1)
            if model.isFullscreen, settings.swipeVolume, x > 0.62 {
                panMode = .volume
                startValue = Double(AVAudioSession.sharedInstance().outputVolume)
            } else if model.isFullscreen, settings.swipeVolume, x < 0.38 {
                panMode = .brightness
                startValue = Double(view.window?.windowScene?.screen.brightness ?? 0.5)
            } else {
                panMode = settings.swipeFullscreen ? .fullscreen : .none
            }
        case .changed:
            let delta = -g.translation(in: view).y / max(size.height, 1)
            switch panMode {
            case .volume:
                let value = Float(min(1, max(0, startValue + delta)))
                setVolume(value)
                model.showHUD(.volume(value))
            case .brightness:
                let value = min(1, max(0, startValue + delta))
                view.window?.windowScene?.screen.brightness = CGFloat(value)
                model.showHUD(.brightness(value))
            default:
                break
            }
        case .ended:
            if panMode == .fullscreen {
                let dy = g.translation(in: view).y
                let vy = g.velocity(in: view).y
                if !model.isFullscreen, dy < -40 || vy < -600 {
                    model.setFullscreen(true)
                } else if model.isFullscreen, dy > 40 || vy > 600 {
                    model.setFullscreen(false)
                }
            }
            panMode = .none
        default:
            panMode = .none
        }
    }

    private func setVolume(_ value: Float) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.value = value
        slider.sendActions(for: .valueChanged)
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
