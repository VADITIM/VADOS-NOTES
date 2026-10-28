import { create } from "./components.js"
import { KeyedList, itemSize, navMetrics, navSizeSlider, separator, separatorExtent } from "./controls.js"
import { animate, duration, tween } from "./motion.js"
import { PillMotion, hideTurned, popTogether, revealElement, shapePillShell, spring, springAnimate } from "./pill.js"
import { navPlacement, setNavPlacement } from "./preferences.js"
import { glyph } from "./shapes.js"
import { tokens } from "./tokens.js"

const swallowMilliseconds = 600

function along(size, orientation) {
    return orientation === "horizontal" ? size[0] : size[1]
}

function rectFrom(center, size) {
    return { x: center[0] - size[0] / 2, y: center[1] - size[1] / 2, width: size[0], height: size[1] }
}

function intersects(first, second) {
    return first.x < second.x + second.width && second.x < first.x + first.width && first.y < second.y + second.height && second.y < first.y + first.height
}

function inset(rect, amount) {
    return { x: rect.x + amount, y: rect.y + amount, width: rect.width - amount * 2, height: rect.height - amount * 2 }
}

class SpringPoint {
    constructor(onFrame) {
        this.onFrame = onFrame
        this.value = null
        this.target = null
        this.velocity = [0, 0]
        this.request = null
    }

    set(target, isAnimated) {
        this.target = target
        if (!this.value || !isAnimated) {
            cancelAnimationFrame(this.request)
            this.request = null
            this.value = [...target]
            this.velocity = [0, 0]
            this.onFrame(this.value)
            return
        }
        if (!this.request) {
            this.last = performance.now()
            this.request = requestAnimationFrame((now) => this.step(now))
        }
    }

    step(now) {
        const { response, damping_fraction: damping } = tokens.motion.springs.placement
        const stiffness = Math.pow((2 * Math.PI) / response, 2)
        const friction = (4 * Math.PI * damping) / response
        let remaining = Math.min(0.05, (now - this.last) / 1000)
        this.last = now
        while (remaining > 0) {
            const step = Math.min(remaining, 1 / 240)
            for (const axis of [0, 1]) {
                const force = -stiffness * (this.value[axis] - this.target[axis]) - friction * this.velocity[axis]
                this.velocity[axis] += force * step
                this.value[axis] += this.velocity[axis] * step
            }
            remaining -= step
        }
        const isResting = Math.hypot(this.value[0] - this.target[0], this.value[1] - this.target[1]) < 0.3 && Math.hypot(...this.velocity) < 2
        if (isResting) {
            this.value = [...this.target]
            this.velocity = [0, 0]
            this.request = null
        } else {
            this.request = requestAnimationFrame((time) => this.step(time))
        }
        this.onFrame(this.value)
    }
}

class PillBody {
    constructor(className) {
        this.element = create("div", `pill-body ${className}`)
        this.shell = create("div", "pill-shell")
        this.content = create("div", "pill-content")
        this.element.append(this.shell, this.content)
        this.size = [0, 0]
        this.shownSize = null
        this.sizeTween = null
        this.motion = new PillMotion(() => this.paint())
        this.isWide = true
    }

    measure() {
        this.content.style.width = ""
        this.content.style.height = ""
        return [this.content.offsetWidth, this.content.offsetHeight]
    }

    resize(isAnimated) {
        const next = this.measure()
        const isChanged = Math.abs(next[0] - this.size[0]) > 0.5 || Math.abs(next[1] - this.size[1]) > 0.5
        this.size = next
        if (!this.shownSize || !isAnimated) {
            this.sizeTween?.stop()
            this.shownSize = [...next]
        } else if (isChanged) {
            const from = [...this.shownSize]
            this.sizeTween?.stop()
            this.sizeTween = tween({
                milliseconds: duration("navigation_switch") * 2,
                curveName: "power_three_in_out",
                onFrame: (eased) => {
                    this.shownSize = [from[0] + (next[0] - from[0]) * eased, from[1] + (next[1] - from[1]) * eased]
                    this.paint()
                },
            })
        }
        this.paint()
        return next
    }

    paint() {
        const [width, height] = this.shownSize ?? this.size
        const offsetX = (this.size[0] - width) / 2
        const offsetY = (this.size[1] - height) / 2
        shapePillShell(this.shell, { width, height, isWide: this.isWide, scale: this.motion.shellScale, spread: this.motion.shellSpread })
        this.shell.style.left = `${parseFloat(this.shell.style.left) + offsetX}px`
        this.shell.style.top = `${parseFloat(this.shell.style.top) + offsetY}px`
        this.element.style.visibility = this.motion.isPresent ? "visible" : "hidden"
        this.element.classList.toggle("is-interactive", this.motion.areElementsShown)
    }
}

export class ToolNav {
    constructor(layer) {
        this.layer = layer
        this.props = null
        this.orientation = navPlacement()?.orientation === "vertical" ? "vertical" : "horizontal"
        this.placement = navPlacement()
        this.carryPoint = null
        this.carryGrab = null
        this.swallowUntil = 0
        this.toolReordering = null
        this.groupReordering = null
        this.sizingDrag = null
        this.edgeOffset = 0
        this.isEdgeHidden = false
        this.shownSubNavigationKey = null
        this.shownPillPanelKey = null
        this.shownWheelKey = null
        this.lastFace = null
        this.lastSelectedId = undefined

        this.navigation = new PillBody("navigation")
        this.navigation.element.addEventListener("pointerdown", (event) => this.navPointerDown(event))
        this.navigation.element.addEventListener("pointermove", (event) => this.navPointerMove(event))
        this.navigation.element.addEventListener("pointerup", (event) => this.navPointerUp(event))
        this.navigation.element.addEventListener("pointercancel", (event) => this.navPointerUp(event))
        this.navigation.element.addEventListener("click", (event) => {
            if (performance.now() < this.swallowUntil) {
                event.stopPropagation()
                event.preventDefault()
            }
        }, true)
        this.wash = create("span", "navigation-wash")
        this.navigation.content.append(this.wash)
        this.startGrip = this.makeGrip()
        this.endGrip = this.makeGrip()
        this.navigation.content.append(this.startGrip, this.endGrip)
        this.items = new KeyedList(this.navigation.content, {
            make: (entry) => (entry.isSeparator ? separator(this.orientation) : this.makeItem(entry.item)),
            update: (element, entry) => {
                if (!entry.isSeparator) {
                    element.item = entry.item
                    this.paintItem(element)
                }
            },
            isRevealed: () => this.navigation.motion.areElementsShown,
        })
        this.navigation.motion.onElements = (shown, isInstant) => {
            for (const element of [...this.items.elements.values(), this.startGrip, this.endGrip]) {
                if (isInstant) {
                    hideTurned(element)
                } else {
                    element.style.opacity = ""
                    revealElement(element, shown)
                }
            }
        }
        this.slider = null

        this.subNavigation = new PillBody("sub-navigation")
        this.subNavigation.element.addEventListener("click", (event) => {
            if (performance.now() < this.swallowUntil) {
                event.stopPropagation()
                event.preventDefault()
            }
        }, true)
        this.groupElements = new Map()
        this.subNavigation.motion.onElements = (shown, isInstant) => {
            for (const element of this.subNavigation.content.querySelectorAll("[data-revealed-element]")) {
                if (isInstant) {
                    hideTurned(element)
                } else {
                    element.style.opacity = ""
                    revealElement(element, shown)
                }
            }
        }

        this.pillPanel = new PillBody("pill-panel")
        this.pillPanel.motion.onElements = (shown, isInstant) => {
            for (const element of this.pillPanel.content.firstElementChild?.revealTargets?.() ?? []) {
                if (isInstant) {
                    hideTurned(element)
                } else {
                    element.style.opacity = ""
                    revealElement(element, shown)
                }
            }
        }

        this.wheelHost = create("div", "wheel-host")
        this.edgeStrip = create("div", "edge-strip", create("span", "edge-handle"))
        this.edgeStrip.hidden = true
        this.bindEdgeStrip()
        this.layer.append(this.subNavigation.element, this.wheelHost, this.pillPanel.element, this.navigation.element, this.edgeStrip)

        this.navigationCenter = new SpringPoint((value) => this.placeNavigation(value))
        this.subNavigationCenter = new SpringPoint((value) => placeAt(this.subNavigation.element, value, this.subNavigation.size))
        this.panelCenter = new SpringPoint((value) => {
            placeAt(this.pillPanel.element, value, this.pillPanel.size)
            placeAt(this.wheelHost, value, [this.wheelHost.offsetWidth, this.wheelHost.offsetHeight])
        })
        window.addEventListener("resize", () => this.layout(false))
        this.applyOrientationClasses()
    }

    applyOrientationClasses() {
        const isVertical = this.orientation === "vertical"
        for (const body of [this.navigation, this.subNavigation, this.pillPanel]) {
            body.element.classList.toggle("is-vertical", isVertical)
            body.content.classList.toggle("is-vertical", isVertical)
        }
    }

    makeGrip() {
        const grip = create("span", "navigation-grip")
        grip.addEventListener("pointerdown", (event) => this.gripDown(event))
        return grip
    }

    makeItem(item) {
        const [width, height] = itemSize(this.orientation)
        const button = create("button", "navigation-item")
        button.style.width = `${width}px`
        button.style.height = `${height}px`
        button.item = item
        button.addEventListener("click", () => {
            if (performance.now() < this.swallowUntil || button.disabled) {
                return
            }
            button.item.action(button.getBoundingClientRect())
        })
        button.addEventListener("pointerdown", (event) => this.itemPointerDown(event, button))
        this.paintItem(button)
        pressPop(button)
        return button
    }

    paintItem(button) {
        const item = button.item
        const isSelected = item.id === this.props?.selectedId
        const color = isSelected || item.isTinted ? item.tint : tokens.palette.text_body
        const signature = JSON.stringify([item.glyph, item.caption, color, item.swatch, isSelected, item.isEnabled])
        if (button.dataset.signature === signature) {
            return
        }
        button.dataset.signature = signature
        button.replaceChildren()
        if (item.caption !== undefined && item.caption !== null) {
            const caption = create("span", "navigation-caption", item.caption)
            caption.style.color = color
            button.append(caption)
        } else {
            const icon = glyph(item.glyph, { color, size: navMetrics.glyphSize })
            icon.classList.toggle("is-selected", isSelected)
            button.append(icon)
        }
        if (item.swatch) {
            const dot = create("span", "navigation-swatch")
            dot.style.background = item.swatch
            button.append(dot)
        }
        button.disabled = item.isEnabled === false
        button.classList.toggle("is-disabled", item.isEnabled === false)
        button.setAttribute("aria-label", item.label)
    }

    update(props) {
        const previous = this.props
        this.props = props
        const isFaceChange = previous && previous.face !== props.face
        this.syncItems(isFaceChange)
        if (!previous || previous.isShown !== props.isShown) {
            if (props.isShown) {
                this.navigation.motion.enter()
            } else {
                this.navigation.motion.leave()
            }
        }
        const isWanted = props.subNavKey !== null && props.isShown
        const wasWanted = Boolean(previous && previous.subNavKey !== null && previous.isShown)
        if (isWanted && !wasWanted) {
            this.shownSubNavigationKey = props.subNavKey
            this.syncGroups(false)
            this.subNavigation.motion.enter()
        } else if (!isWanted && wasWanted) {
            this.subNavigation.motion.leave(() => {
                this.shownSubNavigationKey = null
                if (this.isEdgeHidden) {
                    this.showFromEdge()
                }
                this.layout(false)
            })
        } else if (isWanted) {
            const isSwitch = this.shownSubNavigationKey !== props.subNavKey
            this.shownSubNavigationKey = props.subNavKey
            this.syncGroups(isSwitch)
        }
        if (this.shownSubNavigationKey && !isWanted) {
            this.syncGroups(false)
        }
        this.syncPanels(isWanted)
        this.layout(true)
    }

    entries() {
        const groups = this.props.groups
        const entries = []
        groups.forEach((group, index) => {
            if (!group.length) {
                return
            }
            if (entries.length) {
                entries.push({ key: `separator-${this.props.face}-${index}`, isSeparator: true })
            }
            const ordered = index === 0 && this.toolReordering ? this.toolReordering.start.map((id) => group.find((item) => item.id === id)).filter(Boolean) : group
            ordered.forEach((item) => entries.push({ key: item.id, item }))
        })
        return entries
    }

    syncItems(isFaceChange) {
        const before = this.navigation.content.getBoundingClientRect()
        this.items.sync(this.entries(), { isSwitch: true })
        this.navigation.content.append(this.endGrip)
        this.navigation.content.prepend(this.startGrip)
        this.navigation.content.prepend(this.wash)
        for (const element of this.items.elements.values()) {
            if (element.item) {
                this.paintItem(element)
            }
        }
        this.navigation.isWide = this.orientation === "horizontal"
        this.navigation.resize(Boolean(isFaceChange))
        this.moveWash(before)
        this.syncSlider()
    }

    moveWash() {
        const selectedId = this.props.selectedId
        const target = selectedId ? this.items.elements.get(selectedId) : null
        if (!target || !this.navigation.motion.isPresent) {
            this.wash.style.opacity = target ? "1" : "0"
            if (target) {
                this.positionWash(target)
            }
            this.lastSelectedId = selectedId
            return
        }
        const from = { left: this.wash.offsetLeft, top: this.wash.offsetTop }
        const isVisible = this.wash.style.opacity === "1"
        this.positionWash(target)
        this.wash.style.opacity = "1"
        if (isVisible && this.lastSelectedId !== selectedId) {
            const deltaX = from.left - this.wash.offsetLeft
            const deltaY = from.top - this.wash.offsetTop
            springAnimate(this.wash, [{ translate: `${deltaX}px ${deltaY}px` }, { translate: "0px 0px" }], "wash")
        }
        this.lastSelectedId = selectedId
    }

    positionWash(target) {
        this.wash.style.left = `${target.offsetLeft}px`
        this.wash.style.top = `${target.offsetTop}px`
        this.wash.style.width = `${target.offsetWidth}px`
        this.wash.style.height = `${target.offsetHeight}px`
    }

    sizableItem() {
        const items = this.props.groups.flat()
        if (this.props.selectedId) {
            return items.find((item) => item.id === this.props.selectedId && item.sizing) ?? null
        }
        return items.find((item) => item.sizing) ?? null
    }

    syncSlider() {
        const item = this.sizingDrag ? this.props.groups.flat().find((candidate) => candidate.id === this.sizingDrag.id) : null
        if (item?.sizing) {
            if (!this.slider) {
                this.slider = navSizeSlider(this.orientation)
                this.navigation.element.append(this.slider)
                animate(this.slider, [{ opacity: 0, transform: `scale(${tokens.motion.scales.slider_enter})` }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("overlay_leave"), curveName: "power_two_out", delay: duration("press") })
                animate(this.navigation.content, [{ opacity: 1, transform: "scale(1)" }, { opacity: 0, transform: `scale(${tokens.motion.scales.slider_enter})` }], { milliseconds: duration("press"), curveName: "power_two_in", fill: "forwards" })
            }
            const sizing = item.sizing
            this.slider.style.width = `${this.navigation.size[0] - navMetrics.padding * 2}px`
            this.slider.style.height = `${this.navigation.size[1] - navMetrics.padding * 2}px`
            this.slider.update({ share: sizing.share, color: sizing.color, diameter: sizing.previewDiameter(sizing.share), text: sizing.caption(sizing.share) })
        } else if (this.slider) {
            const slider = this.slider
            this.slider = null
            animate(slider, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("press"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => slider.remove())
            this.navigation.content.getAnimations().forEach((running) => running.cancel())
            animate(this.navigation.content, [{ opacity: 0, transform: `scale(${tokens.motion.scales.slider_enter})` }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("state"), curveName: "power_two_out", delay: duration("press") })
        }
    }

    groupList() {
        const groups = this.props.subNavigationGroups
        if (!this.groupReordering) {
            return groups
        }
        return this.groupReordering.start.map((id) => groups.find((group) => group.id === id)).filter(Boolean)
    }

    syncGroups(isSwitch) {
        const content = this.subNavigation.content
        if (content.dataset.orientation !== this.orientation) {
            content.replaceChildren()
            this.groupElements.clear()
            content.dataset.orientation = this.orientation
        }
        const groups = this.groupList()
        const wanted = new Set(groups.map((group) => group.id))
        for (const [id, record] of this.groupElements) {
            if (!wanted.has(id)) {
                this.groupElements.delete(id)
                for (const element of [record.element, record.separator].filter(Boolean)) {
                    leaveGroup(element, isSwitch)
                }
            }
        }
        let previous = null
        groups.forEach((group, index) => {
            let record = this.groupElements.get(group.id)
            const isNew = !record
            if (isNew) {
                const element = group.make(this.orientation)
                element.classList.add("sub-navigation-group")
                element.dataset.group = group.id
                element.addEventListener("pointerdown", (event) => this.groupPointerDown(event, group.id, element))
                record = { element, separator: null }
                this.groupElements.set(group.id, record)
            } else {
                group.update?.(record.element)
            }
            if (index > 0 && !record.separator) {
                record.separator = separator(this.orientation)
                record.separator.dataset.revealedElement = ""
            } else if (index === 0 && record.separator) {
                leaveGroup(record.separator, isSwitch)
                record.separator = null
            }
            const nodes = [record.separator, record.element].filter(Boolean)
            for (const node of nodes) {
                if (previous) {
                    if (previous.nextSibling !== node) {
                        previous.after(node)
                    }
                } else if (content.firstChild !== node) {
                    content.prepend(node)
                }
                previous = node
            }
            if (isNew || (record.separator && !record.separator.dataset.shown)) {
                const targets = [...record.element.querySelectorAll("[data-revealed-element]")]
                if (record.element.hasAttribute("data-revealed-element")) {
                    targets.push(record.element)
                }
                if (record.separator) {
                    targets.push(record.separator)
                    record.separator.dataset.shown = "true"
                }
                for (const target of isNew ? targets : [record.separator]) {
                    if (this.subNavigation.motion.areElementsShown) {
                        revealElement(target, true, isSwitch)
                    } else {
                        hideTurned(target)
                    }
                }
            }
        })
        this.subNavigation.isWide = this.orientation === "horizontal"
        this.subNavigation.resize(isSwitch)
        for (const group of groups) {
            group.afterLayout?.(this.groupElements.get(group.id)?.element)
        }
    }

    syncPanels(isWanted) {
        const panelKey = this.props.panelKey
        const prefix = navMetrics.pillPanelPrefix
        const wantedPill = isWanted && panelKey?.startsWith(prefix) ? panelKey : null
        const wantedWheel = isWanted && panelKey && !panelKey.startsWith(prefix) ? panelKey : null
        if (wantedPill) {
            const isEntering = !this.shownPillPanelKey || !this.pillPanel.motion.areElementsShown
            if (this.shownPillPanelKey !== wantedPill || !this.pillPanel.content.firstElementChild) {
                this.pillPanel.content.replaceChildren(this.props.panel(wantedPill, this.orientation))
            } else {
                this.props.updatePanel?.(this.pillPanel.content.firstElementChild, wantedPill)
            }
            this.shownPillPanelKey = wantedPill
            this.pillPanel.isWide = this.orientation === "horizontal"
            this.pillPanel.resize(false)
            if (isEntering) {
                this.pillPanel.motion.enter()
            }
        } else if (this.shownPillPanelKey && !this.pillPanelLeaving) {
            this.pillPanelLeaving = true
            this.pillPanel.motion.leave(() => {
                this.pillPanelLeaving = false
                if (!this.props.panelKey?.startsWith(prefix)) {
                    this.shownPillPanelKey = null
                    this.pillPanel.content.replaceChildren()
                }
            })
        }
        if (wantedWheel !== this.shownWheelKey) {
            const old = this.wheelHost.firstElementChild
            if (old) {
                old.style.pointerEvents = "none"
                popTogether(old, false).finished.then(() => old.remove(), () => old.remove())
            }
            this.shownWheelKey = wantedWheel
            if (wantedWheel) {
                const panel = this.props.panel(wantedWheel, this.orientation)
                this.wheelHost.append(panel)
                popTogether(panel, true)
            }
        } else if (wantedWheel) {
            this.props.updatePanel?.(this.wheelHost.firstElementChild, wantedWheel)
        }
    }

    obstacles() {
        const blocked = [...(this.props?.obstacles ?? [])]
        const keyboard = this.props?.keyboardHeight ?? 0
        if (keyboard > 0) {
            blocked.push({ x: 0, y: window.innerHeight - keyboard, width: window.innerWidth, height: keyboard })
        }
        return blocked
    }

    clamped(point, size) {
        const width = window.innerWidth
        const height = window.innerHeight
        const clamp = (value, half, total) => (total - navMetrics.edgeMargin * 2 < half * 2 ? total / 2 : Math.min(total - navMetrics.edgeMargin - half, Math.max(navMetrics.edgeMargin + half, value)))
        return [clamp(point[0], size[0] / 2, width), clamp(point[1], size[1] / 2, height)]
    }

    avoiding(center, size, blocked) {
        const start = this.clamped(center, size)
        const gap = navMetrics.avoidGap
        const isFree = (point) => {
            const candidate = inset(rectFrom(point, size), -gap / 2)
            return !blocked.some((obstacle) => intersects(obstacle, candidate))
        }
        if (isFree(start)) {
            return start
        }
        const candidates = []
        let frontier = [start]
        for (let pass = 0; pass < 3; pass += 1) {
            const next = []
            for (const point of frontier) {
                const current = rectFrom(point, size)
                for (const obstacle of blocked) {
                    if (!intersects(inset(obstacle, -gap), current)) {
                        continue
                    }
                    next.push([point[0], obstacle.y - gap - size[1] / 2])
                    next.push([point[0], obstacle.y + obstacle.height + gap + size[1] / 2])
                    next.push([obstacle.x - gap - size[0] / 2, point[1]])
                    next.push([obstacle.x + obstacle.width + gap + size[0] / 2, point[1]])
                }
            }
            const inside = next.filter((point) => {
                const clamped = this.clamped(point, size)
                return Math.abs(clamped[0] - point[0]) < 0.01 && Math.abs(clamped[1] - point[1]) < 0.01
            })
            candidates.push(...inside.filter(isFree))
            frontier = inside
        }
        candidates.sort((first, second) => Math.hypot(first[0] - start[0], first[1] - start[1]) - Math.hypot(second[0] - start[0], second[1] - start[1]))
        return candidates[0] ?? start
    }

    navCenter(blocked) {
        const size = this.navigation.size
        if (this.carryPoint) {
            return this.clamped(this.carryPoint, size)
        }
        const placement = this.placement
        const wanted = placement && Number.isFinite(placement.x) && Number.isFinite(placement.y)
            ? [placement.x * window.innerWidth, placement.y * window.innerHeight]
            : [window.innerWidth / 2, window.innerHeight - navMetrics.bottomGap - size[1] / 2]
        return this.avoiding(wanted, size, blocked)
    }

    outwardSide(center) {
        if (this.orientation === "vertical") {
            return center[0] > window.innerWidth / 2 ? "left" : "right"
        }
        return center[1] > window.innerHeight / 2 ? "up" : "down"
    }

    beside(anchor, size, side) {
        const gap = navMetrics.besideGap
        switch (side) {
        case "up": return [anchor.x + anchor.width / 2, anchor.y - gap - size[1] / 2]
        case "down": return [anchor.x + anchor.width / 2, anchor.y + anchor.height + gap + size[1] / 2]
        case "left": return [anchor.x - gap - size[0] / 2, anchor.y + anchor.height / 2]
        default: return [anchor.x + anchor.width + gap + size[0] / 2, anchor.y + anchor.height / 2]
        }
    }

    edgeSide(side) {
        return { up: "down", down: "up", left: "right", right: "left" }[side]
    }

    layout(isAnimated) {
        if (!this.props) {
            return
        }
        const blocked = this.obstacles()
        const center = this.navCenter(blocked)
        const navigationRect = rectFrom(center, this.navigation.size)
        const side = this.outwardSide(center)
        this.edge = this.edgeSide(side)
        this.hiddenReach = this.hiddenDistance(center, this.edge)
        const subSize = this.subNavigation.size
        const subCenter = this.avoiding(this.beside(navigationRect, subSize, side), subSize, [...blocked, navigationRect])
        const subRect = rectFrom(subCenter, subSize)
        const anchorElement = typeof this.props.panelAnchor === "function" ? this.props.panelAnchor() : this.props.panelAnchor
        const anchor = anchorElement?.isConnected ? anchorElement.getBoundingClientRect() : null
        if (anchor || !this.shownPillPanelKey) {
            this.lastAnchor = anchor ? { x: anchor.x, y: anchor.y, width: anchor.width, height: anchor.height } : null
        }
        const panelSize = this.shownPillPanelKey ? this.pillPanel.size : [this.wheelHost.offsetWidth, this.wheelHost.offsetHeight]
        const panelCenter = this.avoiding(this.beside(this.lastAnchor ?? subRect, panelSize, side), panelSize, [...blocked, navigationRect, subRect])
        const isSettled = !this.carryPoint && this.navigation.motion.areElementsShown
        this.navigationCenter.set(center, isAnimated && isSettled)
        this.subNavigationCenter.set(subCenter, isAnimated && isSettled)
        this.panelCenter.set(panelCenter, isAnimated && Boolean(this.shownPillPanelKey) && this.pillPanel.motion.areElementsShown)
        this.placeEdgeStrip(center)
    }

    placeNavigation(center) {
        const [x, y] = this.edgeVector(this.edge ?? "down", this.edgeOffset)
        placeAt(this.navigation.element, [center[0] + x, center[1] + y], this.navigation.size)
        this.navigation.element.classList.toggle("is-carried", Boolean(this.carryPoint))
    }

    edgeVector(edge, distance) {
        switch (edge) {
        case "up": return [0, -distance]
        case "down": return [0, distance]
        case "left": return [-distance, 0]
        default: return [distance, 0]
        }
    }

    outwardTravel(translation, edge) {
        switch (edge) {
        case "up": return [-translation[1], translation[0]]
        case "down": return [translation[1], translation[0]]
        case "left": return [-translation[0], translation[1]]
        default: return [translation[0], translation[1]]
        }
    }

    crossExtent(edge) {
        return edge === "up" || edge === "down" ? this.navigation.size[1] : this.navigation.size[0]
    }

    hiddenDistance(center, edge) {
        const size = this.navigation.size
        switch (edge) {
        case "up": return center[1] + size[1] / 2 + navMetrics.shadowReach
        case "down": return window.innerHeight - center[1] + size[1] / 2 + navMetrics.shadowReach
        case "left": return center[0] + size[0] / 2 + navMetrics.shadowReach
        default: return window.innerWidth - center[0] + size[0] / 2 + navMetrics.shadowReach
        }
    }

    rubberBanded(distance, limit) {
        const rubber = tokens.motion.shares.nav_edge_rubber
        if (distance < 0) {
            return distance * rubber
        }
        if (distance > limit) {
            return limit + (distance - limit) * rubber
        }
        return distance
    }

    setEdgeOffset(value, milliseconds = 0, curveName = "power_two_out") {
        this.edgeTween?.stop()
        if (milliseconds <= 0) {
            this.edgeOffset = value
            this.placeNavigation(this.navigationCenter.value ?? [0, 0])
            return
        }
        const from = this.edgeOffset
        this.edgeTween = tween({
            milliseconds,
            curveName,
            onFrame: (eased) => {
                this.edgeOffset = from + (value - from) * eased
                this.placeNavigation(this.navigationCenter.value ?? [0, 0])
            },
        })
    }

    placeEdgeStrip(center) {
        const isAcross = this.edge === "up" || this.edge === "down"
        const size = this.navigation.size
        const depth = navMetrics.edgeStripDepth
        const width = isAcross ? Math.max(size[0], navMetrics.edgeHandle[0]) : depth
        const height = isAcross ? depth : Math.max(size[1], navMetrics.edgeHandle[0])
        let stripCenter
        switch (this.edge) {
        case "up": stripCenter = [center[0], depth / 2]; break
        case "down": stripCenter = [center[0], window.innerHeight - depth / 2]; break
        case "left": stripCenter = [depth / 2, center[1]]; break
        default: stripCenter = [window.innerWidth - depth / 2, center[1]]
        }
        placeAt(this.edgeStrip, stripCenter, [width, height])
        this.edgeStrip.style.width = `${width}px`
        this.edgeStrip.style.height = `${height}px`
        this.edgeStrip.classList.toggle("is-across", isAcross)
    }

    showFromEdge() {
        this.isEdgeHidden = false
        popTogether(this.edgeStrip, false).finished.then(() => {
            if (!this.isEdgeHidden) {
                this.edgeStrip.hidden = true
            }
        })
        this.setEdgeOffset(0, duration("nav_edge_hide"), "back_out")
    }

    hideToEdge() {
        this.isEdgeHidden = true
        this.setEdgeOffset(this.hiddenReach, (duration("nav_edge_hide") * 2) / 3, "power_two_in")
        this.edgeStrip.hidden = false
        popTogether(this.edgeStrip, true)
    }

    bindEdgeStrip() {
        let start = null
        this.edgeStrip.addEventListener("pointerdown", (event) => {
            this.edgeStrip.setPointerCapture(event.pointerId)
            start = [event.clientX, event.clientY]
        })
        this.edgeStrip.addEventListener("pointermove", (event) => {
            if (!start || Math.hypot(event.clientX - start[0], event.clientY - start[1]) < 4) {
                return
            }
            const inward = -this.outwardTravel([event.clientX - start[0], event.clientY - start[1]], this.edge)[0]
            this.setEdgeOffset(this.hiddenReach - this.rubberBanded(inward, this.hiddenReach))
        })
        const end = () => {
            if (!start) {
                return
            }
            start = null
            if (this.hiddenReach - this.edgeOffset > this.crossExtent(this.edge) * tokens.motion.shares.nav_edge_hide) {
                this.showFromEdge()
            } else {
                this.setEdgeOffset(this.hiddenReach, (duration("nav_edge_hide") * 2) / 3, "power_two_in")
            }
        }
        this.edgeStrip.addEventListener("pointerup", end)
        this.edgeStrip.addEventListener("pointercancel", end)
        this.edgeStrip.addEventListener("click", () => {
            if (this.isEdgeHidden && this.edgeOffset >= this.hiddenReach - 1) {
                this.showFromEdge()
            }
        })
    }

    navPointerDown(event) {
        if (event.button !== 0 || this.carryPoint || this.toolReordering) {
            return
        }
        this.navGesture = { pointerId: event.pointerId, start: [event.clientX, event.clientY], isRejected: false }
    }

    navPointerMove(event) {
        const gesture = this.navGesture
        if (!gesture || gesture.pointerId !== event.pointerId || this.carryPoint || this.toolReordering) {
            return
        }
        const translation = [event.clientX - gesture.start[0], event.clientY - gesture.start[1]]
        if (this.sizingDrag) {
            const alongTravel = this.orientation === "horizontal" ? translation[0] : -translation[1]
            const item = this.props.groups.flat().find((candidate) => candidate.id === this.sizingDrag.id)
            const travel = Math.max(1, along(this.navigation.size, this.orientation) - navMetrics.padding * 2 - navMetrics.sliderKnob)
            item?.sizing.onChange(Math.min(1, Math.max(0, this.sizingDrag.startShare + (alongTravel - this.sizingDrag.startTranslation) / travel)))
            return
        }
        if (this.edgeDragStart !== undefined && this.edgeDragStart !== null) {
            const travel = this.outwardTravel(translation, this.edge)
            this.setEdgeOffset(this.rubberBanded(travel[0] - this.edgeDragStart, this.hiddenReach))
            return
        }
        if (gesture.isRejected || Math.hypot(...translation) < navMetrics.navSizingSlop) {
            return
        }
        const alongTravel = this.orientation === "horizontal" ? translation[0] : -translation[1]
        const acrossTravel = this.orientation === "horizontal" ? translation[1] : translation[0]
        const item = this.sizableItem()
        if (item && Math.abs(alongTravel) > Math.abs(acrossTravel) * navMetrics.navSizingDominance) {
            this.navigation.element.setPointerCapture(event.pointerId)
            this.swallowUntil = Infinity
            this.sizingDrag = { id: item.id, startShare: item.sizing.share, startTranslation: alongTravel }
            this.syncSlider()
            return
        }
        const travel = this.outwardTravel(translation, this.edge)
        if (this.shownSubNavigationKey && !this.isEdgeHidden && Math.abs(travel[0]) > Math.abs(travel[1]) * navMetrics.navSizingDominance) {
            this.navigation.element.setPointerCapture(event.pointerId)
            this.swallowUntil = Infinity
            this.edgeDragStart = travel[0]
            return
        }
        gesture.isRejected = true
    }

    navPointerUp(event) {
        const gesture = this.navGesture
        if (!gesture || gesture.pointerId !== event.pointerId) {
            return
        }
        this.navGesture = null
        if (this.sizingDrag) {
            this.sizingDrag = null
            this.swallowUntil = performance.now() + swallowMilliseconds
            this.syncSlider()
            return
        }
        if (this.edgeDragStart !== undefined && this.edgeDragStart !== null) {
            this.edgeDragStart = null
            this.swallowUntil = performance.now() + swallowMilliseconds
            if (this.edgeOffset > this.crossExtent(this.edge) * tokens.motion.shares.nav_edge_hide) {
                this.hideToEdge()
            } else {
                this.setEdgeOffset(0, duration("nav_edge_hide"), "back_out")
            }
        }
    }

    gripDown(event) {
        if (event.button !== 0) {
            return
        }
        const grip = event.currentTarget
        const start = [event.clientX, event.clientY]
        const pointerId = event.pointerId
        let isCarrying = false
        const timer = setTimeout(() => {
            isCarrying = true
            this.swallowUntil = Infinity
            const center = this.navigationCenter.value
            this.carryGrab = [start[0] - center[0], start[1] - center[1]]
            this.carryPoint = [...center]
            grip.setPointerCapture(pointerId)
            this.navigation.element.classList.add("is-carried")
            animate(this.navigation.element, [{ scale: "1" }, { scale: String(tokens.motion.scales.held) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
            this.layout(false)
        }, duration("navigation_grip_hold"))
        const move = (moveEvent) => {
            if (moveEvent.pointerId !== pointerId) {
                return
            }
            if (!isCarrying) {
                if (Math.hypot(moveEvent.clientX - start[0], moveEvent.clientY - start[1]) > 10) {
                    clearTimeout(timer)
                }
                return
            }
            this.carryPoint = [moveEvent.clientX - this.carryGrab[0], moveEvent.clientY - this.carryGrab[1]]
            this.layout(false)
        }
        const end = (endEvent) => {
            if (endEvent.pointerId !== pointerId) {
                return
            }
            clearTimeout(timer)
            grip.removeEventListener("pointermove", move)
            grip.removeEventListener("pointerup", end)
            grip.removeEventListener("pointercancel", end)
            if (isCarrying) {
                this.finishCarry()
            }
        }
        grip.addEventListener("pointermove", move)
        grip.addEventListener("pointerup", end)
        grip.addEventListener("pointercancel", end)
    }

    finishCarry() {
        const point = this.clamped(this.carryPoint, this.navigation.size)
        const width = window.innerWidth
        const height = window.innerHeight
        const sideDistance = Math.min(point[0], width - point[0])
        const endDistance = Math.min(point[1], height - point[1])
        const nextOrientation = sideDistance < endDistance ? "vertical" : "horizontal"
        const next = { x: point[0] / Math.max(1, width), y: point[1] / Math.max(1, height), orientation: nextOrientation }
        setNavPlacement(next)
        const before = this.navigation.element.getBoundingClientRect()
        const subBefore = this.subNavigation.element.getBoundingClientRect()
        this.placement = next
        this.carryPoint = null
        this.navigation.element.classList.remove("is-carried")
        animate(this.navigation.element, [{ scale: String(tokens.motion.scales.held) }, { scale: "1" }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        if (nextOrientation !== this.orientation) {
            this.orientation = nextOrientation
            this.rebuildForOrientation()
        }
        this.layout(false)
        morphFrom(this.navigation.element, before)
        if (this.shownSubNavigationKey) {
            morphFrom(this.subNavigation.element, subBefore)
        }
        this.swallowUntil = performance.now() + swallowMilliseconds
    }

    rebuildForOrientation() {
        for (const element of this.items.elements.values()) {
            element.remove()
        }
        this.items.elements.clear()
        this.applyOrientationClasses()
        this.syncItems(false)
        this.items.reveal(true)
        if (this.shownSubNavigationKey) {
            this.syncGroups(false)
            this.subNavigation.content.querySelectorAll("[data-revealed-element]").forEach((element) => revealElement(element, true))
        }
        if (this.shownPillPanelKey) {
            this.pillPanel.content.replaceChildren(this.props.panel(this.shownPillPanelKey, this.orientation))
            this.pillPanel.isWide = this.orientation === "horizontal"
            this.pillPanel.resize(false)
            this.pillPanel.content.firstElementChild?.revealTargets?.().forEach((element) => revealElement(element, true))
        }
        if (this.shownWheelKey) {
            this.wheelHost.replaceChildren(this.props.panel(this.shownWheelKey, this.orientation))
        }
    }

    itemPointerDown(event, button) {
        const isTool = this.props.groups[0]?.some((item) => item.id === button.item.id)
        if (!isTool || event.button !== 0) {
            return
        }
        const pointerId = event.pointerId
        const start = [event.clientX, event.clientY]
        const axis = (point) => (this.orientation === "horizontal" ? point[0] : point[1])
        const extent = along(itemSize(this.orientation), this.orientation) + navMetrics.spacing
        let reordering = null
        const timer = setTimeout(() => {
            if (this.sizingDrag || this.carryPoint || this.edgeDragStart) {
                return
            }
            this.swallowUntil = Infinity
            const ids = this.props.groups[0].map((item) => item.id)
            reordering = { id: button.item.id, start: ids, order: [...ids], anchor: axis(start), drag: 0 }
            this.toolReordering = reordering
            this.navGesture = null
            button.setPointerCapture(pointerId)
            button.classList.add("is-lifted")
            animate(button, [{ scale: "1" }, { scale: String(tokens.motion.scales.held) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        }, duration("menu_hold"))
        const move = (moveEvent) => {
            if (moveEvent.pointerId !== pointerId) {
                return
            }
            if (!reordering) {
                if (Math.hypot(moveEvent.clientX - start[0], moveEvent.clientY - start[1]) > 10) {
                    clearTimeout(timer)
                }
                return
            }
            reordering.drag = axis([moveEvent.clientX, moveEvent.clientY]) - reordering.anchor
            stepReordering(reordering, () => extent)
            this.applyToolOffsets(reordering, extent)
        }
        const end = (endEvent) => {
            if (endEvent.pointerId !== pointerId) {
                return
            }
            clearTimeout(timer)
            button.removeEventListener("pointermove", move)
            button.removeEventListener("pointerup", end)
            button.removeEventListener("pointercancel", end)
            if (!reordering) {
                return
            }
            this.toolReordering = null
            const residual = reordering.drag - shiftOf(reordering, reordering.id, () => extent)
            for (const element of this.items.elements.values()) {
                element.style.translate = ""
                element.getAnimations().filter((running) => running.id === "offset").forEach((running) => running.cancel())
            }
            button.classList.remove("is-lifted")
            animate(button, [{ scale: String(tokens.motion.scales.held) }, { scale: "1" }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
            this.props.onReorderTools(reordering.order)
            const offset = this.orientation === "horizontal" ? `${residual}px 0px` : `0px ${residual}px`
            springAnimate(button, [{ translate: offset }, { translate: "0px 0px" }], "placement")
            this.swallowUntil = performance.now() + swallowMilliseconds
        }
        button.addEventListener("pointermove", move)
        button.addEventListener("pointerup", end)
        button.addEventListener("pointercancel", end)
    }

    applyToolOffsets(reordering, extent) {
        for (const id of reordering.start) {
            const element = this.items.elements.get(id)
            if (!element) {
                continue
            }
            const offset = id === reordering.id ? reordering.drag : shiftOf(reordering, id, () => extent)
            const value = this.orientation === "horizontal" ? `${offset}px 0px` : `0px ${offset}px`
            if (element.style.translate === value) {
                continue
            }
            const previous = element.style.translate || "0px 0px"
            element.style.translate = value
            if (id !== reordering.id) {
                const running = springAnimate(element, [{ translate: previous }, { translate: value }], "placement")
                running.id = "offset"
            }
        }
    }

    groupPointerDown(event, groupId, element) {
        if (event.button !== 0) {
            return
        }
        const pointerId = event.pointerId
        const start = [event.clientX, event.clientY]
        const axis = (point) => (this.orientation === "horizontal" ? point[0] : point[1])
        const extent = (id) => {
            const groupElement = this.groupElements.get(id)?.element
            const size = groupElement ? [groupElement.offsetWidth, groupElement.offsetHeight] : [0, 0]
            return along(size, this.orientation) + separatorExtent + navMetrics.spacing * 2
        }
        let reordering = null
        const timer = setTimeout(() => {
            const ids = this.props.subNavigationGroups.map((group) => group.id)
            reordering = { id: groupId, start: ids, order: [...ids], anchor: axis(start), drag: 0 }
            this.groupReordering = reordering
            element.setPointerCapture(pointerId)
            animate(element, [{ scale: "1" }, { scale: String(tokens.motion.scales.held) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        }, duration("menu_hold"))
        const move = (moveEvent) => {
            if (moveEvent.pointerId !== pointerId) {
                return
            }
            if (!reordering) {
                if (Math.hypot(moveEvent.clientX - start[0], moveEvent.clientY - start[1]) > 10) {
                    clearTimeout(timer)
                }
                return
            }
            reordering.drag = axis([moveEvent.clientX, moveEvent.clientY]) - reordering.anchor
            stepReordering(reordering, extent)
            for (const id of reordering.start) {
                const groupElement = this.groupElements.get(id)?.element
                if (!groupElement) {
                    continue
                }
                const offset = id === reordering.id ? reordering.drag : shiftOf(reordering, id, extent)
                const value = this.orientation === "horizontal" ? `${offset}px 0px` : `0px ${offset}px`
                if (groupElement.style.translate !== value) {
                    const previous = groupElement.style.translate || "0px 0px"
                    groupElement.style.translate = value
                    if (id !== reordering.id) {
                        springAnimate(groupElement, [{ translate: previous }, { translate: value }], "placement")
                    }
                }
            }
        }
        const end = (endEvent) => {
            if (endEvent.pointerId !== pointerId) {
                return
            }
            clearTimeout(timer)
            element.removeEventListener("pointermove", move)
            element.removeEventListener("pointerup", end)
            element.removeEventListener("pointercancel", end)
            if (!reordering) {
                return
            }
            this.groupReordering = null
            const residual = reordering.drag - shiftOf(reordering, reordering.id, extent)
            for (const record of this.groupElements.values()) {
                record.element.style.translate = ""
            }
            animate(element, [{ scale: String(tokens.motion.scales.held) }, { scale: "1" }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
            this.props.onReorderSubNavigation(reordering.order)
            const offset = this.orientation === "horizontal" ? `${residual}px 0px` : `0px ${residual}px`
            springAnimate(element, [{ translate: offset }, { translate: "0px 0px" }], "placement")
        }
        element.addEventListener("pointermove", move)
        element.addEventListener("pointerup", end)
        element.addEventListener("pointercancel", end)
    }
}

function positions(ids, extent) {
    const result = new Map()
    let position = 0
    for (const id of ids) {
        result.set(id, position)
        position += extent(id)
    }
    return result
}

function shiftOf(reordering, id, extent) {
    return (positions(reordering.order, extent).get(id) ?? 0) - (positions(reordering.start, extent).get(id) ?? 0)
}

function stepReordering(reordering, extent) {
    const relative = () => reordering.drag - shiftOf(reordering, reordering.id, extent)
    for (;;) {
        const index = reordering.order.indexOf(reordering.id)
        if (index < 0 || index >= reordering.order.length - 1 || relative() <= extent(reordering.order[index + 1]) / 2) {
            break
        }
        ;[reordering.order[index], reordering.order[index + 1]] = [reordering.order[index + 1], reordering.order[index]]
    }
    for (;;) {
        const index = reordering.order.indexOf(reordering.id)
        if (index <= 0 || relative() >= -extent(reordering.order[index - 1]) / 2) {
            break
        }
        ;[reordering.order[index], reordering.order[index - 1]] = [reordering.order[index - 1], reordering.order[index]]
    }
}

function placeAt(element, center, size) {
    element.style.left = `${center[0] - size[0] / 2}px`
    element.style.top = `${center[1] - size[1] / 2}px`
}

function morphFrom(element, before) {
    const after = element.getBoundingClientRect()
    if (!before.width || !after.width) {
        return
    }
    const deltaX = before.left + before.width / 2 - (after.left + after.width / 2)
    const deltaY = before.top + before.height / 2 - (after.top + after.height / 2)
    animate(element, [{ translate: `${deltaX}px ${deltaY}px` }, { translate: "0px 0px" }], { milliseconds: duration("state") * 2, curveName: "power_three_in_out" })
}

function leaveGroup(element, isSwitch) {
    const parent = element.parentElement
    if (!parent) {
        return
    }
    element.style.position = "absolute"
    element.style.left = `${element.offsetLeft}px`
    element.style.top = `${element.offsetTop}px`
    element.style.pointerEvents = "none"
    const targets = [...element.querySelectorAll("[data-revealed-element]")]
    if (element.hasAttribute("data-revealed-element") || element.classList.contains("nav-separator")) {
        targets.push(element)
    }
    if (isSwitch && targets.length) {
        Promise.all(targets.map((target) => revealElement(target, false).finished.catch(() => null))).then(() => element.remove())
    } else {
        animate(element, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("press"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => element.remove(), () => element.remove())
    }
}

function pressPop(element) {
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) {
            return
        }
        element.querySelector(".glyph, .navigation-caption")?.animate([{ scale: "1" }, { scale: String(tokens.motion.scales.press_pop) }], { duration: duration("press"), easing: `cubic-bezier(${tokens.motion.curves.power_two_out.join(",")})`, fill: "forwards" })
    })
    const release = () => {
        element.querySelector(".glyph, .navigation-caption")?.animate([{ scale: String(tokens.motion.scales.press_pop) }, { scale: "1" }], { duration: duration("release"), easing: `cubic-bezier(${tokens.motion.curves.back_out.join(",")})`, fill: "forwards" })
    }
    element.addEventListener("pointerup", release)
    element.addEventListener("pointercancel", release)
}

export { spring }
