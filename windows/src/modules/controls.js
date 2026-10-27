import { create, microLabel } from "./components.js"
import { duration } from "./motion.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { componentsToHex, hexComponents, tokens } from "./tokens.js"

const sliderLength = 148
const wheelSize = 184
const wheelStepShare = 0.05
const swatchArmMilliseconds = 2400

function clampShare(value) {
    return Math.min(1, Math.max(0, value))
}

export function sizeSlider({ orientation, share, onChange }) {
    const isVertical = orientation === "vertical"
    const fill = create("span", "size-slider-fill")
    const track = create("span", "size-slider-track", fill)
    const dot = create("span", "size-slider-dot")
    const knob = create("span", "size-slider-knob", dot)
    const element = create("div", `size-slider${isVertical ? " is-vertical" : ""}`, track, knob)
    element.setAttribute("role", "slider")
    let current = clampShare(share)
    let drag = null
    const paint = () => {
        const travel = sliderLength - 26
        if (isVertical) {
            fill.style.height = `${current * 100}%`
            knob.style.top = `${(1 - current) * travel}px`
        } else {
            fill.style.width = `${current * 100}%`
            knob.style.left = `${current * travel}px`
        }
        element.setAttribute("aria-valuenow", String(Math.round(current * 100)))
    }
    const shareAt = (event) => {
        const rect = element.getBoundingClientRect()
        const travel = sliderLength - 26
        return isVertical ? clampShare(1 - (event.clientY - rect.top - 13) / travel) : clampShare((event.clientX - rect.left - 13) / travel)
    }
    const commit = (next) => {
        const clamped = clampShare(next)
        if (clamped === current) {
            return
        }
        current = clamped
        paint()
        onChange(current)
    }
    element.addEventListener("pointerdown", (event) => {
        event.stopPropagation()
        element.setPointerCapture(event.pointerId)
        element.classList.add("is-held")
        if (!knob.contains(event.target)) {
            commit(shareAt(event))
        }
        drag = { pointerId: event.pointerId, start: isVertical ? event.clientY : event.clientX, share: current }
    })
    element.addEventListener("pointermove", (event) => {
        if (!drag || event.pointerId !== drag.pointerId) {
            return
        }
        const travel = sliderLength - 26
        const delta = ((isVertical ? event.clientY : event.clientX) - drag.start) / travel
        commit(drag.share + (isVertical ? -delta : delta))
    })
    const release = (event) => {
        if (drag && event.pointerId === drag.pointerId) {
            drag = null
            element.classList.remove("is-held")
        }
    }
    element.addEventListener("pointerup", release)
    element.addEventListener("pointercancel", release)
    element.addEventListener("wheel", (event) => {
        event.preventDefault()
        event.stopPropagation()
        commit(current + (event.deltaY < 0 || event.deltaX > 0 ? wheelStepShare : -wheelStepShare))
    }, { passive: false })
    element.setShare = (next) => {
        if (!drag) {
            current = clampShare(next)
            paint()
        }
    }
    element.setPreview = ({ diameter, color }) => {
        dot.style.width = `${diameter}px`
        dot.style.height = `${diameter}px`
        dot.style.background = color
    }
    paint()
    return element
}

export function swatchButton({ color, label, onSelect, onRemove }) {
    const dot = create("span", "swatch-dot")
    const cross = create("span", "swatch-cross", glyph("close", { size: 14, color: tokens.semantic.destructive }))
    const button = create("button", "swatch-button pressable", dot, cross)
    button.type = "button"
    button.setAttribute("aria-label", label)
    let holdTimer = null
    let disarmTimer = null
    let isHoldConsumingClick = false
    const disarm = () => {
        clearTimeout(disarmTimer)
        button.classList.remove("is-armed")
    }
    button.addEventListener("pointerdown", (event) => {
        event.stopPropagation()
        if (!onRemove) {
            return
        }
        clearTimeout(holdTimer)
        holdTimer = setTimeout(() => {
            isHoldConsumingClick = true
            button.classList.add("is-armed")
            clearTimeout(disarmTimer)
            disarmTimer = setTimeout(disarm, swatchArmMilliseconds)
        }, duration("menu_hold"))
    })
    const cancelHold = () => clearTimeout(holdTimer)
    button.addEventListener("pointerup", cancelHold)
    button.addEventListener("pointerleave", cancelHold)
    button.addEventListener("pointercancel", cancelHold)
    button.addEventListener("contextmenu", (event) => {
        event.preventDefault()
        if (onRemove) {
            button.classList.add("is-armed")
            clearTimeout(disarmTimer)
            disarmTimer = setTimeout(disarm, swatchArmMilliseconds)
        }
    })
    button.addEventListener("click", (event) => {
        event.stopPropagation()
        if (isHoldConsumingClick) {
            isHoldConsumingClick = false
            return
        }
        if (button.classList.contains("is-armed")) {
            disarm()
            onRemove()
            return
        }
        onSelect()
    })
    button.setState = ({ color: nextColor, isSelected }) => {
        dot.style.background = nextColor
        button.classList.toggle("is-selected", isSelected)
    }
    button.setState({ color, isSelected: false })
    return button
}

export function iconButton({ glyphName, label, onPress }) {
    const button = create("button", "tool-nav-button pressable", create("span", "tool-nav-glyph", glyph(glyphName)))
    button.type = "button"
    button.setAttribute("aria-label", label)
    button.addEventListener("pointerdown", (event) => event.stopPropagation())
    button.addEventListener("click", (event) => {
        event.stopPropagation()
        if (!button.disabled) {
            onPress(button)
        }
    })
    button.setEnabled = (isEnabled) => {
        button.disabled = !isEnabled
        button.classList.toggle("is-disabled", !isEnabled)
    }
    button.setTint = (color) => {
        button.querySelector(".tool-nav-glyph").style.color = color
    }
    return button
}

export function wheelButton({ label, onPress }) {
    const button = create("button", "swatch-button wheel-button pressable", create("span", "swatch-dot wheel-dot"))
    button.type = "button"
    button.setAttribute("aria-label", label)
    button.addEventListener("pointerdown", (event) => event.stopPropagation())
    button.addEventListener("click", (event) => {
        event.stopPropagation()
        onPress(button)
    })
    return button
}

function hsvToComponents(hue, saturation, value) {
    const chroma = value * saturation
    const sector = (hue / 60) % 6
    const second = chroma * (1 - Math.abs((sector % 2) - 1))
    const base = value - chroma
    const [red, green, blue] = sector < 1 ? [chroma, second, 0]
        : sector < 2 ? [second, chroma, 0]
            : sector < 3 ? [0, chroma, second]
                : sector < 4 ? [0, second, chroma]
                    : sector < 5 ? [second, 0, chroma]
                        : [chroma, 0, second]
    return { red: red + base, green: green + base, blue: blue + base, alpha: 1 }
}

function componentsToHsv({ red, green, blue }) {
    const maximum = Math.max(red, green, blue)
    const minimum = Math.min(red, green, blue)
    const chroma = maximum - minimum
    let hue = 0
    if (chroma > 0) {
        if (maximum === red) {
            hue = 60 * (((green - blue) / chroma) % 6)
        } else if (maximum === green) {
            hue = 60 * ((blue - red) / chroma + 2)
        } else {
            hue = 60 * ((red - green) / chroma + 4)
        }
    }
    return { hue: (hue + 360) % 360, saturation: maximum === 0 ? 0 : chroma / maximum, value: maximum }
}

export function colorPanel({ color, onChange }) {
    const canvas = create("canvas", "color-wheel")
    const marker = create("span", "color-wheel-marker")
    const wheel = create("div", "color-wheel-frame", canvas, marker)
    const valueSlider = sizeSlider({ orientation: "horizontal", share: 1, onChange: (share) => {
        hsv.value = share
        drawWheel()
        emit()
    } })
    valueSlider.classList.add("color-value-slider")
    const preview = create("span", "color-preview")
    const input = create("input", "field-input color-hex-input")
    input.spellcheck = false
    input.autocomplete = "off"
    input.maxLength = 7
    const hexField = create("label", "field color-hex-field", input)
    squircle(hexField, { radius: squircleRadius.slot, fill: tokens.palette.sunken_deep, border: tokens.palette.border_control })
    const row = create("div", "color-hex-row", preview, hexField)
    const element = create("div", "color-panel", microLabel("Colour"), wheel, valueSlider, row)
    squircle(element, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    element.addEventListener("pointerdown", (event) => event.stopPropagation())
    let hsv = componentsToHsv(hexComponents(color))
    const pixelRatio = window.devicePixelRatio || 1
    canvas.width = wheelSize * pixelRatio
    canvas.height = wheelSize * pixelRatio
    let drawnValue = null

    function currentHex() {
        return componentsToHex(hsvToComponents(hsv.hue, hsv.saturation, hsv.value))
    }

    function drawWheel() {
        if (drawnValue === hsv.value) {
            return
        }
        drawnValue = hsv.value
        const context = canvas.getContext("2d")
        const size = canvas.width
        const image = context.createImageData(size, size)
        const radius = size / 2
        for (let y = 0; y < size; y += 1) {
            for (let x = 0; x < size; x += 1) {
                const offsetX = x - radius
                const offsetY = y - radius
                const distance = Math.hypot(offsetX, offsetY)
                const index = (y * size + x) * 4
                if (distance > radius) {
                    image.data[index + 3] = 0
                    continue
                }
                const hue = (Math.atan2(offsetY, offsetX) * 180 / Math.PI + 360) % 360
                const components = hsvToComponents(hue, distance / radius, hsv.value)
                image.data[index] = components.red * 255
                image.data[index + 1] = components.green * 255
                image.data[index + 2] = components.blue * 255
                image.data[index + 3] = Math.min(1, radius - distance) * 255
            }
        }
        context.putImageData(image, 0, 0)
    }

    function paint() {
        const radius = wheelSize / 2
        const angle = hsv.hue * Math.PI / 180
        marker.style.left = `${radius + Math.cos(angle) * hsv.saturation * radius}px`
        marker.style.top = `${radius + Math.sin(angle) * hsv.saturation * radius}px`
        const hex = currentHex()
        marker.style.background = hex
        preview.style.background = hex
        valueSlider.setShare(hsv.value)
        valueSlider.style.setProperty("--slider-gradient", `linear-gradient(90deg, #000, ${componentsToHex(hsvToComponents(hsv.hue, hsv.saturation, 1))})`)
        if (document.activeElement !== input) {
            input.value = hex
        }
    }

    function emit() {
        paint()
        onChange(currentHex())
    }

    let wheelDrag = null
    const pick = (event) => {
        const rect = canvas.getBoundingClientRect()
        const offsetX = event.clientX - rect.left - rect.width / 2
        const offsetY = event.clientY - rect.top - rect.height / 2
        hsv.hue = (Math.atan2(offsetY, offsetX) * 180 / Math.PI + 360) % 360
        hsv.saturation = Math.min(1, Math.hypot(offsetX, offsetY) / (rect.width / 2))
        if (hsv.value < 0.05) {
            hsv.value = 1
            drawWheel()
        }
        emit()
    }
    wheel.addEventListener("pointerdown", (event) => {
        wheel.setPointerCapture(event.pointerId)
        wheelDrag = event.pointerId
        pick(event)
    })
    wheel.addEventListener("pointermove", (event) => {
        if (wheelDrag === event.pointerId) {
            pick(event)
        }
    })
    const release = (event) => {
        if (wheelDrag === event.pointerId) {
            wheelDrag = null
        }
    }
    wheel.addEventListener("pointerup", release)
    wheel.addEventListener("pointercancel", release)
    input.addEventListener("input", () => {
        let text = input.value.trim().toUpperCase()
        if (!text.startsWith("#")) {
            text = `#${text}`
        }
        if (/^#[0-9A-F]{6}$/.test(text)) {
            hsv = componentsToHsv(hexComponents(text))
            drawWheel()
            paint()
            onChange(text)
        }
    })
    input.addEventListener("keydown", (event) => {
        event.stopPropagation()
        if (event.key === "Enter") {
            input.blur()
        }
    })
    input.addEventListener("blur", paint)
    element.setColor = (hex) => {
        if (wheelDrag !== null || document.activeElement === input) {
            return
        }
        if (hex.toUpperCase() === currentHex()) {
            return
        }
        hsv = componentsToHsv(hexComponents(hex))
        drawWheel()
        paint()
    }
    drawWheel()
    paint()
    return element
}
