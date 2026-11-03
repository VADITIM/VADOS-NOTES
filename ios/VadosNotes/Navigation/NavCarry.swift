import SwiftUI
import UIKit

enum NavCarryState {
    case idle
    case carried
    case thrown
    case docking
    case parking
    case parked
}

enum NavEdge: String {
    case top
    case bottom
    case left
    case right

    var orientation: NavOrientation {
        self == .left || self == .right ? .vertical : .horizontal
    }
}

enum NavCarryZone {
    case open
    case corner(String)
    case edge(NavEdge, NavOrientation)
}

struct NavCarryHost {
    var bounds: () -> CGSize
    var orientation: () -> NavOrientation
    var shownSize: (CGFloat) -> CGSize
    var clamped: (CGPoint, CGSize) -> CGPoint
    var turnTo: (NavOrientation, Bool) -> Double
    var dockSpot: (NavEdge?, CGPoint) -> CGPoint
    var cornerSpot: (String) -> CGPoint
    var onLand: (String?) -> Void
}

@MainActor
final class NavCarry: ObservableObject {
    @Published private(set) var state: NavCarryState = .idle
    @Published private(set) var center: CGPoint?
    @Published private(set) var morph: CGFloat = 0
    @Published private(set) var stretchAmount: CGFloat = 0
    @Published private(set) var stretchAngle: CGFloat = 0
    private(set) var corner: String?

    var host: NavCarryHost?

    private var velocity = CGVector.zero
    private var follow = CGPoint.zero
    private var followVelocity = CGVector.zero
    private var target = CGPoint.zero
    private var morphVelocity: CGFloat = 0
    private var morphTarget: CGFloat = 0
    private var samples: [(point: CGPoint, time: Double)] = []
    private var start = CGPoint.zero
    private var finger = CGPoint.zero
    private var grabOffset = CGSize.zero
    private var isLatched = false
    private var isHolding = false
    private var lastWall: NavEdge?
    private var phase = 0
    private var turnUntil: Double = 0
    private var displayLink: CADisplayLink?
    private var lastFrame: Double = 0

    private static let substep: Double = 1.0 / 240

    private var settings: Tokens.CarryTokens { Motion.carry }

    var isActive: Bool {
        state != .idle && state != .parked
    }

    var isStageCleared: Bool {
        state != .idle
    }

    private static func now() -> Double {
        CACurrentMediaTime() * 1000
    }

    private static func share(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }

    private static func force(_ value: CGFloat, _ velocity: CGFloat, _ target: CGFloat, _ spring: Tokens.SpringToken) -> CGFloat {
        let stiffness = pow(2 * .pi / spring.response, 2)
        let friction = 4 * .pi * spring.dampingFraction / spring.response
        return CGFloat(-stiffness) * (value - target) - CGFloat(friction) * velocity
    }

    func restore(corner: String?) {
        guard let corner else { return }
        state = .parked
        self.corner = corner
        morph = 1
        morphTarget = 1
    }

    func grab(finger point: CGPoint, center current: CGPoint) {
        phase += 1
        isHolding = false
        center = current
        follow = current
        followVelocity = isActive ? velocity : .zero
        velocity = followVelocity
        state = .carried
        start = point
        finger = point
        grabOffset = CGSize(width: point.x - current.x, height: point.y - current.y)
        isLatched = morph >= 0.5
        samples = [(point, Self.now())]
        lastWall = nil
        corner = nil
        run()
    }

    func drag(finger point: CGPoint) {
        guard state == .carried else { return }
        finger = point
        let time = Self.now()
        samples.append((point, time))
        trimSamples(time)
        if hypot(fingerVelocity().dx, fingerVelocity().dy) >= settings.throwVelocity {
            isLatched = true
        }
    }

    func swapGrab() {
        grabOffset = CGSize(width: grabOffset.height, height: grabOffset.width)
    }

    func release() {
        guard state == .carried else { return }
        trimSamples(Self.now())
        let released = fingerVelocity()
        let zone = carriedZone()
        var isOpen = false
        if case .open = zone {
            isOpen = true
        }
        if hypot(released.dx, released.dy) >= settings.throwVelocity || (isOpen && freeMorph() >= 0.5) {
            throwWith(released)
            return
        }
        switch zone {
        case .corner(let name): park(name)
        case .edge(let edge, _): dock(edge)
        case .open: dock(nil)
        }
    }

    func expand() {
        guard state == .parked || state == .parking, let host else { return }
        let name = corner ?? "bottom-right"
        let current = center ?? host.cornerSpot(name)
        center = current
        let parts = name.split(separator: "-").map(String.init)
        let bounds = host.bounds()
        let vertical = NavEdge(rawValue: parts.first ?? "bottom") ?? .bottom
        let horizontal = NavEdge(rawValue: parts.last ?? "right") ?? .right
        let verticalDistance = vertical == .top ? current.y : bounds.height - current.y
        let horizontalDistance = horizontal == .left ? current.x : bounds.width - current.x
        dock(verticalDistance <= horizontalDistance ? vertical : horizontal)
    }

    private func trimSamples(_ time: Double) {
        let window = settings.velocityWindow
        while samples.count > 2, time - samples[0].time > window {
            samples.removeFirst()
        }
        if let last = samples.last, time - last.time > window {
            samples = [last]
        }
    }

    private func fingerVelocity() -> CGVector {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else { return .zero }
        let seconds = (last.time - first.time) / 1000
        guard seconds > 0.004 else { return .zero }
        return CGVector(dx: (last.point.x - first.point.x) / seconds, dy: (last.point.y - first.point.y) / seconds)
    }

    private func freeMorph() -> CGFloat {
        if isLatched {
            return 1
        }
        let travel = hypot(finger.x - start.x, finger.y - start.y)
        return Self.share((travel - settings.morphStart) / max(1, settings.morphFull - settings.morphStart))
    }

    private func cornerAt(_ point: CGPoint) -> String? {
        guard let host else { return nil }
        let bounds = host.bounds()
        let reach = settings.cornerZone
        let vertical = point.y < reach ? "top" : point.y > bounds.height - reach ? "bottom" : nil
        let horizontal = point.x < reach ? "left" : point.x > bounds.width - reach ? "right" : nil
        guard let vertical, let horizontal else { return nil }
        return "\(vertical)-\(horizontal)"
    }

    private func edgeZone(_ point: CGPoint) -> NavCarryZone {
        guard let host else { return .open }
        let bounds = host.bounds()
        let size = host.shownSize(morph)
        let reach = settings.edgeZone
        let isLeft = point.x - size.width / 2 <= reach
        let isRight = point.x + size.width / 2 >= bounds.width - reach
        let isTop = point.y - size.height / 2 <= reach
        let isBottom = point.y + size.height / 2 >= bounds.height - reach
        let isAtSide = isLeft || isRight
        let isAtEnd = isTop || isBottom
        guard isAtSide || isAtEnd else { return .open }
        let orientation: NavOrientation = isAtSide && isAtEnd ? host.orientation() : isAtSide ? .vertical : .horizontal
        let sideEdge: NavEdge = point.x < bounds.width / 2 ? .left : .right
        let endEdge: NavEdge = point.y < bounds.height / 2 ? .top : .bottom
        if orientation == .vertical {
            let edge: NavEdge = isLeft && isRight ? sideEdge : isLeft ? .left : isRight ? .right : sideEdge
            return .edge(edge, orientation)
        }
        let edge: NavEdge = isTop && isBottom ? endEdge : isTop ? .top : isBottom ? .bottom : endEdge
        return .edge(edge, orientation)
    }

    private func carriedZone() -> NavCarryZone {
        if let name = cornerAt(finger) {
            return .corner(name)
        }
        return edgeZone(center ?? finger)
    }

    private func nearestEdge(_ point: CGPoint) -> NavEdge {
        guard let host else { return .bottom }
        let bounds = host.bounds()
        let distances: [(NavEdge, CGFloat)] = [(.top, point.y), (.bottom, bounds.height - point.y), (.left, point.x), (.right, bounds.width - point.x)]
        return distances.min { $0.1 < $1.1 }?.0 ?? .bottom
    }

    private func throwWith(_ released: CGVector) {
        phase += 1
        state = .thrown
        let speed = hypot(released.dx, released.dy)
        let limit = settings.throwVelocityLimit
        let share = speed > limit ? limit / speed : 1
        velocity = CGVector(dx: released.dx * share, dy: released.dy * share)
        morphTarget = 1
        lastWall = nil
        run()
    }

    private func park(_ name: String) {
        guard let host else { return }
        phase += 1
        state = .parking
        corner = name
        isHolding = false
        target = host.cornerSpot(name)
        morphTarget = 1
        run()
    }

    private func dock(_ edge: NavEdge?) {
        guard let host, let current = center else { return }
        phase += 1
        let dockPhase = phase
        state = .docking
        corner = nil
        target = current
        isHolding = true
        let time = Self.now()
        if let edge, edge.orientation != host.orientation() {
            turnUntil = max(turnUntil, time + host.turnTo(edge.orientation, morph >= 0.5))
        }
        let travel = { [weak self] in
            guard let self, dockPhase == self.phase, let host = self.host, let from = self.center else { return }
            self.isHolding = false
            self.target = host.dockSpot(edge, from)
            self.morphTarget = 0
            self.run()
        }
        let wait = turnUntil - time
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait / 1000, execute: travel)
        } else {
            travel()
        }
        run()
    }

    private func run() {
        guard displayLink == nil else { return }
        lastFrame = Self.now()
        let link = CADisplayLink(target: NavCarryTicker(self), selector: #selector(NavCarryTicker.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func frame() {
        let time = Self.now()
        var remaining = min(0.05, (time - lastFrame) / 1000)
        lastFrame = time
        while remaining > 0, isActive {
            let step = min(remaining, Self.substep)
            advance(step, time)
            remaining -= step
        }
        let speed = hypot(velocity.dx, velocity.dy)
        stretchAmount = isActive ? min(settings.stretchLimit, speed * settings.stretchPerVelocity) * Self.share(morph) : 0
        stretchAngle = atan2(velocity.dy, velocity.dx)
        if !isActive {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func advance(_ step: Double, _ time: Double) {
        switch state {
        case .carried: advanceCarried(step, time)
        case .thrown: advanceThrown(step)
        default: advanceSettling(step)
        }
        morphVelocity += Self.force(morph, morphVelocity, morphTarget, Motion.morphSpring) * step
        morph += morphVelocity * step
    }

    private func advanceCarried(_ step: Double, _ time: Double) {
        guard let host else { return }
        let zone = carriedZone()
        switch zone {
        case .corner: morphTarget = 1
        case .edge(_, let orientation):
            morphTarget = 0
            if orientation != host.orientation() {
                turnUntil = max(turnUntil, time + host.turnTo(orientation, morph >= 0.5))
            }
        case .open: morphTarget = freeMorph()
        }
        let offsetShare = Self.share(1 - morph)
        let wanted = CGPoint(x: finger.x - grabOffset.width * offsetShare, y: finger.y - grabOffset.height * offsetShare)
        target = host.clamped(wanted, host.shownSize(morph))
        followVelocity.dx += Self.force(follow.x, followVelocity.dx, target.x, Motion.bubbleFollowSpring) * step
        followVelocity.dy += Self.force(follow.y, followVelocity.dy, target.y, Motion.bubbleFollowSpring) * step
        follow.x += followVelocity.dx * step
        follow.y += followVelocity.dy * step
        let lag = Self.share(morph)
        center = CGPoint(x: target.x + (follow.x - target.x) * lag, y: target.y + (follow.y - target.y) * lag)
        velocity = followVelocity
    }

    private func advanceThrown(_ step: Double) {
        guard let host, var point = center else { return }
        let keep = pow(settings.throwDecay, step * 1000)
        velocity = CGVector(dx: velocity.dx * keep, dy: velocity.dy * keep)
        point.x += velocity.dx * step
        point.y += velocity.dy * step
        let bounds = host.bounds()
        let size = host.shownSize(morph)
        let margin = NavMetrics.edgeMargin
        let lowX = margin + size.width / 2
        let highX = bounds.width - margin - size.width / 2
        let lowY = margin + size.height / 2
        let highY = bounds.height - margin - size.height / 2
        if point.x < lowX || point.x > highX {
            let isLow = point.x < lowX
            point.x = isLow ? lowX : highX
            let into = velocity.dx
            velocity.dx = 0
            center = point
            if let name = cornerAt(CGPoint(x: isLow ? 0 : bounds.width, y: point.y)) {
                park(name)
                return
            }
            velocity.dx = -into * settings.bounce
            lastWall = isLow ? .left : .right
        }
        if point.y < lowY || point.y > highY {
            let isLow = point.y < lowY
            point.y = isLow ? lowY : highY
            let into = velocity.dy
            velocity.dy = 0
            center = point
            if let name = cornerAt(CGPoint(x: point.x, y: isLow ? 0 : bounds.height)) {
                park(name)
                return
            }
            velocity.dy = -into * settings.bounce
            lastWall = isLow ? .top : .bottom
        }
        center = point
        if hypot(velocity.dx, velocity.dy) < settings.restVelocity {
            if let name = cornerAt(point) {
                park(name)
            } else {
                dock(lastWall ?? nearestEdge(point))
            }
        }
    }

    private func advanceSettling(_ step: Double) {
        guard var point = center else { return }
        let goal = isHolding ? point : target
        velocity.dx += Self.force(point.x, velocity.dx, goal.x, Motion.dockSpring) * step
        velocity.dy += Self.force(point.y, velocity.dy, goal.y, Motion.dockSpring) * step
        point.x += velocity.dx * step
        point.y += velocity.dy * step
        center = point
        guard !isHolding else { return }
        let isResting = hypot(point.x - goal.x, point.y - goal.y) < 0.5
            && hypot(velocity.dx, velocity.dy) < 8
            && abs(morph - morphTarget) < 0.005
            && abs(morphVelocity) < 0.05
        guard isResting else { return }
        center = goal
        velocity = .zero
        morph = morphTarget
        morphVelocity = 0
        let isParked = state == .parking
        state = isParked ? .parked : .idle
        host?.onLand(isParked ? corner : nil)
    }
}

private final class NavCarryTicker: NSObject {
    weak var carry: NavCarry?

    init(_ carry: NavCarry) {
        self.carry = carry
    }

    @MainActor @objc func tick() {
        carry?.frame()
    }
}
