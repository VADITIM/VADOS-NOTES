import { create, microLabel } from "./components.js"
import { curveAt, duration, tween } from "./motion.js"
import { glyph } from "./shapes.js"
import { tokens } from "./tokens.js"

const gap = 18
const columns = 3
const shutHeight = 150
const headingHeight = 52
const tiltDegrees = 7
const shift = 9
const shrink = 0.05
const darken = 0.2
const visibleLayers = 3
const labelGap = 28
const arrowSize = 44
const arrowTurn = 0.5
const pullReach = 0.8
const decideShare = 0.3

export class StackGroup {
    constructor({ group, caption, isOpen, cardHeight, onToggle, onMenu, card }) {
        this.group = group
        this.caption = caption
        this.isOpen = isOpen
        this.cardHeight = cardHeight
        this.onToggle = onToggle
        this.onMenu = onMenu
        this.card = card
        this.time = isOpen ? 1 : 0
        this.isPulled = false
        this.width = 0
        this.element = create("div", "stack-group")
        this.cards = group.members.map((memberId) => {
            const holder = create("div", "stack-card")
            holder.append(card(memberId))
            this.element.append(holder)
            return holder
        })
        this.shutLabel = create("div", "stack-shut-label", create("span", "stack-title", group.title), microLabel(caption))
        this.shutMask = create("div", "stack-shut-mask", this.shutLabel)
        this.heading = create("div", "stack-heading", glyph("stack", { color: tokens.palette.accent, size: 18 }), create("span", "stack-heading-title", group.title.toUpperCase()), microLabel(caption))
        this.heading.addEventListener("click", () => this.onToggle(false))
        this.arrow = create("button", "stack-arrow", glyph("back", { color: tokens.palette.accent }))
        this.arrow.addEventListener("click", (event) => {
            event.stopPropagation()
            this.onToggle(!(this.isOpen && !this.isPulled))
        })
        this.shutHit = create("div", "stack-shut-hit")
        this.shutHit.addEventListener("click", () => {
            if (!this.wasSwiped) {
                this.onToggle(true)
            }
        })
        this.shutHit.addEventListener("contextmenu", (event) => {
            event.preventDefault()
            this.onMenu([event.clientX, event.clientY])
        })
        let holdTimer = null
        this.shutHit.addEventListener("pointerdown", (event) => {
            if (event.button !== 0) {
                return
            }
            const start = [event.clientX, event.clientY]
            holdTimer = setTimeout(() => this.onMenu(start), duration("menu_hold"))
            const cancel = () => clearTimeout(holdTimer)
            this.shutHit.addEventListener("pointerup", cancel, { once: true })
            this.shutHit.addEventListener("pointermove", (moveEvent) => {
                if (Math.hypot(moveEvent.clientX - start[0], moveEvent.clientY - start[1]) > 10) {
                    cancel()
                }
            })
        })
        this.element.append(this.shutMask, this.heading, this.arrow, this.shutHit)
        this.bindSwipe()
        this.resizeObserver = new ResizeObserver(() => {
            this.width = this.element.clientWidth
            this.paint()
        })
        this.resizeObserver.observe(this.element)
    }

    setOpen(isOpen) {
        if (isOpen === this.isOpen) {
            return
        }
        this.isOpen = isOpen
        this.run(isOpen ? 1 : 0)
    }

    run(target) {
        this.running?.stop()
        const from = this.time
        const remaining = Math.abs(target - from)
        this.running = tween({
            milliseconds: duration("stack") * remaining,
            curveName: "power_two_out",
            onFrame: (eased, progress) => {
                this.time = from + (target - from) * progress
                this.paint()
            },
        })
    }

    bindSwipe() {
        let start = null
        this.element.addEventListener("pointerdown", (event) => {
            start = [event.clientX, event.clientY]
            this.wasSwiped = false
        })
        this.element.addEventListener("pointermove", (event) => {
            if (!start || this.width <= 0) {
                return
            }
            const translation = [event.clientX - start[0], event.clientY - start[1]]
            if (!this.isPulled && (Math.hypot(...translation) < 24 || Math.abs(translation[0]) <= Math.abs(translation[1]))) {
                return
            }
            const share = translation[0] / (this.width * pullReach)
            if (this.isOpen && share < 0) {
                this.isPulled = true
                this.time = Math.min(1, Math.max(0, 1 + share))
            } else if (!this.isOpen && share > 0) {
                this.isPulled = true
                this.time = Math.min(1, Math.max(0, share))
            } else {
                return
            }
            this.wasSwiped = true
            this.element.setPointerCapture(event.pointerId)
            this.running?.stop()
            this.paint()
        })
        const end = () => {
            start = null
            if (!this.isPulled) {
                return
            }
            this.isPulled = false
            if (this.isOpen && 1 - this.time > decideShare) {
                this.onToggle(false)
            } else if (!this.isOpen && this.time > decideShare) {
                this.onToggle(true)
            } else {
                this.run(this.isOpen ? 1 : 0)
            }
        }
        this.element.addEventListener("pointerup", end)
        this.element.addEventListener("pointercancel", end)
    }

    progress(index) {
        const count = this.group.members.length
        const span = tokens.motion.shares.stack_stagger
        const start = (index / Math.max(1, count)) * span
        const local = Math.min(1, Math.max(0, (this.time - start) / (1 - span)))
        const isOpening = this.isOpen && !this.isPulled
        return isOpening ? curveAt("back_out")(local) : curveAt("power_three_in_out")(local)
    }

    paint() {
        const width = this.width
        if (width <= 0) {
            return
        }
        const count = this.group.members.length
        const cell = Math.max(1, (width - gap * (columns - 1)) / columns)
        const height = this.cardHeight(cell)
        const shutScale = shutHeight / Math.max(1, height)
        const stackWidth = cell * shutScale + shift * (visibleLayers - 1)
        let reach = shutHeight
        this.cards.forEach((holder, index) => {
            const shown = this.progress(index)
            const layer = Math.min(index, visibleLayers - 1)
            const openX = (index % columns) * (cell + gap)
            const openY = headingHeight + Math.floor(index / columns) * (height + gap)
            const shutX = shift * layer
            const startScale = shutScale * (1 - shrink * layer)
            const shade = index >= visibleLayers ? 0 : 1 - darken * layer
            const x = shutX + (openX - shutX) * shown
            const y = openY * shown
            const scale = startScale + (1 - startScale) * shown
            const rotation = tiltDegrees * layer * (1 - shown)
            const alpha = shade + (1 - shade) * Math.min(1, Math.max(0, shown))
            holder.style.width = `${cell}px`
            holder.style.height = `${height}px`
            holder.style.transform = `translate(${x}px, ${y}px) rotate(${rotation}deg) scale(${scale})`
            holder.style.opacity = String(alpha)
            holder.style.zIndex = String(count - index)
            holder.style.pointerEvents = this.time >= 1 ? "auto" : "none"
            reach = Math.max(reach, y + height * scale)
        })
        const frameHeight = Math.max(shutHeight * (1 - Math.min(1, this.time)), reach)
        this.element.style.height = `${frameHeight}px`
        const arrowShown = Math.min(1, Math.max(0, this.time))
        const turn = Math.min(1, Math.max(0, (arrowShown - (1 - arrowTurn) / 2) / arrowTurn))
        const labelWidth = Math.max(0, width - stackWidth - labelGap)
        this.shutMask.style.width = `${labelWidth * (1 - arrowShown)}px`
        this.shutMask.style.transform = `translate(${stackWidth + labelGap}px, ${shutHeight / 2 - 22}px)`
        this.heading.style.opacity = String(arrowShown)
        this.heading.style.pointerEvents = this.time >= 1 ? "auto" : "none"
        this.heading.style.zIndex = String(count + 1)
        const arrowShutX = stackWidth + labelGap * 0.5 - arrowSize / 2
        const arrowOpenX = width - arrowSize
        const arrowX = arrowShutX + (arrowOpenX - arrowShutX) * arrowShown
        const arrowY = (shutHeight / 2 - arrowSize / 2) * (1 - arrowShown) + ((headingHeight - arrowSize) / 2) * arrowShown
        this.arrow.style.transform = `translate(${arrowX}px, ${arrowY}px)`
        this.arrow.firstElementChild.style.transform = `rotate(${180 * (1 - turn)}deg)`
        this.arrow.style.zIndex = String(count + 2)
        this.shutHit.hidden = this.time > 0
        this.shutHit.style.height = `${shutHeight}px`
        this.shutHit.style.zIndex = String(count + 1)
    }

    destroy() {
        this.resizeObserver.disconnect()
        this.running?.stop()
    }
}
