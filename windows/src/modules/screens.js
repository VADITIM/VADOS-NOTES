import { InkCanvas } from "./canvas.js"
import { create, microLabel, roundIconButton, searchField, settingsButton, topBar } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { cellCount, clampBox, paperHeight, paperWidth } from "./model.js"
import { tileAppear } from "./motion.js"
import { fontMetrics, renderThumbnail, textLayout } from "./renderer.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { PageTools } from "./pageTools.js"
import { TileDrag, tileGestures } from "./tileDrag.js"
import { paperStyle, textFontSize } from "./preferences.js"
import { folderLook, noteLook } from "./sheets.js"
import { readSetting, writeSetting } from "./storage.js"
import { inkOnPaper, tokens } from "./tokens.js"

const gridPadding = 28
const gridSpacing = 18

function plural(count, word) {
    return `${count} ${word}${count === 1 ? "" : "s"}`
}

function folderSummary(library, notebookId) {
    const notes = library.pages(notebookId).length
    const folders = library.folders(notebookId).length
    return folders ? `${plural(notes, "note")} · ${plural(folders, "folder")}` : plural(notes, "note")
}

export function noteTitle(library, page) {
    if (page.title) {
        return page.title
    }
    const index = library.pages(page.notebook).findIndex((candidate) => candidate.id === page.id)
    return `Note ${index + 1}`
}

const tileMenuColumns = 2

function thumbnail(page) {
    const canvas = create("canvas", "page-thumbnail")
    canvas.renderKey = null
    canvas.refresh = (nextPage) => {
        const showsGuides = readSetting("showsGuides", true)
        const style = paperStyle()
        const key = `${nextPage.id}-${nextPage.updated}-${nextPage.extent.cols}x${nextPage.extent.rows}-${showsGuides}-${style}-${canvas.clientWidth}x${canvas.clientHeight}`
        if (key === canvas.renderKey) {
            return
        }
        canvas.renderKey = key
        renderThumbnail(canvas, nextPage, showsGuides, style)
    }
    new ResizeObserver(() => canvas.refresh(canvas.page)).observe(canvas)
    canvas.page = page
    return canvas
}

export function overlayTopBar(screen, header) {
    header.classList.add("is-overlay")
    new ResizeObserver(() => screen.style.setProperty("--top-bar-height", `${header.offsetHeight}px`)).observe(header)
}

function settingsControl(app) {
    return settingsButton(() => app.showSheet({ kind: "settings" }))
}

function matches(text, query) {
    return text.toLocaleLowerCase().includes(query)
}

class GridScreen {
    constructor(app, notebookId) {
        this.app = app
        this.notebookId = notebookId
        this.element = create("section", "screen grid-screen")
        this.folderTiles = new Map()
        this.noteTiles = new Map()
        this.resultFolderTiles = new Map()
        this.resultNoteTiles = new Map()
        this.query = ""
        this.drag = null
        this.keyDown = (event) => {
            if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") {
                event.preventDefault()
                this.search.input.focus()
                this.search.input.select()
            }
        }
        window.addEventListener("keydown", this.keyDown)
    }

    destroy() {
        window.removeEventListener("keydown", this.keyDown)
        this.drag?.end(false)
    }

    mount({ title, label, onBack }) {
        this.search = searchField({
            placeholder: "Search",
            onChange: (value) => {
                this.query = value.trim().toLocaleLowerCase()
                this.update()
            },
        })
        this.header = topBar({ title, label, onBack, trailing: [this.search, settingsControl(this.app)] })
        this.content = create("div", "grid-content")
        this.scroller = create("div", "screen-scroll", this.content)
        this.element.append(this.scroller, this.header)
        overlayTopBar(this.element, this.header)
        this.browse = create("div", "grid-browse")
        this.results = create("div", "grid-results")
        this.resultFolderHeading = create("div", "grid-heading", microLabel("Folders"))
        this.resultFolderGrid = this.makeGrid("notebook-grid", 230, 320)
        this.resultNoteHeading = create("div", "grid-heading", microLabel("Notes"))
        this.resultNoteGrid = this.makeGrid("page-grid", 170, 240)
        this.resultEmpty = create("div", "empty-notice", microLabel("Nothing found"))
        this.results.append(this.resultFolderHeading, this.resultFolderGrid, this.resultNoteHeading, this.resultNoteGrid, this.resultEmpty)
        this.content.append(this.browse, this.results)
    }

    makeGrid(className, minimumWidth, maximumWidth) {
        const grid = create("div", `tile-grid ${className}`)
        new ResizeObserver(() => {
            const available = grid.clientWidth - gridPadding * 2
            const columns = Math.max(1, Math.floor((available + gridSpacing) / (minimumWidth + gridSpacing)))
            const width = Math.min(maximumWidth, (available - gridSpacing * (columns - 1)) / columns)
            grid.style.gridTemplateColumns = `repeat(${columns}, ${width}px)`
        }).observe(grid)
        return grid
    }

    syncTiles(grid, tiles, items, makeTile, refreshTile, leading = null) {
        if (this.drag && grid.contains(this.drag.wrapper)) {
            return
        }
        const seen = new Set()
        const ordered = items.map((item, rank) => {
            seen.add(item.id)
            let tile = tiles.get(item.id)
            if (!tile) {
                tile = makeTile(item, rank + (leading ? 1 : 0))
                tiles.set(item.id, tile)
            }
            refreshTile(tile, item, rank)
            return tile
        })
        for (const key of [...tiles.keys()]) {
            if (!seen.has(key)) {
                tiles.delete(key)
            }
        }
        grid.replaceChildren(...(leading ? [leading] : []), ...ordered)
    }

    update() {
        const isSearching = this.query.length > 0
        this.browse.style.display = isSearching ? "none" : "block"
        this.results.style.display = isSearching ? "block" : "none"
        this.app.nav.hide()
        if (isSearching) {
            this.updateResults()
        } else {
            this.updateBrowse()
        }
    }

    updateResults() {
        const library = this.app.library
        const folders = library.liveNotebooks().filter((notebook) => matches(notebook.title, this.query))
        const notes = library.liveNotebooks().flatMap((notebook) => library.pages(notebook.id)).filter((page) => matches(noteTitle(library, page), this.query))
        this.resultFolderHeading.style.display = folders.length ? "flex" : "none"
        this.resultFolderGrid.style.display = folders.length ? "grid" : "none"
        this.resultNoteHeading.style.display = notes.length ? "flex" : "none"
        this.resultNoteGrid.style.display = notes.length ? "grid" : "none"
        this.resultEmpty.style.display = folders.length || notes.length ? "none" : "flex"
        this.syncTiles(this.resultFolderGrid, this.resultFolderTiles, folders, (notebook, rank) => this.folderTile(notebook, rank, false), (tile, notebook) => this.refreshFolderTile(tile, notebook, true))
        this.syncTiles(this.resultNoteGrid, this.resultNoteTiles, notes, (page, rank) => this.pageTile(page, rank, false), (tile, page) => this.refreshPageTile(tile, page, true))
    }

    folderPath(notebookId) {
        const library = this.app.library
        const names = []
        let current = notebookId
        const visited = new Set()
        while (current && !visited.has(current)) {
            visited.add(current)
            names.unshift(library.notebook(current)?.title ?? "")
            current = library.parentOf(current)
        }
        return names.join(" / ")
    }

    addTile({ glyphName, title, aspect, className, action }) {
        const frame = create("div", "add-tile-frame", glyph(glyphName, { size: 34, color: tokens.semantic.create }))
        frame.style.aspectRatio = aspect
        const caption = create("div", "add-tile-caption", glyph("plus", { size: 16, color: tokens.semantic.create }), create("span", "add-tile-title", title))
        const button = create("button", `add-tile ${className} pressable-soft`, frame, caption)
        button.type = "button"
        button.setAttribute("aria-label", title)
        button.addEventListener("click", action)
        const wrapper = create("div", "tile-wrapper add-tile-wrapper", button)
        tileAppear(wrapper, 0)
        return wrapper
    }

    refreshFolderTile(tile, notebook, isResult = false) {
        const library = this.app.library
        const look = folderLook(notebook)
        tile.titleElement.textContent = notebook.title
        tile.countElement.textContent = isResult && library.parentOf(notebook.id) ? this.folderPath(library.parentOf(notebook.id)) : folderSummary(library, notebook.id)
        tile.iconElement.replaceChildren(glyph(look.icon, { size: 22, color: look.color }))
        const pages = library.pages(notebook.id)
        tile.preview.replaceChildren()
        if (pages[0]) {
            if (!tile.thumbnail) {
                tile.thumbnail = thumbnail(pages[0])
            }
            tile.thumbnail.page = pages[0]
            tile.preview.append(tile.thumbnail)
            requestAnimationFrame(() => tile.thumbnail.refresh(pages[0]))
        } else {
            tile.preview.append(create("span", "folder-empty-icon", glyph(look.icon, { size: 44, color: look.color })))
        }
    }

    folderTile(notebook, rank, isDraggable = true) {
        const notebookId = notebook.id
        const preview = create("div", "notebook-preview")
        const previewFrame = create("div", "notebook-preview-frame", preview)
        squircle(previewFrame, { radius: squircleRadius.tile, fill: tokens.palette.sunken_deep })
        const titleElement = create("span", "notebook-title")
        const countElement = microLabel("")
        const iconElement = create("span", "tile-icon")
        const caption = create("div", "notebook-caption", iconElement, create("div", "notebook-caption-text", titleElement, countElement))
        const button = create("button", "notebook-tile pressable-soft", previewFrame, caption)
        button.type = "button"
        squircle(button, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
        const wrapper = create("div", "tile-wrapper", button)
        wrapper.dataset.kind = "folder"
        wrapper.dataset.identifier = notebookId
        this.tileGestures(wrapper, button, {
            onTap: () => this.app.go({ kind: "notebook", notebookId }),
            onMenu: (rect) => this.showFolderMenu(notebookId, rect),
            isDraggable,
        })
        wrapper.preview = preview
        wrapper.titleElement = titleElement
        wrapper.countElement = countElement
        wrapper.iconElement = iconElement
        tileAppear(wrapper, rank)
        return wrapper
    }

    refreshPageTile(tile, page, isResult = false) {
        const look = noteLook(page)
        tile.titleElement.textContent = noteTitle(this.app.library, page)
        tile.iconElement.replaceChildren(glyph(look.icon, { size: 16, color: look.color }))
        tile.extentElement.textContent = isResult ? this.folderPath(page.notebook) : cellCount(page.extent) > 1 ? `${page.extent.cols}×${page.extent.rows}` : ""
        tile.thumbnailFrame.style.aspectRatio = `${paperWidth(page.extent)} / ${paperHeight(page.extent)}`
        tile.thumbnail.page = page
        requestAnimationFrame(() => tile.thumbnail.refresh(page))
    }

    pageTile(page, index, isDraggable = true) {
        const pageId = page.id
        const pageThumbnail = thumbnail(page)
        const thumbnailFrame = create("div", "page-thumbnail-frame", pageThumbnail)
        squircle(thumbnailFrame, { radius: 6, clip: true })
        const iconElement = create("span", "page-caption-icon")
        const titleElement = create("span", "page-caption-title")
        const extentElement = microLabel("")
        const caption = create("div", "page-caption", iconElement, titleElement, extentElement)
        const button = create("button", "page-tile pressable-soft", thumbnailFrame, caption)
        button.type = "button"
        squircle(button, { radius: squircleRadius.tile, fill: tokens.palette.panel_solid, border: tokens.palette.border })
        const wrapper = create("div", "tile-wrapper", button)
        wrapper.dataset.kind = "note"
        wrapper.dataset.identifier = pageId
        this.tileGestures(wrapper, button, {
            onTap: () => {
                const current = this.app.library.page(pageId)
                if (current) {
                    this.app.go({ kind: "page", notebookId: current.notebook, pageId })
                }
            },
            onMenu: (rect) => this.showNoteMenu(pageId, rect),
            isDraggable,
        })
        wrapper.thumbnail = pageThumbnail
        wrapper.thumbnailFrame = thumbnailFrame
        wrapper.titleElement = titleElement
        wrapper.iconElement = iconElement
        wrapper.extentElement = extentElement
        tileAppear(wrapper, index)
        return wrapper
    }

    tileGestures(wrapper, button, { onTap, onMenu, isDraggable }) {
        tileGestures(button, {
            onTap,
            onMenu,
            onDrag: (event) => {
                if (!isDraggable || this.drag) {
                    return
                }
                this.app.menu.dismiss()
                this.startDrag(wrapper, button, event)
            },
        })
    }

    startDrag(wrapper, button, event) {
        const kind = wrapper.dataset.kind
        const identifier = wrapper.dataset.identifier
        this.drag = new TileDrag({
            wrapper,
            handle: button,
            event,
            scroller: this.scroller,
            resolve: (clientX, clientY) => this.dropTarget(kind, identifier, wrapper, clientX, clientY),
            onDrop: (target) => {
                this.drag = null
                this.drop(kind, identifier, wrapper, target)
            },
        })
    }

    dropTarget(kind, identifier, source, clientX, clientY) {
        const library = this.app.library
        const hit = document.elementFromPoint(clientX, clientY)
        if (!hit) {
            return null
        }
        const back = this.header.backButton
        if (back && back.contains(hit) && this.notebookId) {
            const parentId = library.parentOf(this.notebookId)
            if (kind === "folder" || parentId) {
                return { kind: "up", element: back, notebookId: parentId }
            }
            return null
        }
        const wrapper = hit.closest(".tile-wrapper")
        if (!wrapper || wrapper === source || !this.browse.contains(wrapper) || wrapper.classList.contains("add-tile-wrapper")) {
            return null
        }
        const rect = wrapper.getBoundingClientRect()
        const isFolder = wrapper.dataset.kind === "folder"
        const horizontalShare = (clientX - rect.left) / rect.width
        if (isFolder && (kind === "note" || (horizontalShare > dropEdgeShare && horizontalShare < 1 - dropEdgeShare))) {
            if (kind === "folder" && !library.canMoveNotebook(identifier, wrapper.dataset.identifier)) {
                return null
            }
            return { kind: "into", element: wrapper, notebookId: wrapper.dataset.identifier }
        }
        if (wrapper.dataset.kind !== kind || wrapper.parentElement !== source.parentElement) {
            return null
        }
        return { kind: horizontalShare < 0.5 ? "before" : "after", element: wrapper }
    }

    drop(kind, identifier, wrapper, target) {
        const library = this.app.library
        if (!target) {
            this.update()
            return
        }
        if (target.kind === "into" || target.kind === "up") {
            if (kind === "folder") {
                library.moveNotebook(identifier, target.notebookId)
            } else if (target.notebookId) {
                library.movePage(identifier, target.notebookId)
            }
            return
        }
        const identifiers = [...wrapper.parentElement.children].filter((child) => child.dataset.kind === kind).map((child) => child.dataset.identifier)
        if (kind === "folder") {
            library.arrangeFolders(identifiers)
        } else {
            library.arrangePages(identifiers)
        }
        this.update()
    }

    showFolderMenu(notebookId, rect) {
        const library = this.app.library
        const notebook = library.notebook(notebookId)
        if (!notebook) {
            return
        }
        const target = { kind: "folder", id: notebookId }
        const slots = slotsFromTokens(tokens.menus.notebook, {
            title: (action) => tileMenuTitles[action] ?? action,
            perform: (action) => {
                if (action === "rename") {
                    this.app.showSheet({ kind: "rename-folder", notebookId })
                } else if (action === "appearance") {
                    this.app.showSheet({ kind: "appearance", target })
                } else if (action === "move") {
                    this.app.showSheet({ kind: "move", target })
                } else if (action === "delete_notebook") {
                    library.deleteNotebook(notebookId)
                }
            },
        })
        this.app.menu.present(slots, { around: rect, title: notebook.title, columns: tileMenuColumns })
    }

    showNoteMenu(pageId, rect) {
        const library = this.app.library
        const page = library.page(pageId)
        if (!page) {
            return
        }
        const target = { kind: "note", id: pageId }
        const isReadOnly = library.isReadOnly(pageId)
        const slots = slotsFromTokens(tokens.menus.page_tile, {
            title: (action) => tileMenuTitles[action] ?? action,
            isEnabled: (action) => action === "delete_page" || !isReadOnly,
            perform: (action) => {
                if (action === "rename") {
                    this.app.showSheet({ kind: "rename-note", pageId })
                } else if (action === "appearance") {
                    this.app.showSheet({ kind: "appearance", target })
                } else if (action === "move") {
                    this.app.showSheet({ kind: "move", target })
                } else if (action === "delete_page") {
                    library.deletePage(pageId)
                }
            },
        })
        this.app.menu.present(slots, { around: rect, title: noteTitle(library, page), columns: tileMenuColumns })
    }
}

const dropEdgeShare = 0.22
const tileMenuTitles = { rename: "Rename", appearance: "Icon & colour", move: "Move", delete_notebook: "Delete", delete_page: "Delete" }
const folderAspect = "1.25"

export class LibraryScreen extends GridScreen {
    constructor(app) {
        super(app, null)
        this.grid = this.makeGrid("notebook-grid", 230, 320)
        this.addFolder = this.addTile({ glyphName: "folder", title: "Add folder", aspect: folderAspect, className: "add-folder", action: () => app.showSheet({ kind: "new-folder", parentId: null }) })
        this.mount({ title: "Folders", label: "" })
        this.browse.append(this.grid)
        this.update()
    }

    updateBrowse() {
        const folders = this.app.library.folders(null)
        this.header.update({ label: plural(folders.length, "folder") })
        this.syncTiles(this.grid, this.folderTiles, folders, (notebook, rank) => this.folderTile(notebook, rank), (tile, notebook) => this.refreshFolderTile(tile, notebook), this.addFolder)
    }
}

export class NotebookScreen extends GridScreen {
    constructor(app, notebookId) {
        super(app, notebookId)
        this.folderGrid = this.makeGrid("notebook-grid", 230, 320)
        this.noteGrid = this.makeGrid("page-grid", 170, 240)
        this.addFolder = this.addTile({ glyphName: "folder", title: "Add folder", aspect: folderAspect, className: "add-folder", action: () => app.showSheet({ kind: "new-folder", parentId: this.notebookId }) })
        this.addNote = this.addTile({ glyphName: "note", title: "Add note", aspect: `${paperWidth({ cols: 1, rows: 1 })} / ${paperHeight({ cols: 1, rows: 1 })}`, className: "add-note", action: () => this.addPage() })
        this.mount({ title: app.library.notebook(notebookId)?.title ?? "Folder", label: "", onBack: () => this.goBack() })
        this.browse.append(create("div", "grid-heading", microLabel("Folders")), this.folderGrid, create("div", "grid-heading", microLabel("Notes")), this.noteGrid)
        this.update()
    }

    goBack() {
        const parentId = this.app.library.parentOf(this.notebookId)
        this.app.go(parentId ? { kind: "notebook", notebookId: parentId } : { kind: "library" })
    }

    addPage() {
        const page = this.app.library.createPage(this.notebookId)
        this.app.go({ kind: "page", notebookId: this.notebookId, pageId: page.id })
    }

    update() {
        if (!this.app.library.notebook(this.notebookId)) {
            this.app.go({ kind: "library" })
            return
        }
        super.update()
    }

    updateBrowse() {
        const library = this.app.library
        const notebook = library.notebook(this.notebookId)
        this.header.update({ title: notebook.title, label: folderSummary(library, this.notebookId) })
        this.syncTiles(this.folderGrid, this.folderTiles, library.folders(this.notebookId), (folder, rank) => this.folderTile(folder, rank), (tile, folder) => this.refreshFolderTile(tile, folder), this.addFolder)
        this.syncTiles(this.noteGrid, this.noteTiles, library.pages(this.notebookId), (page, rank) => this.pageTile(page, rank), (tile, page) => this.refreshPageTile(tile, page), this.addNote)
    }
}

const menuTitles = {
    previous_page: "Previous note",
    next_page: "Next note",
    new_page: "New note",
    expand_columns: "Add column",
    expand_rows: "Add row",
    import: "Import",
    fit_page: "Fit page",
    delete_page: "Delete note",
}

export class PageScreen {
    constructor(app, notebookId, pageId) {
        this.app = app
        this.notebookId = notebookId
        this.pageId = pageId
        this.element = create("section", "screen page-screen")
        this.undoButton = roundIconButton({ glyphName: "undo", label: "Undo", action: () => app.library.undo(this.pageId) })
        this.redoButton = roundIconButton({ glyphName: "redo", label: "Redo", action: () => app.library.redo(this.pageId) })
        this.header = topBar({ title: "", label: "", onBack: () => app.go({ kind: "notebook", notebookId }), trailing: [], below: [this.undoButton, this.redoButton] })
        this.canvas = new InkCanvas(this.callbacks())
        this.editorHost = create("div", "text-editor-host")
        this.deletedNotice = create("div", "deleted-notice", microLabel("This note was deleted"))
        this.canvasArea = create("div", "canvas-area", this.canvas.element, this.editorHost, this.deletedNotice)
        this.stage = create("div", "page-stage", this.canvasArea)
        this.element.append(this.stage, this.header)
        overlayTopBar(this.element, this.header)
        new ResizeObserver(() => this.canvas.setInsets({ top: this.header.offsetTop + this.header.offsetHeight })).observe(this.header)
        this.tools = new PageTools(this)
        this.editor = null
        this.keyDown = (event) => this.handleKey(event)
        window.addEventListener("keydown", this.keyDown)
        this.update()
    }

    destroy() {
        window.removeEventListener("keydown", this.keyDown)
        this.canvas.destroy()
        this.tools.destroy()
    }

    get settings() {
        return {
            showsGuides: readSetting("showsGuides", true),
        }
    }

    update() {
        const library = this.app.library
        const page = library.page(this.pageId)
        const trailing = []
        if (library.isReadOnly(this.pageId)) {
            trailing.push(microLabel("Read only", tokens.semantic.destructive))
        }
        trailing.push(settingsControl(this.app))
        this.undoButton.setEnabled(library.canUndo(this.pageId))
        this.redoButton.setEnabled(library.canRedo(this.pageId))
        this.header.update({
            title: page ? noteTitle(library, page) : "Note",
            label: library.notebook(this.notebookId)?.title ?? "Folder",
            trailing,
        })
        this.deletedNotice.style.display = page ? "none" : "flex"
        this.canvas.element.style.display = page ? "block" : "none"
        const session = library.textEditing?.pageId === this.pageId ? library.textEditing : null
        if (page) {
            this.canvas.configure({
                page,
                tool: this.tools.canvasTool(),
                paperStyle: paperStyle(),
                showsGuides: this.settings.showsGuides,
                hiddenElementIds: session ? new Set([session.element.id]) : new Set(),
                isReadOnly: library.isReadOnly(this.pageId),
            })
        }
        this.updateEditor(session)
        this.tools.update(session)
    }

    setSettings(values) {
        for (const [key, value] of Object.entries(values)) {
            writeSetting(key, value)
        }
        this.update()
    }

    showPageMenu({ around, at }) {
        const library = this.app.library
        const pages = library.pages(this.notebookId)
        const index = pages.findIndex((page) => page.id === this.pageId)
        const page = library.page(this.pageId)
        const isReadOnly = library.isReadOnly(this.pageId)
        const showsGuides = this.settings.showsGuides
        const slots = slotsFromTokens(tokens.menus.page, {
            title: (action) => (action === "toggle_guides" ? (showsGuides ? "Guides off" : "Guides on") : menuTitles[action] ?? action),
            isEnabled: (action) => {
                switch (action) {
                case "previous_page": return index > 0
                case "next_page": return index >= 0 && index < pages.length - 1
                case "expand_columns":
                case "expand_rows": return Boolean(page) && !isReadOnly
                case "import": return false
                case "delete_page": return Boolean(page)
                default: return true
                }
            },
            perform: (action) => {
                switch (action) {
                case "previous_page":
                    if (index > 0) {
                        this.app.go({ kind: "page", notebookId: this.notebookId, pageId: pages[index - 1].id })
                    }
                    break
                case "next_page":
                    if (index >= 0 && index < pages.length - 1) {
                        this.app.go({ kind: "page", notebookId: this.notebookId, pageId: pages[index + 1].id })
                    }
                    break
                case "new_page": {
                    const created = library.createPage(this.notebookId)
                    this.app.go({ kind: "page", notebookId: this.notebookId, pageId: created.id })
                    break
                }
                case "expand_columns":
                    library.expand(this.pageId, true)
                    break
                case "expand_rows":
                    library.expand(this.pageId, false)
                    break
                case "toggle_guides":
                    this.setSettings({ showsGuides: !showsGuides })
                    break
                case "fit_page":
                    this.canvas.fit()
                    break
                case "delete_page":
                    library.deletePage(this.pageId)
                    this.app.go({ kind: "notebook", notebookId: this.notebookId })
                    break
                default:
                    break
                }
            },
        })
        if (at) {
            this.app.menu.presentAt(slots, { x: at[0], y: at[1], title: "Note" })
        } else {
            this.app.menu.present(slots, { around, title: "Note" })
        }
    }

    callbacks() {
        const library = this.app.library
        return {
            onCameraChange: () => this.positionEditor(),
            onStroke: (tool, color, pieces, width) => library.addStrokes(this.pageId, tool, color, pieces, width),
            onErase: (identifiers) => library.erase(identifiers, this.pageId),
            onEraseArea: (replacements) => library.replaceStrokes(this.pageId, replacements),
            onUndo: () => library.undo(this.pageId),
            onRedo: () => library.redo(this.pageId),
            onTextTap: (point, elementId) => {
                if (library.textEditing) {
                    library.finishText()
                    return
                }
                if (elementId) {
                    library.editText(elementId, this.pageId)
                } else {
                    const page = library.page(this.pageId)
                    const fontSize = textFontSize()
                    const height = textLayout({ font_size: fontSize, content: "" }).lineHeight
                    const box = clampBox({ x: point[0], y: point[1], width: tokens.text.box_width }, page.extent, height)
                    library.beginText(this.pageId, [box.x, box.y], fontSize)
                }
            },
            onTextMove: (elementId, box) => library.moveText(elementId, this.pageId, box),
            onInput: () => this.tools.closeSubNav(),
            onHold: (clientX, clientY, isFromTouch) => this.showPageMenu(isFromTouch ? { at: [clientX, clientY] } : { around: { left: clientX, top: clientY, width: 0, height: 0, bottom: clientY } }),
            onHoldMove: (clientX, clientY) => this.app.menu.drag(clientX, clientY),
            onHoldEnd: (clientX, clientY) => this.app.menu.release(clientX, clientY),
        }
    }

    updateEditor(session) {
        if (!session) {
            if (this.editor) {
                this.editor.remove()
                this.editor = null
            }
            return
        }
        if (this.editor?.elementId !== session.element.id) {
            this.editor?.remove()
            const textarea = create("textarea", "text-editor")
            textarea.spellcheck = true
            textarea.value = session.element.content ?? ""
            textarea.addEventListener("input", () => {
                this.app.library.updateText(textarea.value)
                this.positionEditor()
            })
            textarea.addEventListener("keydown", (event) => {
                if (event.key === "Escape") {
                    event.preventDefault()
                    this.app.library.finishText()
                }
            })
            const caret = create("span", "text-caret")
            const frame = create("div", "text-editor-frame", textarea, caret)
            frame.elementId = session.element.id
            frame.textarea = textarea
            frame.caret = caret
            this.editorHost.append(frame)
            this.editor = frame
            this.positionEditor()
            textarea.focus({ preventScroll: true })
            requestAnimationFrame(() => textarea.focus({ preventScroll: true }))
        }
        this.positionEditor()
    }

    positionEditor() {
        const session = this.app.library.textEditing
        if (!this.editor || !session?.element.box) {
            return
        }
        const camera = this.canvas.camera
        const box = session.element.box
        const fontSize = (session.element.font_size ?? tokens.text.font_size) * camera.scale
        const metrics = fontMetrics(fontSize)
        const textarea = this.editor.textarea
        this.editor.classList.toggle("has-content", textarea.value.length > 0)
        this.editor.style.left = `${box.x * camera.scale + camera.offsetX}px`
        this.editor.style.top = `${box.y * camera.scale + camera.offsetY}px`
        this.editor.style.width = `${box.width * camera.scale}px`
        textarea.style.fontSize = `${fontSize}px`
        textarea.style.lineHeight = `${metrics.lineHeight}px`
        textarea.style.color = inkOnPaper(session.element.color ?? tokens.text.color, paperStyle())
        this.editor.caret.style.height = `${metrics.lineHeight}px`
        textarea.style.height = "0px"
        textarea.style.height = `${Math.max(textarea.scrollHeight, fontSize * 1.4)}px`
    }

    handleKey(event) {
        const isCommand = event.ctrlKey || event.metaKey
        if (!isCommand || document.activeElement?.tagName === "TEXTAREA" || document.activeElement?.tagName === "INPUT") {
            return
        }
        const key = event.key.toLowerCase()
        if (key === "z" && !event.shiftKey) {
            event.preventDefault()
            this.app.library.undo(this.pageId)
        } else if ((key === "z" && event.shiftKey) || key === "y") {
            event.preventDefault()
            this.app.library.redo(this.pageId)
        }
    }
}
