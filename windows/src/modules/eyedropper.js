import { create } from "./components.js"
import { duration } from "./motion.js"
import { popTogether } from "./pill.js"
import { glyph } from "./shapes.js"
import { isLight, tokens } from "./tokens.js"

const loupeLift = 64

export class ColorPickOverlay {
    constructor({ host, sample, onPick, onCancel }) {
        this.sample = sample
        this.onPick = onPick
        this.onCancel = onCancel
        this.color = null
        this.isFinished = false
        this.layer = create("div", "eyedropper-layer")
        this.loupe = create("div", "eyedropper-loupe", create("span", "eyedropper-cross"))
        this.label = create("span", "eyedropper-label")
        this.loupe.append(this.label)
        this.loupe.hidden = true
        const cancel = create("button", "eyedropper-cancel", glyph("close", { color: tokens.palette.text_body, size: 14 }))
        cancel.setAttribute("aria-label", "Cancel")
        cancel.addEventListener("pointerdown", (event) => event.stopPropagation())
        cancel.addEventListener("click", () => this.cancel())
        this.hint = create("div", "eyedropper-hint", glyph("eyedropper", { color: tokens.palette.accent, size: 16 }), create("span", "eyedropper-hint-text", "PICK A COLOUR FROM THE CANVAS"), cancel)
        this.layer.append(this.loupe, this.hint)
        host.append(this.layer)
        popTogether(this.hint, true)
        this.pointerId = null
        this.layer.addEventListener("pointerdown", (event) => this.down(event))
        this.layer.addEventListener("pointermove", (event) => this.move(event))
        this.layer.addEventListener("pointerup", (event) => this.up(event))
        this.layer.addEventListener("pointercancel", () => this.hideLoupe())
        this.layer.addEventListener("contextmenu", (event) => {
            event.preventDefault()
            this.cancel()
        })
        this.keydown = (event) => {
            if (event.key === "Escape") {
                event.stopImmediatePropagation()
                this.cancel()
            }
        }
        window.addEventListener("keydown", this.keydown, true)
    }

    showAt(point, isTouch) {
        const color = this.sample(point)
        this.color = color
        const wasHidden = this.loupe.hidden
        this.loupe.hidden = false
        this.loupe.style.left = `${point[0]}px`
        this.loupe.style.top = `${point[1] - (isTouch ? loupeLift : 0)}px`
        this.loupe.style.setProperty("--sample", color ?? "transparent")
        this.label.textContent = color ?? "—"
        this.label.style.color = color && isLight(color) ? tokens.palette.ground : tokens.palette.text_bright
        this.label.style.background = color ?? tokens.palette.sunken
        if (wasHidden) {
            popTogether(this.loupe, true)
        }
    }

    hideLoupe() {
        this.pointerId = null
        if (!this.loupe.hidden && !this.isFinished) {
            this.loupe.hidden = true
        }
    }

    down(event) {
        if (event.button > 0) {
            return
        }
        this.pointerId = event.pointerId
        this.layer.setPointerCapture(event.pointerId)
        this.showAt([event.clientX, event.clientY], event.pointerType !== "mouse")
    }

    move(event) {
        if (event.pointerType === "mouse" || event.pointerId === this.pointerId) {
            this.showAt([event.clientX, event.clientY], event.pointerType !== "mouse")
        }
    }

    up(event) {
        if (event.pointerId !== this.pointerId) {
            return
        }
        this.showAt([event.clientX, event.clientY], event.pointerType !== "mouse")
        if (this.color) {
            this.finish()
            this.onPick(this.color)
        } else {
            this.hideLoupe()
        }
    }

    cancel() {
        if (this.isFinished) {
            return
        }
        this.finish()
        this.onCancel?.()
    }

    finish() {
        this.isFinished = true
        window.removeEventListener("keydown", this.keydown, true)
        this.layer.style.pointerEvents = "none"
        const leaving = [this.hint]
        if (!this.loupe.hidden) {
            leaving.push(this.loupe)
        }
        Promise.all(leaving.map((element) => popTogether(element, false).finished.catch(() => {}))).then(() => this.layer.remove())
        setTimeout(() => this.layer.remove(), duration("state") * 3)
    }
}
