import { create, microLabel, pressable } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { cellHeight, cellWidth } from "./model.js"
import { animate, duration } from "./motion.js"
import { springAnimate } from "./pill.js"
import * as preferences from "./preferences.js"
import { renderCell } from "./renderer.js"
import { importsRevision, subscribeImports } from "./imports.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { StackGroup } from "./stackGroup.js"
import { tokens, withAlpha } from "./tokens.js"

const gridSpacing = 18
const sidePadding = 28
const dropEdgeShare = 0.22
const noteColumnWidth = 170
const dragTolerance = 8
const slotReach = 48
const tileIcons = { folder: 160, add: 40, note: 22 }
const noteNameSize = 12
const noteNameLineHeight = 1.3
const thumbnails = new Map()
const thumbnailJobs = []
let thumbnailBytes = 0
let isThumbnailDrainScheduled = false
const whenIdle = window.requestIdleCallback ?? ((callback) => setTimeout(() => callback({ timeRemaining: () => 0, didTimeout: true }), 16))

export function folderLook(notebook) {
    return { color: notebook?.color ?? tokens.folders.default_color, icon: notebook?.icon ?? tokens.folders.default_icon }
}

export function noteLook(page) {
    return { color: page?.color ?? tokens.palette.text_muted, icon: page?.icon ?? tokens.folders.note_icon }
}

function noteHeaderHeight() {
    return Math.max(tileIcons.note, tokens.title.tile_name_lines * noteNameSize * noteNameLineHeight)
}

export function noteUnitHeight(width) {
    return (width - 24) * (cellHeight / cellWidth) + 24 + 10 + noteHeaderHeight()
}

export function purgeThumbnails() {
    thumbnails.clear()
    thumbnailBytes = 0
}

function thumbnailCost(canvas) {
    return canvas.width * canvas.height * 4
}

function storeThumbnail(key, source) {
    const copy = document.createElement("canvas")
    copy.width = source.width
    copy.height = source.height
    copy.getContext("2d").drawImage(source, 0, 0)
    thumbnails.delete(key)
    thumbnails.set(key, copy)
    thumbnailBytes += thumbnailCost(copy)
    const limit = tokens.memory.thumbnail_cache_megabytes * 1024 * 1024
    for (const [oldKey, old] of thumbnails) {
        if (thumbnailBytes <= limit) {
            break
        }
        thumbnails.delete(oldKey)
        thumbnailBytes -= thumbnailCost(old)
    }
}

function cachedThumbnail(key) {
    const cached = thumbnails.get(key)
    if (cached) {
        thumbnails.delete(key)
        thumbnails.set(key, cached)
    }
    return cached
}

function scheduleThumbnail(job) {
    thumbnailJobs.push(job)
    if (isThumbnailDrainScheduled) {
        return
    }
    isThumbnailDrainScheduled = true
    whenIdle(drainThumbnails, { timeout: 120 })
}

function drainThumbnails(deadline) {
    isThumbnailDrainScheduled = false
    do {
        thumbnailJobs.shift()?.()
    } while (thumbnailJobs.length && deadline.timeRemaining() > 4)
    if (thumbnailJobs.length) {
        isThumbnailDrainScheduled = true
        whenIdle(drainThumbnails, { timeout: 120 })
    }
}

function adaptiveColumns(width, minimum, maximum) {
    const count = Math.max(1, Math.floor((width + gridSpacing) / (minimum + gridSpacing)))
    return { count, width: Math.min(maximum, (width - gridSpacing * (count - 1)) / count) }
}

function appear(element, rank) {
    animate(element, [{ opacity: 0, transform: "translateY(14px) scale(0.94)" }, { opacity: 1, transform: "translateY(0) scale(1)" }], { milliseconds: 240, curveName: "power_two_out", delay: Math.min(rank, 16) * 12 })
}

function holdPop(element) {
    const target = element
    const set = (value, milliseconds, easing) => {
        target.getAnimations().filter((running) => running.id === "hold").forEach((running) => running.cancel())
        const from = getComputedStyle(target).scale
        const running = target.animate([{ scale: from === "none" ? "1" : from }, { scale: String(value) }], { duration: milliseconds, easing, fill: "forwards" })
        running.id = "hold"
    }
    const curve = (name) => `cubic-bezier(${tokens.motion.curves[name].join(",")})`
    return {
        press() {
            set(tokens.motion.scales.hold_grow, duration("menu_hold"), "linear")
        },
        held() {
            set(tokens.motion.scales.hold_pop, duration("state"), curve("back_out"))
        },
        release() {
            set(1, duration("release"), curve("back_out"))
        },
    }
}

export function tileGestures(element, { onTap, onMenu, onDragBegin, onDragMove, onDragEnd }) {
    const pop = holdPop(element)
    let press = null
    element.addEventListener("pointerdown", (event) => {
        if (event.button !== 0) {
            return
        }
        pop.press()
        press = { pointerId: event.pointerId, start: [event.clientX, event.clientY], isHeld: false, isDragging: false, hasMoved: false }
        press.timer = setTimeout(() => {
            if (!press || press.hasMoved) {
                return
            }
            press.isHeld = true
            pop.held()
            element.setPointerCapture(press.pointerId)
            onMenu([press.start[0], press.start[1]])
        }, duration("menu_hold"))
    })
    element.addEventListener("pointermove", (event) => {
        if (!press || press.pointerId !== event.pointerId) {
            return
        }
        const distance = Math.hypot(event.clientX - press.start[0], event.clientY - press.start[1])
        if (!press.isHeld) {
            if (distance > 10) {
                press.hasMoved = true
                clearTimeout(press.timer)
                pop.release()
            }
            return
        }
        if (!press.isDragging && distance > dragTolerance && onDragBegin) {
            press.isDragging = true
            onDragBegin(press.start)
        }
        if (press.isDragging) {
            onDragMove?.([event.clientX, event.clientY])
        }
    })
    const end = (event, isCancelled) => {
        if (!press || press.pointerId !== event.pointerId) {
            return
        }
        clearTimeout(press.timer)
        pop.release()
        const finished = press
        press = null
        if (finished.isDragging) {
            onDragEnd?.([event.clientX, event.clientY], !isCancelled)
        } else if (!finished.isHeld && !finished.hasMoved && !isCancelled) {
            onTap(element.getBoundingClientRect())
        }
    }
    element.addEventListener("pointerup", (event) => end(event, false))
    element.addEventListener("pointercancel", (event) => end(event, true))
    element.addEventListener("touchmove", (event) => {
        if (press?.isHeld) {
            event.preventDefault()
        }
    }, { passive: false })
    element.addEventListener("contextmenu", (event) => {
        event.preventDefault()
        if (event.pointerType !== "touch") {
            onMenu([event.clientX, event.clientY])
        }
    })
}

function folderTile(notebook, caption) {
    const tile = create("div", "folder-tile")
    const preview = create("div", "folder-tile-preview")
    const name = create("span", "folder-tile-name")
    const label = microLabel("")
    tile.append(preview, create("div", "folder-tile-text", name, label))
    tile.update = (next, nextCaption) => {
        const look = folderLook(next)
        preview.replaceChildren(glyph(look.icon, { color: look.color, size: tileIcons.folder }))
        preview.style.borderColor = withAlpha(look.color, 0.35)
        name.textContent = next.title
        label.textContent = nextCaption.toUpperCase()
        squircle(tile, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: look.color, borderWidth: 1.5 })
    }
    tile.update(notebook, caption)
    return tile
}

function noteTile(page, title, caption) {
    const tile = create("div", "note-tile")
    const icon = create("span", "note-tile-icon")
    const name = create("span", "note-tile-name")
    const label = microLabel("")
    const header = create("div", "note-tile-header", icon, name, label)
    header.style.height = `${noteHeaderHeight()}px`
    const thumbnailHost = create("div", "note-tile-thumbnail")
    const thumbnail = create("canvas", "note-tile-canvas")
    thumbnailHost.append(thumbnail)
    tile.append(header, thumbnailHost)
    let current = page
    let renderedKey = null
    const fitName = () => {
        const minimum = tokens.title.tile_name_minimum_scale
        if (name.style.fontSize) {
            name.style.fontSize = ""
        }
        if (name.scrollHeight <= name.clientHeight + 1) {
            return
        }
        let scale = Math.max(minimum, Math.min(1, Math.sqrt(name.clientHeight / name.scrollHeight)))
        name.style.fontSize = `${noteNameSize * scale}px`
        while (scale > minimum && name.scrollHeight > name.clientHeight + 1) {
            scale = Math.max(minimum, scale - 0.05)
            name.style.fontSize = `${noteNameSize * scale}px`
        }
    }
    const draw = (key) => {
        if (renderedKey !== key || !thumbnail.isConnected) {
            return
        }
        const cached = cachedThumbnail(key)
        if (cached) {
            thumbnail.width = cached.width
            thumbnail.height = cached.height
            thumbnail.getContext("2d").drawImage(cached, 0, 0)
            return
        }
        renderCell(thumbnail, current, 0, 0, { showsGuides: preferences.showsGuides(), showsDividers: preferences.showsDividers(), paperStyle: preferences.paperStyle() })
        storeThumbnail(key, thumbnail)
    }
    const render = () => {
        const width = thumbnailHost.clientWidth
        const height = thumbnailHost.clientHeight
        if (!width || !height) {
            return
        }
        const ratio = cellWidth / cellHeight
        const fittedWidth = Math.min(width, height * ratio)
        const fittedHeight = fittedWidth / ratio
        const imports = current.elements.some((element) => element.type === "import") ? importsRevision() : 0
        const key = `${current.id}|${current.updated}|${current.extent.cols}x${current.extent.rows}|${preferences.showsGuides()}|${preferences.showsDividers()}|${preferences.paperStyle()}|${preferences.writingFont()}|${fittedWidth}|${fittedHeight}|${window.devicePixelRatio || 1}|${imports}`
        if (key === renderedKey) {
            return
        }
        renderedKey = key
        thumbnail.style.width = `${fittedWidth}px`
        thumbnail.style.height = `${fittedHeight}px`
        if (thumbnails.has(key)) {
            draw(key)
        } else {
            scheduleThumbnail(() => draw(key))
        }
    }
    tile.update = (next, nextTitle, nextCaption) => {
        current = next
        const look = noteLook(next)
        icon.replaceChildren(glyph(look.icon, { color: look.color, size: tileIcons.note }))
        name.textContent = nextTitle
        label.textContent = nextCaption.toUpperCase()
        label.hidden = !nextCaption
        fitName()
        render()
    }
    tile.render = render
    const observer = new ResizeObserver(() => {
        fitName()
        render()
    })
    observer.observe(thumbnailHost)
    squircle(tile, { radius: squircleRadius.tile, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    tile.update(page, title, caption)
    return tile
}

function compactAddTile(glyphName, title, action) {
    const tile = create("button", "compact-add-tile", glyph(glyphName, { color: tokens.semantic.create, size: tileIcons.add }), create("span", "add-tile-label", glyph("plus", { color: tokens.semantic.create, size: 16 }), create("span", "", title.toUpperCase())))
    squircle(tile, { radius: squircleRadius.tile, fill: tokens.palette.ground })
    pressable(tile)
    tile.addEventListener("click", action)
    appear(tile, 0)
    return tile
}

function addFolderTile(action) {
    const preview = create("div", "add-tile-preview", glyph("folder", { color: tokens.semantic.create, size: tileIcons.folder }))
    const tile = create("button", "add-folder-tile", preview, create("span", "add-tile-label", glyph("plus", { color: tokens.semantic.create, size: 16 }), create("span", "", "ADD FOLDER")))
    squircle(tile, { radius: squircleRadius.panel, fill: tokens.palette.ground, border: tokens.palette.border_control, borderWidth: 1.5 })
    pressable(tile)
    tile.addEventListener("click", action)
    appear(tile, 0)
    return tile
}

export class GridScreen {
    constructor(app) {
        this.app = app
        this.notebookId = null
        this.element = create("div", "screen grid-screen")
        this.scroller = create("div", "grid-scroller")
        this.spacer = create("div", "grid-spacer")
        this.content = null
        this.scroller.append(this.spacer)
        this.element.append(this.scroller)
        this.tiles = new Map()
        this.stacks = new Map()
        this.openGroups = new Set()
        this.drag = null
        this.arrangedFolders = null
        this.arrangedNotes = null
        this.lastSignature = null
        this.resizeObserver = new ResizeObserver(() => {
            this.layoutMasonry(false)
            this.layoutColumns()
        })
        this.resizeObserver.observe(this.scroller)
        this.bindGroupClosing()
        this.unsubscribeImports = subscribeImports(() => {
            for (const holder of this.tiles.values()) {
                holder.tile?.render?.()
            }
        })
    }

    destroy() {
        this.resizeObserver.disconnect()
        this.unsubscribeImports()
        this.stacks.forEach((stack) => stack.destroy())
    }

    get library() {
        return this.app.library
    }

    setFolder(notebookId) {
        if (notebookId === this.notebookId && this.content) {
            return
        }
        this.notebookId = notebookId
        this.drag = null
        this.arrangedFolders = null
        this.arrangedNotes = null
        const old = this.content
        if (old) {
            old.style.pointerEvents = "none"
            old.style.position = "absolute"
            old.style.top = `${old.offsetTop}px`
            old.style.left = "0"
            old.style.right = "0"
            animate(old, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("section_leave"), curveName: "power_two_in", fill: "forwards" }).finished.then(() => old.remove())
        }
        this.stacks.forEach((stack) => stack.destroy())
        this.stacks = new Map()
        this.tiles = new Map()
        this.content = create("div", "grid-content")
        this.scroller.append(this.content)
        this.scroller.scrollTop = 0
        if (old) {
            animate(this.content, [{ opacity: 0, transform: `scale(${tokens.motion.scales.folder_enter})` }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("section_enter"), curveName: "power_two_out", delay: duration("section_enter_delay") })
        }
        this.lastSignature = null
    }

    trimmedQuery() {
        return this.app.navigator.query.trim().toLowerCase()
    }

    groups() {
        return this.library.groups(this.notebookId)
    }

    isGrouped(id) {
        return this.groups().some((group) => group.members.includes(id))
    }

    folders() {
        const items = this.library.folders(this.notebookId).filter((folder) => !this.isGrouped(folder.id))
        if (!this.arrangedFolders) {
            return items
        }
        return this.arrangedFolders.map((id) => items.find((item) => item.id === id)).filter(Boolean)
    }

    notes() {
        if (!this.notebookId) {
            return []
        }
        const items = this.library.pages(this.notebookId).filter((page) => !this.isGrouped(page.id))
        if (!this.arrangedNotes) {
            return items
        }
        return this.arrangedNotes.map((id) => items.find((item) => item.id === id)).filter(Boolean)
    }

    hasGroups(isFolders) {
        return this.groups().some((group) => group.isFolders === isFolders)
    }

    update() {
        if (this.notebookId && !this.library.notebook(this.notebookId)) {
            this.app.navigator.go({ kind: "library" })
            return
        }
        this.spacer.style.height = `${Math.max(0, this.app.chromeLayout.bottom)}px`
        const signature = JSON.stringify([
            this.trimmedQuery(),
            this.groups(),
            [...this.openGroups],
            this.library.folders(this.notebookId).map((folder) => [folder.id, folder.title, folder.color, folder.icon, this.library.folderSummary(folder.id)]),
            this.notebookId ? this.library.pages(this.notebookId).map((page) => [page.id, page.updated, this.library.noteTitle(page)]) : [],
            this.trimmedQuery() ? this.library.liveNotebooks().map((folder) => [folder.id, folder.title, folder.updated]) : null,
            this.trimmedQuery() ? this.library.liveNotebooks().flatMap((folder) => this.library.pages(folder.id).map((page) => [page.id, page.updated])) : null,
            preferences.paperStyle(),
            preferences.showsGuides(),
            preferences.showsDividers(),
        ])
        if (signature === this.lastSignature || this.drag) {
            return
        }
        this.lastSignature = signature
        this.build()
    }

    build() {
        const content = this.content
        const scrollTop = this.scroller.scrollTop
        const usedTiles = new Set()
        this.usedTiles = usedTiles
        const usedStacks = new Set()
        this.usedStacks = usedStacks
        const sections = []
        if (this.trimmedQuery()) {
            sections.push(...this.results())
        } else if (this.notebookId) {
            sections.push(...this.foldersSection(), ...this.notesSection())
        } else {
            sections.push(...this.foldersSection())
        }
        content.replaceChildren(...sections)
        for (const [key] of this.tiles) {
            if (!usedTiles.has(key)) {
                this.tiles.delete(key)
            }
        }
        for (const [key, stack] of this.stacks) {
            if (!usedStacks.has(key)) {
                stack.destroy()
                this.stacks.delete(key)
            }
        }
        this.layoutMasonry(false)
        this.layoutColumns()
        this.scroller.scrollTop = scrollTop
    }

    heading(text) {
        return create("div", "grid-heading", microLabel(text))
    }

    folderGrid(className = "folder-grid") {
        const grid = create("div", className)
        grid.dataset.minimum = "230"
        grid.dataset.maximum = "320"
        return grid
    }

    layoutColumns() {
        for (const grid of this.content?.querySelectorAll("[data-minimum]") ?? []) {
            const width = grid.clientWidth
            if (!width) {
                continue
            }
            const columns = adaptiveColumns(width, Number(grid.dataset.minimum), Number(grid.dataset.maximum))
            grid.style.gridTemplateColumns = `repeat(${columns.count}, ${columns.width}px)`
        }
    }

    foldersSection() {
        const folders = this.folders()
        if (this.notebookId && folders.length === 0 && !this.hasGroups(true)) {
            return []
        }
        const parts = []
        if (this.notebookId) {
            parts.push(this.heading("Folders"))
        }
        parts.push(...this.groupRows(true))
        const grid = this.folderGrid()
        grid.classList.toggle("is-top", !this.notebookId)
        if (!this.notebookId) {
            grid.append(this.cachedTile("add-folder", () => addFolderTile(() => this.app.navigator.show({ kind: "newFolder", parentId: null }))))
        }
        folders.forEach((folder, index) => grid.append(this.folderTileFor(folder, index + 1, true)))
        parts.push(grid)
        return parts
    }

    notesSection() {
        const notebookId = this.notebookId
        const heading = this.heading("Notes")
        heading.classList.add("is-notes")
        const masonry = create("div", "masonry")
        this.masonry = masonry
        const adds = this.cachedTile("add-stack", () => create("div", "add-stack",
            compactAddTile("note", "Add note", () => this.app.navigator.show({ kind: "newNote", notebookId: this.notebookId })),
            compactAddTile("folder", "Add folder", () => this.app.navigator.show({ kind: "newFolder", parentId: this.notebookId })),
        ))
        adds.dataset.span = "1"
        adds.dataset.rows = "1"
        masonry.append(adds)
        this.notes().forEach((page, index) => {
            masonry.append(this.noteTileFor(page, index + 1, true))
        })
        return [heading, ...this.groupRows(false), masonry].filter(() => notebookId)
    }

    masonryMetrics(width) {
        const count = Math.max(1, Math.floor((width + gridSpacing) / (noteColumnWidth + gridSpacing)))
        const columnWidth = (width - gridSpacing * (count - 1)) / count
        return { count, columnWidth, unit: noteUnitHeight(columnWidth) }
    }

    masonryFrames(cells, width) {
        const { count, columnWidth, unit } = this.masonryMetrics(width)
        const heights = new Array(count).fill(0)
        const frames = cells.map((cell) => {
            const span = Math.min(count, Math.max(1, cell.span || 1))
            const rows = Math.max(1, cell.rows || 1)
            const tileWidth = columnWidth * span + gridSpacing * (span - 1)
            const tileHeight = unit * rows + gridSpacing * (rows - 1)
            let bestColumn = 0
            let bestTop = Infinity
            for (let column = 0; column <= count - span; column += 1) {
                const top = Math.max(...heights.slice(column, column + span))
                if (top < bestTop - 0.5) {
                    bestTop = top
                    bestColumn = column
                }
            }
            for (let column = bestColumn; column < bestColumn + span; column += 1) {
                heights[column] = bestTop + tileHeight + gridSpacing
            }
            return { left: bestColumn * (columnWidth + gridSpacing), top: bestTop, width: tileWidth, height: tileHeight }
        })
        return { frames, height: Math.max(0, Math.max(...heights) - gridSpacing) }
    }

    layoutMasonry(isAnimated) {
        const masonry = this.masonry
        if (!masonry?.isConnected) {
            return
        }
        const width = masonry.clientWidth
        if (!width) {
            return
        }
        const before = isAnimated ? new Map([...masonry.children].map((child) => [child, child.getBoundingClientRect()])) : null
        const children = [...masonry.children]
        const { frames, height } = this.masonryFrames(children.map((child) => ({ span: Number(child.dataset.span) || 1, rows: Number(child.dataset.rows) || 1 })), width)
        children.forEach((child, index) => {
            const frame = frames[index]
            child.style.left = `${frame.left}px`
            child.style.top = `${frame.top}px`
            child.style.width = `${frame.width}px`
            child.style.height = `${frame.height}px`
        })
        masonry.style.height = `${height}px`
        if (before) {
            for (const [child, rect] of before) {
                const after = child.getBoundingClientRect()
                const deltaX = rect.left - after.left
                const deltaY = rect.top - after.top
                if (Math.abs(deltaX) > 0.5 || Math.abs(deltaY) > 0.5) {
                    springAnimate(child, [{ translate: `${deltaX}px ${deltaY}px` }, { translate: "0px 0px" }], "placement")
                }
            }
        }
        this.layoutColumns()
    }

    groupRows(isFolders) {
        const shown = this.groups().filter((group) => group.isFolders === isFolders).map((group) => ({
            ...group,
            members: group.members.filter((id) => (isFolders ? this.library.notebook(id) && this.library.parentOf(id) === this.notebookId : this.library.page(id)?.notebook === this.notebookId)),
        })).filter((group) => group.members.length > 0)
        return shown.map((group) => {
            const key = `${group.id}|${group.members.join(",")}|${group.title}`
            this.usedStacks.add(key)
            let stack = this.stacks.get(key)
            if (!stack) {
                stack = new StackGroup({
                    group,
                    caption: `${group.members.length} ${isFolders ? "folder" : "note"}${group.members.length === 1 ? "" : "s"}`,
                    isOpen: this.openGroups.has(group.id),
                    isSwipeEnabled: () => !this.drag,
                    cardHeight: (cell) => (isFolders ? (cell - 28) / 1.25 + 28 + 12 + 44 : noteUnitHeight(cell)),
                    onToggle: (isOpen) => {
                        if (isOpen) {
                            this.openGroups.add(group.id)
                        } else {
                            this.openGroups.delete(group.id)
                        }
                        stack.setOpen(isOpen)
                    },
                    onMenu: (point) => this.showGroupMenu(group, point),
                    card: (id) => this.groupCard(id, isFolders, group.id),
                })
                this.stacks.set(key, stack)
            }
            stack.setOpen(this.openGroups.has(group.id))
            const row = create("div", "group-row", stack.element)
            row.dataset.group = group.id
            row.dataset.kind = isFolders ? "folder" : "note"
            return row
        })
    }

    groupCard(id, isFolders, groupId) {
        if (isFolders) {
            const folder = this.library.notebook(id)
            return folder ? this.makeFolderTile(folder, 0, true, false, groupId) : create("div")
        }
        const page = this.library.page(id)
        return page ? this.makeNoteTile(page, 0, true, false, groupId) : create("div")
    }

    results() {
        const query = this.trimmedQuery()
        const matchingFolders = this.library.liveNotebooks().filter((folder) => folder.title.toLowerCase().includes(query))
        const matchingNotes = this.library.liveNotebooks().flatMap((folder) => this.library.pages(folder.id)).filter((page) => this.library.noteTitle(page).toLowerCase().includes(query))
        const parts = []
        if (matchingFolders.length) {
            parts.push(this.heading("Folders"))
            const grid = this.folderGrid()
            matchingFolders.forEach((folder, index) => grid.append(this.makeFolderTile(folder, index, false, true)))
            parts.push(grid)
        }
        if (matchingNotes.length) {
            const heading = this.heading("Notes")
            heading.classList.add("is-notes")
            parts.push(heading)
            const grid = this.folderGrid("note-grid")
            grid.dataset.minimum = "170"
            grid.dataset.maximum = "240"
            matchingNotes.forEach((page, index) => grid.append(this.makeNoteTile(page, index, false, true)))
            parts.push(grid)
        }
        if (!matchingFolders.length && !matchingNotes.length) {
            parts.push(create("div", "grid-empty", microLabel("Nothing found")))
        }
        return parts
    }

    cachedTile(key, make) {
        this.usedTiles.add(key)
        let tile = this.tiles.get(key)
        if (!tile) {
            tile = make()
            this.tiles.set(key, tile)
        }
        return tile
    }

    folderTileFor(folder, rank, isDraggable) {
        const key = `folder:${folder.id}`
        const caption = this.library.folderSummary(folder.id)
        const existing = this.tiles.get(key)
        if (existing) {
            this.usedTiles.add(key)
            existing.tile.update(folder, caption)
            return existing
        }
        return this.cachedTile(key, () => this.makeFolderTile(folder, rank, isDraggable, false))
    }

    noteTileFor(page, rank, isDraggable) {
        const key = `note:${page.id}`
        const caption = page.extent.cols * page.extent.rows > 1 ? `${page.extent.cols}×${page.extent.rows}` : ""
        const existing = this.tiles.get(key)
        if (existing) {
            this.usedTiles.add(key)
            existing.tile.update(page, this.library.noteTitle(page), caption)
            return existing
        }
        return this.cachedTile(key, () => this.makeNoteTile(page, rank, isDraggable, false))
    }

    makeFolderTile(folder, rank, isDraggable, isResult, groupId = null) {
        const parentId = this.library.parentOf(folder.id)
        const caption = isResult && parentId ? this.library.path(parentId) : this.library.folderSummary(folder.id)
        const tile = folderTile(folder, caption)
        const holder = create("div", "tile-holder", tile)
        holder.tile = tile
        holder.dataset.key = `folder:${folder.id}`
        holder.dataset.draggable = String(isDraggable && !groupId)
        appear(holder, rank)
        tileGestures(holder, this.callbacks("folder", folder.id, isDraggable, () => this.app.navigator.go({ kind: "notebook", notebookId: folder.id }), (point) => this.showFolderMenu(folder.id, point), groupId))
        return holder
    }

    makeNoteTile(page, rank, isDraggable, isResult, groupId = null) {
        const caption = isResult ? this.library.path(page.notebook) : page.extent.cols * page.extent.rows > 1 ? `${page.extent.cols}×${page.extent.rows}` : ""
        const tile = noteTile(page, this.library.noteTitle(page), caption)
        const holder = create("div", "tile-holder is-note", tile)
        holder.tile = tile
        holder.dataset.key = `note:${page.id}`
        holder.dataset.draggable = String(isDraggable && !groupId)
        appear(holder, rank)
        tileGestures(holder, this.callbacks("note", page.id, isDraggable, (frame) => this.app.navigator.go({ kind: "page", notebookId: page.notebook, pageId: page.id }, frame), (point) => this.showNoteMenu(page.id, point), groupId))
        return holder
    }

    callbacks(kind, id, isDraggable, onTap, onMenu, groupId = null) {
        return {
            onTap,
            onMenu,
            onDragBegin: isDraggable ? (point) => this.beginDrag(kind, id, point, groupId) : null,
            onDragMove: isDraggable ? (point) => this.moveDrag(point) : null,
            onDragEnd: isDraggable ? (point, isDrop) => this.endDrag(point, isDrop) : null,
        }
    }

    beginDrag(kind, id, point, groupId = null) {
        this.app.menu.dismiss()
        const scope = groupId ? `.group-row[data-group='${groupId}'] ` : ""
        const holder = this.content.querySelector(`${scope}.tile-holder[data-key='${kind}:${id}']`)
        if (!holder) {
            return
        }
        const rect = holder.getBoundingClientRect()
        this.arrangedFolders = this.folders().map((folder) => folder.id)
        this.arrangedNotes = this.notes().map((page) => page.id)
        const ghost = holder.cloneNode(true)
        ghost.className = "tile-ghost"
        ghost.getAnimations?.().forEach((running) => running.cancel())
        ghost.style.opacity = "1"
        ghost.style.width = `${rect.width}px`
        ghost.style.height = `${rect.height}px`
        ghost.querySelectorAll("canvas").forEach((canvas, index) => {
            const source = holder.querySelectorAll("canvas")[index]
            canvas.width = source.width
            canvas.height = source.height
            canvas.getContext("2d").drawImage(source, 0, 0)
        })
        const grab = [point[0] - rect.left, point[1] - rect.top]
        ghost.style.transformOrigin = `${grab[0]}px ${grab[1]}px`
        this.app.overlayHost.append(ghost)
        animate(ghost, [{ scale: "1" }, { scale: String(tokens.motion.scales.held) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        holder.classList.add("is-source")
        this.drag = { kind, id, holder, ghost, grab, target: null, groupId, placeholder: null }
        this.moveDrag(point)
    }

    shownOrder(kind) {
        return (kind === "folder" ? this.arrangedFolders : this.arrangedNotes) ?? []
    }

    setShownOrder(kind, order) {
        if (kind === "folder") {
            this.arrangedFolders = order
            this.reorderLive(".folder-grid", "folder", order)
        } else {
            this.arrangedNotes = order
            this.reorderLive(".masonry", "note", order)
        }
    }

    isLoose(drag) {
        return Boolean(drag.groupId) && drag.target?.kind === "slot"
    }

    moveDrag(point) {
        const drag = this.drag
        if (!drag) {
            return
        }
        drag.ghost.style.left = `${point[0] - drag.grab[0]}px`
        drag.ghost.style.top = `${point[1] - drag.grab[1]}px`
        const previous = drag.target
        const target = this.dropTarget(drag, point)
        if (target) {
            drag.target = target
        } else {
            const index = this.slotIndex(drag, point)
            if (index !== null) {
                drag.target = { kind: "slot", index }
            } else if (drag.target?.kind !== "slot") {
                drag.target = null
            }
        }
        drag.ghost.classList.toggle("is-into", drag.target?.kind === "into")
        this.markTarget(previous, false)
        this.markTarget(drag.target, true)
        this.syncPlaceholder(drag)
        if (drag.target?.kind !== "slot") {
            return
        }
        const others = this.shownOrder(drag.kind).filter((candidate) => candidate !== drag.id)
        const order = [...others]
        order.splice(Math.min(drag.target.index, others.length), 0, drag.id)
        if (order.join() !== this.shownOrder(drag.kind).join()) {
            this.setShownOrder(drag.kind, order)
        }
    }

    markTarget(target, isMarked) {
        const element = target?.kind === "into"
            ? this.content.querySelector(`.tile-holder[data-key='folder:${target.id}']`)
            : target?.kind === "group" ? this.content.querySelector(`.group-row[data-group='${target.id}']`) : null
        if (!element || element.classList.contains("is-drop-target") === isMarked) {
            return
        }
        element.classList.toggle("is-drop-target", isMarked)
        if (target.kind === "into") {
            animate(element, [{ scale: isMarked ? "1" : "1.04" }, { scale: isMarked ? "1.04" : "1" }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
        }
    }

    syncPlaceholder(drag) {
        if (!drag.groupId) {
            return
        }
        const isLoose = this.isLoose(drag)
        if (isLoose && !drag.placeholder) {
            const container = this.content.querySelector(drag.kind === "folder" ? ".folder-grid" : ".masonry")
            if (!container) {
                return
            }
            const placeholder = drag.kind === "folder"
                ? this.makeFolderTile(this.library.notebook(drag.id), 0, false, false)
                : this.makeNoteTile(this.library.page(drag.id), 0, false, false)
            placeholder.getAnimations().forEach((running) => running.cancel())
            placeholder.classList.add("is-source")
            container.append(placeholder)
            drag.placeholder = placeholder
        } else if (!isLoose && drag.placeholder) {
            drag.placeholder.remove()
            drag.placeholder = null
            this.setShownOrder(drag.kind, this.shownOrder(drag.kind).filter((candidate) => candidate !== drag.id))
        }
    }

    reorderLive(selector, kind, order) {
        const container = this.content.querySelector(selector)
        if (!container) {
            return
        }
        const before = new Map([...container.children].map((child) => [child, child.getBoundingClientRect()]))
        for (const id of order) {
            const holder = container.querySelector(`:scope > .tile-holder[data-key='${kind}:${id}']`)
            if (holder) {
                container.append(holder)
            }
        }
        if (kind === "note") {
            this.layoutMasonry(false)
        }
        for (const [child, rect] of before) {
            const after = child.getBoundingClientRect()
            const deltaX = rect.left - after.left
            const deltaY = rect.top - after.top
            if (Math.abs(deltaX) > 0.5 || Math.abs(deltaY) > 0.5) {
                springAnimate(child, [{ translate: `${deltaX}px ${deltaY}px` }, { translate: "0px 0px" }], "placement")
            }
        }
    }

    folderSlotFrames(grid, count) {
        const style = getComputedStyle(grid)
        const columns = style.gridTemplateColumns.split(" ").filter(Boolean)
        const columnCount = Math.max(1, columns.length)
        const columnWidth = parseFloat(columns[0]) || 230
        const gap = parseFloat(style.columnGap) || gridSpacing
        const rowGap = parseFloat(style.rowGap) || gridSpacing
        const first = grid.firstElementChild?.getBoundingClientRect()
        const area = grid.getBoundingClientRect()
        const left = area.left + (parseFloat(style.paddingLeft) || 0)
        const top = area.top + (parseFloat(style.paddingTop) || 0)
        const height = first?.height || columnWidth
        return Array.from({ length: count }, (unused, index) => {
            const column = index % columnCount
            const row = Math.floor(index / columnCount)
            const x = left + column * (columnWidth + gap)
            const y = top + row * (height + rowGap)
            return { left: x, top: y, right: x + columnWidth, bottom: y + height }
        })
    }

    slotIndex(drag, point) {
        const isFolder = drag.kind === "folder"
        const area = this.content.querySelector(isFolder ? ".folder-grid" : ".masonry")
        if (!area) {
            return null
        }
        const order = this.shownOrder(drag.kind)
        const others = order.filter((candidate) => candidate !== drag.id)
        const leading = isFolder ? (this.notebookId ? 0 : 1) : 1
        let candidates
        if (isFolder) {
            const frames = this.folderSlotFrames(area, leading + others.length + 1)
            candidates = others.concat([null]).map((unused, index) => frames[leading + index])
        } else {
            const origin = area.getBoundingClientRect()
            const { frames } = this.masonryFrames(Array.from({ length: leading + others.length + 1 }, () => ({ span: 1, rows: 1 })), area.clientWidth)
            candidates = others.concat([null]).map((unused, index) => {
                const frame = frames[leading + index]
                return { left: origin.left + frame.left, top: origin.top + frame.top, right: origin.left + frame.left + frame.width, bottom: origin.top + frame.top + frame.height }
            })
        }
        const contains = (rect) => point[0] >= rect.left && point[0] <= rect.right && point[1] >= rect.top && point[1] <= rect.bottom
        const bounds = area.getBoundingClientRect()
        const isNear = (point[0] >= bounds.left - slotReach && point[0] <= bounds.right + slotReach && point[1] >= bounds.top - slotReach && point[1] <= bounds.bottom + slotReach) || candidates.some(contains)
        if (!isNear) {
            return null
        }
        const isShown = !drag.groupId || this.isLoose(drag)
        const current = isShown ? order.indexOf(drag.id) : -1
        if (current >= 0 && current < candidates.length && contains(candidates[current])) {
            return current
        }
        const containing = candidates.map((rect, index) => index).filter((index) => contains(candidates[index]))
        const pool = containing.length ? containing : candidates.map((rect, index) => index)
        const distance = (index) => Math.hypot((candidates[index].left + candidates[index].right) / 2 - point[0], (candidates[index].top + candidates[index].bottom) / 2 - point[1])
        return pool.reduce((best, index) => (distance(index) < distance(best) ? index : best), pool[0])
    }

    dropTarget(drag, point) {
        const back = this.app.chromeLayout.back
        if (this.notebookId && back && point[0] >= back.x && point[0] <= back.x + back.width && point[1] >= back.y && point[1] <= back.y + back.height) {
            const parentId = this.library.parentOf(this.notebookId)
            return drag.kind === "folder" || parentId ? { kind: "up", id: parentId } : null
        }
        for (const holder of this.content.querySelectorAll(".tile-holder[data-key^='folder:']")) {
            const rect = holder.getBoundingClientRect()
            if (holder.classList.contains("is-source") || point[0] < rect.left || point[0] > rect.right || point[1] < rect.top || point[1] > rect.bottom) {
                continue
            }
            const id = holder.dataset.key.slice("folder:".length)
            if (id === drag.id || !this.library.notebook(id)) {
                continue
            }
            if (drag.kind === "note") {
                return { kind: "into", id }
            }
            const share = (point[0] - rect.left) / Math.max(1, rect.width)
            if (share > dropEdgeShare && share < 1 - dropEdgeShare && this.library.canMoveNotebook(drag.id, id)) {
                return { kind: "into", id }
            }
        }
        for (const row of this.content.querySelectorAll(`.group-row[data-kind='${drag.kind}']`)) {
            const rect = row.getBoundingClientRect()
            if (point[0] >= rect.left && point[0] <= rect.right && point[1] >= rect.top && point[1] <= rect.bottom) {
                return { kind: "group", id: row.dataset.group }
            }
        }
        return null
    }

    endDrag(point, isDrop) {
        const drag = this.drag
        if (!drag) {
            return
        }
        if (isDrop) {
            this.moveDrag(point)
        }
        const target = isDrop ? drag.target : null
        this.drag = null
        drag.holder.classList.remove("is-source")
        drag.placeholder?.remove()
        this.markTarget(drag.target, false)
        this.content.querySelectorAll(".is-drop-target").forEach((element) => {
            element.classList.remove("is-drop-target")
            element.getAnimations().forEach((running) => running.cancel())
        })
        animate(drag.ghost, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("state"), curveName: "power_two_out", fill: "forwards" }).finished.then(() => drag.ghost.remove())
        const arrangedFolders = this.arrangedFolders
        const arrangedNotes = this.arrangedNotes
        this.arrangedFolders = null
        this.arrangedNotes = null
        this.lastSignature = null
        const leaveGroup = () => {
            if (drag.groupId) {
                this.library.removeFromGroup(drag.id, this.notebookId)
            }
        }
        if (target?.kind === "into") {
            leaveGroup()
            if (drag.kind === "folder") {
                this.library.moveNotebook(drag.id, target.id)
            } else {
                this.library.movePage(drag.id, target.id)
            }
        } else if (target?.kind === "up") {
            leaveGroup()
            if (drag.kind === "folder") {
                this.library.moveNotebook(drag.id, target.id)
            } else if (target.id) {
                this.library.movePage(drag.id, target.id)
            }
        } else if (target?.kind === "group") {
            if (target.id !== drag.groupId) {
                this.library.addToGroup(drag.id, target.id, this.notebookId)
            }
        } else if (isDrop && (!drag.groupId || target?.kind === "slot")) {
            leaveGroup()
            if (drag.kind === "folder" && arrangedFolders) {
                this.library.arrangeFolders(arrangedFolders)
            } else if (drag.kind === "note" && arrangedNotes) {
                this.library.arrangePages(arrangedNotes)
            }
        }
        this.update()
    }

    closeGroups() {
        if (!this.openGroups.size) {
            return
        }
        this.openGroups.clear()
        for (const stack of this.stacks.values()) {
            stack.setOpen(false)
        }
    }

    bindGroupClosing() {
        let swipe = null
        this.scroller.addEventListener("pointerdown", (event) => {
            const isInsideOpenGroup = [...this.content?.querySelectorAll(".group-row") ?? []].some((row) => this.openGroups.has(row.dataset.group) && row.contains(event.target))
            swipe = isInsideOpenGroup || event.button !== 0 ? null : { start: [event.clientX, event.clientY], pointerId: event.pointerId, isDecided: false }
        })
        this.scroller.addEventListener("pointermove", (event) => {
            if (!swipe || swipe.pointerId !== event.pointerId || swipe.isDecided) {
                return
            }
            const travel = [event.clientX - swipe.start[0], event.clientY - swipe.start[1]]
            if (Math.hypot(...travel) < 22) {
                return
            }
            swipe.isDecided = true
            if (Math.abs(travel[0]) > Math.abs(travel[1]) * 2 && !this.drag) {
                this.closeGroups()
            }
        })
        this.scroller.addEventListener("pointerup", () => {
            swipe = null
        })
        this.scroller.addEventListener("click", (event) => {
            const isEmpty = !event.target.closest(".tile-holder, .stack-card, .stack-heading, .stack-arrow, .stack-shut-hit, .add-stack, .grid-heading button")
            if (isEmpty) {
                this.closeGroups()
            }
        })
    }

    menuTitle(action, memberId) {
        switch (action) {
        case "rename": return "Rename"
        case "appearance": return "Icon & colour"
        case "move": return "Move"
        case "delete_notebook":
        case "delete_page": return "Delete"
        case "group": return this.isGrouped(memberId) ? "Remove from group" : "Add to group"
        default: return action
        }
    }

    toggleGroup(target, memberId) {
        if (this.isGrouped(memberId)) {
            this.library.removeFromGroup(memberId, this.notebookId)
        } else {
            this.app.navigator.show({ kind: "pickGroup", target, parentId: this.notebookId })
        }
    }

    showFolderMenu(folderId, point) {
        const folder = this.library.notebook(folderId)
        if (!folder) {
            return
        }
        const slots = slotsFromTokens([...tokens.menus.notebook, ...tokens.menus.grouping], {
            title: (action) => this.menuTitle(action, folderId),
            perform: (action) => {
                switch (action) {
                case "rename": this.app.navigator.show({ kind: "renameFolder", notebookId: folderId }); break
                case "appearance": this.app.navigator.show({ kind: "appearance", target: { kind: "folder", id: folderId } }); break
                case "move": this.app.navigator.show({ kind: "move", target: { kind: "folder", id: folderId } }); break
                case "delete_notebook": this.library.deleteNotebook(folderId); break
                case "group": this.toggleGroup({ kind: "folder", id: folderId }, folderId); break
                default: break
                }
            },
        })
        this.app.menu.present(slots, point, folder.title)
    }

    showNoteMenu(pageId, point) {
        const page = this.library.page(pageId)
        if (!page) {
            return
        }
        const isReadOnly = this.library.isReadOnly(pageId)
        const slots = slotsFromTokens([...tokens.menus.page_tile, ...tokens.menus.grouping], {
            title: (action) => this.menuTitle(action, pageId),
            isEnabled: (action) => action === "delete_page" || action === "group" || !isReadOnly,
            perform: (action) => {
                switch (action) {
                case "rename": this.app.navigator.show({ kind: "renameNote", pageId }); break
                case "appearance": this.app.navigator.show({ kind: "appearance", target: { kind: "note", id: pageId } }); break
                case "move": this.app.navigator.show({ kind: "move", target: { kind: "note", id: pageId } }); break
                case "delete_page": this.library.deletePage(pageId); break
                case "group": this.toggleGroup({ kind: "note", id: pageId }, pageId); break
                default: break
                }
            },
        })
        this.app.menu.present(slots, point, this.library.noteTitle(page))
    }

    showGroupMenu(group, point) {
        const slots = slotsFromTokens(tokens.menus.group, {
            title: (action) => ({ rename: "Rename", ungroup: "Ungroup" })[action] ?? action,
            perform: (action) => {
                if (action === "rename") {
                    this.app.navigator.show({ kind: "renameGroup", groupId: group.id, parentId: this.notebookId })
                } else if (action === "ungroup") {
                    this.openGroups.delete(group.id)
                    this.library.ungroup(group.id)
                }
            },
        })
        this.app.menu.present(slots, point, group.title)
    }
}
