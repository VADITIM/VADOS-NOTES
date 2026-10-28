import { create, microLabel } from "./components.js"
import { animate, duration, fadeIn, fadeOut } from "./motion.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { isLight, roleColor, tokens } from "./tokens.js"

const rowSize = [184, 46]
const spacing = 4
const dividerGap = 13
const padding = 6
const titleHeight = 26
const screenMargin = 16
const fingerGap = 14

const arrangement = {
    rename: [0, 0, "pencil"],
    appearance: [0, 1, "star"],
    group: [1, 0, "stack"],
    ungroup: [1, 0, "stack"],
    move: [1, 1, "move"],
    expand_columns: [0, 0, "add_column"],
    expand_rows: [0, 1, "add_row"],
    toggle_guides: [1, 0, "guides"],
    toggle_dividers: [1, 1, "cell_lines"],
    delete_notebook: [2, 0, "trash"],
    delete_page: [2, 0, "trash"],
}

export function slotsFromTokens(definitions, { title, isEnabled = () => true, perform }) {
    return definitions.map((definition) => {
        const arranged = arrangement[definition.action]
        return {
            position: definition.slot,
            title: title(definition.action),
            role: definition.role,
            glyph: arranged?.[2] ?? null,
            section: arranged?.[0] ?? 0,
            rank: arranged?.[1] ?? definition.slot,
            isEnabled: isEnabled(definition.action),
            isDestructive: definition.role === "destructive",
            handler: () => perform(definition.action),
        }
    })
}

export class MenuController {
    constructor(host) {
        this.host = host
        this.presentation = null
        this.highlightedPosition = null
        this.armedPosition = null
        this.backdrop = null
        this.panel = null
        this.rows = new Map()
        window.addEventListener("keydown", (event) => {
            if (event.key === "Escape" && this.presentation) {
                this.dismiss()
            }
        })
    }

    present(slots, point, title = null) {
        this.removeNow()
        const ordered = [...slots].sort((first, second) => {
            if (first.isDestructive !== second.isDestructive) {
                return first.isDestructive ? 1 : -1
            }
            if (first.section !== second.section) {
                return first.section - second.section
            }
            if (first.rank !== second.rank) {
                return first.rank - second.rank
            }
            return first.position - second.position
        })
        const rows = []
        const dividers = []
        let top = padding + (title ? titleHeight : 0)
        ordered.forEach((slot, index) => {
            if (index > 0) {
                const previous = ordered[index - 1]
                if (previous.section !== slot.section || previous.isDestructive !== slot.isDestructive) {
                    dividers.push(top + (dividerGap - spacing) / 2)
                    top += dividerGap - spacing
                }
            }
            rows.push({ x: padding, y: top })
            top += rowSize[1] + spacing
        })
        const size = [padding * 2 + rowSize[0], top - spacing + padding]
        const width = window.innerWidth
        const height = window.innerHeight
        const isOnLeft = point[0] + fingerGap + size[0] > width - screenMargin
        const origin = [isOnLeft ? point[0] - fingerGap - size[0] : point[0] + fingerGap, point[1]]
        if (origin[1] + size[1] > height - screenMargin) {
            origin[1] = point[1] - size[1]
        }
        origin[0] = Math.min(Math.max(screenMargin, origin[0]), width - size[0] - screenMargin)
        origin[1] = Math.min(Math.max(screenMargin, origin[1]), height - size[1] - screenMargin)
        this.armedPosition = null
        this.highlightedPosition = null
        this.presentation = { slots: ordered, rows, origin, size }

        const backdrop = create("div", "menu-backdrop")
        backdrop.addEventListener("pointerdown", (event) => {
            event.preventDefault()
            this.dismiss()
        })
        backdrop.addEventListener("contextmenu", (event) => event.preventDefault())
        const panel = create("div", "menu-panel")
        panel.style.left = `${origin[0]}px`
        panel.style.top = `${origin[1]}px`
        panel.style.width = `${size[0]}px`
        panel.style.height = `${size[1]}px`
        panel.style.transformOrigin = isOnLeft ? "top right" : "top left"
        if (title) {
            const label = microLabel(title)
            label.classList.add("menu-title")
            label.style.left = `${padding + 6}px`
            label.style.top = `${padding + 4}px`
            label.style.width = `${rowSize[0] - 12}px`
            panel.append(label)
        }
        dividers.forEach((y) => {
            const divider = create("span", "menu-divider")
            divider.style.left = `${padding + 12}px`
            divider.style.top = `${y}px`
            divider.style.width = `${rowSize[0] - 24}px`
            panel.append(divider)
            animate(divider, [{ opacity: 0 }, { opacity: 1 }], { milliseconds: duration("state"), curveName: "power_two_out", delay: duration("rise_delay") })
        })
        this.rows = new Map()
        ordered.forEach((slot, index) => {
            const row = this.makeRow(slot)
            row.style.left = `${rows[index].x}px`
            row.style.top = `${rows[index].y}px`
            panel.append(row)
            this.rows.set(slot.position, row)
            animate(row, [{ opacity: 0, transform: "scale(0.001)" }, { opacity: 1, transform: "scale(1)" }], {
                milliseconds: duration("state"),
                curveName: "power_two_out",
                delay: duration("rise_delay") + index * duration("rise_stagger"),
            })
        })
        squircle(panel, { radius: squircleRadius.sheet, fill: tokens.palette.panel_solid, border: tokens.palette.border_strong })
        this.host.append(backdrop, panel)
        this.backdrop = backdrop
        this.panel = panel
        fadeIn(backdrop)
        animate(panel, [{ opacity: 0, transform: "scale(0.001)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out" })
    }

    makeRow(slot) {
        const row = create("button", "menu-row")
        row.style.width = `${rowSize[0]}px`
        row.style.height = `${rowSize[1]}px`
        const inner = create("span", "menu-row-inner")
        row.append(inner)
        row.inner = inner
        row.menuSlot = slot
        row.addEventListener("click", () => this.activate(slot.position))
        row.disabled = !slot.isEnabled
        row.classList.toggle("is-disabled", !slot.isEnabled)
        this.paintRow(row)
        return row
    }

    paintRow(row) {
        const slot = row.menuSlot
        const isArmed = this.armedPosition === slot.position
        const isHighlighted = this.highlightedPosition === slot.position
        const color = slot.swatch ?? roleColor(slot.role)
        const fill = isArmed ? tokens.semantic.destructive_hard : isHighlighted ? color : tokens.palette.sunken
        let ink = slot.swatch ? tokens.palette.text_body : color
        if (isArmed) {
            ink = "#FFFFFF"
        } else if (isHighlighted) {
            ink = slot.swatch ? (isLight(slot.swatch) ? tokens.palette.ground : "#FFFFFF") : tokens.palette.ground
        }
        const inner = row.inner
        inner.replaceChildren()
        if (slot.glyph) {
            inner.append(glyph(isArmed ? "check" : slot.glyph, { color: ink, size: 18 }))
        } else {
            const bar = create("span", "menu-row-bar")
            bar.style.background = isArmed || isHighlighted ? ink : color
            inner.append(bar)
        }
        const text = create("span", "menu-row-title", (isArmed ? "Confirm" : slot.title).toUpperCase())
        text.style.color = ink
        inner.append(text)
        squircle(row, { radius: squircleRadius.slot, fill, border: tokens.palette.border })
        row.classList.toggle("is-highlighted", isHighlighted)
    }

    slotAt(point) {
        if (!this.presentation) {
            return null
        }
        for (const [position, row] of this.rows) {
            const rect = row.getBoundingClientRect()
            if (point[0] >= rect.left && point[0] <= rect.right && point[1] >= rect.top && point[1] <= rect.bottom) {
                return position
            }
        }
        return null
    }

    drag(point) {
        const position = this.slotAt(point)
        if (position === this.highlightedPosition) {
            return
        }
        const previous = this.highlightedPosition
        this.highlightedPosition = position
        for (const key of [previous, position]) {
            const row = this.rows.get(key)
            if (row) {
                this.paintRow(row)
            }
        }
    }

    release(point) {
        const previous = this.highlightedPosition
        this.highlightedPosition = null
        if (this.rows.get(previous)) {
            this.paintRow(this.rows.get(previous))
        }
        const position = this.slotAt(point)
        if (position !== null) {
            this.activate(position)
        }
    }

    activate(position) {
        const slot = this.presentation?.slots.find((candidate) => candidate.position === position)
        if (!slot || !slot.isEnabled) {
            return
        }
        if (slot.isDestructive && this.armedPosition !== position) {
            const previous = this.armedPosition
            this.armedPosition = position
            for (const key of [previous, position]) {
                if (this.rows.get(key)) {
                    this.paintRow(this.rows.get(key))
                }
            }
            return
        }
        this.dismiss()
        slot.handler()
    }

    removeNow() {
        this.backdrop?.remove()
        this.panel?.remove()
        this.backdrop = null
        this.panel = null
        this.presentation = null
    }

    dismiss() {
        if (!this.presentation) {
            return
        }
        const { backdrop, panel } = this
        this.presentation = null
        this.backdrop = null
        this.panel = null
        this.armedPosition = null
        this.highlightedPosition = null
        backdrop.style.pointerEvents = "none"
        panel.style.pointerEvents = "none"
        fadeOut(backdrop).then(() => backdrop.remove())
        animate(panel, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.001)" }], { milliseconds: duration("overlay_leave"), curveName: "back_in", fill: "forwards" }).finished.then(() => panel.remove())
    }
}
