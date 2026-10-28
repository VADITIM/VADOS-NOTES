import { create, pressable } from "./components.js"
import { animate, duration } from "./motion.js"
import { hideTurned, popTogether, revealElement, springAnimate, switchOut } from "./pill.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { componentsToHex, hexComponents, tokens } from "./tokens.js"

export const navMetrics = {
    edgeMargin: 16,
    bottomGap: 24,
    besideGap: 10,
    avoidGap: 12,
    padding: 5,
    spacing: 2,
    glyphSize: 22,
    gripLength: 18,
    sizingSlop: 6,
    navSizingSlop: 22,
    navSizingDominance: 2,
    shadowReach: 32,
    edgeStripDepth: 28,
    edgeHandle: [36, 4],
    pillPanelPrefix: "variations-",
    swatchPitch: 34,
    sliderKnob: 34,
}

export function itemSize(orientation) {
    return orientation === "horizontal" ? [56, 48] : [48, 52]
}

export const separatorExtent = 9

export function separator(orientation) {
    return create("span", `nav-separator is-${orientation}`)
}

export class KeyedList {
    constructor(container, { make, update, isRevealed = () => true }) {
        this.container = container
        this.make = make
        this.updateElement = update
        this.isRevealed = isRevealed
        this.elements = new Map()
    }

    sync(entries, { isSwitch = true } = {}) {
        const wanted = new Set(entries.map((entry) => entry.key))
        for (const [key, element] of this.elements) {
            if (!wanted.has(key)) {
                this.elements.delete(key)
                leaveInPlace(element)
            }
        }
        let previous = null
        for (const entry of entries) {
            let element = this.elements.get(entry.key)
            if (!element) {
                element = this.make(entry)
                element.dataset.key = entry.key
                this.elements.set(entry.key, element)
                this.place(element, previous)
                if (this.isRevealed()) {
                    revealElement(element, true, isSwitch)
                } else {
                    element.dataset.turned = "out"
                    hideTurned(element)
                }
            } else {
                this.updateElement?.(element, entry)
                if (element.previousElementSibling !== previous && !(previous === null && element === firstInFlow(this.container))) {
                    this.place(element, previous)
                }
            }
            previous = element
        }
    }

    place(element, previous) {
        if (previous) {
            previous.after(element)
        } else {
            const first = firstInFlow(this.container)
            if (first) {
                first.before(element)
            } else {
                this.container.append(element)
            }
        }
    }

    reveal(shown, isSwitch = false) {
        for (const element of this.elements.values()) {
            element.style.opacity = ""
            revealElement(element, shown, isSwitch)
        }
    }
}

function firstInFlow(container) {
    return [...container.children].find((child) => !child.classList.contains("is-leaving") && child.dataset.key !== undefined) ?? null
}

export function leaveInPlace(element) {
    const parent = element.offsetParent
    if (parent) {
        element.style.position = "absolute"
        element.style.left = `${element.offsetLeft}px`
        element.style.top = `${element.offsetTop}px`
    }
    element.classList.add("is-leaving")
    element.style.pointerEvents = "none"
    switchOut(element).finished.then(() => element.remove(), () => element.remove())
}

export class SelectionRing {
    constructor(container, className, springName = "selection") {
        this.container = container
        this.ring = create("span", className)
        this.ring.style.opacity = "0"
        container.append(this.ring)
        this.springName = springName
        this.target = null
    }

    moveTo(target, isAnimated = true) {
        if (!target) {
            this.ring.style.opacity = "0"
            this.target = null
            return
        }
        const before = this.target ? { left: this.ring.offsetLeft, top: this.ring.offsetTop } : null
        const left = target.offsetLeft + target.offsetWidth / 2 - this.ring.offsetWidth / 2
        const top = target.offsetTop + (target.ringCentreY ?? target.offsetHeight / 2) - this.ring.offsetHeight / 2
        this.ring.style.left = `${left}px`
        this.ring.style.top = `${top}px`
        this.ring.style.opacity = "1"
        this.target = target
        if (before && isAnimated && (Math.abs(before.left - left) > 0.5 || Math.abs(before.top - top) > 0.5)) {
            springAnimate(this.ring, [{ translate: `${before.left - left}px ${before.top - top}px` }, { translate: "0px 0px" }], this.springName)
        }
    }
}

export function swatchButton({ color, diameter = 26, isSizePreset = false, caption = null, orientation, onSelect, onRemove }) {
    const button = create("button", `swatch-button is-${orientation}`)
    const well = create("span", "swatch-well")
    const dot = create("span", isSizePreset ? "swatch-size" : "swatch-dot")
    const armedRing = create("span", "swatch-armed")
    const cross = create("span", "swatch-cross", glyph("close", { color: tokens.semantic.destructive, size: 14 }))
    well.append(armedRing, dot, cross)
    button.append(well)
    const label = caption === null ? null : create("span", "swatch-caption")
    if (label) {
        button.append(label)
    }
    let isArmed = false
    let armTimer = null
    button.ringCentreY = navMetrics.swatchPitch / 2
    button.update = ({ color: nextColor = color, diameter: nextDiameter = diameter, isSelected = false, caption: nextCaption = caption }) => {
        dot.style.background = nextColor
        if (isSizePreset) {
            dot.style.width = `${nextDiameter}px`
            dot.style.height = `${nextDiameter}px`
        }
        button.classList.toggle("is-selected", isSelected)
        if (label) {
            label.textContent = nextCaption
        }
    }
    const setArmed = (armed) => {
        isArmed = armed
        button.classList.toggle("is-armed", armed)
        if (armed) {
            animate(cross, [{ transform: "scale(0.001)", opacity: 0 }, { transform: "scale(1)", opacity: 1 }], { milliseconds: duration("state"), curveName: "back_out" })
        }
    }
    pressable(button)
    let holdTimer = null
    let isConsumed = false
    button.addEventListener("pointerdown", (event) => {
        if (event.button !== 0 || !onRemove) {
            return
        }
        holdTimer = setTimeout(() => {
            isConsumed = true
            setArmed(true)
            clearTimeout(armTimer)
            armTimer = setTimeout(() => setArmed(false), 2400)
        }, duration("menu_hold"))
    })
    for (const name of ["pointerup", "pointercancel", "pointerleave"]) {
        button.addEventListener(name, () => clearTimeout(holdTimer))
    }
    button.addEventListener("contextmenu", (event) => {
        event.preventDefault()
        if (onRemove) {
            setArmed(true)
            clearTimeout(armTimer)
            armTimer = setTimeout(() => setArmed(false), 2400)
        }
    })
    button.addEventListener("click", () => {
        if (isConsumed) {
            isConsumed = false
            return
        }
        if (isArmed) {
            setArmed(false)
            onRemove?.()
        } else {
            onSelect()
        }
    })
    button.update({ color, diameter, isSelected: false, caption })
    return button
}

export function navIconButton({ glyphName, tint = tokens.palette.text_body, orientation, action }) {
    const [width, height] = itemSize(orientation)
    const button = create("button", "nav-icon-button")
    button.style.width = `${width}px`
    button.style.height = `${height}px`
    const icon = glyph(glyphName, { size: navMetrics.glyphSize })
    button.append(icon)
    button.update = ({ isSelected = false, isEnabled = true }) => {
        button.classList.toggle("is-selected", isSelected)
        icon.style.color = isSelected ? tint : tokens.palette.text_body
        button.disabled = !isEnabled
        button.classList.toggle("is-disabled", !isEnabled)
    }
    pressable(button)
    button.addEventListener("click", () => {
        if (!button.disabled) {
            action()
        }
    })
    button.update({})
    return button
}

export function captionButton({ caption, action }) {
    const button = create("button", "caption-button", create("span", "caption-button-text", caption))
    button.update = ({ isSelected = false }) => button.classList.toggle("is-selected", isSelected)
    pressable(button)
    button.addEventListener("click", action)
    return button
}

export function wheelButton({ orientation, action }) {
    const button = create("button", `wheel-button is-${orientation}`, create("span", "wheel-dot"))
    button.update = ({ isOpen = false }) => button.classList.toggle("is-open", isOpen)
    pressable(button)
    button.addEventListener("click", action)
    return button
}

function clamp01(value) {
    return Math.min(1, Math.max(0, value))
}

export function sizeSlider({ orientation = "horizontal", share, previewDiameter = 0, previewColor = "transparent", length = 148, onChange }) {
    const isVertical = orientation === "vertical"
    const knob = 26
    const thickness = 48
    const travel = length - knob
    const slider = create("div", `size-slider is-${orientation}`)
    slider.style.width = `${isVertical ? thickness : length}px`
    slider.style.height = `${isVertical ? length : thickness}px`
    const track = create("span", "size-slider-track")
    const fill = create("span", "size-slider-fill")
    track.append(fill)
    const knobElement = create("span", "size-slider-knob")
    const preview = create("span", "size-slider-preview")
    knobElement.append(preview)
    slider.append(track, knobElement)
    let current = share
    const render = () => {
        if (isVertical) {
            track.style.height = `${travel}px`
            fill.style.height = `${travel * current}px`
            knobElement.style.bottom = `${travel * current}px`
        } else {
            track.style.width = `${travel}px`
            fill.style.width = `${travel * current}px`
            knobElement.style.left = `${travel * current}px`
        }
        preview.style.width = `${previewDiameter}px`
        preview.style.height = `${previewDiameter}px`
        preview.style.background = previewColor
    }
    slider.update = ({ share: nextShare = current, previewDiameter: nextDiameter = previewDiameter, previewColor: nextColor = previewColor }) => {
        current = nextShare
        previewDiameter = nextDiameter
        previewColor = nextColor
        render()
    }
    let dragStart = null
    slider.addEventListener("pointerdown", (event) => {
        slider.setPointerCapture(event.pointerId)
        dragStart = { share: current, x: event.clientX, y: event.clientY }
        slider.classList.add("is-held")
        event.stopPropagation()
    })
    slider.addEventListener("pointermove", (event) => {
        if (!dragStart) {
            return
        }
        const delta = isVertical ? dragStart.y - event.clientY : event.clientX - dragStart.x
        current = clamp01(dragStart.share + delta / travel)
        render()
        onChange(current)
    })
    const end = () => {
        dragStart = null
        slider.classList.remove("is-held")
    }
    slider.addEventListener("pointerup", end)
    slider.addEventListener("pointercancel", end)
    render()
    return slider
}

export function navSizeSlider(orientation) {
    const isVertical = orientation === "vertical"
    const slider = create("div", `nav-size-slider is-${orientation}`)
    const track = create("span", "nav-size-track")
    const fill = create("span", "nav-size-fill")
    track.append(fill)
    const knob = create("span", "nav-size-knob")
    const preview = create("span", "nav-size-preview")
    const caption = create("span", "nav-size-caption")
    knob.append(preview, caption)
    slider.append(track, knob)
    slider.update = ({ share, color, diameter, text }) => {
        const length = isVertical ? slider.clientHeight : slider.clientWidth
        const travel = Math.max(1, length - navMetrics.sliderKnob)
        if (isVertical) {
            track.style.height = `${travel}px`
            fill.style.height = `${travel * share}px`
            knob.style.bottom = `${travel * share}px`
        } else {
            track.style.width = `${travel}px`
            fill.style.width = `${travel * share}px`
            knob.style.left = `${travel * share}px`
        }
        preview.style.background = color
        preview.style.width = `${diameter}px`
        preview.style.height = `${diameter}px`
        caption.textContent = text
    }
    return slider
}

export function hsvFromHex(hex) {
    const { red, green, blue } = hexComponents(hex)
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

export function hexFromHsv({ hue, saturation, value }) {
    const chroma = value * saturation
    const sector = (hue / 60) % 6
    const second = chroma * (1 - Math.abs((sector % 2) - 1))
    const base = value - chroma
    let rgb
    if (sector < 1) {
        rgb = [chroma, second, 0]
    } else if (sector < 2) {
        rgb = [second, chroma, 0]
    } else if (sector < 3) {
        rgb = [0, chroma, second]
    } else if (sector < 4) {
        rgb = [0, second, chroma]
    } else if (sector < 5) {
        rgb = [second, 0, chroma]
    } else {
        rgb = [chroma, 0, second]
    }
    return componentsToHex({ red: rgb[0] + base, green: rgb[1] + base, blue: rgb[2] + base, alpha: 1 })
}

const variationCount = 3
const saturationStep = 0.22
const valueStep = 0.05
const neutralValueStep = 0.18
const neutralSaturation = 0.08
const variationRange = [0.06, 1]
const stepOrder = [-1, 1, -2, 2, -3, 3, -4, 4]

export function colorVariations(hex) {
    const base = hsvFromHex(hex)
    const isNeutral = base.saturation < neutralSaturation
    const isInside = (value) => value >= variationRange[0] && value <= variationRange[1]
    const steps = stepOrder.filter((step) => (isNeutral ? isInside(base.value + step * neutralValueStep) : isInside(base.saturation + step * saturationStep)))
    const chosen = [...steps.slice(0, variationCount), 0].sort((first, second) => first - second)
    return chosen.map((step) => {
        if (step === 0) {
            return hex.toUpperCase()
        }
        const variation = { ...base }
        if (isNeutral) {
            variation.value = base.value + step * neutralValueStep
        } else {
            variation.saturation = base.saturation + step * saturationStep
            variation.value = Math.min(variationRange[1], Math.max(variationRange[0], base.value + step * valueStep))
        }
        return hexFromHsv(variation).toUpperCase()
    })
}

export function colorPanel({ color, onChange }) {
    const wheelSize = 184
    const panel = create("div", "color-panel")
    squircle(panel, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    const heading = create("span", "micro-label", "COLOUR")
    const wheel = create("div", "color-wheel")
    wheel.style.width = `${wheelSize}px`
    wheel.style.height = `${wheelSize}px`
    const hues = create("span", "color-wheel-hues")
    const whites = create("span", "color-wheel-whites")
    const marker = create("span", "color-wheel-marker")
    wheel.append(hues, whites, marker)
    let hsv = hsvFromHex(color)
    let isDragging = false
    const swatch = create("span", "color-panel-swatch")
    const hexInput = create("input", "color-panel-hex")
    hexInput.spellcheck = false
    hexInput.maxLength = 7
    const hexWrapper = create("div", "color-panel-hex-wrapper", hexInput)
    squircle(hexWrapper, { radius: squircleRadius.slot, fill: tokens.palette.sunken_deep, border: tokens.palette.border_control })
    const valueSlider = sizeSlider({ share: hsv.value, length: wheelSize, onChange: (share) => {
        hsv = { ...hsv, value: share }
        emit()
    } })
    const render = () => {
        const stops = []
        for (let degrees = 0; degrees <= 360; degrees += 30) {
            stops.push(hexFromHsv({ hue: degrees % 360, saturation: 1, value: hsv.value }))
        }
        hues.style.background = `conic-gradient(from 90deg, ${stops.join(", ")})`
        const grey = hexFromHsv({ hue: 0, saturation: 0, value: hsv.value })
        whites.style.background = `radial-gradient(circle closest-side, ${grey}, ${grey}00)`
        const radians = (hsv.hue * Math.PI) / 180
        marker.style.left = `${wheelSize / 2 + Math.cos(radians) * hsv.saturation * (wheelSize / 2)}px`
        marker.style.top = `${wheelSize / 2 + Math.sin(radians) * hsv.saturation * (wheelSize / 2)}px`
        marker.style.background = hexFromHsv(hsv)
        swatch.style.background = hexFromHsv(hsv)
        valueSlider.update({ share: hsv.value })
    }
    const emit = () => {
        const hex = hexFromHsv(hsv)
        if (document.activeElement !== hexInput) {
            hexInput.value = hex
        }
        render()
        onChange(hex)
    }
    const pick = (event) => {
        const rect = wheel.getBoundingClientRect()
        const x = event.clientX - rect.left - wheelSize / 2
        const y = event.clientY - rect.top - wheelSize / 2
        hsv = { ...hsv, hue: ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360, saturation: Math.min(1, Math.hypot(x, y) / (wheelSize / 2)) }
        if (hsv.value < 0.05) {
            hsv.value = 1
        }
        emit()
    }
    wheel.addEventListener("pointerdown", (event) => {
        wheel.setPointerCapture(event.pointerId)
        isDragging = true
        pick(event)
        event.stopPropagation()
    })
    wheel.addEventListener("pointermove", (event) => {
        if (isDragging) {
            pick(event)
        }
    })
    wheel.addEventListener("pointerup", () => {
        isDragging = false
    })
    hexInput.addEventListener("input", () => {
        let candidate = hexInput.value.trim().toUpperCase()
        if (!candidate.startsWith("#")) {
            candidate = `#${candidate}`
        }
        if (/^#[0-9A-F]{6}$/.test(candidate)) {
            hsv = hsvFromHex(candidate)
            render()
            onChange(candidate)
        }
    })
    hexInput.addEventListener("keydown", (event) => event.stopPropagation())
    panel.append(heading, wheel, valueSlider, create("div", "color-panel-row", swatch, hexWrapper))
    panel.update = ({ color: next }) => {
        if (isDragging || document.activeElement === hexInput || next.toUpperCase() === hexFromHsv(hsv)) {
            return
        }
        hsv = hsvFromHex(next)
        hexInput.value = next.toUpperCase()
        render()
    }
    hexInput.value = color.toUpperCase()
    render()
    return panel
}

export function variationPanel({ orientation, onPick }) {
    const panel = create("div", `variation-panel is-${orientation}`)
    const ring = new SelectionRing(panel, "selection-ring")
    const mark = create("span", `variation-mark is-${orientation}`)
    panel.append(mark)
    const swatches = []
    panel.update = ({ colors, main, selected, display }) => {
        while (swatches.length < colors.length) {
            const index = swatches.length
            const swatch = swatchButton({ color: "#000000", orientation, onSelect: () => onPick(panel.colors[index]) })
            panel.append(swatch)
            swatches.push(swatch)
        }
        panel.colors = colors
        let selectedSwatch = null
        let mainSwatch = null
        colors.forEach((color, index) => {
            const swatch = swatches[index]
            const previous = swatch.dataset.color
            swatch.update({ color: display(color), isSelected: color === selected.toUpperCase() })
            if (previous && previous !== color) {
                springAnimate(swatch.querySelector(".swatch-dot"), [{ background: display(previous) }, { background: display(color) }], "placement")
            }
            swatch.dataset.color = color
            if (color === selected.toUpperCase()) {
                selectedSwatch = swatch
            }
            if (color === main.toUpperCase()) {
                mainSwatch = swatch
            }
        })
        requestAnimationFrame(() => {
            ring.moveTo(selectedSwatch)
            placeMark(mark, mainSwatch, orientation)
        })
    }
    panel.revealTargets = () => [...swatches, mark]
    return panel
}

function placeMark(mark, swatch, orientation) {
    if (!swatch) {
        mark.style.opacity = "0"
        return
    }
    const before = mark.dataset.placed === "true" ? { left: mark.offsetLeft, top: mark.offsetTop } : null
    let left
    let top
    if (orientation === "horizontal") {
        left = swatch.offsetLeft + swatch.offsetWidth / 2 - 6
        top = swatch.offsetTop + swatch.offsetHeight + 1 - 2
    } else {
        left = swatch.offsetLeft + swatch.offsetWidth + 1 - 2
        top = swatch.offsetTop + swatch.offsetHeight / 2 - 6
    }
    mark.style.left = `${left}px`
    mark.style.top = `${top}px`
    mark.style.opacity = ""
    mark.dataset.placed = "true"
    if (before && (before.left !== left || before.top !== top)) {
        springAnimate(mark, [{ translate: `${before.left - left}px ${before.top - top}px` }, { translate: "0px 0px" }], "placement")
    }
}

export function popPanel(element, isShown) {
    return popTogether(element, isShown)
}
