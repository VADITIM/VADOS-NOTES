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
    @Published private(set) var placement: NavPlacement?
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
    private var dockEdge: NavEdge = .bottom
    private var dockFrom = CGPoint.zero
    private var phase = 0
    private var turnUntil: Double = 0
    private var displayLink: CADisplayLink?
    private var lastFrame: Double = 0

    private static let substep: Double = 1.0 / 240

    private var settings: Tokens.CarryTokens { Motion.carry }

    init(placement: NavPlacement?) {
        self.placement = placement
    }

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

    func place(_ next: NavPlacement) {
        placement = next
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
        case .open: dock(nearestEdge(center ?? finger))
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

    private func edgeAt(_ point: CGPoint, share: CGFloat) -> NavEdge? {
        guard let host else { return nil }
        let bounds = host.bounds()
        let width = max(1, bounds.width)
        let height = max(1, bounds.height)
        let distances: [(NavEdge, CGFloat)] = [(.left, point.x / width), (.right, (bounds.width - point.x) / width), (.top, point.y / height), (.bottom, (bounds.height - point.y) / height)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= share else { return nil }
        return nearest.0
    }

    private func carriedZone() -> NavCarryZone {
        if let name = cornerAt(finger) {
            return .corner(name)
        }
        guard let edge = edgeAt(finger, share: CGFloat(settings.edgeShare)) else { return .open }
        return .edge(edge, edge.orientation)
    }

    private func wallAhead(_ point: CGPoint, _ heading: CGVector) -> (edge: NavEdge, point: CGPoint)? {
        guard let host else { return nil }
        let bounds = host.bounds()
        var arrivals: [(NavEdge, CGFloat)] = []
        if heading.dx < 0 {
            arrivals.append((.left, -point.x / heading.dx))
        } else if heading.dx > 0 {
            arrivals.append((.right, (bounds.width - point.x) / heading.dx))
        }
        if heading.dy < 0 {
            arrivals.append((.top, -point.y / heading.dy))
        } else if heading.dy > 0 {
            arrivals.append((.bottom, (bounds.height - point.y) / heading.dy))
        }
        guard let first = arrivals.min(by: { $0.1 < $1.1 }) else { return nil }
        return (first.0, CGPoint(x: point.x + heading.dx * first.1, y: point.y + heading.dy * first.1))
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

    private func dock(_ edge: NavEdge) {
        guard let host, let current = center else { return }
        phase += 1
        let dockPhase = phase
        state = .docking
        corner = nil
        dockEdge = edge
        dockFrom = current
        target = current
        isHolding = true
        let speed = hypot(velocity.dx, velocity.dy)
        let limit = CGFloat(settings.dockVelocity)
        if speed > limit {
            velocity = CGVector(dx: velocity.dx * limit / speed, dy: velocity.dy * limit / speed)
        }
        let time = Self.now()
        if edge.orientation != host.orientation() {
            turnUntil = max(turnUntil, time + host.turnTo(edge.orientation, morph >= 0.5))
        }
        let travel = { [weak self] in
            guard let self, dockPhase == self.phase, let host = self.host, let from = self.center else { return }
            self.isHolding = false
            self.dockFrom = from
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
        if state == .docking, !isHolding, let host {
            target = host.dockSpot(dockEdge, dockFrom)
        }
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
        morphVelocity += Self.force(morph, morphVelocity, morphTarget, morphTarget == 0 ? Motion.unfoldSpring : Motion.morphSpring) * step
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
        let from = CGFloat(settings.fingerCentreFrom)
        let centring = Self.share((morph - from) / (1 - from))
        let offsetShare = 1 - centring * centring * (3 - 2 * centring)
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
        }
        center = point
        let speed = hypot(velocity.dx, velocity.dy)
        let ahead = speed < CGFloat(settings.restVelocity) ? nil : wallAhead(point, velocity)
        let zoneEdge = edgeAt(point, share: CGFloat(settings.throwEdgeShare))
        let isHeadingIn = ahead.map { $0.edge == zoneEdge && cornerAt($0.point) == nil } ?? false
        guard isHeadingIn || speed < CGFloat(settings.dockVelocity) else { return }
        if let name = cornerAt(point) {
            park(name)
            return
        }
        dock(zoneEdge ?? ahead?.edge ?? nearestEdge(point))
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
        host?.onLand(isParked ? corner : nil)
        state = isParked ? .parked : .idle
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
