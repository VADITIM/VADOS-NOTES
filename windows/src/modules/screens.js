import { InkCanvas } from "./canvas.js"
import { create, holdable, microLabel, paperButton, syncBadge, topBar } from "./components.js"
import { slotsFromTokens } from "./menu.js"
import { cellCount, paperHeight, paperWidth } from "./model.js"
import { popIn, tileAppear } from "./motion.js"
import { fontMetrics, renderThumbnail } from "./renderer.js"
import { squircle, squircleRadius } from "./shapes.js"
import { PageTools } from "./pageTools.js"
import { paperStyle, togglePaperStyle } from "./preferences.js"
import { readSetting, writeSetting } from "./storage.js"
import { inkOnPaper, tokens } from "./tokens.js"

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
        this.element.append(this.header, this.scroller)
    }

    badge() {
        return syncBadge(this.app.syncStatus(), () => this.app.showSheet({ kind: "sync" }))
    }

    trailing() {
        return [paperButton(paperStyle(), togglePaperStyle), this.badge()]
    }
}

export class LibraryScreen extends GridScreen {
    constructor(app) {
        super(app)
        this.header = topBar({ title: "Notes", label: "", trailing: this.trailing() })
        this.mountGrid("notebook-grid", 230, 320)
        this.update()
    }

    update() {
        const library = this.app.library
        const notebooks = library.liveNotebooks()
        this.header.update({ label: plural(notebooks.length, "notebook"), trailing: this.trailing() })
        this.app.nav.show("library", [[{ id: "new-notebook", glyph: "plus", label: "New notebook", tint: tokens.semantic.create, isTinted: true, action: () => this.app.showSheet({ kind: "new-notebook" }) }]], { isCarriable: true })
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
        this.header = topBar({ title: app.library.notebook(notebookId)?.title ?? "Notebook", label: "", onBack: () => app.go({ kind: "library" }), trailing: this.trailing() })
        this.mountGrid("page-grid", 170, 240)
        this.update()
    }

    addPage() {
        const page = this.app.library.createPage(this.notebookId)
        this.app.go({ kind: "page", notebookId: this.notebookId, pageId: page.id })
    }

    update() {
        const library = this.app.library
        const pages = library.pages(this.notebookId)
        this.header.update({ title: library.notebook(this.notebookId)?.title ?? "Notebook", label: plural(pages.length, "page"), trailing: this.trailing() })
        this.app.nav.show("notebook", [[
            { id: "notebook-back", glyph: "back", label: "Back", tint: tokens.semantic.navigation, isTinted: true, action: () => this.app.go({ kind: "library" }) },
            { id: "new-page", glyph: "plus", label: "New page", tint: tokens.semantic.create, isTinted: true, action: () => this.addPage() },
        ]], { isCarriable: true })
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
        this.stage = create("div", "page-stage", this.canvasArea)
        this.element.append(this.header, this.stage)
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
        const pages = library.pages(this.notebookId)
        const index = pages.findIndex((page) => page.id === this.pageId)
        const trailing = []
        if (library.isReadOnly(this.pageId)) {
            trailing.push(microLabel("Read only", tokens.semantic.destructive))
        }
        trailing.push(paperButton(paperStyle(), togglePaperStyle))
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
            this.app.menu.presentAt(slots, { x: at[0], y: at[1], title: "Page" })
        } else {
            this.app.menu.present(slots, { around, title: "Page" })
        }
    }

    callbacks() {
        const library = this.app.library
        return {
            onCameraChange: () => this.positionEditor(),
            onStroke: (tool, color, points, width) => library.addStroke(this.pageId, tool, color, points, width),
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
                    library.beginText(this.pageId, point)
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
        textarea.style.color = inkOnPaper(session.element.color ?? tokens.text.color, paperStyle())
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
