import {
    decodeFile,
    encodeNotebook,
    encodePage,
    isNewer,
    isOrderedBefore,
    layerForTool,
    makeIdentifier,
    mergeElement,
    mergeHeader,
    mergeNotebook,
    nextOrder,
    notebookPath,
    pagePath,
    schemaVersion,
    timestampMilliseconds,
    timestampNow,
    tombstone,
} from "./model.js"
import { deviceIdentity, loadFiles, writeFile } from "./storage.js"
import { tokens } from "./tokens.js"

const undoLimit = 200
const writeDelayMilliseconds = 250

export class Library {
    constructor() {
        this.device = deviceIdentity()
        this.notebooks = new Map()
        this.pagesById = new Map()
        this.readOnlyPages = new Set()
        this.undoSteps = new Map()
        this.redoSteps = new Map()
        this.textEditing = null
        this.listeners = new Set()
        this.pendingWrites = new Map()
        this.writeTimer = null
        this.lastError = null
    }

    async open() {
        const files = await loadFiles()
        for (const file of files) {
            try {
                const { value, isReadOnly } = decodeFile(file.contents)
                if (file.path.endsWith("/notebook.json")) {
                    this.notebooks.set(value.id, value)
                } else if (file.path.includes("/pages/")) {
                    this.pagesById.set(value.id, value)
                    if (isReadOnly) {
                        this.readOnlyPages.add(value.id)
                    }
                }
            } catch (error) {
                this.lastError = `${file.path}: ${error.message}`
            }
        }
    }

    subscribe(listener) {
        this.listeners.add(listener)
        return () => this.listeners.delete(listener)
    }

    changed() {
        for (const listener of this.listeners) {
            listener()
        }
    }

    timestamp() {
        return timestampNow()
    }

    liveNotebooks() {
        return [...this.notebooks.values()].filter((notebook) => !notebook.deleted).sort((first, second) => (first.id < second.id ? -1 : 1))
    }

    notebook(notebookId) {
        const notebook = this.notebooks.get(notebookId)
        return notebook && !notebook.deleted ? notebook : null
    }

    pages(notebookId) {
        return [...this.pagesById.values()]
            .filter((page) => page.notebook === notebookId && !page.deleted)
            .sort((first, second) => (first.id < second.id ? -1 : 1))
    }

    page(pageId) {
        const page = this.pagesById.get(pageId)
        return page && !page.deleted ? page : null
    }

    isReadOnly(pageId) {
        return this.readOnlyPages.has(pageId)
    }

    createNotebook(title) {
        const now = this.timestamp()
        const notebook = {
            schema_version: schemaVersion,
            id: makeIdentifier("nb", timestampMilliseconds(now)),
            title,
            updated: now,
            device: this.device,
            deleted: false,
        }
        this.applyNotebook(notebook)
        this.createPage(notebook.id)
        return notebook
    }

    rename(notebookId, title) {
        const notebook = this.notebook(notebookId)
        if (!notebook) {
            return
        }
        this.applyNotebook({ ...notebook, title, updated: this.timestamp(), device: this.device })
    }

    deleteNotebook(notebookId) {
        const notebook = this.notebook(notebookId)
        if (!notebook) {
            return
        }
        for (const page of this.pages(notebookId)) {
            this.deletePage(page.id)
        }
        this.applyNotebook({ ...notebook, deleted: true, updated: this.timestamp(), device: this.device })
    }

    createPage(notebookId) {
        const now = this.timestamp()
        const header = {
            schema_version: schemaVersion,
            id: makeIdentifier("p", timestampMilliseconds(now)),
            notebook: notebookId,
            updated: now,
            device: this.device,
            deleted: false,
            extent: { cols: 1, rows: 1 },
        }
        this.applyHeader(header)
        return this.pagesById.get(header.id)
    }

    deletePage(pageId) {
        const page = this.page(pageId)
        if (!page) {
            return
        }
        this.applyHeader({ ...this.header(page), deleted: true, updated: this.timestamp(), device: this.device })
        this.undoSteps.delete(pageId)
        this.redoSteps.delete(pageId)
    }

    expand(pageId, isColumns) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId)) {
            return
        }
        const extent = isColumns ? { cols: page.extent.cols * 2, rows: page.extent.rows } : { cols: page.extent.cols, rows: page.extent.rows * 2 }
        this.applyHeader({ ...this.header(page), extent, updated: this.timestamp(), device: this.device })
    }

    addStroke(pageId, tool, color, points, width = tokens.tools[tool].width) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId) || points.length === 0) {
            return
        }
        const now = this.timestamp()
        const layer = layerForTool(tool)
        const element = {
            id: makeIdentifier("e", timestampMilliseconds(now)),
            type: "stroke",
            layer,
            order: nextOrder(page, layer),
            tool,
            color,
            width,
            points,
            updated: now,
            device: this.device,
            deleted: false,
        }
        this.applyElement(pageId, element)
        this.record({ before: [], after: [element] }, pageId)
    }

    erase(elementIds, pageId) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId)) {
            return
        }
        const now = this.timestamp()
        const step = { before: [], after: [] }
        for (const id of elementIds) {
            const element = page.elements.find((candidate) => candidate.id === id)
            if (!element || element.deleted) {
                continue
            }
            const removed = tombstone(element, now, this.device)
            this.applyElement(pageId, removed)
            step.before.push(element)
            step.after.push(removed)
        }
        if (step.after.length) {
            this.record(step, pageId)
        }
    }

    replaceStrokes(pageId, replacements) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId)) {
            return
        }
        const now = this.timestamp()
        const step = { before: [], after: [] }
        for (const { elementId, pieces } of replacements) {
            const element = page.elements.find((candidate) => candidate.id === elementId)
            if (!element || element.deleted) {
                continue
            }
            const removed = tombstone(element, now, this.device)
            this.applyElement(pageId, removed)
            step.before.push(element)
            step.after.push(removed)
            for (const points of pieces) {
                const piece = { ...element, id: makeIdentifier("e", timestampMilliseconds(now)), points, updated: now, device: this.device, deleted: false }
                this.applyElement(pageId, piece)
                step.after.push(piece)
            }
        }
        if (step.after.length) {
            this.record(step, pageId)
        }
    }

    moveText(elementId, pageId, box) {
        const page = this.page(pageId)
        const element = page?.elements.find((candidate) => candidate.id === elementId)
        if (!page || !element || element.deleted || this.isReadOnly(pageId)) {
            return
        }
        const moved = { ...element, box, updated: this.timestamp(), device: this.device }
        this.applyElement(pageId, moved)
        this.record({ before: [element], after: [moved] }, pageId)
    }

    beginText(pageId, point) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId)) {
            return
        }
        this.finishText()
        const now = this.timestamp()
        const element = {
            id: makeIdentifier("e", timestampMilliseconds(now)),
            type: "text",
            layer: "text",
            order: nextOrder(page, "text"),
            color: tokens.text.color,
            content: "",
            box: { x: point[0], y: point[1], width: tokens.text.box_width },
            font_size: tokens.text.font_size,
            updated: now,
            device: this.device,
            deleted: false,
        }
        this.textEditing = { pageId, element, original: null, isApplied: false }
        this.changed()
    }

    editText(elementId, pageId) {
        const element = this.page(pageId)?.elements.find((candidate) => candidate.id === elementId)
        if (!element || element.deleted || this.isReadOnly(pageId)) {
            return
        }
        this.finishText()
        this.textEditing = { pageId, element, original: element, isApplied: true }
        this.changed()
    }

    updateText(content) {
        const session = this.textEditing
        if (!session || session.element.content === content) {
            return
        }
        session.element = { ...session.element, content, updated: this.timestamp(), device: this.device }
        if (session.isApplied || content.length > 0) {
            session.isApplied = true
            this.applyElement(session.pageId, session.element)
        }
    }

    finishText() {
        const session = this.textEditing
        if (!session) {
            return
        }
        this.textEditing = null
        if (!session.isApplied) {
            this.changed()
            return
        }
        if ((session.element.content ?? "").trim().length === 0) {
            const removed = tombstone(session.element, this.timestamp(), this.device)
            this.applyElement(session.pageId, removed)
            if (session.original) {
                this.record({ before: [session.original], after: [removed] }, session.pageId)
            }
            return
        }
        if (session.original?.content !== session.element.content) {
            this.record({ before: session.original ? [session.original] : [], after: [session.element] }, session.pageId)
        }
        this.changed()
    }

    canUndo(pageId) {
        return (this.undoSteps.get(pageId) ?? []).length > 0
    }

    canRedo(pageId) {
        return (this.redoSteps.get(pageId) ?? []).length > 0
    }

    undo(pageId) {
        this.finishText()
        const step = this.undoSteps.get(pageId)?.pop()
        if (!step) {
            return
        }
        this.stack(this.redoSteps, pageId).push(this.revert(step, pageId))
        this.changed()
    }

    redo(pageId) {
        this.finishText()
        const step = this.redoSteps.get(pageId)?.pop()
        if (!step) {
            return
        }
        this.stack(this.undoSteps, pageId).push(this.revert(step, pageId))
        this.changed()
    }

    revert(step, pageId) {
        const page = this.page(pageId)
        const reverse = { before: [], after: [] }
        if (!page || this.isReadOnly(pageId)) {
            return reverse
        }
        const now = this.timestamp()
        const beforeById = new Map(step.before.map((element) => [element.id, element]))
        for (const after of step.after) {
            const current = this.page(pageId).elements.find((candidate) => candidate.id === after.id) ?? after
            const before = beforeById.get(after.id)
            if (before) {
                if (after.deleted && !before.deleted) {
                    const revived = { ...before, id: makeIdentifier("e", timestampMilliseconds(now)), updated: now, device: this.device, deleted: false }
                    this.applyElement(pageId, revived)
                    reverse.after.push(revived)
                } else if (!after.deleted) {
                    const restored = { ...before, updated: now, device: this.device }
                    this.applyElement(pageId, restored)
                    reverse.before.push(current)
                    reverse.after.push(restored)
                }
            } else if (!current.deleted) {
                const removed = tombstone(current, now, this.device)
                this.applyElement(pageId, removed)
                reverse.before.push(current)
                reverse.after.push(removed)
            }
        }
        return reverse
    }

    stack(stacks, pageId) {
        if (!stacks.has(pageId)) {
            stacks.set(pageId, [])
        }
        return stacks.get(pageId)
    }

    record(step, pageId) {
        const steps = this.stack(this.undoSteps, pageId)
        steps.push(step)
        if (steps.length > undoLimit) {
            steps.splice(0, steps.length - undoLimit)
        }
        this.redoSteps.set(pageId, [])
        this.changed()
    }

    header(page) {
        const { elements, ...header } = page
        return header
    }

    applyNotebook(notebook) {
        const existing = this.notebooks.get(notebook.id)
        const merged = existing ? mergeNotebook(existing, notebook) : notebook
        this.notebooks.set(notebook.id, merged)
        this.schedule(notebookPath(notebook.id), () => encodeNotebook(this.notebooks.get(notebook.id)))
        this.changed()
    }

    applyHeader(header) {
        const existing = this.pagesById.get(header.id)
        const page = existing ? { ...mergeHeader(this.header(existing), header), elements: existing.elements } : { ...header, elements: [] }
        this.pagesById.set(header.id, page)
        this.schedulePage(page)
        this.changed()
    }

    applyElement(pageId, element) {
        const existing = this.pagesById.get(pageId)
        if (!existing) {
            return
        }
        const elements = [...existing.elements]
        const index = elements.findIndex((candidate) => candidate.id === element.id)
        if (index >= 0) {
            elements[index] = mergeElement(elements[index], element)
        } else {
            const insertion = elements.findIndex((candidate) => isOrderedBefore(element, candidate))
            elements.splice(insertion < 0 ? elements.length : insertion, 0, element)
        }
        const page = { ...existing, elements }
        if (isNewer(element.updated, element.device, page.updated, page.device)) {
            page.updated = element.updated
            page.device = element.device
        }
        this.pagesById.set(pageId, page)
        this.schedulePage(page)
        this.changed()
    }

    schedulePage(page) {
        this.schedule(pagePath(page.notebook, page.id), () => encodePage(this.pagesById.get(page.id)))
    }

    schedule(path, encode) {
        this.pendingWrites.set(path, encode)
        clearTimeout(this.writeTimer)
        this.writeTimer = setTimeout(() => this.flush(), writeDelayMilliseconds)
    }

    flush() {
        clearTimeout(this.writeTimer)
        const writes = [...this.pendingWrites.entries()]
        this.pendingWrites.clear()
        for (const [path, encode] of writes) {
            writeFile(path, encode()).catch((error) => {
                this.lastError = String(error)
                this.changed()
            })
        }
    }
}
