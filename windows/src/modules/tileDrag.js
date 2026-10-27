import { animate, duration } from "./motion.js"

const dragTolerance = 8
const clickSwallowMilliseconds = 400
const edgeScrollZone = 72
const edgeScrollSpeed = 16
const liftScale = 1.04

export function tileGestures(element, { onTap, onMenu, onDrag }) {
    let press = null
    let isConsumed = false
    let swallowUntil = 0
    const release = () => {
        clearTimeout(press?.timer)
        press = null
    }
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) {
            return
        }
        release()
        isConsumed = false
        press = { pointerId: event.pointerId, isMouse: event.pointerType === "mouse", start: [event.clientX, event.clientY], isHeld: false }
        press.timer = setTimeout(() => {
            if (!press) {
                return
            }
            press.isHeld = true
            isConsumed = true
            onMenu(element.getBoundingClientRect())
        }, duration("menu_hold"))
    })
    element.addEventListener("pointermove", (event) => {
        if (!press || event.pointerId !== press.pointerId) {
            return
        }
        if (Math.hypot(event.clientX - press.start[0], event.clientY - press.start[1]) <= dragTolerance) {
            return
        }
        const current = press
        release()
        if (current.isMouse || current.isHeld) {
            isConsumed = true
            onDrag(event)
        }
    })
    element.addEventListener("touchmove", (event) => {
        if (press?.isHeld || isConsumed) {
            event.preventDefault()
        }
    }, { passive: false })
    const finish = () => {
        release()
        if (isConsumed) {
            isConsumed = false
            swallowUntil = performance.now() + clickSwallowMilliseconds
        }
    }
    element.addEventListener("pointerup", finish)
    element.addEventListener("pointercancel", finish)
    element.addEventListener("contextmenu", (event) => {
        event.preventDefault()
        release()
        onMenu(element.getBoundingClientRect())
    })
    element.addEventListener("click", (event) => {
        event.stopPropagation()
        if (performance.now() < swallowUntil) {
            return
        }
        onTap()
    })
    return element
}

function ghostOf(source) {
    const ghost = source.cloneNode(true)
    const originals = source.querySelectorAll("canvas")
    ghost.querySelectorAll("canvas").forEach((copy, index) => {
        const original = originals[index]
        copy.width = original.width
        copy.height = original.height
        copy.getContext("2d").drawImage(original, 0, 0)
    })
    return ghost
}

function rectsOf(elements) {
    return new Map(elements.map((element) => [element, element.getBoundingClientRect()]))
}

export class TileDrag {
    constructor({ wrapper, handle, event, scroller, resolve, onDrop }) {
        this.wrapper = wrapper
        this.handle = handle
        this.scroller = scroller
        this.resolve = resolve
        this.onDrop = onDrop
        this.pointerId = event.pointerId
        this.pointer = [event.clientX, event.clientY]
        this.target = null
        this.highlighted = null
        const rect = handle.getBoundingClientRect()
        this.grab = [event.clientX - rect.left, event.clientY - rect.top]
        this.ghost = ghostOf(handle)
        this.ghost.classList.add("drag-ghost")
        this.ghost.style.width = `${rect.width}px`
        this.ghost.style.height = `${rect.height}px`
        document.body.append(this.ghost)
        this.placeGhost()
        animate(this.ghost, [{ scale: "1" }, { scale: String(liftScale) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        wrapper.classList.add("is-drag-source")
        handle.setPointerCapture(this.pointerId)
        this.move = (moveEvent) => {
            if (moveEvent.pointerId === this.pointerId) {
                this.pointer = [moveEvent.clientX, moveEvent.clientY]
                this.placeGhost()
                this.track()
            }
        }
        this.up = (upEvent) => {
            if (upEvent.pointerId === this.pointerId) {
                this.end(upEvent.type === "pointerup")
            }
        }
        window.addEventListener("pointermove", this.move)
        window.addEventListener("pointerup", this.up)
        window.addEventListener("pointercancel", this.up)
        this.scrollFrame = requestAnimationFrame(() => this.edgeScroll())
        this.track()
    }

    placeGhost() {
        this.ghost.style.left = `${this.pointer[0] - this.grab[0]}px`
        this.ghost.style.top = `${this.pointer[1] - this.grab[1]}px`
    }

    edgeScroll() {
        const rect = this.scroller.getBoundingClientRect()
        const top = rect.top + edgeScrollZone
        const bottom = rect.bottom - edgeScrollZone
        let speed = 0
        if (this.pointer[1] < top) {
            speed = -edgeScrollSpeed * Math.min(1, (top - this.pointer[1]) / edgeScrollZone)
        } else if (this.pointer[1] > bottom) {
            speed = edgeScrollSpeed * Math.min(1, (this.pointer[1] - bottom) / edgeScrollZone)
        }
        if (speed) {
            const before = this.scroller.scrollTop
            this.scroller.scrollTop += speed
            if (this.scroller.scrollTop !== before) {
                this.track()
            }
        }
        this.scrollFrame = requestAnimationFrame(() => this.edgeScroll())
    }

    track() {
        const target = this.resolve(this.pointer[0], this.pointer[1])
        this.target = target
        const highlight = target && (target.kind === "into" || target.kind === "up") ? target.element : null
        if (highlight !== this.highlighted) {
            this.highlighted?.classList.remove("is-drop-target")
            highlight?.classList.add("is-drop-target")
            this.highlighted = highlight
        }
        if (target?.kind === "before" || target?.kind === "after") {
            this.reorder(target.element, target.kind === "after")
        }
    }

    reorder(element, isAfter) {
        const grid = this.wrapper.parentElement
        if (!grid || element.parentElement !== grid || element === this.wrapper) {
            return
        }
        const adjacent = isAfter ? element.nextElementSibling : element.previousElementSibling
        if (adjacent === this.wrapper) {
            return
        }
        const siblings = [...grid.children]
        const before = rectsOf(siblings)
        if (isAfter) {
            element.after(this.wrapper)
        } else {
            element.before(this.wrapper)
        }
        for (const sibling of siblings) {
            const from = before.get(sibling)
            const to = sibling.getBoundingClientRect()
            const deltaX = from.left - to.left
            const deltaY = from.top - to.top
            if (deltaX || deltaY) {
                animate(sibling, [{ translate: `${deltaX}px ${deltaY}px` }, { translate: "0px 0px" }], { milliseconds: duration("nav_slide"), curveName: "power_two_out" })
            }
        }
    }

    end(isDrop) {
        cancelAnimationFrame(this.scrollFrame)
        window.removeEventListener("pointermove", this.move)
        window.removeEventListener("pointerup", this.up)
        window.removeEventListener("pointercancel", this.up)
        this.highlighted?.classList.remove("is-drop-target")
        const target = isDrop ? this.target : null
        const ghost = this.ghost
        const wrapper = this.wrapper
        const ghostRect = ghost.getBoundingClientRect()
        if (target && (target.kind === "into" || target.kind === "up")) {
            const goal = target.element.getBoundingClientRect()
            const deltaX = goal.left + goal.width / 2 - (ghostRect.left + ghostRect.width / 2)
            const deltaY = goal.top + goal.height / 2 - (ghostRect.top + ghostRect.height / 2)
            animate(ghost, [{ translate: "0px 0px", scale: String(liftScale), opacity: 1 }, { translate: `${deltaX}px ${deltaY}px`, scale: "0.2", opacity: 0 }], { milliseconds: duration("state"), curveName: "power_two_in", fill: "forwards" })
                .finished.then(() => ghost.remove()).catch(() => ghost.remove())
            this.onDrop(target)
            wrapper.classList.remove("is-drag-source")
            return
        }
        const home = this.handle.getBoundingClientRect()
        animate(ghost, [{ translate: "0px 0px", scale: String(liftScale) }, { translate: `${home.left - ghostRect.left}px ${home.top - ghostRect.top}px`, scale: "1" }], { milliseconds: duration("state"), curveName: "power_two_out", fill: "forwards" })
            .finished.then(() => {
                ghost.remove()
                wrapper.classList.remove("is-drag-source")
            }).catch(() => {
                ghost.remove()
                wrapper.classList.remove("is-drag-source")
            })
        this.onDrop(isDrop ? { kind: "arrange" } : null)
    }
}
