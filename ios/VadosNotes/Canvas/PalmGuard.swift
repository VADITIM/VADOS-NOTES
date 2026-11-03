import UIKit
import UIKit.UIGestureRecognizerSubclass

final class PalmGuard {
    weak var view: UIView?

    private let pencilTouches = NSHashTable<UITouch>.weakObjects()
    private let palmTouches = NSHashTable<UITouch>.weakObjects()
    private var lastPencilContact: TimeInterval = -.infinity
    private var restPoints: [CGPoint] = []

    private static let palmRadius: CGFloat = 52
    private static let writingWindow: TimeInterval = 1.2
    private static let restBottomShare: CGFloat = 0.25
    private static let restRightShare: CGFloat = 0.35
    private static let restRightHeightShare: CGFloat = 0.55
    private static let learnedMargin: CGFloat = 64
    private static let learnedLimit = 24

    func isPalm(_ touch: UITouch) -> Bool {
        guard touch.type == .direct else { return false }
        if palmTouches.contains(touch) || touch.majorRadius >= Self.palmRadius || isPencilDown {
            return true
        }
        guard touch.timestamp - lastPencilContact < Self.writingWindow, let view else { return false }
        let location = touch.location(in: view)
        return restZones(in: view.bounds).contains { $0.contains(location) }
    }

    private var isPencilDown: Bool {
        pencilTouches.allObjects.contains { $0.phase != .ended && $0.phase != .cancelled }
    }

    func rejects(_ touches: Set<UITouch>?) -> Bool {
        touches?.contains { isPalm($0) } ?? false
    }

    func began(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                pencilTouches.add(touch)
                lastPencilContact = touch.timestamp
            } else if isPalm(touch) {
                palmTouches.add(touch)
                learn(touch)
            }
        }
    }

    func moved(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch.type == .pencil {
                lastPencilContact = touch.timestamp
            } else if touch.type == .direct, touch.majorRadius >= Self.palmRadius, !palmTouches.contains(touch) {
                palmTouches.add(touch)
                learn(touch)
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
        }
    }

    private func learn(_ touch: UITouch) {
        guard touch.majorRadius >= Self.palmRadius, let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let location = touch.location(in: view)
        restPoints.append(CGPoint(x: location.x / view.bounds.width, y: location.y / view.bounds.height))
        if restPoints.count > Self.learnedLimit {
            restPoints.removeFirst(restPoints.count - Self.learnedLimit)
        }
    }

    private func restZones(in bounds: CGRect) -> [CGRect] {
        let bottomHeight = bounds.height * Self.restBottomShare
        let rightHeight = bounds.height * Self.restRightHeightShare
        var zones = [
            CGRect(x: bounds.minX, y: bounds.maxY - bottomHeight, width: bounds.width, height: bottomHeight),
            CGRect(x: bounds.maxX - bounds.width * Self.restRightShare, y: bounds.maxY - rightHeight, width: bounds.width * Self.restRightShare, height: rightHeight)
        ]
        let learned = restPoints.map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
        if let first = learned.first {
            let area = learned.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            zones.append(area.insetBy(dx: -Self.learnedMargin, dy: -Self.learnedMargin))
        }
        return zones
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
