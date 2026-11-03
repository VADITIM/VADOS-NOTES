import { tokens } from "./tokens.js"

const substep = 1 / 240

function settings() {
    return tokens.motion.carry
}

function clampShare(value) {
    return Math.min(1, Math.max(0, value))
}

function springForce(value, velocity, target, name) {
    const { response, damping_fraction: damping } = tokens.motion.springs[name]
    const stiffness = Math.pow((2 * Math.PI) / response, 2)
    const friction = (4 * Math.PI * damping) / response
    return -stiffness * (value - target) - friction * velocity
}

export function edgeOrientation(edge) {
    return edge === "left" || edge === "right" ? "vertical" : "horizontal"
}

export class NavigationCarry {
    constructor(host) {
        this.host = host
        this.state = "idle"
        this.center = null
        this.velocity = [0, 0]
        this.follow = null
        this.followVelocity = [0, 0]
        this.target = null
        this.morph = 0
        this.morphVelocity = 0
        this.morphTarget = 0
        this.stretch = { amount: 0, angle: 0 }
        this.samples = []
        this.request = null
        this.phase = 0
        this.turnUntil = 0
        this.isHolding = false
        this.corner = null
        this.lastWall = null
    }

    get isActive() {
        return this.state !== "idle" && this.state !== "parked"
    }

    get isStageCleared() {
        return this.state !== "idle"
    }

    restore(corner) {
        if (!corner) {
            return
        }
        this.state = "parked"
        this.corner = corner
        this.morph = 1
        this.morphTarget = 1
    }

    grab(finger, center, now) {
        this.phase += 1
        this.isHolding = false
        this.center = [...center]
        this.follow = [...center]
        this.followVelocity = this.isActive ? [...this.velocity] : [0, 0]
        this.velocity = [...this.followVelocity]
        this.state = "carried"
        this.start = [...finger]
        this.finger = [...finger]
        this.grabOffset = [finger[0] - center[0], finger[1] - center[1]]
        this.isLatched = this.morph >= 0.5
        this.samples = [{ point: [...finger], time: now }]
        this.lastWall = null
        this.corner = null
        this.run()
    }

    drag(finger, now) {
        if (this.state !== "carried") {
            return
        }
        this.finger = [...finger]
        this.samples.push({ point: [...finger], time: now })
        this.trimSamples(now)
        if (Math.hypot(...this.fingerVelocity()) >= settings().throw_velocity) {
            this.isLatched = true
        }
    }

    swapGrab() {
        if (this.grabOffset) {
            this.grabOffset = [this.grabOffset[1], this.grabOffset[0]]
        }
    }

    release(now) {
        if (this.state !== "carried") {
            return
        }
        this.trimSamples(now)
        const velocity = this.fingerVelocity()
        const zone = this.carriedZone()
        if (Math.hypot(...velocity) >= settings().throw_velocity || (zone.kind === "open" && this.freeMorph() >= 0.5)) {
            this.throwWith(velocity)
        } else if (zone.kind === "corner") {
            this.park(zone.corner)
        } else if (zone.kind === "edge") {
            this.dock(zone.edge)
        } else {
            this.dock(null)
        }
    }

    expand() {
        if (this.state !== "parked" && this.state !== "parking") {
            return
        }
        this.center = this.center ?? this.host.cornerSpot(this.corner)
        const corner = this.corner ?? "bottom-right"
        const [vertical, horizontal] = corner.split("-")
        const bounds = this.host.bounds()
        const verticalDistance = vertical === "top" ? this.center[1] : bounds.height - this.center[1]
        const horizontalDistance = horizontal === "left" ? this.center[0] : bounds.width - this.center[0]
        this.dock(verticalDistance <= horizontalDistance ? vertical : horizontal)
    }

    trimSamples(now) {
        const window = settings().velocity_window
        while (this.samples.length > 2 && now - this.samples[0].time > window) {
            this.samples.shift()
        }
        if (this.samples.length && now - this.samples[this.samples.length - 1].time > window) {
            this.samples = [this.samples[this.samples.length - 1]]
        }
    }

    fingerVelocity() {
        if (this.samples.length < 2) {
            return [0, 0]
        }
        const first = this.samples[0]
        const last = this.samples[this.samples.length - 1]
        const seconds = (last.time - first.time) / 1000
        if (seconds <= 0.004) {
            return [0, 0]
        }
        return [(last.point[0] - first.point[0]) / seconds, (last.point[1] - first.point[1]) / seconds]
    }

    freeMorph() {
        if (this.isLatched) {
            return 1
        }
        const { morph_start: start, morph_full: full } = settings()
        return clampShare((Math.hypot(this.finger[0] - this.start[0], this.finger[1] - this.start[1]) - start) / Math.max(1, full - start))
    }

    cornerAt(point) {
        const { width, height } = this.host.bounds()
        const reach = settings().corner_zone
        const vertical = point[1] < reach ? "top" : point[1] > height - reach ? "bottom" : null
        const horizontal = point[0] < reach ? "left" : point[0] > width - reach ? "right" : null
        return vertical && horizontal ? `${vertical}-${horizontal}` : null
    }

    edgeZone(center) {
        const { width, height } = this.host.bounds()
        const size = this.host.shownSize(this.morph)
        const reach = settings().edge_zone
        const isLeft = center[0] - size[0] / 2 <= reach
        const isRight = center[0] + size[0] / 2 >= width - reach
        const isTop = center[1] - size[1] / 2 <= reach
        const isBottom = center[1] + size[1] / 2 >= height - reach
        const isAtSide = isLeft || isRight
        const isAtEnd = isTop || isBottom
        if (!isAtSide && !isAtEnd) {
            return { kind: "open" }
        }
        const orientation = isAtSide && isAtEnd ? this.host.orientation() : isAtSide ? "vertical" : "horizontal"
        const sideEdge = center[0] < width / 2 ? "left" : "right"
        const endEdge = center[1] < height / 2 ? "top" : "bottom"
        if (orientation === "vertical") {
            return { kind: "edge", orientation, edge: isLeft && isRight ? sideEdge : isLeft ? "left" : isRight ? "right" : sideEdge }
        }
        return { kind: "edge", orientation, edge: isTop && isBottom ? endEdge : isTop ? "top" : isBottom ? "bottom" : endEdge }
    }

    carriedZone() {
        const corner = this.cornerAt(this.finger)
        if (corner) {
            return { kind: "corner", corner }
        }
        return this.edgeZone(this.center)
    }

    nearestEdge(center) {
        const { width, height } = this.host.bounds()
        const distances = [["top", center[1]], ["bottom", height - center[1]], ["left", center[0]], ["right", width - center[0]]]
        distances.sort((first, second) => first[1] - second[1])
        return distances[0][0]
    }

    throwWith(velocity) {
        this.phase += 1
        this.state = "thrown"
        const speed = Math.hypot(...velocity)
        const limit = settings().throw_velocity_limit
        const share = speed > limit ? limit / speed : 1
        this.velocity = [velocity[0] * share, velocity[1] * share]
        this.morphTarget = 1
        this.lastWall = null
        this.run()
    }

    park(corner) {
        this.phase += 1
        this.state = "parking"
        this.corner = corner
        this.isHolding = false
        this.target = this.host.cornerSpot(corner)
        this.morphTarget = 1
        this.run()
    }

    dock(edge) {
        this.phase += 1
        const phase = this.phase
        this.state = "docking"
        this.corner = null
        this.dockEdge = edge
        this.target = [...this.center]
        this.isHolding = true
        const now = performance.now()
        if (edge && edgeOrientation(edge) !== this.host.orientation()) {
            this.turnUntil = Math.max(this.turnUntil, now + this.host.turnTo(edgeOrientation(edge), this.morph >= 0.5))
        }
        const travel = () => {
            if (phase !== this.phase) {
                return
            }
            this.isHolding = false
            this.target = this.host.dockSpot(edge, this.center)
            this.morphTarget = 0
            this.run()
        }
        const wait = this.turnUntil - now
        if (wait > 0) {
            setTimeout(travel, wait)
        } else {
            travel()
        }
        this.run()
    }

    run() {
        if (this.request || this.isInFrame) {
            return
        }
        this.last = performance.now()
        this.request = requestAnimationFrame((now) => this.frame(now))
    }

    frame(now) {
        this.request = null
        this.isInFrame = true
        let remaining = Math.min(0.05, (now - this.last) / 1000)
        this.last = now
        while (remaining > 0 && this.isActive) {
            const step = Math.min(remaining, substep)
            this.advance(step, now)
            remaining -= step
        }
        this.paintStretch()
        this.isInFrame = false
        this.host.onFrame()
        if (this.isActive && !this.request) {
            this.request = requestAnimationFrame((time) => this.frame(time))
        }
    }

    advance(step, now) {
        if (this.state === "carried") {
            this.advanceCarried(step, now)
        } else if (this.state === "thrown") {
            this.advanceThrown(step)
        } else {
            this.advanceSettling(step)
        }
        this.morphVelocity += springForce(this.morph, this.morphVelocity, this.morphTarget, "morph") * step
        this.morph += this.morphVelocity * step
    }

    advanceCarried(step, now) {
        const zone = this.carriedZone()
        this.morphTarget = zone.kind === "corner" ? 1 : zone.kind === "edge" ? 0 : this.freeMorph()
        if (zone.kind === "edge" && zone.orientation !== this.host.orientation()) {
            this.turnUntil = Math.max(this.turnUntil, now + this.host.turnTo(zone.orientation, this.morph >= 0.5))
        }
        const offsetShare = clampShare(1 - this.morph)
        const wanted = [this.finger[0] - this.grabOffset[0] * offsetShare, this.finger[1] - this.grabOffset[1] * offsetShare]
        this.target = this.host.clamped(wanted, this.host.shownSize(this.morph))
        for (const axis of [0, 1]) {
            this.followVelocity[axis] += springForce(this.follow[axis], this.followVelocity[axis], this.target[axis], "bubble_follow") * step
            this.follow[axis] += this.followVelocity[axis] * step
        }
        const lag = clampShare(this.morph)
        this.center = [this.target[0] + (this.follow[0] - this.target[0]) * lag, this.target[1] + (this.follow[1] - this.target[1]) * lag]
        this.velocity = [...this.followVelocity]
    }

    advanceThrown(step) {
        const { throw_decay: decay, bounce, rest_velocity: rest, corner_zone: cornerReach } = settings()
        const keep = Math.pow(decay, step * 1000)
        this.velocity = [this.velocity[0] * keep, this.velocity[1] * keep]
        this.center = [this.center[0] + this.velocity[0] * step, this.center[1] + this.velocity[1] * step]
        const { width, height } = this.host.bounds()
        const size = this.host.shownSize(this.morph)
        const margin = this.host.edgeMargin()
        const walls = [
            { axis: 0, low: margin + size[0] / 2, high: width - margin - size[0] / 2, lowEdge: "left", highEdge: "right", across: 1, acrossTotal: height },
            { axis: 1, low: margin + size[1] / 2, high: height - margin - size[1] / 2, lowEdge: "top", highEdge: "bottom", across: 0, acrossTotal: width },
        ]
        for (const wall of walls) {
            const value = this.center[wall.axis]
            const velocityIntoWall = this.velocity[wall.axis]
            const isLow = value < wall.low
            const isHigh = value > wall.high
            if (!isLow && !isHigh) {
                continue
            }
            this.center[wall.axis] = isLow ? wall.low : wall.high
            this.velocity[wall.axis] = 0
            const acrossValue = this.center[wall.across]
            const isNearCorner = acrossValue < cornerReach || acrossValue > wall.acrossTotal - cornerReach
            if (isNearCorner) {
                const corner = this.cornerAt(wall.axis === 0
                    ? [isLow ? 0 : width, acrossValue]
                    : [acrossValue, isLow ? 0 : height])
                if (corner) {
                    this.park(corner)
                    return
                }
            }
            this.velocity[wall.axis] = -velocityIntoWall * bounce
            this.lastWall = isLow ? wall.lowEdge : wall.highEdge
        }
        if (Math.hypot(...this.velocity) < rest) {
            const corner = this.cornerAt(this.center)
            if (corner) {
                this.park(corner)
            } else {
                this.dock(this.lastWall ?? this.nearestEdge(this.center))
            }
        }
    }

    advanceSettling(step) {
        const target = this.isHolding ? this.center : this.target
        for (const axis of [0, 1]) {
            this.velocity[axis] += springForce(this.center[axis], this.velocity[axis], target[axis], "dock") * step
            this.center[axis] += this.velocity[axis] * step
        }
        if (this.isHolding) {
            return
        }
        const isResting = Math.hypot(this.center[0] - target[0], this.center[1] - target[1]) < 0.5
            && Math.hypot(...this.velocity) < 8
            && Math.abs(this.morph - this.morphTarget) < 0.005
            && Math.abs(this.morphVelocity) < 0.05
        if (!isResting) {
            return
        }
        this.center = [...target]
        this.velocity = [0, 0]
        this.morph = this.morphTarget
        this.morphVelocity = 0
        const isParked = this.state === "parking"
        this.state = isParked ? "parked" : "idle"
        this.host.onLand(isParked ? this.corner : null)
    }

    paintStretch() {
        const { stretch_per_velocity: perVelocity, stretch_limit: limit } = settings()
        const speed = Math.hypot(...this.velocity)
        this.stretch = {
            amount: this.isActive ? Math.min(limit, speed * perVelocity) * clampShare(this.morph) : 0,
            angle: Math.atan2(this.velocity[1], this.velocity[0]),
        }
    }
}
