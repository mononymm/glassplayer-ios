import SwiftUI
import UIKit

enum ScreenSide { case left, right }

/// Tap / double-tap / hold handling over the video, split into left and right halves.
/// UIKit recognizers make single-vs-double tap and press-and-hold behave like other video apps.
struct GestureLayer: UIViewRepresentable {
    var onTap: () -> Void
    var onDoubleTap: (ScreenSide) -> Void
    var onHoldBegan: (ScreenSide) -> Void
    var onHoldEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let c = context.coordinator

        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.double(_:)))
        double.numberOfTapsRequired = 2
        double.delaysTouchesBegan = false
        v.addGestureRecognizer(double)

        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.single(_:)))
        single.numberOfTapsRequired = 1
        single.require(toFail: double)
        v.addGestureRecognizer(single)

        let hold = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 40
        v.addGestureRecognizer(hold)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: GestureLayer
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        init(_ p: GestureLayer) { parent = p }

        private func side(_ g: UIGestureRecognizer) -> ScreenSide {
            guard let v = g.view else { return .right }
            return g.location(in: v).x < v.bounds.midX ? .left : .right
        }

        @objc func single(_ g: UITapGestureRecognizer) { parent.onTap() }

        @objc func double(_ g: UITapGestureRecognizer) {
            haptic.impactOccurred()
            parent.onDoubleTap(side(g))
        }

        @objc func hold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                haptic.impactOccurred(intensity: 0.8)
                parent.onHoldBegan(side(g))
            case .ended, .cancelled, .failed:
                parent.onHoldEnded()
            default:
                break
            }
        }
    }
}
