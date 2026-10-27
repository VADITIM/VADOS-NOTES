import { InkCanvas } from "./canvas.js"
import { create, holdable, microLabel, popBar, syncBadge, topBar } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { cellCount, paperHeight, paperWidth } from "./model.js"
import { popIn, tileAppear } from "./motion.js"
import { fontMetrics, renderThumbnail } from "./renderer.js"
import { squircle, squircleRadius } from "./shapes.js"
import { readSetting, writeSetting } from "./storage.js"
import { isLight, tokens } from "./tokens.js"

const gridPadding = 28
const gridSpacing = 18

function plural(count, word) {
    return `${count} ${word}${count === 1 ? "" : "s"}`
}

function thumbnail(page) {
    const canvas = create("canvas", "page-thumbnail")
    canvas.renderKey = null
    canvas.refresh = (nextPage) => {
        const showsGuides = readSetting("showsGuides", true)
        const key = `${nextPage.id}-${nextPage.updated}-${nextPage.extent.cols}x${nextPage.extent.rows}-${showsGuides}-${canvas.clientWidth}x${canvas.clientHeight}`
        if (key === canvas.renderKey) {
            return
        }
        canvas.renderKey = key
        renderThumbnail(canvas, nextPage, showsGuides)
    }
    new ResizeObserver(() => canvas.refresh(canvas.page)).observe(canvas)
    canvas.page = page
    return canvas
}

class GridScreen {
    constructor(app) {
        this.app = app
        this.element = create("section", "screen")
        this.tiles = new Map()
    }

    mountGrid(className, minimumWidth, maximumWidth) {
        this.grid = create("div", `tile-grid ${className}`)
        this.scroller = create("div", "screen-scroll", this.grid)
        new ResizeObserver(() => {
            const available = this.grid.clientWidth - gridPadding * 2
            const columns = Math.max(1, Math.floor((available + gridSpacing) / (minimumWidth + gridSpacing)))
            const width = Math.min(maximumWidth, (available - gridSpacing * (columns - 1)) / columns)
            this.grid.style.gridTemplateColumns = `repeat(${columns}, ${width}px)`
        }).observe(this.grid)
        this.bar = popBar()
        this.barHost = create("div", "pop-bar-host", this.bar)
        this.element.append(this.header, this.scroller, this.barHost)
    }

    badge() {
        return syncBadge(this.app.syncStatus(), () => this.app.showSheet({ kind: "sync" }))
    }
}

export class LibraryScreen extends GridScreen {
    constructor(app) {
        super(app)
        this.header = topBar({ title: "Notes", label: "", trailing: [this.badge()] })
        this.mountGrid("notebook-grid", 230, 320)
        this.bar.update([[{ id: "new-notebook", glyph: "plus", label: "New notebook", tint: tokens.semantic.create, isActive: true, action: () => this.app.showSheet({ kind: "new-notebook" }) }]])
        this.update()
    }

    update() {
        const library = this.app.library
        const notebooks = library.liveNotebooks()
        this.header.update({ label: plural(notebooks.length, "notebook"), trailing: [this.badge()] })
        const seen = new Set()
        const ordered = notebooks.map((notebook, rank) => {
            seen.add(notebook.id)
            let tile = this.tiles.get(notebook.id)
            if (!tile) {
                tile = this.notebookTile(notebook.id, rank)
                this.tiles.set(notebook.id, tile)
            }
            const pages = library.pages(notebook.id)
            tile.titleElement.textContent = notebook.title
            tile.countElement.textContent = plural(pages.length, "page")
            tile.preview.replaceChildren()
            if (pages[0]) {
                if (!tile.thumbnail) {
                    tile.thumbnail = thumbnail(pages[0])
                }
                tile.thumbnail.page = pages[0]
                tile.preview.append(tile.thumbnail)
                requestAnimationFrame(() => tile.thumbnail.refresh(pages[0]))
            }
            return tile
        })
        for (const key of [...this.tiles.keys()]) {
            if (!seen.has(key)) {
                this.tiles.delete(key)
            }
        }
        this.grid.replaceChildren(...ordered)
    }

    notebookTile(notebookId, rank) {
        const preview = create("div", "notebook-preview")
        const previewFrame = create("div", "notebook-preview-frame", preview)
        squircle(previewFrame, { radius: squircleRadius.tile, fill: tokens.palette.sunken_deep })
        const titleElement = create("span", "notebook-title")
        const countElement = microLabel("")
        const caption = create("div", "notebook-caption", create("span", "accent-bar"), create("div", "notebook-caption-text", titleElement, countElement))
        const button = create("button", "notebook-tile pressable-soft", previewFrame, caption)
        button.type = "button"
        squircle(button, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
        const open = () => this.app.go({ kind: "notebook", notebookId })
        holdable(button, {
            action: open,
            onHold: (rect) => {
                const notebook = this.app.library.notebook(notebookId)
                if (!notebook) {
                    return
                }
                const titles = { open: "Open", rename: "Rename", delete_notebook: "Delete" }
                const slots = slotsFromTokens(tokens.menus.notebook, {
                    title: (action) => titles[action] ?? action,
                    perform: (action) => {
                        if (action === "open") {
                            open()
                        } else if (action === "rename") {
                            this.app.showSheet({ kind: "rename", notebookId, title: notebook.title })
                        } else if (action === "delete_notebook") {
                            this.app.library.deleteNotebook(notebookId)
                        }
                    },
                })
                this.app.menu.present(slots, { around: rect, title: notebook.title })
            },
        })
        const wrapper = create("div", "tile-wrapper", button)
        wrapper.preview = preview
        wrapper.titleElement = titleElement
        wrapper.countElement = countElement
        tileAppear(wrapper, rank)
        return wrapper
    }
}

export class NotebookScreen extends GridScreen {
    constructor(app, notebookId) {
        super(app)
        this.notebookId = notebookId
        this.header = topBar({ title: app.library.notebook(notebookId)?.title ?? "Notebook", label: "", onBack: () => app.go({ kind: "library" }), trailing: [this.badge()] })
        this.mountGrid("page-grid", 170, 240)
        this.bar.update([[
            { id: "notebook-back", glyph: "back", label: "Back", tint: tokens.semantic.navigation, action: () => app.go({ kind: "library" }) },
            { id: "new-page", glyph: "plus", label: "New page", tint: tokens.semantic.create, isActive: true, action: () => this.addPage() },
        ]])
        this.update()
    }

    addPage() {
        const page = this.app.library.createPage(this.notebookId)
        this.app.go({ kind: "page", notebookId: this.notebookId, pageId: page.id })
    }

    update() {
        const library = this.app.library
        const pages = library.pages(this.notebookId)
        this.header.update({ title: library.notebook(this.notebookId)?.title ?? "Notebook", label: plural(pages.length, "page"), trailing: [this.badge()] })
        const seen = new Set()
        const ordered = pages.map((page, index) => {
            seen.add(page.id)
            let tile = this.tiles.get(page.id)
            if (!tile) {
                tile = this.pageTile(page, index)
                this.tiles.set(page.id, tile)
            }
            tile.number = index + 1
            tile.numberElement.textContent = String(index + 1).padStart(2, "0")
            tile.extentElement.textContent = cellCount(page.extent) > 1 ? `${page.extent.cols}×${page.extent.rows}` : ""
            tile.thumbnailFrame.style.aspectRatio = `${paperWidth(page.extent)} / ${paperHeight(page.extent)}`
            tile.thumbnail.page = page
            requestAnimationFrame(() => tile.thumbnail.refresh(page))
            return tile
        })
        for (const key of [...this.tiles.keys()]) {
            if (!seen.has(key)) {
                this.tiles.delete(key)
            }
        }
        this.grid.replaceChildren(...ordered)
    }

    pageTile(page, index) {
        const pageId = page.id
        const pageThumbnail = thumbnail(page)
        const thumbnailFrame = create("div", "page-thumbnail-frame", pageThumbnail)
        squircle(thumbnailFrame, { radius: 6, clip: true })
        const numberElement = microLabel("", tokens.palette.text_bright)
        const extentElement = microLabel("")
        const caption = create("div", "page-caption", numberElement, extentElement)
        const button = create("button", "page-tile pressable-soft", thumbnailFrame, caption)
        button.type = "button"
        squircle(button, { radius: squircleRadius.tile, fill: tokens.palette.panel_solid, border: tokens.palette.border })
        const wrapper = create("div", "tile-wrapper", button)
        const open = () => this.app.go({ kind: "page", notebookId: this.notebookId, pageId })
        holdable(button, {
            action: open,
            onHold: (rect) => {
                const titles = { open: "Open", new_page: "New page", delete_page: "Delete" }
                const slots = slotsFromTokens(tokens.menus.page_tile, {
                    title: (action) => titles[action] ?? action,
                    perform: (action) => {
                        if (action === "open") {
                            open()
                        } else if (action === "new_page") {
                            this.addPage()
                        } else if (action === "delete_page") {
                            this.app.library.deletePage(pageId)
                        }
                    },
                })
                this.app.menu.present(slots, { around: rect, title: `Page ${wrapper.number}` })
            },
        })
        wrapper.thumbnail = pageThumbnail
        wrapper.thumbnailFrame = thumbnailFrame
        wrapper.numberElement = numberElement
        wrapper.extentElement = extentElement
        tileAppear(wrapper, index)
        return wrapper
    }
}

const inkTools = ["pen", "pencil", "marker"]
const menuTitles = {
    previous_page: "Previous",
    next_page: "Next",
    new_page: "New page",
    expand_columns: "Add column",
    expand_rows: "Add row",
    import: "Import",
    fit_page: "Fit page",
    delete_page: "Delete page",
}

export class PageScreen {
    constructor(app, notebookId, pageId) {
        this.app = app
        this.notebookId = notebookId
        this.pageId = pageId
        this.element = create("section", "screen page-screen")
        this.header = topBar({ title: "", label: "", onBack: () => app.go({ kind: "notebook", notebookId }), trailing: [] })
        this.header.classList.add("page-top-bar")
        this.canvas = new InkCanvas(this.callbacks())
        this.editorHost = create("div", "text-editor-host")
        this.deletedNotice = create("div", "deleted-notice", microLabel("This page was deleted"))
        this.canvasArea = create("div", "canvas-area", this.canvas.element, this.editorHost, this.deletedNotice)
        this.bar = popBar()
        this.barHost = create("div", "pop-bar-host", this.bar)
        this.stage = create("div", "page-stage", this.canvasArea, this.barHost)
        this.element.append(this.header, this.stage)
        this.editor = null
        this.keyDown = (event) => this.handleKey(event)
        window.addEventListener("keydown", this.keyDown)
        this.update()
    }

    destroy() {
        window.removeEventListener("keydown", this.keyDown)
        this.canvas.destroy()
    }

    get settings() {
        return {
            showsGuides: readSetting("showsGuides", true),
            tool: readSetting("tool", "pen"),
            isErasing: readSetting("isErasing", false),
            isTyping: readSetting("isTyping", false),
        }
    }

    color(tool) {
        return readSetting(`${tool}Color`, tokens.tools[tool].colors[0])
    }

    canvasTool() {
        const settings = this.settings
        if (settings.isTyping) {
            return { kind: "text" }
        }
        if (settings.isErasing) {
            return { kind: "eraser" }
        }
        return { kind: "ink", tool: inkTools.includes(settings.tool) ? settings.tool : "pen" }
    }

    update() {
        const library = this.app.library
        const pages = library.pages(this.notebookId)
        const index = pages.findIndex((page) => page.id === this.pageId)
        const trailing = []
        if (library.isReadOnly(this.pageId)) {
            trailing.push(microLabel("Read only", tokens.semantic.destructive))
        }
        trailing.push(syncBadge(this.app.syncStatus(), () => this.app.showSheet({ kind: "sync" })))
        this.header.update({
            title: library.notebook(this.notebookId)?.title ?? "Notebook",
            label: index >= 0 ? `Page ${index + 1} / ${pages.length}` : "Page",
            trailing,
        })
        const page = library.page(this.pageId)
        this.deletedNotice.style.display = page ? "none" : "flex"
        this.canvas.element.style.display = page ? "block" : "none"
        const session = library.textEditing?.pageId === this.pageId ? library.textEditing : null
        if (page) {
            const tool = this.canvasTool()
            this.canvas.configure({
                page,
                tool,
                inkColor: this.color(tool.tool ?? this.settings.tool),
                showsGuides: this.settings.showsGuides,
                hiddenElementIds: session ? new Set([session.element.id]) : new Set(),
                isReadOnly: library.isReadOnly(this.pageId),
            })
        }
        this.updateEditor(session)
        this.bar.update(this.barGroups(session))
    }

    barGroups(session) {
        const library = this.app.library
        if (session) {
            return [[
                { id: "typing", glyph: "text", label: "Typing", tint: tokens.palette.accent, isActive: true, action: () => {} },
                { id: "finish-text", glyph: "check", label: "Done", tint: tokens.semantic.create, isActive: true, action: () => library.finishText() },
            ]]
        }
        const tool = this.canvasTool()
        const tools = [
            ...inkTools.map((inkTool) => this.inkItem(inkTool, tool)),
            { id: "eraser", glyph: "eraser", label: "Eraser", tint: tokens.semantic.destructive, isActive: tool.kind === "eraser", action: () => this.setSettings({ isTyping: false, isErasing: true }) },
            { id: "text", glyph: "text", label: "Text", tint: tokens.palette.accent, isActive: tool.kind === "text", action: () => this.setSettings({ isErasing: false, isTyping: true }) },
        ]
        const history = [
            { id: "undo", glyph: "undo", label: "Undo", isEnabled: library.canUndo(this.pageId), action: () => library.undo(this.pageId) },
            { id: "redo", glyph: "redo", label: "Redo", isEnabled: library.canRedo(this.pageId), action: () => library.redo(this.pageId) },
        ]
        const more = [{ id: "page-menu", glyph: "more", label: "Page menu", action: () => {}, onTapAt: (rect) => this.showPageMenu({ around: rect }) }]
        return [tools, history, more]
    }

    inkItem(inkTool, tool) {
        const color = this.color(inkTool)
        return {
            id: inkTool,
            glyph: inkTool,
            label: inkTool,
            tint: isLight(color) ? color : tokens.palette.text_bright,
            isActive: tool.kind === "ink" && tool.tool === inkTool,
            swatch: color,
            action: () => this.setSettings({ isErasing: false, isTyping: false, tool: inkTool }),
            onHold: (rect) => this.showColorMenu(inkTool, rect),
        }
    }

    setSettings(values) {
        for (const [key, value] of Object.entries(values)) {
            writeSetting(key, value)
        }
        this.update()
    }

    showColorMenu(tool, rect) {
        const current = this.color(tool)
        const slots = tokens.tools[tool].colors.map((color, position) => ({
            position,
            title: color,
            role: "ink",
            swatch: color,
            isActive: color === current,
            isEnabled: true,
            handler: () => {
                writeSetting(`${tool}Color`, color)
                this.setSettings({ isErasing: false, isTyping: false, tool })
            },
        }))
        this.app.menu.present(slots, { columns: 2, around: rect, title: tool })
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
            this.app.menu.presentAt(slots, { x: at[0], y: at[1], title: "Page" })
        } else {
            this.app.menu.present(slots, { around, title: "Page" })
        }
    }

    callbacks() {
        const library = this.app.library
        return {
            onCameraChange: () => this.positionEditor(),
            onStroke: (tool, color, points) => library.addStroke(this.pageId, tool, color, points),
            onErase: (identifiers) => library.erase(identifiers, this.pageId),
            onTextTap: (point, elementId) => {
                if (library.textEditing) {
                    library.finishText()
                    return
                }
                if (elementId) {
                    library.editText(elementId, this.pageId)
                } else {
                    library.beginText(this.pageId, point)
                }
            },
            onTextMove: (elementId, box) => library.moveText(elementId, this.pageId, box),
            onInput: () => {},
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
            const frame = create("div", "text-editor-frame", textarea)
            frame.elementId = session.element.id
            frame.textarea = textarea
            this.editorHost.append(frame)
            this.editor = frame
            popIn(frame)
            requestAnimationFrame(() => textarea.focus())
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
        this.editor.style.left = `${box.x * camera.scale + camera.offsetX}px`
        this.editor.style.top = `${box.y * camera.scale + camera.offsetY}px`
        this.editor.style.width = `${box.width * camera.scale}px`
        textarea.style.fontSize = `${fontSize}px`
        textarea.style.lineHeight = `${metrics.lineHeight}px`
        textarea.style.color = session.element.color ?? tokens.text.color
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
