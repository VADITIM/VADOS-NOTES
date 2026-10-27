import { create } from "./components.js"
import { animate, duration, popInNow, popOut, tween } from "./motion.js"
import { navPlacement, setNavPlacement } from "./preferences.js"
import { glyph } from "./shapes.js"
import { tokens } from "./tokens.js"

const edgeMargin = 16
const defaultBottomGap = 24
const carryDiameter = 58
const carryTolerance = 10
const besideGap = 10
const clickSwallowWindowMilliseconds = 600
const childStaggerMilliseconds = 18

function cancelAnimations(element) {
    for (const animation of element.getAnimations()) {
        animation.cancel()
    }
}

function lerp(from, to, share) {
    return from + (to - from) * share
}

export function slideWash(wash, button, orientation, isAnimated) {
    if (!button) {
        wash.style.opacity = "0"
        wash.edges = null
        return
    }
    const track = wash.parentElement
    const isVertical = orientation === "vertical"
    const startName = isVertical ? "top" : "left"
    const endName = isVertical ? "bottom" : "right"
    const start = isVertical ? button.offsetTop : button.offsetLeft
    const length = isVertical ? button.offsetHeight : button.offsetWidth
    const total = isVertical ? track.clientHeight : track.clientWidth
    const next = { start, end: total - start - length }
    wash.style[isVertical ? "left" : "top"] = `${isVertical ? button.offsetLeft : button.offsetTop}px`
    wash.style[isVertical ? "right" : "bottom"] = `${isVertical ? track.clientWidth - button.offsetLeft - button.offsetWidth : track.clientHeight - button.offsetTop - button.offsetHeight}px`
    const computed = getComputedStyle(wash)
    const previous = wash.edges && wash.edges.orientation === orientation ? { start: parseFloat(computed[startName]), end: parseFloat(computed[endName]) } : null
    cancelAnimations(wash)
    wash.style[startName] = `${next.start}px`
    wash.style[endName] = `${next.end}px`
    wash.style.opacity = "1"
    wash.edges = { ...next, orientation }
    if (!isAnimated || !previous || (previous.start === next.start && previous.end === next.end)) {
        return
    }
    const isForward = next.start > previous.start
    const options = (delay) => ({ milliseconds: duration("nav_slide"), curveName: "power_two_out", delay })
    animate(wash, [{ [startName]: `${previous.start}px` }, { [startName]: `${next.start}px` }], options(isForward ? duration("nav_trail") : 0))
    animate(wash, [{ [endName]: `${previous.end}px` }, { [endName]: `${next.end}px` }], options(isForward ? 0 : duration("nav_trail")))
}

export function separator() {
    return create("span", "tool-nav-separator")
}

function navButton(item) {
    const icon = create("span", "tool-nav-glyph", glyph(item.glyph))
    const dot = create("span", "tool-nav-swatch")
    const button = create("button", "tool-nav-button pressable", icon, dot)
    button.type = "button"
    button.dataset.identifier = item.id
    button.setAttribute("aria-label", item.label ?? item.id)
    button.current = item
    button.addEventListener("click", (event) => {
        event.stopPropagation()
        if (button.disabled) {
            return
        }
        button.current.action?.(button)
    })
    return button
}

export class ToolNav {
    constructor(layer) {
        this.layer = layer
        this.element = create("nav", "tool-nav")
        this.grip = create("span", "tool-nav-grip", glyph("move", { color: tokens.palette.accent }))
        this.element.append(this.grip)
        this.layer.append(this.element)
        this.face = null
        this.signature = null
        this.selectedId = null
        this.isCarriable = false
        this.orientation = navPlacement()?.orientation === "vertical" ? "vertical" : "horizontal"
        this.element.classList.toggle("is-vertical", this.orientation === "vertical")
        this.size = null
        this.center = null
        this.motion = null
        this.carry = null
        this.hold = null
        this.isSwallowingClick = false
        this.subNav = null
        this.panel = null
        this.listenForCarry()
        new ResizeObserver(() => this.relayout()).observe(this.layer)
    }

    layerSize() {
        return { width: this.layer.clientWidth, height: this.layer.clientHeight }
    }

    show(kind, groups, { selectedId = null, isCarriable = false } = {}) {
        this.isCarriable = isCarriable
        const signature = `${kind}|${groups.map((group) => group.map((item) => item.id).join(",")).join("/")}`
        if (signature === this.signature) {
            this.updateFace(groups)
            this.select(selectedId, true)
            return
        }
        this.signature = signature
        this.closeSubNav()
        const outgoing = this.face
        const face = this.buildFace(groups)
        this.face = face
        this.element.append(face)
        this.selectedId = selectedId
        this.updateFace(groups)
        if (this.carry) {
            face.style.visibility = "hidden"
            outgoing?.remove()
            return
        }
        const target = this.measure(face)
        if (!outgoing || !this.size) {
            this.place(target, this.desiredCenter(target))
            this.select(selectedId, false)
            return
        }
        const state = duration("state")
        for (const child of outgoing.children) {
            if (!child.classList.contains("tool-nav-wash")) {
                cancelAnimations(child)
                popOut(child, state)
            }
        }
        animate(outgoing.querySelector(".tool-nav-wash"), [{ opacity: 1 }, { opacity: 0 }], { milliseconds: state, curveName: "power_two_in", fill: "forwards" })
        setTimeout(() => outgoing.remove(), state * 2)
        this.popFaceIn(face, state)
        this.morphTo(target, this.desiredCenter(target))
        this.select(selectedId, false)
        animate(face.querySelector(".tool-nav-wash"), [{ opacity: 0 }, { opacity: 0 }], { milliseconds: state * 2, curveName: "power_two_out" })
    }

    popFaceIn(face, delay) {
        for (const child of face.children) {
            if (!child.classList.contains("tool-nav-wash")) {
                cancelAnimations(child)
                popInNow(child, delay)
            }
        }
    }

    buildFace(groups) {
        const face = create("div", "tool-nav-track")
        face.append(create("span", "tool-nav-wash"))
        face.buttons = new Map()
        groups.filter((group) => group.length).forEach((group, index) => {
            if (index > 0) {
                face.append(separator())
            }
            for (const item of group) {
                const button = navButton(item)
                face.buttons.set(item.id, button)
                face.append(button)
            }
        })
        return face
    }

    updateFace(groups) {
        for (const item of groups.flat()) {
            const button = this.face.buttons.get(item.id)
            if (!button) {
                continue
            }
            button.current = item
            const isEnabled = item.isEnabled !== false
            button.disabled = !isEnabled
            button.classList.toggle("is-disabled", !isEnabled)
            const dot = button.querySelector(".tool-nav-swatch")
            dot.style.display = item.swatch ? "block" : "none"
            if (item.swatch) {
                dot.style.background = item.swatch
            }
        }
        this.paintSelection()
    }

    paintSelection() {
        if (!this.face) {
            return
        }
        for (const [id, button] of this.face.buttons) {
            const item = button.current
            const isSelected = id === this.selectedId
            button.classList.toggle("is-selected", isSelected)
            button.querySelector(".tool-nav-glyph").style.color = isSelected || item.isTinted ? item.tint ?? tokens.palette.text_bright : tokens.palette.text_body
        }
    }

    select(selectedId, isAnimated) {
        this.selectedId = selectedId
        this.paintSelection()
        if (!this.face) {
            return
        }
        slideWash(this.face.querySelector(".tool-nav-wash"), selectedId ? this.face.buttons.get(selectedId) : null, this.orientation, isAnimated)
    }

    button(id) {
        return this.face?.buttons.get(id) ?? null
    }

    measure(face) {
        return { width: face.offsetWidth, height: face.offsetHeight }
    }

    desiredCenter(size) {
        const layer = this.layerSize()
        const placement = navPlacement()
        if (placement && Number.isFinite(placement.x) && Number.isFinite(placement.y)) {
            return this.clampCenter({ x: placement.x * layer.width, y: placement.y * layer.height }, size)
        }
        return this.clampCenter({ x: layer.width / 2, y: layer.height - defaultBottomGap - size.height / 2 }, size)
    }

    clampCenter(center, size) {
        const layer = this.layerSize()
        const clamp = (value, half, total) => (total - edgeMargin * 2 < half * 2 ? total / 2 : Math.min(total - edgeMargin - half, Math.max(edgeMargin + half, value)))
        return { x: clamp(center.x, size.width / 2, layer.width), y: clamp(center.y, size.height / 2, layer.height) }
    }

    place(size, center) {
        this.size = size
        this.center = center
        this.element.style.width = `${size.width}px`
        this.element.style.height = `${size.height}px`
        this.element.style.left = `${center.x - size.width / 2}px`
        this.element.style.top = `${center.y - size.height / 2}px`
    }

    morphTo(size, center, { milliseconds = duration("state") * 2, follow = null } = {}) {
        this.motion?.stop()
        const fromSize = this.size ?? size
        const fromCenter = this.center ?? center
        this.motion = tween({
            milliseconds,
            curveName: "power_three_in_out",
            onFrame: (share) => {
                const goal = follow ? follow() : center
                this.place(
                    { width: lerp(fromSize.width, size.width, share), height: lerp(fromSize.height, size.height, share) },
                    { x: lerp(fromCenter.x, goal.x, share), y: lerp(fromCenter.y, goal.y, share) },
                )
                this.positionSubNav(false)
            },
            onDone: () => {
                this.motion = null
            },
        })
    }

    relayout() {
        if (!this.face || this.carry || this.motion) {
            return
        }
        const size = this.measure(this.face)
        this.place(size, this.desiredCenter(size))
        this.select(this.selectedId, false)
        this.positionSubNav(false)
    }

    setOrientation(orientation) {
        this.orientation = orientation
        this.element.classList.toggle("is-vertical", orientation === "vertical")
    }

    listenForCarry() {
        const element = this.element
        element.addEventListener("pointerdown", (event) => {
            if (!this.isCarriable || this.carry || (event.pointerType === "mouse" && event.button !== 0)) {
                return
            }
            clearTimeout(this.hold?.timer)
            this.hold = {
                pointerId: event.pointerId,
                start: [event.clientX, event.clientY],
                last: [event.clientX, event.clientY],
                timer: setTimeout(() => this.beginCarry(), duration("nav_carry_hold")),
            }
        }, true)
        element.addEventListener("pointermove", (event) => {
            if (this.hold && event.pointerId === this.hold.pointerId) {
                this.hold.last = [event.clientX, event.clientY]
                if (Math.hypot(event.clientX - this.hold.start[0], event.clientY - this.hold.start[1]) > carryTolerance) {
                    this.cancelHold()
                }
            }
            if (this.carry && event.pointerId === this.carry.pointerId) {
                this.carry.pointer = this.layerPoint(event.clientX, event.clientY)
                if (!this.motion) {
                    this.place(this.size, this.carry.pointer)
                }
            }
        })
        const finish = (event) => {
            if (this.hold && event.pointerId === this.hold.pointerId) {
                this.cancelHold()
            }
            if (this.carry && event.pointerId === this.carry.pointerId) {
                this.endCarry()
            }
        }
        element.addEventListener("pointerup", finish)
        element.addEventListener("pointercancel", finish)
        element.addEventListener("lostpointercapture", finish)
        element.addEventListener("click", (event) => {
            if (this.isSwallowingClick) {
                this.isSwallowingClick = false
                event.stopPropagation()
                event.preventDefault()
            }
        }, true)
    }

    cancelHold() {
        clearTimeout(this.hold?.timer)
        this.hold = null
    }

    layerPoint(clientX, clientY) {
        const rect = this.layer.getBoundingClientRect()
        return { x: clientX - rect.left, y: clientY - rect.top }
    }

    beginCarry() {
        const hold = this.hold
        this.hold = null
        if (!hold || !this.face) {
            return
        }
        this.closeSubNav()
        try {
            this.element.setPointerCapture(hold.pointerId)
        } catch {
            return
        }
        this.carry = { pointerId: hold.pointerId, pointer: this.layerPoint(hold.last[0], hold.last[1]) }
        this.isSwallowingClick = true
        this.element.classList.add("is-carried")
        const state = duration("state")
        for (const child of this.face.children) {
            if (!child.classList.contains("tool-nav-wash")) {
                cancelAnimations(child)
                popOut(child, state)
            }
        }
        animate(this.face.querySelector(".tool-nav-wash"), [{ opacity: 1 }, { opacity: 0 }], { milliseconds: state, curveName: "power_two_in", fill: "forwards" })
        cancelAnimations(this.grip)
        animate(this.grip, [{ opacity: 0, transform: "scale(0.001)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: state, curveName: "back_out", delay: state, fill: "both" })
        this.morphTo({ width: carryDiameter, height: carryDiameter }, this.carry.pointer, { follow: () => this.carry?.pointer ?? this.center })
    }

    endCarry() {
        const carry = this.carry
        if (!carry) {
            return
        }
        this.carry = null
        this.element.classList.remove("is-carried")
        setTimeout(() => {
            this.isSwallowingClick = false
        }, clickSwallowWindowMilliseconds)
        const layer = this.layerSize()
        const point = carry.pointer
        const sideDistance = Math.min(point.x, layer.width - point.x)
        const endDistance = Math.min(point.y, layer.height - point.y)
        this.setOrientation(sideDistance < endDistance ? "vertical" : "horizontal")
        const face = this.face
        face.style.visibility = ""
        const target = this.measure(face)
        const center = this.clampCenter(point, target)
        setNavPlacement({ x: center.x / Math.max(1, layer.width), y: center.y / Math.max(1, layer.height), orientation: this.orientation })
        const state = duration("state")
        cancelAnimations(this.grip)
        animate(this.grip, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.001)" }], { milliseconds: state, curveName: "back_in", fill: "forwards" })
        this.popFaceIn(face, state)
        const wash = face.querySelector(".tool-nav-wash")
        cancelAnimations(wash)
        wash.edges = null
        this.select(this.selectedId, false)
        animate(wash, [{ opacity: 0 }, { opacity: 0 }], { milliseconds: state * 2, curveName: "power_two_out" })
        this.morphTo(target, center)
    }

    outwardSide() {
        const layer = this.layerSize()
        const center = this.center ?? { x: layer.width / 2, y: layer.height }
        if (this.orientation === "vertical") {
            return center.x > layer.width / 2 ? "left" : "right"
        }
        return center.y > layer.height / 2 ? "up" : "down"
    }

    besideRect(anchor, size, side) {
        const layerRect = this.layer.getBoundingClientRect()
        const anchorCenter = { x: anchor.left + anchor.width / 2 - layerRect.left, y: anchor.top + anchor.height / 2 - layerRect.top }
        let center
        switch (side) {
        case "up":
            center = { x: anchorCenter.x, y: anchor.top - layerRect.top - besideGap - size.height / 2 }
            break
        case "down":
            center = { x: anchorCenter.x, y: anchor.bottom - layerRect.top + besideGap + size.height / 2 }
            break
        case "left":
            center = { x: anchor.left - layerRect.left - besideGap - size.width / 2, y: anchorCenter.y }
            break
        default:
            center = { x: anchor.right - layerRect.left + besideGap + size.width / 2, y: anchorCenter.y }
            break
        }
        return this.clampCenter(center, size)
    }

    openSubNav({ key, anchorId, children, onClose }) {
        this.closeSubNav()
        const anchor = this.button(anchorId)
        if (!anchor) {
            return
        }
        const track = create("div", "tool-nav-track", ...children)
        const panel = create("div", `tool-subnav${this.orientation === "vertical" ? " is-vertical" : ""}`, track)
        this.layer.append(panel)
        this.subNav = { key, anchorId, panel, track, onClose, size: null }
        this.positionSubNav(false)
        const side = this.outwardSide()
        panel.style.transformOrigin = { up: "center bottom", down: "center top", left: "right center", right: "left center" }[side]
        animate(panel, [{ opacity: 0, transform: "scale(0.6)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("state"), curveName: "back_out" })
        children.forEach((child, index) => popInNow(child, index * childStaggerMilliseconds))
        const observer = new ResizeObserver(() => {
            if (this.subNav?.panel === panel) {
                this.positionSubNav(true)
            }
        })
        observer.observe(track)
        this.subNav.observer = observer
    }

    positionSubNav(isAnimated) {
        const subNav = this.subNav
        if (!subNav) {
            return
        }
        const anchor = this.button(subNav.anchorId)
        if (!anchor) {
            return
        }
        const size = { width: subNav.track.offsetWidth, height: subNav.track.offsetHeight }
        const center = this.besideRect(this.element.getBoundingClientRect(), size, this.outwardSide())
        const anchorRect = anchor.getBoundingClientRect()
        const layerRect = this.layer.getBoundingClientRect()
        const aligned = this.orientation === "vertical"
            ? this.clampCenter({ x: center.x, y: anchorRect.top + anchorRect.height / 2 - layerRect.top }, size)
            : this.clampCenter({ x: anchorRect.left + anchorRect.width / 2 - layerRect.left, y: center.y }, size)
        const apply = (nextSize, nextCenter) => {
            subNav.size = nextSize
            subNav.center = nextCenter
            subNav.panel.style.width = `${nextSize.width}px`
            subNav.panel.style.height = `${nextSize.height}px`
            subNav.panel.style.left = `${nextCenter.x - nextSize.width / 2}px`
            subNav.panel.style.top = `${nextCenter.y - nextSize.height / 2}px`
            this.positionPanel()
        }
        subNav.motion?.stop()
        if (!isAnimated || !subNav.size) {
            apply(size, aligned)
            return
        }
        const fromSize = subNav.size
        const fromCenter = subNav.center
        subNav.motion = tween({
            milliseconds: duration("state"),
            curveName: "power_three_in_out",
            onFrame: (share) => apply(
                { width: lerp(fromSize.width, size.width, share), height: lerp(fromSize.height, size.height, share) },
                { x: lerp(fromCenter.x, aligned.x, share), y: lerp(fromCenter.y, aligned.y, share) },
            ),
        })
    }

    isSubNavOpen(key) {
        return this.subNav?.key === key
    }

    closeSubNav() {
        this.closePanel()
        const subNav = this.subNav
        if (!subNav) {
            return
        }
        this.subNav = null
        subNav.motion?.stop()
        subNav.observer.disconnect()
        subNav.onClose?.()
        subNav.panel.style.pointerEvents = "none"
        animate(subNav.panel, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.6)" }], {
            milliseconds: duration("overlay_leave"),
            curveName: "back_in",
            fill: "forwards",
        }).finished.then(() => subNav.panel.remove()).catch(() => subNav.panel.remove())
    }

    openPanel(element, anchor) {
        this.closePanel()
        this.layer.append(element)
        this.panel = { element, anchor }
        this.positionPanel()
        const side = this.outwardSide()
        element.style.transformOrigin = { up: "center bottom", down: "center top", left: "right center", right: "left center" }[side]
        animate(element, [{ opacity: 0, transform: "scale(0.8)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("overlay_enter"), curveName: "back_out" })
    }

    positionPanel() {
        const panel = this.panel
        if (!panel || !this.subNav) {
            return
        }
        const size = { width: panel.element.offsetWidth, height: panel.element.offsetHeight }
        const subNavRect = this.subNav.panel.getBoundingClientRect()
        const anchorRect = panel.anchor.getBoundingClientRect()
        const layerRect = this.layer.getBoundingClientRect()
        const side = this.outwardSide()
        const outward = this.besideRect(subNavRect, size, side)
        const center = this.orientation === "vertical"
            ? this.clampCenter({ x: outward.x, y: anchorRect.top + anchorRect.height / 2 - layerRect.top }, size)
            : this.clampCenter({ x: anchorRect.left + anchorRect.width / 2 - layerRect.left, y: outward.y }, size)
        panel.element.style.left = `${center.x - size.width / 2}px`
        panel.element.style.top = `${center.y - size.height / 2}px`
    }

    isPanelOpen() {
        return Boolean(this.panel)
    }

    closePanel() {
        const panel = this.panel
        if (!panel) {
            return
        }
        this.panel = null
        panel.element.style.pointerEvents = "none"
        animate(panel.element, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: "scale(0.8)" }], {
            milliseconds: duration("overlay_leave"),
            curveName: "power_two_in",
            fill: "forwards",
        }).finished.then(() => panel.element.remove()).catch(() => panel.element.remove())
    }
}
