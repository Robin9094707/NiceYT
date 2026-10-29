import AVKit
import MediaPlayer
import SwiftUI
import UIKit

/// Full AVKit player (Liquid Glass controls on iOS 26, PiP, AirPlay, speed menu)
/// plus YouTube-style gestures: double-tap to seek, swipe up for fullscreen, swipe
/// down to leave fullscreen or minimise, pinch to fill the screen, optional
/// volume/brightness swipes.
struct SystemPlayerView: UIViewControllerRepresentable {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var settings: AppSettings
    /// Whether the player currently covers the whole screen.
    let isFull: Bool

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
                     AVPlaybackSpeed(rate: 1, localizedName: "Normal"),
                     AVPlaybackSpeed(rate: 1.25, localizedName: "1,25×"),
                     AVPlaybackSpeed(rate: 1.5, localizedName: "1,5×"),
                     AVPlaybackSpeed(rate: 1.75, localizedName: "1,75×"),
                     AVPlaybackSpeed(rate: 2, localizedName: "2×")]
        context.coordinator.model = model
        context.coordinator.settings = settings
        context.coordinator.isFull = isFull
        context.coordinator.install(on: vc.view)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== model.player { vc.player = model.player }
        if vc.canStartPictureInPictureAutomaticallyFromInline != settings.autoPiP {
            vc.canStartPictureInPictureAutomaticallyFromInline = settings.autoPiP
        }
        let gravity: AVLayerVideoGravity = isFull && model.videoFill ? .resizeAspectFill : .resizeAspect
        if vc.videoGravity != gravity { vc.videoGravity = gravity }
        context.coordinator.model = model
        context.coordinator.settings = settings
        context.coordinator.isFull = isFull
    }
}

@MainActor
final class GestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var model: PlayerModel?
    var settings: AppSettings = .shared
    var isFull = false
    private weak var view: UIView?
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private enum PanMode { case none, volume, brightness, fullscreen, dismiss }
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
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
    }

    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    nonisolated func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            if g is UIPinchGestureRecognizer { return isFull }
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

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended || g.state == .changed, isFull, let model else { return }
        if g.scale > 1.08, !model.videoFill {
            model.videoFill = true
            model.showToast("Auf Bildschirm gezoomt")
        } else if g.scale < 0.92, model.videoFill {
            model.videoFill = false
            model.showToast("Originalgröße")
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let view, let model else { return }
        let size = view.bounds.size
        switch g.state {
        case .began:
            let x = g.location(in: view).x / max(size.width, 1)
            let up = g.velocity(in: view).y < 0
            if isFull, settings.swipeVolume, x > 0.62 {
                panMode = .volume
                startValue = Double(AVAudioSession.sharedInstance().outputVolume)
            } else if isFull, settings.swipeVolume, x < 0.38 {
                panMode = .brightness
                startValue = Double(view.window?.windowScene?.screen.brightness ?? 0.5)
            } else if !isFull, !up {
                panMode = .dismiss
            } else {
                panMode = settings.swipeFullscreen ? .fullscreen : .none
            }
        case .changed:
            let translation = g.translation(in: view).y
            let delta = -translation / max(size.height, 1)
            switch panMode {
            case .volume:
                let value = Float(min(1, max(0, startValue + delta)))
                setVolume(value)
                model.showHUD(.volume(value))
            case .brightness:
                let value = min(1, max(0, startValue + delta))
                view.window?.windowScene?.screen.brightness = CGFloat(value)
                model.showHUD(.brightness(value))
            case .dismiss:
                model.live.dragOffset = max(0, translation)
            default:
                break
            }
        case .ended:
            let dy = g.translation(in: view).y
            let vy = g.velocity(in: view).y
            switch panMode {
            case .fullscreen:
                if !isFull, dy < -40 || vy < -600 {
                    model.setFullscreen(true)
                } else if isFull, dy > 40 || vy > 600 {
                    model.setFullscreen(false)
                }
            case .dismiss:
                if dy > 110 || vy > 900 {
                    model.minimize()
                    // Reset once the dismissal animation has finished.
                    Task { @MainActor [weak model] in
                        try? await Task.sleep(for: .milliseconds(600))
                        if model?.isPresented == false { model?.live.dragOffset = 0 }
                    }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.live.dragOffset = 0 }
                }
            default:
                break
            }
            panMode = .none
        default:
            if panMode == .dismiss {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { model.live.dragOffset = 0 }
            }
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
