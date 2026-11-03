import { create } from "./components.js"
import { duration, fadeIn, fadeOut, tween } from "./motion.js"
import { PillMotion, hideTurned, popSwitchIn, revealElement, shapePillShell, turnOut } from "./pill.js"
import { glyph } from "./shapes.js"
import { isLight, roleColor, tokens } from "./tokens.js"

const chipHeight = 44
const titleHeight = 28
const spacing = 6
const sectionGap = 14
const screenMargin = 16
const fingerGap = 14
const swatchesPerLine = 4
const armedMilliseconds = 2400

const arrangement = {
    rename: { section: 0, rank: 0, glyph: "pencil" },
    appearance: { section: 0, rank: 0, glyph: "star", lane: 1 },
    group: { section: 1, rank: 0, glyph: "stack" },
    ungroup: { section: 1, rank: 0, glyph: "stack" },
    move: { section: 1, rank: 1, glyph: "move" },
    new_folder: { section: 0, rank: 1, glyph: "folder_add" },
    new_note: { section: 0, rank: 1, glyph: "note_add", lane: 1 },
    paste: { section: 0, rank: 0, glyph: "paste" },
    expand_columns: { section: 1, rank: 0, glyph: "add_column" },
    shrink_columns: { section: 1, rank: 0, glyph: "remove_column", lane: 1, isIconOnly: true },
    expand_rows: { section: 1, rank: 1, glyph: "add_row" },
    shrink_rows: { section: 1, rank: 1, glyph: "remove_row", lane: 1, isIconOnly: true },
    toggle_guides: { section: 2, rank: 0, glyph: "guides" },
    toggle_dividers: { section: 2, rank: 1, glyph: "cell_lines" },
    invert_import: { section: 2, rank: 2, glyph: "invert" },
    delete_notebook: { section: 3, rank: 0, glyph: "trash" },
    delete_page: { section: 3, rank: 0, glyph: "trash" },
    cut: { section: 0, rank: 0, glyph: "cut", isIconOnly: true },
    copy: { section: 0, rank: 0, glyph: "copy", lane: 1, isIconOnly: true },
    duplicate: { section: 0, rank: 0, glyph: "duplicate", lane: 2 },
    color: { section: 1, rank: 0, glyph: "color" },
    equal_width: { section: 1, rank: 0, glyph: "equal_width", lane: 1 },
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
        swatch: color,
        isActive: color.toUpperCase() === current?.toUpperCase(),
        isEnabled: true,
        isDestructive: false,
        handler: () => perform(color),
    }))
}

function sortedLines(slots) {
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
        if (slot.lane > 0 && previous && previous.section === slot.section && previous.rank === slot.rank && !isTrailing(previous)) {
            lines[lines.length - 1].push(slot)
        } else {
            lines.push([slot])
        }
    })
    return lines
}

class MenuChip {
    constructor(slot, controller) {
        this.slot = slot
        this.controller = controller
        this.element = create("button", "menu-chip")
        this.element.setAttribute("aria-label", slot.title)
        this.shell = create("span", "pill-shell menu-chip-shell")
        this.content = create("span", "menu-chip-content")
        this.element.append(this.shell, this.content)
        this.element.disabled = !slot.isEnabled
        this.element.classList.toggle("is-disabled", !slot.isEnabled)
        this.element.addEventListener("click", () => controller.activate(slot.position))
        this.width = chipHeight
        this.x = 0
        this.y = 0
        this.motion = new PillMotion(() => this.paintShell())
        this.motion.onElements = (shown, isInstant) => {
            if (isInstant) {
                hideTurned(this.content)
                return
            }
            this.content.style.opacity = ""
            revealElement(this.content, shown)
        }
        this.fill()
    }

    isArmed() {
        return this.controller.armedPosition === this.slot.position
    }

    isHighlighted() {
        return this.controller.highlightedPosition === this.slot.position
    }

    isCircle() {
        return this.slot.isIconOnly && !this.isArmed()
    }

    ink() {
        const slot = this.slot
        if (this.isArmed()) {
            return "#FFFFFF"
        }
        if (this.isHighlighted()) {
            return slot.swatch ? (isLight(slot.swatch) ? tokens.palette.ground : "#FFFFFF") : tokens.palette.ground
        }
        return slot.swatch ? tokens.palette.text_body : roleColor(slot.role)
    }

    fill() {
        const slot = this.slot
        const content = this.content
        content.replaceChildren()
        const ink = this.ink()
        if (slot.swatch && !this.isArmed()) {
            const dot = create("span", "menu-chip-swatch")
            dot.style.background = slot.swatch
            dot.style.boxShadow = `inset 0 0 0 1px ${tokens.palette.border_control}`
            content.append(dot)
        } else if (slot.glyph || this.isArmed()) {
            content.append(glyph(this.isArmed() ? "check" : slot.glyph, { color: ink, size: 18 }))
        }
        if (!this.isCircle()) {
            const text = create("span", "menu-chip-title", (this.isArmed() ? "Confirm" : slot.title).toUpperCase())
            text.style.color = ink
            content.append(text)
        }
        content.classList.toggle("is-centred", this.isCircle())
        this.paintColours()
    }

    paintColours() {
        const slot = this.slot
        const color = slot.swatch ?? roleColor(slot.role)
        const isArmed = this.isArmed()
        const isHighlighted = this.isHighlighted()
        this.shell.style.background = isArmed ? tokens.semantic.destructive_hard : isHighlighted ? color : ""
        this.shell.style.borderColor = isArmed ? tokens.semantic.destructive_hard : slot.isActive ? tokens.palette.accent : ""
        this.element.classList.toggle("is-highlighted", isHighlighted)
        for (const icon of this.content.querySelectorAll(".glyph")) {
            icon.style.color = this.ink()
        }
        for (const text of this.content.querySelectorAll(".menu-chip-title")) {
            text.style.color = this.ink()
        }
    }

    naturalWidth() {
        if (this.isCircle()) {
            return chipHeight
        }
        this.content.style.width = "max-content"
        const width = Math.ceil(this.content.offsetWidth)
        this.content.style.width = ""
        return Math.max(chipHeight, width)
    }

    place(x, y, width) {
        this.x = x
        this.y = y
        this.width = width
        this.element.style.left = `${x}px`
        this.element.style.top = `${y}px`
        this.element.style.width = `${width}px`
        this.element.style.height = `${chipHeight}px`
        this.paintShell()
    }

    paintShell() {
        shapePillShell(this.shell, { width: this.width, height: chipHeight, isWide: true, scale: this.motion.shellScale, spread: this.motion.shellSpread })
        this.element.style.visibility = this.motion.isPresent ? "visible" : "hidden"
        this.element.style.pointerEvents = this.motion.areElementsShown ? "auto" : "none"
    }

    mutate(change) {
        this.mutation = (this.mutation ?? 0) + 1
        const step = this.mutation
        turnOut(this.content, { milliseconds: duration("navigation_mutate_leave") })
        setTimeout(() => {
            if (step !== this.mutation || !this.element.isConnected) {
                return
            }
            change()
            this.fill()
            this.controller.relayout(true)
            popSwitchIn(this.content)
        }, duration("navigation_mutate_leave"))
    }
}

export class MenuController {
    constructor(host) {
        this.host = host
        this.presentation = null
        this.highlightedPosition = null
        this.armedPosition = null
        this.backdrop = null
        this.panel = null
        this.chips = new Map()
        this.layoutTween = null
        window.addEventListener("keydown", (event) => {
            if (event.key === "Escape" && this.presentation) {
                event.stopImmediatePropagation()
                this.dismiss()
            }
        })
    }

    get isPresented() {
        return Boolean(this.presentation)
    }

    present(slots, point, title = null) {
        this.removeNow()
        const lines = sortedLines(slots)
        this.armedPosition = null
        this.highlightedPosition = null
        clearTimeout(this.armTimer)
        const backdrop = create("div", "menu-backdrop")
        backdrop.addEventListener("pointerdown", (event) => {
            event.preventDefault()
            this.dismiss()
        })
        backdrop.addEventListener("contextmenu", (event) => event.preventDefault())
        const panel = create("div", "menu-panel")
        panel.style.visibility = "hidden"
        this.host.append(backdrop, panel)
        this.backdrop = backdrop
        this.panel = panel
        this.chips = new Map()
        this.lines = lines.map((line) => line.map((slot) => {
            const chip = new MenuChip(slot, this)
            panel.append(chip.element)
            this.chips.set(slot.position, chip)
            return chip
        }))
        this.titleChip = null
        if (title) {
            const titleChip = {
                element: create("div", "menu-title-chip"),
                shell: create("span", "pill-shell menu-title-shell"),
                content: create("span", "menu-title-text", title.toUpperCase()),
                width: titleHeight,
            }
            titleChip.element.append(titleChip.shell, titleChip.content)
            titleChip.motion = new PillMotion(() => {
                shapePillShell(titleChip.shell, { width: titleChip.width, height: titleHeight, isWide: true, scale: titleChip.motion.shellScale, spread: titleChip.motion.shellSpread })
                titleChip.element.style.visibility = titleChip.motion.isPresent ? "visible" : "hidden"
            })
            titleChip.motion.onElements = (shown, isInstant) => {
                if (isInstant) {
                    hideTurned(titleChip.content)
                } else {
                    titleChip.content.style.opacity = ""
                    revealElement(titleChip.content, shown)
                }
            }
            panel.append(titleChip.element)
            this.titleChip = titleChip
        }
        const frames = this.frames()
        const size = frames.size
        const width = window.innerWidth
        const height = window.innerHeight
        const isOnLeft = point[0] + fingerGap + size[0] > width - screenMargin
        const origin = [isOnLeft ? point[0] - fingerGap - size[0] : point[0] + fingerGap, point[1]]
        if (origin[1] + size[1] > height - screenMargin) {
            origin[1] = point[1] - size[1]
        }
        origin[0] = Math.min(Math.max(screenMargin, origin[0]), width - size[0] - screenMargin)
        origin[1] = Math.min(Math.max(screenMargin, origin[1]), height - size[1] - screenMargin)
        this.presentation = { origin, isOnLeft, step: (this.presentation?.step ?? 0) + 1 }
        panel.style.left = `${origin[0]}px`
        panel.style.top = `${origin[1]}px`
        panel.style.width = `${size[0]}px`
        panel.style.height = `${size[1]}px`
        this.applyFrames(this.frames(), false)
        panel.style.visibility = ""
        fadeIn(backdrop)
        const all = [this.titleChip, ...this.lines.flat()].filter(Boolean)
        const presentation = this.presentation
        all.forEach((chip, index) => {
            chip.motion.isPresent = false
            chip.motion.onFrame()
            setTimeout(() => {
                if (this.presentation === presentation) {
                    chip.motion.enter()
                }
            }, index * duration("rise_stagger"))
        })
    }

    frames() {
        const isOnLeft = this.presentation?.isOnLeft ?? false
        const result = new Map()
        let top = 0
        let widest = 0
        if (this.titleChip) {
            const content = this.titleChip.content
            content.style.width = "max-content"
            this.titleChip.width = Math.max(titleHeight, Math.ceil(content.offsetWidth))
            content.style.width = ""
            widest = this.titleChip.width
            top = titleHeight + spacing
        }
        const measured = this.lines.map((line) => line.map((chip) => chip.naturalWidth()))
        this.lines.forEach((line, index) => {
            const previous = this.lines[index - 1]?.[0]?.slot
            if (previous && (previous.section !== line[0].slot.section || isTrailing(previous) !== isTrailing(line[0].slot))) {
                top += sectionGap - spacing
            }
            const lineWidth = measured[index].reduce((total, width) => total + width, 0) + spacing * (line.length - 1)
            widest = Math.max(widest, lineWidth)
            line.forEach((chip, lane) => {
                result.set(chip, { y: top, width: measured[index][lane], lineWidth, offset: measured[index].slice(0, lane).reduce((total, width) => total + width + spacing, 0) })
            })
            top += chipHeight + spacing
        })
        for (const frame of result.values()) {
            frame.x = isOnLeft ? widest - frame.lineWidth + frame.offset : frame.offset
        }
        return { chips: result, size: [widest, Math.max(0, top - spacing)], titleX: isOnLeft && this.titleChip ? widest - this.titleChip.width : 0 }
    }

    applyFrames(frames, isAnimated) {
        this.layoutTween?.stop()
        const panelWidth = frames.size[0]
        const panelHeight = frames.size[1]
        if (this.titleChip) {
            this.titleChip.element.style.left = `${frames.titleX}px`
            this.titleChip.element.style.width = `${this.titleChip.width}px`
            this.titleChip.element.style.height = `${titleHeight}px`
            this.titleChip.motion.onFrame()
        }
        const isOnLeft = this.presentation?.isOnLeft ?? false
        const startWidth = this.panel.offsetWidth || panelWidth
        const shift = isOnLeft ? panelWidth - startWidth : 0
        if (!isAnimated) {
            for (const [chip, frame] of frames.chips) {
                chip.place(frame.x, frame.y, frame.width)
            }
            this.resizePanel(panelWidth, panelHeight, 0)
            return
        }
        const starts = new Map([...frames.chips.keys()].map((chip) => [chip, { x: chip.x + shift, width: chip.width }]))
        this.resizePanel(panelWidth, panelHeight, shift)
        for (const [chip, start] of starts) {
            chip.place(start.x, chip.y, start.width)
        }
        this.layoutTween = tween({
            milliseconds: duration("navigation_switch") * 2,
            curveName: "power_three_in_out",
            onFrame: (eased) => {
                for (const [chip, frame] of frames.chips) {
                    const start = starts.get(chip)
                    chip.place(start.x + (frame.x - start.x) * eased, frame.y, start.width + (frame.width - start.width) * eased)
                }
            },
        })
    }

    resizePanel(width, height, shift) {
        const left = (parseFloat(this.panel.style.left) || 0) - shift
        const clamped = Math.min(Math.max(screenMargin, left), window.innerWidth - width - screenMargin)
        this.panel.style.left = `${clamped}px`
        this.panel.style.width = `${width}px`
        this.panel.style.height = `${height}px`
    }

    relayout(isAnimated) {
        if (!this.presentation) {
            return
        }
        this.applyFrames(this.frames(), isAnimated)
    }

    slotAt(point) {
        if (!this.presentation) {
            return null
        }
        for (const [position, chip] of this.chips) {
            const rect = chip.element.getBoundingClientRect()
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
            this.chips.get(key)?.paintColours()
        }
    }

    release(point) {
        const previous = this.highlightedPosition
        this.highlightedPosition = null
        this.chips.get(previous)?.paintColours()
        const position = this.slotAt(point)
        if (position !== null) {
            this.activate(position)
        }
    }

    setArmed(position) {
        const previous = this.armedPosition
        if (previous === position) {
            return
        }
        clearTimeout(this.armTimer)
        this.armedPosition = position
        for (const key of [previous, position]) {
            this.chips.get(key)?.mutate(() => {})
        }
        if (position !== null) {
            this.armTimer = setTimeout(() => this.setArmed(null), armedMilliseconds)
        }
    }

    activate(position) {
        const chip = this.chips.get(position)
        const slot = chip?.slot
        if (!slot || !slot.isEnabled || !this.presentation) {
            return
        }
        if (slot.isDestructive && this.armedPosition !== position) {
            this.setArmed(position)
            return
        }
        this.dismiss()
        slot.handler()
    }

    removeNow() {
        this.layoutTween?.stop()
        clearTimeout(this.armTimer)
        this.backdrop?.remove()
        this.panel?.remove()
        this.backdrop = null
        this.panel = null
        this.presentation = null
        this.chips = new Map()
        this.lines = []
        this.titleChip = null
    }

    dismiss() {
        if (!this.presentation) {
            return
        }
        const { backdrop, panel } = this
        const leaving = [this.titleChip, ...this.lines.flat()].filter(Boolean)
        clearTimeout(this.armTimer)
        this.presentation = null
        this.backdrop = null
        this.panel = null
        this.armedPosition = null
        this.highlightedPosition = null
        this.chips = new Map()
        this.lines = []
        this.titleChip = null
        backdrop.style.pointerEvents = "none"
        panel.style.pointerEvents = "none"
        fadeOut(backdrop).then(() => backdrop.remove())
        let remaining = leaving.length
        if (!remaining) {
            panel.remove()
            return
        }
        for (const chip of leaving) {
            chip.motion.leave(() => {
                remaining -= 1
                if (remaining === 0) {
                    panel.remove()
                }
            })
        }
    }
}
