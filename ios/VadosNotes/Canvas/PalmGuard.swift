import UIKit
import UIKit.UIGestureRecognizerSubclass

final class PalmGuard {
    weak var view: UIView?

    private struct RestSpot {
        let point: CGPoint
        let time: TimeInterval
    }

    private let pencilTouches = NSHashTable<UITouch>.weakObjects()
    private let palmTouches = NSHashTable<UITouch>.weakObjects()
    private let fingerTouches = NSHashTable<UITouch>.weakObjects()
    private var lastPencilContact: TimeInterval = -.infinity
    private var restSpots: [RestSpot] = []

    private static let palmRadius: CGFloat = 52
    private static let writingWindow: TimeInterval = 0.35
    private static let restBottomShare: CGFloat = 0.2
    private static let restRightShare: CGFloat = 0.3
    private static let restRightHeightShare: CGFloat = 0.45
    private static let spotRadius: CGFloat = 90
    private static let spotLimit = 8
    private static let spotLifetime: TimeInterval = 60

    func isPalm(_ touch: UITouch) -> Bool {
        guard touch.type == .direct else { return false }
        if palmTouches.contains(touch) {
            return true
        }
        if touch.majorRadius >= Self.palmRadius {
            fingerTouches.remove(touch)
            palmTouches.add(touch)
            learn(touch)
            return true
        }
        if fingerTouches.contains(touch) {
            return false
        }
        if isPencilDown || isInRestZone(touch) {
            palmTouches.add(touch)
            return true
        }
        fingerTouches.add(touch)
        return false
    }

    private var isPencilDown: Bool {
        pencilTouches.allObjects.contains { $0.phase != .ended && $0.phase != .cancelled }
    }

    private func isInRestZone(_ touch: UITouch) -> Bool {
        guard touch.timestamp - lastPencilContact < Self.writingWindow, let view else { return false }
        let location = touch.location(in: view)
        let bounds = view.bounds
        let bottomHeight = bounds.height * Self.restBottomShare
        let rightHeight = bounds.height * Self.restRightHeightShare
        let zones = [
            CGRect(x: bounds.minX, y: bounds.maxY - bottomHeight, width: bounds.width, height: bottomHeight),
            CGRect(x: bounds.maxX - bounds.width * Self.restRightShare, y: bounds.maxY - rightHeight, width: bounds.width * Self.restRightShare, height: rightHeight)
        ]
        if zones.contains(where: { $0.contains(location) }) {
            return true
        }
        return restSpots.contains { spot in
            touch.timestamp - spot.time < Self.spotLifetime && hypot(spot.point.x * bounds.width - location.x, spot.point.y * bounds.height - location.y) < Self.spotRadius
        }
    }

    func rejects(_ touches: Set<UITouch>?) -> Bool {
        touches?.contains { isPalm($0) } ?? false
    }

    func began(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                pencilTouches.add(touch)
                lastPencilContact = touch.timestamp
            } else {
                _ = isPalm(touch)
            }
        }
    }

    func moved(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                lastPencilContact = touch.timestamp
            } else {
                _ = isPalm(touch)
            }
        }
    }

    func ended(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                pencilTouches.remove(touch)
                lastPencilContact = touch.timestamp
            }
            palmTouches.remove(touch)
            fingerTouches.remove(touch)
        }
    }

    private func learn(_ touch: UITouch) {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let location = touch.location(in: view)
        restSpots.removeAll { touch.timestamp - $0.time >= Self.spotLifetime }
        restSpots.append(RestSpot(point: CGPoint(x: location.x / view.bounds.width, y: location.y / view.bounds.height), time: touch.timestamp))
        if restSpots.count > Self.spotLimit {
            restSpots.removeFirst(restSpots.count - Self.spotLimit)
        }
    }
}

final class PalmWatchGestureRecognizer: UIGestureRecognizer {
    private let palmGuard: PalmGuard

    init(palmGuard: PalmGuard) {
        self.palmGuard = palmGuard
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        palmGuard.began(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        palmGuard.moved(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        palmGuard.ended(touches)
        finishIfLifted(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        palmGuard.ended(touches)
        finishIfLifted(event)
    }

    private func finishIfLifted(_ event: UIEvent) {
        let isLifted = event.allTouches?.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ?? true
        if isLifted {
            state = .failed
        }
    }
}

final class GuardedPinchGestureRecognizer: UIPinchGestureRecognizer {
    var palmGuard: PalmGuard?

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if palmGuard?.rejects(event.touches(for: self)) ?? false {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesMoved(touches, with: event)
    }
}

final class GuardedPanGestureRecognizer: UIPanGestureRecognizer {
    var palmGuard: PalmGuard?

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if palmGuard?.rejects(event.touches(for: self)) ?? false {
            state = state == .possible ? .failed : .cancelled
            return
        }
        super.touchesMoved(touches, with: event)
    }
}
