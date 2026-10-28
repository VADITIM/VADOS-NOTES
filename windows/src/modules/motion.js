import { tokens } from "./tokens.js"

export function curve(name) {
    return `cubic-bezier(${tokens.motion.curves[name].join(", ")})`
}

export function duration(name) {
    return tokens.motion.durations[name]
}

export function applyDesignVariables(root) {
    for (const [name, value] of Object.entries(tokens.palette)) {
        root.style.setProperty(`--palette-${name.replaceAll("_", "-")}`, value)
    }
    for (const [name, value] of Object.entries(tokens.semantic)) {
        root.style.setProperty(`--semantic-${name.replaceAll("_", "-")}`, value)
    }
    root.style.setProperty("--page-outside", tokens.page.outside)
    for (const name of Object.keys(tokens.motion.curves)) {
        root.style.setProperty(`--curve-${name.replaceAll("_", "-")}`, curve(name))
    }
    for (const [name, value] of Object.entries(tokens.motion.durations)) {
        root.style.setProperty(`--duration-${name.replaceAll("_", "-")}`, `${value}ms`)
    }
}

export function animate(element, keyframes, { milliseconds, curveName, delay = 0, fill = "backwards" }) {
    return element.animate(keyframes, { duration: milliseconds, easing: curve(curveName), delay, fill })
}

export function sectionEnter(element) {
    animate(element, [{ opacity: 0, transform: "scale(0.96)" }, { opacity: 1, transform: "scale(1)" }], {
        milliseconds: duration("section_enter"),
        curveName: "power_two_out",
        delay: duration("section_enter_delay"),
    })
}

export function sectionLeave(element) {
    return animate(element, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("section_leave"), curveName: "power_two_in", fill: "forwards" }).finished
}

export function overlayEnter(element) {
    animate(element, [{ opacity: 0, transform: "translateY(24px) scale(0.94)" }, { opacity: 1, transform: "translateY(0) scale(1)" }], {
        milliseconds: duration("overlay_enter"),
        curveName: "back_out",
    })
}

export function overlayLeave(element) {
    return animate(element, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.96)" }], {
        milliseconds: duration("overlay_leave"),
        curveName: "power_two_in",
        fill: "forwards",
    }).finished
}

export function fadeIn(element, milliseconds = duration("overlay_enter")) {
    animate(element, [{ opacity: 0 }, { opacity: 1 }], { milliseconds, curveName: "power_two_out" })
}

export function fadeOut(element, milliseconds = duration("overlay_leave")) {
    return animate(element, [{ opacity: 1 }, { opacity: 0 }], { milliseconds, curveName: "power_two_in", fill: "forwards" }).finished
}

export function popIn(element) {
    animate(element, [{ opacity: 0, transform: "scale(0.001)" }, { opacity: 1, transform: "scale(1)" }], {
        milliseconds: duration("state"),
        curveName: "back_out",
        delay: duration("state"),
    })
}

export function tileAppear(element, rank) {
    animate(element, [{ opacity: 0, transform: "translateY(14px) scale(0.94)" }, { opacity: 1, transform: "translateY(0) scale(1)" }], {
        milliseconds: 240,
        curveName: "power_two_out",
        delay: Math.min(rank, 16) * 12,
    })
}

const curveFunctions = new Map()

function bezierAxis(first, second, share) {
    const inverse = 1 - share
    return 3 * inverse * inverse * share * first + 3 * inverse * share * share * second + share * share * share
}

export function curveAt(name) {
    const cached = curveFunctions.get(name)
    if (cached) {
        return cached
    }
    const [firstX, firstY, secondX, secondY] = tokens.motion.curves[name]
    const evaluate = (progress) => {
        if (progress <= 0) {
            return 0
        }
        if (progress >= 1) {
            return 1
        }
        let low = 0
        let high = 1
        let share = progress
        for (let iteration = 0; iteration < 24; iteration += 1) {
            const x = bezierAxis(firstX, secondX, share)
            if (Math.abs(x - progress) < 0.0005) {
                break
            }
            if (x < progress) {
                low = share
            } else {
                high = share
            }
            share = (low + high) / 2
        }
        return bezierAxis(firstY, secondY, share)
    }
    curveFunctions.set(name, evaluate)
    return evaluate
}

export function tween({ milliseconds, curveName, onFrame, onDone }) {
    const curveFunction = curveAt(curveName)
    const start = performance.now()
    let request = null
    let isStopped = false
    const frame = (now) => {
        if (isStopped) {
            return
        }
        const progress = milliseconds <= 0 ? 1 : Math.min(1, (now - start) / milliseconds)
        onFrame(curveFunction(progress), progress)
        if (progress < 1) {
            request = requestAnimationFrame(frame)
        } else {
            onDone?.()
        }
    }
    request = requestAnimationFrame(frame)
    return {
        stop() {
            isStopped = true
            cancelAnimationFrame(request)
        },
    }
}

export function popOut(element, milliseconds = duration("state")) {
    return animate(element, [{ transform: "scale(1)", opacity: 1 }, { transform: "scale(0.001)", opacity: 0 }], {
        milliseconds,
        curveName: "back_in",
        fill: "forwards",
    })
}

export function popInNow(element, delay = 0) {
    return animate(element, [{ transform: "scale(0.001)", opacity: 0 }, { transform: "scale(1)", opacity: 1 }], {
        milliseconds: duration("state"),
        curveName: "back_out",
        delay,
        fill: "backwards",
    })
}
