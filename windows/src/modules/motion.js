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
