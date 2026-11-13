import SwiftUI
import UIKit

/// Hosts the Metal layer libmpv renders into.
final class MPVVideoController: UIViewController {
    let metalLayer = MPVMetalLayer()
    weak var player: MPVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.frame = view.bounds
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        player?.start(layer: metalLayer)

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = view.bounds
        CATransaction.commit()
    }

    @objc private func didEnterBackground() {
        // Rendering into a backgrounded layer leaves a black screen afterwards.
        player?.setPaused(true)
        player?.setVideoEnabled(false)
    }

    @objc private func willEnterForeground() {
        player?.setVideoEnabled(true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct MPVVideoView: UIViewControllerRepresentable {
    let player: MPVPlayer

    func makeUIViewController(context: Context) -> MPVVideoController {
        let vc = MPVVideoController()
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: MPVVideoController, context: Context) {}
}
