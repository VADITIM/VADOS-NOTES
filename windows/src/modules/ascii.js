import { create } from "./components.js"
import { monoFamily } from "./renderer.js"
import { backgroundArt } from "./storage.js"
import { tokens } from "./tokens.js"

export class AsciiBackground {
    constructor() {
        this.element = create("div", "ascii-background")
        this.pattern = create("div", "ascii-pattern")
        this.element.append(this.pattern)
        this.art = ""
        this.color = null
        this.isMoving = null
        this.tileSize = [0, 0]
        this.drift = null
        this.reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)")
        backgroundArt().then((text) => {
            this.art = text.replace(/^\n+|\n+$/g, "")
            const color = this.color
            this.color = null
            if (color) {
                this.update({ color, opacity: this.opacity, isMoving: this.wantsMoving })
            }
        })
        window.addEventListener("resize", () => this.layout())
    }

    update({ color, opacity, isMoving }) {
        this.opacity = opacity
        this.wantsMoving = isMoving
        this.element.style.opacity = String(opacity)
        const upper = color.toUpperCase()
        if (upper !== this.color && this.art) {
            this.color = upper
            this.renderTile(upper)
            this.layout()
        } else if (!this.art) {
            this.color = upper
        }
        const moving = isMoving && !this.reducedMotion.matches
        if (moving !== this.isMoving) {
            this.isMoving = moving
            this.restartDrift()
        }
    }

    renderTile(color) {
        const background = tokens.background
        const gap = background.gap
        const lines = this.art.split("\n")
        const ratio = window.devicePixelRatio || 1
        const measuring = document.createElement("canvas").getContext("2d")
        const font = `${background.font_size}px ${monoFamily}`
        measuring.font = font
        const metrics = measuring.measureText("Hg")
        const lineHeight = (metrics.fontBoundingBoxAscent + metrics.fontBoundingBoxDescent) || background.font_size * 1.48
        const width = Math.max(...lines.map((line) => measuring.measureText(line).width))
        const tileWidth = Math.ceil(width + gap)
        const tileHeight = Math.ceil(lines.length * lineHeight + gap)
        this.tileSize = [tileWidth, tileHeight]
        const canvas = document.createElement("canvas")
        canvas.width = Math.ceil(tileWidth * ratio)
        canvas.height = Math.ceil(tileHeight * 2 * ratio)
        const context = canvas.getContext("2d")
        context.scale(ratio, ratio)
        context.font = font
        context.fillStyle = color
        context.textBaseline = "top"
        const shift = tileWidth * background.row_shift
        const draw = (x, y) => lines.forEach((line, index) => context.fillText(line, x, y + index * lineHeight))
        draw(gap / 2, gap / 2)
        for (const x of [shift, shift - tileWidth]) {
            draw(gap / 2 + x, tileHeight + gap / 2)
        }
        this.pattern.style.backgroundImage = `url(${canvas.toDataURL()})`
        this.pattern.style.backgroundSize = `${tileWidth}px ${tileHeight * 2}px`
    }

    layout() {
        if (!this.tileSize[0]) {
            return
        }
        const width = window.innerWidth
        const height = window.innerHeight
        const reach = Math.hypot(width, height) + Math.max(this.tileSize[0], this.tileSize[1] * 2) * 2
        this.pattern.style.width = `${reach}px`
        this.pattern.style.height = `${reach}px`
        this.pattern.style.left = `${(width - reach) / 2}px`
        this.pattern.style.top = `${(height - reach) / 2}px`
        this.pattern.style.rotate = `${tokens.background.angle_degrees}deg`
        this.restartDrift()
    }

    restartDrift() {
        this.drift?.cancel()
        this.drift = null
        if (!this.isMoving || !this.tileSize[0] || tokens.background.speed <= 0) {
            return
        }
        const angle = (tokens.background.angle_degrees * Math.PI) / 180
        const distance = this.tileSize[0]
        this.drift = this.pattern.animate([{ translate: "0px 0px" }, { translate: `${distance * Math.cos(angle)}px ${distance * Math.sin(angle)}px` }], {
            duration: (distance / tokens.background.speed) * 1000,
            iterations: Infinity,
            easing: "linear",
        })
    }
}
