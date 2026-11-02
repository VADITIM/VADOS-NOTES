import { animate, duration, tween } from "./motion.js"
import { tokens } from "./tokens.js"

const springCache = new Map()

export function spring(name) {
    const cached = springCache.get(name)
    if (cached) {
        return cached
    }
    const { response, damping_fraction: damping } = tokens.motion.springs[name]
    const stiffness = Math.pow((2 * Math.PI) / response, 2)
    const friction = (4 * Math.PI * damping) / response
    const step = 1 / 240
    const values = []
    let position = 0
    let velocity = 0
    let time = 0
    let restTime = 0
    while (time < 3) {
        values.push(position)
        const force = -stiffness * (position - 1) - friction * velocity
        velocity += force * step
        position += velocity * step
        time += step
        if (Math.abs(position - 1) < 0.001 && Math.abs(velocity) < 0.01) {
            restTime += step
            if (restTime > 0.03) {
                break
            }
        } else {
            restTime = 0
        }
    }
    values.push(1)
    const stride = Math.max(1, Math.floor(values.length / 80))
    const sampled = values.filter((value, index) => index % stride === 0 || index === values.length - 1)
    const result = { easing: `linear(${sampled.map((value) => value.toFixed(4)).join(", ")})`, milliseconds: Math.round(time * 1000) }
    springCache.set(name, result)
    return result
}

export function springAnimate(element, keyframes, name, fill = "none") {
    const { easing, milliseconds } = spring(name)
    return element.animate(keyframes, { duration: milliseconds, easing, fill })
}

export function glideFrom(element, fromRect, name = "placement") {
    if (!fromRect) {
        return null
    }
    const toRect = element.getBoundingClientRect()
    const deltaX = fromRect.left - toRect.left
    const deltaY = fromRect.top - toRect.top
    const scaleX = toRect.width > 0 ? fromRect.width / toRect.width : 1
    const scaleY = toRect.height > 0 ? fromRect.height / toRect.height : 1
    if (Math.abs(deltaX) < 0.5 && Math.abs(deltaY) < 0.5 && Math.abs(scaleX - 1) < 0.01 && Math.abs(scaleY - 1) < 0.01) {
        return null
    }
    return springAnimate(element, [
        { transformOrigin: "0 0", transform: `translate(${deltaX}px, ${deltaY}px) scale(${scaleX}, ${scaleY})` },
        { transformOrigin: "0 0", transform: "translate(0px, 0px) scale(1, 1)" },
    ], name)
}

function popFrames(element) {
    const depth = Math.max(60, Math.max(element.offsetWidth, element.offsetHeight) * 2)
    return [
        { transform: `perspective(${depth}px) rotateY(-90deg) scale(0.001)`, opacity: 0 },
        { transform: `perspective(${depth}px) rotateY(0deg) scale(1)`, opacity: 1 },
    ]
}

function cancelTurns(element) {
    element.getAnimations().filter((running) => running.id === "turn").forEach((running) => running.cancel())
}

export function turnIn(element, { milliseconds = duration("state"), delay = 0 } = {}) {
    cancelTurns(element)
    const running = animate(element, popFrames(element), { milliseconds, curveName: "power_two_out", delay, fill: "both" })
    running.id = "turn"
    element.dataset.turned = "in"
    return running
}

export function turnOut(element, { milliseconds = duration("navigation_leave_element"), delay = 0 } = {}) {
    cancelTurns(element)
    const running = animate(element, popFrames(element).reverse(), { milliseconds, curveName: "power_two_in", delay, fill: "both" })
    running.id = "turn"
    element.dataset.turned = "out"
    return running
}

export function hideTurned(element) {
    cancelTurns(element)
    const running = element.animate([{ opacity: 0, transform: "scale(0.001)" }], { duration: 0, fill: "forwards" })
    running.id = "turn"
    element.dataset.turned = "out"
}

export function randomUpTo(maximum) {
    return Math.floor(Math.random() * (maximum + 1))
}

export function revealElement(element, isShown, isSwitch = false) {
    if (isShown) {
        const enterDelay = randomUpTo(duration("navigation_element") / 2)
        if (isSwitch) {
            const spread = (enterDelay * duration("navigation_switch")) / 2 / Math.max(1, duration("navigation_element"))
            return turnIn(element, { milliseconds: duration("navigation_switch"), delay: duration("navigation_switch") / 2 + spread })
        }
        return turnIn(element, { milliseconds: duration("navigation_element"), delay: enterDelay })
    }
    return turnOut(element, { milliseconds: duration("navigation_leave_element"), delay: randomUpTo(duration("navigation_leave_element") / 2) })
}

export function switchOut(element) {
    return turnOut(element, { milliseconds: duration("navigation_switch") })
}

export function chromePop(element, isShown, order = 0) {
    if (isShown) {
        return turnIn(element, { milliseconds: duration("state"), delay: order * duration("chrome_stagger") })
    }
    return turnOut(element, { milliseconds: duration("navigation_leave_element") })
}

export function popTogether(element, isShown) {
    return isShown ? turnIn(element, { milliseconds: duration("state") }) : turnOut(element, { milliseconds: duration("state") })
}

export function popSwitchIn(element) {
    return turnIn(element, { milliseconds: duration("navigation_switch"), delay: duration("navigation_switch") / 2 })
}

export class PillMotion {
    constructor(onFrame) {
        this.onFrame = onFrame
        this.shellScale = 0
        this.shellSpread = 0
        this.areElementsShown = false
        this.isPresent = false
        this.step = 0
        this.tweens = []
        this.timers = []
        this.onElements = null
    }

    stopAll() {
        this.tweens.forEach((running) => running.stop())
        this.timers.forEach((timer) => clearTimeout(timer))
        this.tweens = []
        this.timers = []
    }

    after(milliseconds, change) {
        const current = this.step
        this.timers.push(setTimeout(() => {
            if (current === this.step) {
                change()
            }
        }, milliseconds))
    }

    animateValue(key, target, milliseconds, curveName, delay = 0) {
        this.after(delay, () => {
            const from = this[key]
            this.tweens.push(tween({
                milliseconds,
                curveName,
                onFrame: (eased) => {
                    this[key] = from + (target - from) * eased
                    this.onFrame()
                },
            }))
        })
    }

    setElements(shown) {
        if (this.areElementsShown === shown) {
            return
        }
        this.areElementsShown = shown
        this.onElements?.(shown)
        this.onFrame()
    }

    enter() {
        this.step += 1
        this.stopAll()
        const isMidLeave = this.isPresent && this.shellScale > 0
        if (!isMidLeave) {
            this.shellScale = 0
            this.shellSpread = 0
            this.areElementsShown = false
            this.isPresent = true
            this.onElements?.(false, true)
            this.onFrame()
        }
        this.animateValue("shellScale", 1, duration("navigation_pop"), "power_two_out")
        this.animateValue("shellSpread", 1, duration("navigation_spread"), "power_three_in_out", isMidLeave ? 0 : duration("navigation_spread_delay"))
        const enterMilliseconds = Math.max(duration("navigation_pop"), duration("navigation_spread_delay") + duration("navigation_spread") / 2)
        this.after(isMidLeave ? duration("navigation_spread") / 2 : enterMilliseconds, () => this.setElements(true))
    }

    leave(finish = () => {}) {
        if (!this.isPresent) {
            finish()
            return
        }
        this.step += 1
        this.stopAll()
        this.setElements(false)
        const elementsGone = duration("navigation_leave_element")
        const narrowed = elementsGone + (duration("navigation_leave_spread") * 3) / 4
        this.animateValue("shellSpread", 0, duration("navigation_leave_spread"), "power_three_in_out", elementsGone)
        this.animateValue("shellScale", 0, duration("navigation_leave_pop"), "power_two_in", narrowed)
        this.after(narrowed + duration("navigation_leave_pop"), () => {
            this.isPresent = false
            this.onFrame()
            finish()
        })
    }
}

export function shapePillShell(shell, { width, height, isWide, scale, spread }) {
    const thickness = isWide ? height : width
    const along = thickness + ((isWide ? width : height) - thickness) * spread
    const shellWidth = isWide ? along : thickness
    const shellHeight = isWide ? thickness : along
    shell.style.width = `${shellWidth}px`
    shell.style.height = `${shellHeight}px`
    shell.style.left = `${(width - shellWidth) / 2}px`
    shell.style.top = `${(height - shellHeight) / 2}px`
    shell.style.transform = `scale(${scale})`
}

export function labelReveal(element, isShown, { delay = 0, color = tokens.palette.accent } = {}) {
    let bar = element.querySelector(":scope > .reveal-bar")
    if (!bar) {
        bar = document.createElement("span")
        bar.className = "reveal-bar"
        element.append(bar)
    }
    bar.style.background = color
    element.revealStep = (element.revealStep ?? 0) + 1
    const step = element.revealStep
    const isTextShown = element.dataset.revealed === "true"
    const isBarOut = bar.dataset.out === "true"
    if (!isShown && !isTextShown && !isBarOut) {
        return
    }
    const grow = isShown ? duration("sweep_grow") : duration("navigation_leave_element")
    const retract = isShown ? duration("sweep_retract") : duration("navigation_leave_element")
    setTimeout(() => {
        if (step !== element.revealStep) {
            return
        }
        bar.dataset.out = "true"
        bar.style.transformOrigin = "left center"
        animate(bar, [{ transform: "scaleX(0)" }, { transform: "scaleX(1)" }], { milliseconds: grow, curveName: "power_three_in_out", fill: "forwards" })
        setTimeout(() => {
            if (step !== element.revealStep) {
                return
            }
            element.dataset.revealed = String(isShown)
            bar.dataset.out = "false"
            bar.style.transformOrigin = "right center"
            animate(bar, [{ transform: "scaleX(1)" }, { transform: "scaleX(0)" }], { milliseconds: retract, curveName: "power_three_in_out", fill: "forwards" })
        }, grow)
    }, isShown ? delay : 0)
}
