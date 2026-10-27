import SwiftUI
import UIKit

struct TileCallbacks {
    var onTap: (CGRect) -> Void
    var onMenu: (CGPoint) -> Void
    var onDragBegin: ((CGPoint) -> Void)?
    var onDragMove: ((CGPoint) -> Void)?
    var onDragEnd: ((CGPoint, Bool) -> Void)?
    var onPress: ((Bool) -> Void)?
}

final class TileTouchView: UIView, UIGestureRecognizerDelegate {
    var callbacks: TileCallbacks?
    private var pressStart: CGPoint = .zero
    private var isDragging = false

    private static let dragTolerance: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(handleSecondary(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(secondary)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = Motion.seconds(Motion.menuHoldMilliseconds)
        hold.allowableMovement = 10
        hold.cancelsTouchesInView = false
        hold.delegate = self
        addGestureRecognizer(hold)
    }

    required init?(coder: NSCoder) {
        fatalError("TileTouchView is created in code")
    }

    private var windowFrame: CGRect {
        convert(bounds, to: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        callbacks?.onPress?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        callbacks?.onPress?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        callbacks?.onPress?(false)
    }

    @objc private func handleTap() {
        callbacks?.onTap(windowFrame)
    }

    @objc private func handleSecondary(_ recognizer: UITapGestureRecognizer) {
        callbacks?.onMenu(recognizer.location(in: nil))
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            pressStart = location
            isDragging = false
            Haptics.hold()
            callbacks?.onMenu(location)
        case .changed:
            if !isDragging, hypot(location.x - pressStart.x, location.y - pressStart.y) > Self.dragTolerance, let onDragBegin = callbacks?.onDragBegin {
                isDragging = true
                onDragBegin(pressStart)
            }
            if isDragging {
                callbacks?.onDragMove?(location)
            }
        case .ended, .cancelled, .failed:
            callbacks?.onPress?(false)
            if isDragging {
                isDragging = false
                callbacks?.onDragEnd?(location, recognizer.state == .ended)
            }
        default:
            break
        }
    }
}

struct TileInteraction: UIViewRepresentable {
    let callbacks: TileCallbacks

    func makeUIView(context: Context) -> TileTouchView {
        let view = TileTouchView(frame: .zero)
        view.callbacks = callbacks
        return view
    }

    func updateUIView(_ view: TileTouchView, context: Context) {
        view.callbacks = callbacks
    }
}
