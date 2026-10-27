import { animate, duration } from "./motion.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { tokens } from "./tokens.js"

const holdTolerance = 10
const tapConsumptionWindowMilliseconds = 800

export function create(tag, className, ...children) {
    const element = document.createElement(tag)
    if (className) {
        element.className = className
    }
    element.append(...children.filter((child) => child !== null && child !== undefined && child !== false))
    return element
}

export function microLabel(text, color) {
    const label = create("span", "micro-label", text)
    if (color) {
        label.style.color = color
    }
    return label
}

export function sweepTitle(text) {
    const title = create("div", "sweep-title")
    const words = create("span", "sweep-title-text")
    const bar = create("span", "sweep-title-bar")
    title.append(words, bar)
    let current = null
    title.setText = (next) => {
        if (next === current) {
            return
        }
        current = next
        words.textContent = next
        words.style.opacity = "0"
        bar.style.transformOrigin = "left center"
        const grow = animate(bar, [{ transform: "scaleX(0)" }, { transform: "scaleX(1)" }], {
            milliseconds: duration("sweep_grow"),
            curveName: "power_three_in_out",
            fill: "forwards",
        })
        grow.finished.then(() => {
            if (current !== next) {
                return
            }
            words.style.opacity = "1"
            bar.style.transformOrigin = "right center"
            animate(bar, [{ transform: "scaleX(1)" }, { transform: "scaleX(0)" }], {
                milliseconds: duration("sweep_retract"),
                curveName: "power_three_in_out",
                fill: "forwards",
            })
        }).catch(() => {})
    }
    title.setText(text)
    return title
}

export function holdable(element, { action, onHold, onTapAt }) {
    let holdTimer = null
    let start = null
    let isHoldConsumingTap = false
    const rect = () => element.getBoundingClientRect()
    const cancel = () => {
        clearTimeout(holdTimer)
        holdTimer = null
    }
    const fireHold = () => {
        isHoldConsumingTap = true
        onHold(rect())
        setTimeout(() => {
            isHoldConsumingTap = false
        }, tapConsumptionWindowMilliseconds)
    }
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0 || !onHold) {
            return
        }
        start = [event.clientX, event.clientY]
        cancel()
        holdTimer = setTimeout(() => {
            holdTimer = null
            fireHold()
        }, duration("menu_hold"))
    })
    element.addEventListener("pointermove", (event) => {
        if (holdTimer && start && Math.hypot(event.clientX - start[0], event.clientY - start[1]) > holdTolerance) {
            cancel()
        }
    })
    element.addEventListener("pointerup", cancel)
    element.addEventListener("pointercancel", cancel)
    element.addEventListener("pointerleave", cancel)
    element.addEventListener("contextmenu", (event) => {
        event.preventDefault()
        if (onHold) {
            cancel()
            onHold(rect())
        }
    })
    element.addEventListener("click", (event) => {
        if (isHoldConsumingTap) {
            isHoldConsumingTap = false
            return
        }
        if (element.disabled) {
            return
        }
        event.stopPropagation()
        if (onTapAt) {
            onTapAt(rect())
        } else {
            action?.()
        }
    })
    return element
}

export function backButton(onBack) {
    const button = create("button", "back-button pressable", glyph("back", { color: tokens.semantic.navigation }))
    button.type = "button"
    button.setAttribute("aria-label", "Back")
    return holdable(button, { action: onBack })
}

export function topBar({ title, label, onBack, onTitle, trailing = [], below = [] }) {
    const labelElement = label === undefined ? null : microLabel(label)
    const titleElement = sweepTitle(title)
    const trailingElement = create("div", "top-bar-trailing", ...trailing)
    const titles = create("div", "top-bar-titles", labelElement, titleElement)
    if (onTitle) {
        titles.classList.add("is-editable", "pressable-soft")
        titles.setAttribute("role", "button")
        titles.title = "Rename"
        titles.addEventListener("click", onTitle)
    }
    const back = onBack ? backButton(onBack) : null
    const bar = create(
        "header",
        `top-bar${below.length ? " has-below" : ""}`,
        below.length ? create("div", "top-bar-stack", create("div", "top-bar-lead", back, titles), create("div", "top-bar-below", ...below)) : back,
        below.length ? null : titles,
        trailingElement,
    )
    bar.backButton = back
    bar.update = ({ title: nextTitle, label: nextLabel, trailing: nextTrailing }) => {
        if (nextTitle !== undefined) {
            titleElement.setText(nextTitle)
        }
        if (nextLabel !== undefined && labelElement) {
            labelElement.textContent = nextLabel
        }
        if (nextTrailing) {
            trailingElement.replaceChildren(...nextTrailing)
        }
    }
    return bar
}

export function settingsButton(onOpen) {
    const button = create("button", "round-button pressable", glyph("settings", { color: tokens.palette.text_body }))
    button.type = "button"
    button.setAttribute("aria-label", "Settings")
    button.title = "Settings"
    return holdable(button, { action: onOpen })
}

export function roundIconButton({ glyphName, label, color = tokens.palette.text_body, action }) {
    const button = create("button", "round-button pressable", glyph(glyphName, { color }))
    button.style.setProperty("--button-tint", color)
    button.type = "button"
    button.setAttribute("aria-label", label)
    button.title = label
    button.setEnabled = (isEnabled) => {
        button.disabled = !isEnabled
        button.classList.toggle("is-disabled", !isEnabled)
    }
    return holdable(button, { action })
}

export function searchField({ placeholder, onChange }) {
    const input = create("input", "search-input")
    input.type = "search"
    input.placeholder = placeholder
    input.spellcheck = false
    input.autocomplete = "off"
    const clear = create("button", "search-clear pressable", glyph("close", { size: 16, color: tokens.palette.text_muted }))
    clear.type = "button"
    clear.setAttribute("aria-label", "Clear search")
    const wrapper = create("label", "search-field", glyph("search", { size: 18, color: tokens.palette.text_muted }), input, clear)
    const changed = () => {
        wrapper.classList.toggle("has-query", input.value.length > 0)
        onChange(input.value)
    }
    input.addEventListener("input", changed)
    input.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && input.value) {
            event.stopPropagation()
            input.value = ""
            changed()
        }
    })
    clear.addEventListener("click", (event) => {
        event.preventDefault()
        input.value = ""
        changed()
        input.focus()
    })
    wrapper.input = input
    return wrapper
}

export function slabButton(title, color, action) {
    const button = create("button", "slab-button pressable", create("span", "slab-button-title", title))
    button.type = "button"
    squircle(button, { radius: squircleRadius.slot, fill: color })
    button.addEventListener("click", () => {
        if (!button.disabled) {
            action()
        }
    })
    button.setEnabled = (isEnabled) => {
        button.disabled = !isEnabled
        button.classList.toggle("is-disabled", !isEnabled)
    }
    return button
}

export function field({ placeholder, value = "", isSecret = false }) {
    const input = create("input", "field-input")
    input.type = isSecret ? "password" : "text"
    input.placeholder = placeholder
    input.value = value
    input.spellcheck = false
    input.autocomplete = "off"
    const wrapper = create("label", "field", input)
    squircle(wrapper, { radius: squircleRadius.slot, fill: tokens.palette.sunken_deep, border: tokens.palette.border_control })
    wrapper.input = input
    return wrapper
}
