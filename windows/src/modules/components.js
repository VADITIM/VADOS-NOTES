import { animate, duration } from "./motion.js"
import { turnIn, turnOut } from "./pill.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { tokens, withAlpha } from "./tokens.js"

export function create(tag, className, ...children) {
    const element = document.createElement(tag)
    if (className) {
        element.className = className
    }
    element.append(...children.filter((child) => child !== null && child !== undefined && child !== false))
    return element
}

export function microLabel(text, color) {
    const label = create("span", "micro-label", text.toUpperCase())
    if (color) {
        label.style.color = color
    }
    return label
}

function scaleTo(element, value, milliseconds, curveName) {
    const from = getComputedStyle(element).scale
    const start = from === "none" ? "1" : from
    element.getAnimations().filter((running) => running.id === "press").forEach((running) => running.cancel())
    const running = animate(element, [{ scale: start }, { scale: String(value) }], { milliseconds, curveName, fill: "forwards" })
    running.id = "press"
    return running
}

function linearScaleTo(element, value, milliseconds) {
    const from = getComputedStyle(element).scale
    element.getAnimations().filter((running) => running.id === "press").forEach((running) => running.cancel())
    const running = element.animate([{ scale: from === "none" ? "1" : from }, { scale: String(value) }], { duration: milliseconds, easing: "linear", fill: "forwards" })
    running.id = "press"
}

export function pressable(element, { isHoldable = false, target = element } = {}) {
    let holdTimer = null
    const release = () => {
        clearTimeout(holdTimer)
        scaleTo(target, 1, duration("release"), "back_out")
    }
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0 || element.disabled) {
            return
        }
        if (isHoldable) {
            linearScaleTo(target, tokens.motion.scales.hold_grow, duration("menu_hold"))
            holdTimer = setTimeout(() => scaleTo(target, tokens.motion.scales.hold_pop, duration("state"), "back_out"), duration("menu_hold"))
        } else {
            scaleTo(target, tokens.motion.scales.press_pop, duration("press"), "power_two_out")
        }
    })
    for (const name of ["pointerup", "pointercancel", "pointerleave"]) {
        element.addEventListener(name, release)
    }
    return element
}

export function holdable(element, { action, onHold, onTapAt, isHoldable = Boolean(onHold) }) {
    pressable(element, { isHoldable })
    let holdTimer = null
    let start = null
    let isConsumed = false
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0 || !onHold) {
            return
        }
        start = [event.clientX, event.clientY]
        clearTimeout(holdTimer)
        holdTimer = setTimeout(() => {
            isConsumed = true
            onHold(element.getBoundingClientRect(), start)
            setTimeout(() => {
                isConsumed = false
            }, 800)
        }, duration("menu_hold"))
    })
    element.addEventListener("pointermove", (event) => {
        if (start && Math.hypot(event.clientX - start[0], event.clientY - start[1]) > 10) {
            clearTimeout(holdTimer)
        }
    })
    for (const name of ["pointerup", "pointercancel"]) {
        element.addEventListener(name, () => {
            clearTimeout(holdTimer)
            start = null
        })
    }
    element.addEventListener("click", (event) => {
        if (isConsumed) {
            isConsumed = false
            return
        }
        if (onTapAt) {
            onTapAt(element.getBoundingClientRect(), event)
        } else {
            action?.(event)
        }
    })
    if (onHold) {
        element.addEventListener("contextmenu", (event) => {
            event.preventDefault()
            onHold(element.getBoundingClientRect(), [event.clientX, event.clientY])
        })
    }
    return element
}

export function roundIconButton({ glyphName, label, color = tokens.palette.text_body, isTinted = false, action }) {
    const button = create("button", "round-icon-button", glyph(glyphName, { color }))
    button.setAttribute("aria-label", label)
    if (isTinted) {
        button.style.background = withAlpha(color, 0.14)
        button.style.borderColor = withAlpha(color, 0.55)
    }
    return holdable(button, { action })
}

export function slabButton(title, color, action) {
    const button = create("button", "slab-button", title.toUpperCase())
    button.style.setProperty("--slab-color", color)
    squircle(button, { radius: squircleRadius.slot, fill: color })
    pressable(button)
    button.addEventListener("click", () => {
        if (!button.disabled) {
            action()
        }
    })
    return button
}

export function setEnabled(element, isEnabled) {
    element.disabled = !isEnabled
    element.classList.toggle("is-disabled", !isEnabled)
}

export function field({ placeholder, value = "", isSecret = false }) {
    const input = create("input", "field")
    input.type = isSecret ? "password" : "text"
    input.placeholder = placeholder
    input.value = value
    input.spellcheck = false
    input.autocomplete = "off"
    const wrapper = create("div", "field-wrapper", input)
    squircle(wrapper, { radius: squircleRadius.slot, fill: tokens.palette.sunken_deep, border: tokens.palette.border_control })
    wrapper.input = input
    return wrapper
}

export function segmented(options, selected, onPick) {
    const control = create("div", "segmented")
    const wash = create("span", "segmented-wash")
    control.append(wash)
    const buttons = options.map((option) => {
        const button = create("button", "segmented-option", option.title.toUpperCase())
        pressable(button)
        button.addEventListener("click", () => {
            control.select(option.value, true)
            onPick(option.value)
        })
        control.append(button)
        return { option, button }
    })
    control.select = (value, isAnimated) => {
        for (const { option, button } of buttons) {
            button.classList.toggle("is-selected", option.value === value)
        }
        const index = buttons.findIndex(({ option }) => option.value === value)
        const from = wash.style.left
        wash.style.left = `calc(4px + (100% - 8px) * ${index} / ${buttons.length})`
        wash.style.width = `calc((100% - 8px) / ${buttons.length})`
        wash.style.opacity = index < 0 ? "0" : "1"
        if (isAnimated && from && from !== wash.style.left) {
            animate(wash, [{ left: from }, { left: wash.style.left }], { milliseconds: tokens.motion.durations.nav_slide, curveName: "power_two_out" })
        }
    }
    control.select(selected, false)
    return control
}

export function linkButton({ glyphName, title, tint = tokens.palette.text_body, isOn = false, isEnabled = true, action }) {
    const button = create("button", "link-button")
    const icon = glyph(glyphName, { size: 24 })
    const label = create("span", "link-button-title", title.toUpperCase())
    button.append(icon, label)
    const ring = create("span", "link-button-ring")
    button.append(ring)
    button.update = ({ title: nextTitle = title, isOn: nextOn = isOn, isEnabled: nextEnabled = isEnabled } = {}) => {
        label.textContent = nextTitle.toUpperCase()
        icon.style.color = nextOn ? tint : tokens.palette.text_muted
        label.style.color = nextOn ? tint : tokens.palette.text_body
        squircle(button, { radius: 20, fill: nextOn ? withAlpha(tint, 0.16) : tokens.palette.sunken, border: tokens.palette.border })
        ring.style.borderColor = tint
        ring.style.opacity = nextOn ? "1" : "0"
        setEnabled(button, nextEnabled)
    }
    button.update()
    pressable(button)
    button.addEventListener("click", () => {
        if (!button.disabled) {
            action()
        }
    })
    return button
}

export function sweepTitle(text, { size = 34, isSweeping = true } = {}) {
    const title = create("span", "sweep-title")
    title.style.fontSize = `${size}px`
    const words = create("span", "sweep-text")
    const bar = create("span", "sweep-bar")
    title.append(words, bar)
    title.setText = (next) => {
        const upper = next.toUpperCase()
        if (words.textContent === upper && title.dataset.ready === "true") {
            return
        }
        words.textContent = upper
        title.dataset.ready = "true"
        if (!isSweeping) {
            words.style.opacity = "1"
            return
        }
        title.sweepStep = (title.sweepStep ?? 0) + 1
        const step = title.sweepStep
        words.style.opacity = "0"
        bar.style.transformOrigin = "left center"
        animate(bar, [{ transform: "scaleX(0)" }, { transform: "scaleX(1)" }], { milliseconds: duration("sweep_grow"), curveName: "power_three_in_out", fill: "forwards" })
        setTimeout(() => {
            if (step !== title.sweepStep) {
                return
            }
            words.style.opacity = "1"
            bar.style.transformOrigin = "right center"
            animate(bar, [{ transform: "scaleX(1)" }, { transform: "scaleX(0)" }], { milliseconds: duration("sweep_retract"), curveName: "power_three_in_out", fill: "forwards" })
        }, duration("sweep_grow"))
    }
    title.setText(text)
    return title
}

export function inlineTitle({ title, size = 34, isSweeping = true, onRename }) {
    const host = create("span", "inline-title")
    const shown = sweepTitle(title, { size, isSweeping })
    const input = create("input", "inline-title-field")
    input.style.fontSize = `${size}px`
    input.spellcheck = false
    input.hidden = true
    host.append(shown, input)
    let current = title
    const measure = () => {
        input.style.width = `${Math.max(2, input.value.length + 1)}ch`
    }
    shown.addEventListener("click", () => {
        input.value = current
        shown.hidden = true
        input.hidden = false
        measure()
        input.focus()
        input.select()
    })
    input.addEventListener("input", () => {
        measure()
        onRename(input.value)
    })
    input.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === "Escape") {
            input.blur()
        }
        event.stopPropagation()
    })
    input.addEventListener("blur", () => {
        input.hidden = true
        shown.hidden = false
    })
    host.setTitle = (next) => {
        current = next
        if (input.hidden) {
            shown.setText(next)
        }
    }
    host.isEditing = () => !input.hidden
    return host
}

export function revealLabel(content, className = "") {
    const element = create("span", `label-reveal ${className}`)
    const text = create("span", "reveal-text")
    text.append(content)
    element.append(text)
    element.text = text
    return element
}

export function popIn(element) {
    return turnIn(element)
}

export function popOut(element) {
    return turnOut(element)
}
