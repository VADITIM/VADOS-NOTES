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
const swatchesPerLine = 4

const arrangement = {
    rename: { section: 0, rank: 0, glyph: "pencil" },
    appearance: { section: 0, rank: 1, glyph: "star" },
    group: { section: 1, rank: 0, glyph: "stack" },
    ungroup: { section: 1, rank: 0, glyph: "stack" },
    move: { section: 1, rank: 1, glyph: "move" },
    paste: { section: 0, rank: 0, glyph: "paste" },
    expand_columns: { section: 1, rank: 0, glyph: "add_column" },
    shrink_columns: { section: 1, rank: 0, glyph: "remove_column", lane: 1, isIconOnly: true },
    expand_rows: { section: 1, rank: 1, glyph: "add_row" },
    shrink_rows: { section: 1, rank: 1, glyph: "remove_row", lane: 1, isIconOnly: true },
    toggle_guides: { section: 2, rank: 0, glyph: "guides" },
    toggle_dividers: { section: 2, rank: 1, glyph: "cell_lines" },
    delete_notebook: { section: 3, rank: 0, glyph: "trash" },
    delete_page: { section: 3, rank: 0, glyph: "trash" },
    cut: { section: 0, rank: 0, glyph: "cut", isIconOnly: true },
    copy: { section: 0, rank: 0, glyph: "copy", lane: 1, isIconOnly: true },
    duplicate: { section: 1, rank: 0, glyph: "duplicate" },
    color: { section: 1, rank: 1, glyph: "color" },
    equal_width: { section: 1, rank: 2, glyph: "equal_width" },
}

function isTrailing(slot) {
    return slot.isDestructive && slot.lane === 0
}

export function slotsFromTokens(definitions, { title, isEnabled = () => true, perform }) {
    return definitions.map((definition) => {
        const arranged = arrangement[definition.action]
        return {
            position: definition.slot,
            title: title(definition.action),
            role: definition.role,
            glyph: arranged?.glyph ?? null,
            section: arranged?.section ?? 0,
            rank: arranged?.rank ?? definition.slot,
            lane: arranged?.lane ?? 0,
            isIconOnly: arranged?.isIconOnly ?? false,
            isEnabled: isEnabled(definition.action),
            isDestructive: definition.role === "destructive",
            handler: () => perform(definition.action),
        }
    })
}

export function swatchSlots(colors, current, perform) {
    return colors.map((color, index) => ({
        position: index,
        title: color,
        role: "edit",
        glyph: null,
        section: 0,
        rank: Math.floor(index / swatchesPerLine),
        lane: index % swatchesPerLine,
        isIconOnly: true,
        lineCapacity: swatchesPerLine,
        swatch: color,
        isActive: color.toUpperCase() === current?.toUpperCase(),
        isEnabled: true,
        isDestructive: false,
        handler: () => perform(color),
    }))
}

function lineFrames(line, top) {
    const gaps = spacing * (line.length - 1)
    const iconCount = line.filter((slot) => slot.isIconOnly).length
    const labelCount = line.length - iconCount
    const capacity = Math.max(line.length, line[0].lineCapacity ?? 0)
    const iconWidth = labelCount === 0 ? (rowSize[0] - spacing * (capacity - 1)) / capacity : rowSize[1]
    const labelWidth = labelCount === 0 ? 0 : (rowSize[0] - gaps - iconWidth * iconCount) / labelCount
    let left = padding
    return line.map((slot) => {
        const width = slot.isIconOnly ? iconWidth : labelWidth
        const frame = { x: left, y: top, width }
        left += width + spacing
        return frame
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
        const sorted = [...slots].sort((first, second) => {
            if (isTrailing(first) !== isTrailing(second)) {
                return isTrailing(first) ? 1 : -1
            }
            if (first.section !== second.section) {
                return first.section - second.section
            }
            if (first.rank !== second.rank) {
                return first.rank - second.rank
            }
            if (first.lane !== second.lane) {
                return first.lane - second.lane
            }
            return first.position - second.position
        })
        const lines = []
        sorted.forEach((slot) => {
            const previous = lines[lines.length - 1]?.[0]
            if (slot.lane > 0 && previous && previous.section === slot.section && previous.rank === slot.rank) {
                lines[lines.length - 1].push(slot)
            } else {
                lines.push([slot])
            }
        })
        const ordered = lines.flat()
        const rows = []
        const dividers = []
        let top = padding + (title ? titleHeight : 0)
        lines.forEach((line, index) => {
            const previous = lines[index - 1]?.[0]
            if (previous && (previous.section !== line[0].section || isTrailing(previous) !== isTrailing(line[0]))) {
                dividers.push(top - spacing + dividerGap / 2)
                top += dividerGap - spacing
            }
            rows.push(...lineFrames(line, top))
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
            const row = this.makeRow(slot, rows[index].width)
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
        this.host.append(backdrop, panel)
        this.backdrop = backdrop
        this.panel = panel
        fadeIn(backdrop)
        animate(panel, [{ opacity: 0, transform: "scale(0.001)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out" })
    }

    makeRow(slot, width) {
        const row = create("button", "menu-row")
        row.classList.toggle("is-icon-only", slot.isIconOnly)
        row.setAttribute("aria-label", slot.title)
        row.style.width = `${width}px`
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
        if (slot.swatch && slot.isIconOnly) {
            const dot = create("span", "menu-row-swatch")
            dot.style.background = slot.swatch
            dot.style.boxShadow = `inset 0 0 0 1px ${tokens.palette.border_control}`
            inner.append(dot)
        } else if (slot.glyph) {
            inner.append(glyph(isArmed ? "check" : slot.glyph, { color: ink, size: 18 }))
        } else {
            const bar = create("span", "menu-row-bar")
            bar.style.background = isArmed || isHighlighted ? ink : color
            inner.append(bar)
        }
        if (!slot.isIconOnly) {
            const text = create("span", "menu-row-title", (isArmed ? "Confirm" : slot.title).toUpperCase())
            text.style.color = ink
            inner.append(text)
        }
        squircle(row, { radius: squircleRadius.slot, fill, border: slot.isActive ? color : tokens.palette.border })
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
