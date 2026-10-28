import { create, microLabel, pressable } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { cellHeight, cellWidth, paperHeight, paperWidth } from "./model.js"
import { animate, duration } from "./motion.js"
import { springAnimate } from "./pill.js"
import * as preferences from "./preferences.js"
import { renderThumbnail } from "./renderer.js"
import { subscribeImports } from "./imports.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { StackGroup } from "./stackGroup.js"
import { tokens, withAlpha } from "./tokens.js"

const gridSpacing = 18
const sidePadding = 28
const dropEdgeShare = 0.22
const noteColumnWidth = 170
const dragTolerance = 8
const tileIcons = { folder: 64, add: 40, note: 22 }

export function folderLook(notebook) {
    return { color: notebook?.color ?? tokens.folders.default_color, icon: notebook?.icon ?? tokens.folders.default_icon }
}

export function noteLook(page) {
    return { color: page?.color ?? tokens.palette.text_muted, icon: page?.icon ?? tokens.folders.note_icon }
}

export function noteUnitHeight(width) {
    return (width - 24) * (cellHeight / cellWidth) + 24 + 10 + tileIcons.note
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
    const thumbnailHost = create("div", "note-tile-thumbnail")
    const thumbnail = create("canvas", "note-tile-canvas")
    thumbnailHost.append(thumbnail)
    tile.append(header, thumbnailHost)
    let current = page
    let renderedKey = null
    const render = () => {
        const width = thumbnailHost.clientWidth
        const height = thumbnailHost.clientHeight
        if (!width || !height) {
            return
        }
        const ratio = paperWidth(current.extent) / paperHeight(current.extent)
        const fittedWidth = Math.min(width, height * ratio)
        const fittedHeight = fittedWidth / ratio
        const key = `${current.id}|${current.updated}|${current.extent.cols}x${current.extent.rows}|${preferences.showsGuides()}|${preferences.showsDividers()}|${preferences.paperStyle()}|${fittedWidth}|${fittedHeight}|${tile.importRevision ?? 0}`
        if (key === renderedKey) {
            return
        }
        renderedKey = key
        thumbnail.style.width = `${fittedWidth}px`
        thumbnail.style.height = `${fittedHeight}px`
        renderThumbnail(thumbnail, current, { showsGuides: preferences.showsGuides(), showsDividers: preferences.showsDividers(), paperStyle: preferences.paperStyle() })
    }
    tile.update = (next, nextTitle, nextCaption) => {
        current = next
        const look = noteLook(next)
        icon.replaceChildren(glyph(look.icon, { color: look.color, size: tileIcons.note }))
        name.textContent = nextTitle
        label.textContent = nextCaption.toUpperCase()
        label.hidden = !nextCaption
        render()
    }
    tile.render = render
    const observer = new ResizeObserver(render)
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
        this.resizeObserver = new ResizeObserver(() => this.layoutMasonry(false))
        this.resizeObserver.observe(this.scroller)
        this.unsubscribeImports = subscribeImports(() => {
            for (const tile of this.tiles.values()) {
                tile.importRevision = (tile.importRevision ?? 0) + 1
                tile.render?.()
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
        return preferences.groups(this.notebookId)
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
            const notesFirst = this.notes().length === 0 && !this.hasGroups(false)
            const folders = this.foldersSection()
            const notes = this.notesSection()
            sections.push(...(notesFirst ? [...notes, ...folders] : [...folders, ...notes]))
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
            const tile = this.noteTileFor(page, index + 1, true)
            tile.dataset.span = String(page.extent.cols)
            tile.dataset.rows = String(page.extent.rows)
            masonry.append(tile)
        })
        return [heading, ...this.groupRows(false), masonry].filter(() => notebookId)
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
        const count = Math.max(1, Math.floor((width + gridSpacing) / (noteColumnWidth + gridSpacing)))
        const columnWidth = (width - gridSpacing * (count - 1)) / count
        const unit = noteUnitHeight(columnWidth)
        const heights = new Array(count).fill(0)
        const before = isAnimated ? new Map([...masonry.children].map((child) => [child, child.getBoundingClientRect()])) : null
        for (const child of masonry.children) {
            const span = Math.min(count, Math.max(1, Number(child.dataset.span) || 1))
            const rows = Math.max(1, Number(child.dataset.rows) || 1)
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
            child.style.left = `${bestColumn * (columnWidth + gridSpacing)}px`
            child.style.top = `${bestTop}px`
            child.style.width = `${tileWidth}px`
            child.style.height = `${tileHeight}px`
        }
        masonry.style.height = `${Math.max(0, Math.max(...heights) - gridSpacing)}px`
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
                    card: (id) => this.groupCard(id, isFolders),
                })
                this.stacks.set(key, stack)
            }
            stack.setOpen(this.openGroups.has(group.id))
            const row = create("div", "group-row", stack.element)
            return row
        })
    }

    groupCard(id, isFolders) {
        if (isFolders) {
            const folder = this.library.notebook(id)
            return folder ? this.makeFolderTile(folder, 0, false, false) : create("div")
        }
        const page = this.library.page(id)
        return page ? this.makeNoteTile(page, 0, false, false) : create("div")
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

    makeFolderTile(folder, rank, isDraggable, isResult) {
        const parentId = this.library.parentOf(folder.id)
        const caption = isResult && parentId ? this.library.path(parentId) : this.library.folderSummary(folder.id)
        const tile = folderTile(folder, caption)
        const holder = create("div", "tile-holder", tile)
        holder.tile = tile
        holder.dataset.key = `folder:${folder.id}`
        holder.dataset.draggable = String(isDraggable)
        appear(holder, rank)
        tileGestures(holder, this.callbacks("folder", folder.id, isDraggable, () => this.app.navigator.go({ kind: "notebook", notebookId: folder.id }), (point) => this.showFolderMenu(folder.id, point)))
        return holder
    }

    makeNoteTile(page, rank, isDraggable, isResult) {
        const caption = isResult ? this.library.path(page.notebook) : page.extent.cols * page.extent.rows > 1 ? `${page.extent.cols}×${page.extent.rows}` : ""
        const tile = noteTile(page, this.library.noteTitle(page), caption)
        const holder = create("div", "tile-holder is-note", tile)
        holder.tile = tile
        holder.dataset.key = `note:${page.id}`
        holder.dataset.draggable = String(isDraggable)
        appear(holder, rank)
        tileGestures(holder, this.callbacks("note", page.id, isDraggable, (frame) => this.app.navigator.go({ kind: "page", notebookId: page.notebook, pageId: page.id }, frame), (point) => this.showNoteMenu(page.id, point)))
        return holder
    }

    callbacks(kind, id, isDraggable, onTap, onMenu) {
        return {
            onTap,
            onMenu,
            onDragBegin: isDraggable ? (point) => this.beginDrag(kind, id, point) : null,
            onDragMove: isDraggable ? (point) => this.moveDrag(point) : null,
            onDragEnd: isDraggable ? (point, isDrop) => this.endDrag(point, isDrop) : null,
        }
    }

    tileFrames() {
        const frames = []
        for (const holder of this.content.querySelectorAll(".tile-holder[data-draggable='true']")) {
            frames.push({ key: holder.dataset.key, rect: holder.getBoundingClientRect(), holder })
        }
        return frames
    }

    beginDrag(kind, id, point) {
        this.app.menu.dismiss()
        const holder = this.content.querySelector(`.tile-holder[data-key='${kind}:${id}']`)
        if (!holder) {
            return
        }
        const rect = holder.getBoundingClientRect()
        this.arrangedFolders = this.folders().map((folder) => folder.id)
        this.arrangedNotes = this.notes().map((page) => page.id)
        const ghost = holder.cloneNode(true)
        ghost.className = "tile-ghost"
        ghost.style.width = `${rect.width}px`
        ghost.style.height = `${rect.height}px`
        ghost.querySelectorAll("canvas").forEach((canvas, index) => {
            const source = holder.querySelectorAll("canvas")[index]
            canvas.width = source.width
            canvas.height = source.height
            canvas.getContext("2d").drawImage(source, 0, 0)
        })
        this.app.overlayHost.append(ghost)
        holder.classList.add("is-source")
        this.drag = { kind, id, holder, ghost, grab: [point[0] - rect.left, point[1] - rect.top], target: null }
        this.moveDrag(point)
    }

    moveDrag(point) {
        const drag = this.drag
        if (!drag) {
            return
        }
        drag.ghost.style.left = `${point[0] - drag.grab[0]}px`
        drag.ghost.style.top = `${point[1] - drag.grab[1]}px`
        const target = this.dropTarget(drag, point)
        const previousInto = drag.target?.kind === "into" ? drag.target.id : null
        drag.target = target
        drag.ghost.classList.toggle("is-into", target?.kind === "into")
        const nextInto = target?.kind === "into" ? target.id : null
        if (previousInto !== nextInto) {
            for (const [id, isTarget] of [[previousInto, false], [nextInto, true]]) {
                const holder = id ? this.content.querySelector(`.tile-holder[data-key='folder:${id}']`) : null
                if (holder) {
                    holder.classList.toggle("is-drop-target", isTarget)
                    animate(holder, [{ scale: isTarget ? "1" : "1.04" }, { scale: isTarget ? "1.04" : "1" }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
                }
            }
        }
        if (target?.kind === "before" || target?.kind === "after") {
            const isAfter = target.kind === "after"
            if (drag.kind === "folder") {
                const next = moved(this.arrangedFolders, drag.id, target.id, isAfter)
                if (next.join() !== this.arrangedFolders.join()) {
                    this.arrangedFolders = next
                    this.reorderLive(".folder-grid", "folder", next)
                }
            } else {
                const next = moved(this.arrangedNotes, drag.id, target.id, isAfter)
                if (next.join() !== this.arrangedNotes.join()) {
                    this.arrangedNotes = next
                    this.reorderLive(".masonry", "note", next)
                }
            }
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

    dropTarget(drag, point) {
        const back = this.app.chromeLayout.back
        if (this.notebookId && back && point[0] >= back.x && point[0] <= back.x + back.width && point[1] >= back.y && point[1] <= back.y + back.height) {
            const parentId = this.library.parentOf(this.notebookId)
            return drag.kind === "folder" || parentId ? { kind: "up", id: parentId } : null
        }
        for (const { key, rect } of this.tileFrames()) {
            if (point[0] < rect.left || point[0] > rect.right || point[1] < rect.top || point[1] > rect.bottom) {
                continue
            }
            const [kind, id] = key.split(":")
            if (id === drag.id) {
                continue
            }
            const share = (point[0] - rect.left) / Math.max(1, rect.width)
            if (kind === "folder" && (drag.kind === "note" || (share > dropEdgeShare && share < 1 - dropEdgeShare))) {
                if (drag.kind === "folder" && !this.library.canMoveNotebook(drag.id, id)) {
                    return null
                }
                return { kind: "into", id }
            }
            if (kind !== drag.kind) {
                return null
            }
            return { kind: share < 0.5 ? "before" : "after", id }
        }
        return drag.target?.kind === "before" || drag.target?.kind === "after" ? drag.target : null
    }

    endDrag(point, isDrop) {
        const drag = this.drag
        if (!drag) {
            return
        }
        const target = isDrop ? this.dropTarget(drag, point) : null
        this.drag = null
        drag.holder.classList.remove("is-source")
        this.content.querySelectorAll(".is-drop-target").forEach((holder) => {
            holder.classList.remove("is-drop-target")
            holder.getAnimations().forEach((running) => running.cancel())
        })
        animate(drag.ghost, [{ opacity: 1 }, { opacity: 0 }], { milliseconds: duration("state"), curveName: "power_two_out", fill: "forwards" }).finished.then(() => drag.ghost.remove())
        const arrangedFolders = this.arrangedFolders
        const arrangedNotes = this.arrangedNotes
        this.arrangedFolders = null
        this.arrangedNotes = null
        this.lastSignature = null
        if (target?.kind === "into") {
            if (drag.kind === "folder") {
                this.library.moveNotebook(drag.id, target.id)
            } else {
                this.library.movePage(drag.id, target.id)
            }
        } else if (target?.kind === "up") {
            if (drag.kind === "folder") {
                this.library.moveNotebook(drag.id, target.id)
            } else if (target.id) {
                this.library.movePage(drag.id, target.id)
            }
        } else if (isDrop) {
            if (drag.kind === "folder" && arrangedFolders) {
                this.library.arrangeFolders(arrangedFolders)
            } else if (drag.kind === "note" && arrangedNotes) {
                this.library.arrangePages(arrangedNotes)
            }
        }
        this.update()
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
            preferences.removeFromGroup(memberId, this.notebookId)
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
                    preferences.ungroup(group.id, this.notebookId)
                }
            },
        })
        this.app.menu.present(slots, point, group.title)
    }
}

function moved(order, id, otherId, isAfter) {
    const result = order.filter((candidate) => candidate !== id)
    const index = result.indexOf(otherId)
    if (index < 0) {
        return order
    }
    result.splice(isAfter ? index + 1 : index, 0, id)
    return result
}
