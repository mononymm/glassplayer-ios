import SwiftUI
import UIKit

/// A view whose own backing layer is the Metal layer mpv renders into, so the video always
/// covers exactly the view, through rotations and size changes.
final class MPVMetalView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = metalLayer.contentsScale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 1, size.height > 1, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }
}

/// Hosts the view libmpv renders into.
final class MPVVideoController: UIViewController {
    weak var player: MPVPlayer?
    private var started = false
    private var metalView: MPVMetalView { view as! MPVMetalView }

    override func loadView() {
        view = MPVMetalView(frame: UIScreen.main.bounds)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Start mpv once the view has its real (landscape) size, so the first frames are placed right.
        if !started, view.bounds.width > 1, view.bounds.height > 1 {
            started = true
            player?.start(layer: metalView.metalLayer)
        }
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
