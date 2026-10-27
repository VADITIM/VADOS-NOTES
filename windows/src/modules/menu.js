import { create, microLabel } from "./components.js"
import { fadeIn, fadeOut, overlayEnter, overlayLeave } from "./motion.js"
import { squircle, squircleRadius } from "./shapes.js"
import { isLight, roleColor, tokens } from "./tokens.js"

const slotWidth = 132
const slotHeight = 64
const spacing = 6
const padding = 8
const titleHeight = 26
const screenMargin = 16
const fingerClearance = 28

export function slotsFromTokens(definitions, { title, isEnabled = () => true, perform }) {
    return definitions.map((definition) => ({
        position: definition.slot,
        title: title(definition.action),
        role: definition.role,
        isEnabled: isEnabled(definition.action),
        handler: () => perform(definition.action),
    }))
}

function panelSize(columns, rows, hasTitle) {
    return {
        width: padding * 2 + columns * slotWidth + (columns - 1) * spacing,
        height: padding * 2 + rows * slotHeight + (rows - 1) * spacing + (hasTitle ? titleHeight : 0),
    }
}

function slotOrigin(position, columns, hasTitle) {
    const column = position % columns
    const row = Math.floor(position / columns)
    return {
        x: padding + column * (slotWidth + spacing),
        y: padding + (hasTitle ? titleHeight : 0) + row * (slotHeight + spacing),
    }
}

function tint(slot) {
    return slot.swatch ?? roleColor(slot.role)
}

export class MenuController {
    constructor(host) {
        this.host = host
        this.presentation = null
        this.highlightedPosition = null
        this.armedPosition = null
        this.backdrop = null
        this.panel = null
        this.slotElements = new Map()
        window.addEventListener("keydown", (event) => {
            if (event.key === "Escape" && this.presentation) {
                this.dismiss()
            }
        })
    }

    present(slots, { columns = tokens.menus.columns, around, title = null }) {
        this.removeImmediately()
        const rows = Math.floor(Math.max(0, ...slots.map((slot) => slot.position)) / columns) + 1
        const size = panelSize(columns, rows, title !== null)
        const screenWidth = window.innerWidth
        const screenHeight = window.innerHeight
        let x = around.left + around.width / 2 - size.width / 2
        let y = around.top - size.height - spacing * 2
        if (y < screenMargin) {
            y = around.bottom + spacing * 2
        }
        x = Math.min(Math.max(screenMargin, x), screenWidth - size.width - screenMargin)
        y = Math.min(Math.max(screenMargin, y), screenHeight - size.height - screenMargin)
        this.presentation = { slots, columns, rows, x, y, title }
        this.armedPosition = null
        this.highlightedPosition = null
        this.build(size)
    }

    presentAt(slots, { columns, x, y, title }) {
        this.present(slots, {
            columns,
            title,
            around: { left: x, top: y - fingerClearance, width: 0, height: fingerClearance * 2, bottom: y + fingerClearance },
        })
    }

    build(size) {
        const presentation = this.presentation
        this.backdrop = create("div", "menu-backdrop")
        this.backdrop.addEventListener("pointerdown", (event) => {
            event.preventDefault()
            this.dismiss()
        })
        this.backdrop.addEventListener("contextmenu", (event) => event.preventDefault())
        this.panel = create("div", "menu-panel")
        this.panel.style.left = `${presentation.x}px`
        this.panel.style.top = `${presentation.y}px`
        this.panel.style.width = `${size.width}px`
        this.panel.style.height = `${size.height}px`
        this.panel.addEventListener("contextmenu", (event) => event.preventDefault())
        squircle(this.panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border_strong })
        if (presentation.title !== null) {
            const label = microLabel(presentation.title)
            label.classList.add("menu-title")
            label.style.left = `${padding + 6}px`
            label.style.top = `${padding + 4}px`
            this.panel.append(label)
        }
        this.slotElements.clear()
        for (const slot of presentation.slots) {
            const origin = slotOrigin(slot.position, presentation.columns, presentation.title !== null)
            const element = this.slotElement(slot)
            element.style.left = `${origin.x}px`
            element.style.top = `${origin.y}px`
            this.panel.append(element)
            this.slotElements.set(slot.position, element)
            this.refreshSlot(slot)
        }
        this.host.append(this.backdrop, this.panel)
        fadeIn(this.backdrop)
        overlayEnter(this.panel)
    }

    slotElement(slot) {
        const marker = slot.swatch ? create("span", "menu-slot-swatch") : create("span", "menu-slot-bar")
        if (slot.swatch) {
            marker.style.background = slot.swatch
        }
        const label = create("span", "menu-slot-title")
        const element = create("button", "menu-slot", create("span", "menu-slot-content", marker, label))
        element.type = "button"
        element.disabled = !slot.isEnabled
        element.addEventListener("pointerup", (event) => {
            if (event.button === 0 || event.pointerType !== "mouse") {
                event.stopPropagation()
                this.activate(slot.position)
            }
        })
        element.addEventListener("pointerenter", (event) => {
            if (event.pointerType === "mouse") {
                this.setHighlight(slot.position)
            }
        })
        element.addEventListener("pointerleave", (event) => {
            if (event.pointerType === "mouse" && this.highlightedPosition === slot.position) {
                this.setHighlight(null)
            }
        })
        return element
    }

    refreshSlot(slot) {
        const element = this.slotElements.get(slot.position)
        if (!element) {
            return
        }
        const isArmed = this.armedPosition === slot.position
        const isHighlighted = this.highlightedPosition === slot.position && slot.isEnabled
        const slotTint = tint(slot)
        let fill = tokens.palette.sunken
        if (isArmed) {
            fill = tokens.semantic.destructive_hard
        } else if (isHighlighted) {
            fill = slotTint
        }
        let ink = slot.swatch ? tokens.palette.text_body : slotTint
        if (isArmed) {
            ink = "#FFFFFF"
        } else if (isHighlighted) {
            ink = slot.swatch && !isLight(slot.swatch) ? "#FFFFFF" : tokens.palette.ground
        }
        squircle(element, {
            radius: squircleRadius.slot,
            fill,
            border: slot.isActive ? slotTint : tokens.palette.border,
            borderWidth: slot.isActive ? 2 : 1,
        })
        element.classList.toggle("is-highlighted", isHighlighted)
        element.classList.toggle("is-disabled", !slot.isEnabled)
        const bar = element.querySelector(".menu-slot-bar")
        if (bar) {
            bar.style.background = isArmed || isHighlighted ? ink : slotTint
        }
        const label = element.querySelector(".menu-slot-title")
        label.textContent = isArmed ? "Confirm" : slot.title
        label.style.color = ink
    }

    setHighlight(position) {
        if (position === this.highlightedPosition || !this.presentation) {
            return
        }
        const previous = this.highlightedPosition
        this.highlightedPosition = position
        for (const slot of this.presentation.slots) {
            if (slot.position === previous || slot.position === position) {
                this.refreshSlot(slot)
            }
        }
    }

    slotPosition(clientX, clientY) {
        const presentation = this.presentation
        if (!presentation) {
            return null
        }
        for (const slot of presentation.slots) {
            const origin = slotOrigin(slot.position, presentation.columns, presentation.title !== null)
            const left = presentation.x + origin.x
            const top = presentation.y + origin.y
            if (clientX >= left && clientX < left + slotWidth && clientY >= top && clientY < top + slotHeight) {
                return slot.position
            }
        }
        return null
    }

    drag(clientX, clientY) {
        this.setHighlight(this.slotPosition(clientX, clientY))
    }

    release(clientX, clientY) {
        this.setHighlight(null)
        const position = this.slotPosition(clientX, clientY)
        if (position !== null) {
            this.activate(position)
        }
    }

    activate(position) {
        const slot = this.presentation?.slots.find((candidate) => candidate.position === position)
        if (!slot || !slot.isEnabled) {
            return
        }
        if (slot.role === "destructive" && this.armedPosition !== position) {
            const previous = this.armedPosition
            this.armedPosition = position
            for (const candidate of this.presentation.slots) {
                if (candidate.position === previous || candidate.position === position) {
                    this.refreshSlot(candidate)
                }
            }
            return
        }
        this.dismiss()
        slot.handler()
    }

    get isPresented() {
        return this.presentation !== null
    }

    dismiss() {
        if (!this.presentation) {
            return
        }
        const backdrop = this.backdrop
        const panel = this.panel
        this.presentation = null
        this.armedPosition = null
        this.highlightedPosition = null
        this.backdrop = null
        this.panel = null
        fadeOut(backdrop).then(() => backdrop.remove())
        overlayLeave(panel).then(() => panel.remove())
    }

    removeImmediately() {
        this.backdrop?.remove()
        this.panel?.remove()
        this.backdrop = null
        this.panel = null
        this.presentation = null
    }
}
