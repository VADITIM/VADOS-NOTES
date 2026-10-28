import {
    cellHeight,
    cellWidth,
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
    repositoryPathKind,
    scaledElement,
    schemaVersion,
    sortedByOrder,
    timestampMilliseconds,
    timestampNow,
    tombstone,
    translatedElement,
} from "./model.js"
import { deviceIdentity, loadFiles, readSetting, readSyncState, writeFile, writeSetting } from "./storage.js"
import { tokens } from "./tokens.js"

const undoLimit = 200
const importMarginMillimetres = 5
const sizeTolerance = 1
const writeDelayMilliseconds = 250
const dirtyPathsKey = "syncDirtyPaths"

function rounded(value) {
    return Math.round(value * 100) / 100
}

function importElement(asset, index, [width, height], now, device, row = index) {
    const isA4 = Math.abs(width - cellWidth) <= sizeTolerance && Math.abs(height - cellHeight) <= sizeTolerance
    const scale = isA4 ? 1 : Math.min((cellWidth - importMarginMillimetres * 2) / width, (cellHeight - importMarginMillimetres * 2) / height)
    return {
        id: makeIdentifier("e", timestampMilliseconds(now)),
        type: "import",
        layer: "import",
        order: index,
        asset,
        source_page: index,
        source_size_mm: [width, height],
        placement: { x: rounded((cellWidth - width * scale) / 2), y: rounded(row * cellHeight + (cellHeight - height * scale) / 2), scale: Math.round(scale * 10000) / 10000 },
        fit: isA4 ? "original" : "fit_cell",
        updated: now,
        device,
        deleted: false,
    }
}

function endOrder(items) {
    return items.reduce((highest, item, index) => Math.max(highest, Number.isFinite(item.order) ? item.order : index), -1) + 1
}

export class Library {
    constructor() {
        this.device = deviceIdentity()
        this.notebooks = new Map()
        this.pagesById = new Map()
        this.readOnlyPages = new Set()
        this.blockedPaths = new Map()
        this.undoSteps = new Map()
        this.redoSteps = new Map()
        this.textEditing = null
        this.listeners = new Set()
        this.pendingWrites = new Map()
        this.writeTimer = null
        this.lastError = null
        this.dirtyPaths = new Map()
        this.changeCounter = 0
        this.onChange = null
        this.onInput = null
    }

    async open() {
        const files = await loadFiles()
        for (const file of files) {
            try {
                const { value } = decodeFile(file.contents)
                if (file.path.endsWith("/notebook.json")) {
                    this.notebooks.set(value.id, value)
                } else if (file.path.includes("/pages/")) {
                    this.pagesById.set(value.id, value)
                }
            } catch (error) {
                this.lastError = `${file.path}: ${error.message}`
            }
        }
        const state = await readSyncState()
        for (const [path, reason] of Object.entries(state?.blocked ?? {})) {
            this.blockedPaths.set(path, reason)
        }
        this.refreshReadOnly()
        const storedDirty = readSetting(dirtyPathsKey, null)
        if (Array.isArray(storedDirty)) {
            storedDirty.forEach((path) => this.dirtyPaths.set(path, 0))
        } else if (!state?.head) {
            files.forEach((file) => this.dirtyPaths.set(file.path, 0))
            this.saveDirtyPaths()
        }
    }

    refreshReadOnly() {
        this.readOnlyPages = new Set()
        for (const page of this.pagesById.values()) {
            if (this.blockedPaths.has(pagePath(page.notebook, page.id)) || page.schema_version !== schemaVersion) {
                this.readOnlyPages.add(page.id)
            }
        }
    }

    saveDirtyPaths() {
        writeSetting(dirtyPathsKey, [...this.dirtyPaths.keys()])
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

    parentOf(notebookId) {
        const parent = this.notebook(notebookId)?.parent
        return parent && this.notebook(parent) ? parent : null
    }

    folders(parentId = null) {
        return sortedByOrder(this.liveNotebooks().filter((notebook) => this.parentOf(notebook.id) === parentId))
    }

    isInside(notebookId, ancestorId) {
        const visited = new Set()
        let current = notebookId
        while (current && !visited.has(current)) {
            if (current === ancestorId) {
                return true
            }
            visited.add(current)
            current = this.parentOf(current)
        }
        return false
    }

    path(notebookId) {
        const names = []
        const visited = new Set()
        let current = notebookId
        while (current && !visited.has(current)) {
            visited.add(current)
            names.unshift(this.notebook(current)?.title ?? "")
            current = this.parentOf(current)
        }
        return names.join(" / ")
    }

    folderSummary(notebookId) {
        const noteCount = this.pages(notebookId).length
        const folderCount = this.folders(notebookId).length
        const noteText = `${noteCount} note${noteCount === 1 ? "" : "s"}`
        return folderCount > 0 ? `${noteText} · ${folderCount} folder${folderCount === 1 ? "" : "s"}` : noteText
    }

    noteTitle(page) {
        if (typeof page.title === "string") {
            return page.title
        }
        const index = this.pages(page.notebook).findIndex((candidate) => candidate.id === page.id)
        return `Note ${Math.max(0, index) + 1}`
    }

    updateNotebook(notebookId, changes) {
        const notebook = this.notebook(notebookId)
        if (!notebook) {
            return
        }
        const next = { ...notebook, ...changes, updated: this.timestamp(), device: this.device }
        for (const [key, value] of Object.entries(changes)) {
            if (value === null || value === undefined) {
                delete next[key]
            }
        }
        this.applyNotebook(next)
    }

    canMoveNotebook(notebookId, parentId) {
        return Boolean(this.notebook(notebookId)) && (parentId === null || (Boolean(this.notebook(parentId)) && !this.isInside(parentId, notebookId)))
    }

    moveNotebook(notebookId, parentId) {
        if (this.canMoveNotebook(notebookId, parentId) && this.parentOf(notebookId) !== parentId) {
            this.updateNotebook(notebookId, { parent: parentId, order: endOrder(this.folders(parentId)) })
        }
    }

    pages(notebookId) {
        return sortedByOrder([...this.pagesById.values()].filter((page) => page.notebook === notebookId && !page.deleted))
    }

    page(pageId) {
        const page = this.pagesById.get(pageId)
        return page && !page.deleted ? page : null
    }

    isReadOnly(pageId) {
        return this.readOnlyPages.has(pageId)
    }

    createNotebook(title, parentId = null) {
        const now = this.timestamp()
        const validParent = parentId && this.notebook(parentId) ? parentId : null
        const notebook = {
            schema_version: schemaVersion,
            id: makeIdentifier("nb", timestampMilliseconds(now)),
            title,
            updated: now,
            device: this.device,
            deleted: false,
            order: endOrder(this.folders(validParent)),
        }
        if (validParent) {
            notebook.parent = validParent
        }
        this.applyNotebook(notebook)
        return notebook
    }

    deleteNotebook(notebookId) {
        const notebook = this.notebook(notebookId)
        if (!notebook) {
            return
        }
        for (const child of this.folders(notebookId)) {
            this.deleteNotebook(child.id)
        }
        for (const page of this.pages(notebookId)) {
            this.deletePage(page.id)
        }
        this.applyNotebook({ ...notebook, deleted: true, updated: this.timestamp(), device: this.device })
    }

    createPage(notebookId, { title = null, pdf = null } = {}) {
        const now = this.timestamp()
        const siblings = this.pages(notebookId)
        const header = {
            schema_version: schemaVersion,
            id: makeIdentifier("p", timestampMilliseconds(now)),
            notebook: notebookId,
            title: title ?? `Note ${siblings.length + 1}`,
            order: endOrder(siblings),
            updated: now,
            device: this.device,
            deleted: false,
            extent: { cols: 1, rows: Math.max(1, pdf?.pages.length ?? 1) },
        }
        this.applyHeader(header)
        pdf?.pages.forEach((size, index) => this.applyElement(header.id, importElement(pdf.asset, index, size, now, this.device)))
        return this.pagesById.get(header.id)
    }

    appendDocument(pdf, pageId) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId) || !pdf.pages.length) {
            return
        }
        const now = this.timestamp()
        const firstRow = page.extent.rows
        const firstOrder = page.elements.reduce((highest, element) => Math.max(highest, element.order), -1) + 1
        this.updatePage(pageId, { extent: { cols: page.extent.cols, rows: firstRow + pdf.pages.length } })
        pdf.pages.forEach((size, index) => {
            const element = importElement(pdf.asset, index, size, now, this.device, firstRow + index)
            element.order = firstOrder + index
            this.applyElement(pageId, element)
        })
    }

    updatePage(pageId, changes) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId)) {
            return
        }
        const next = { ...this.header(page), ...changes, updated: this.timestamp(), device: this.device }
        for (const [key, value] of Object.entries(changes)) {
            if (value === null || value === undefined) {
                delete next[key]
            }
        }
        this.applyHeader(next)
    }

    movePage(pageId, notebookId) {
        const page = this.page(pageId)
        if (!page || this.isReadOnly(pageId) || page.notebook === notebookId || !this.notebook(notebookId)) {
            return null
        }
        this.finishText()
        const now = this.timestamp()
        const { elements, ...header } = page
        const moved = { ...header, id: makeIdentifier("p", timestampMilliseconds(now)), notebook: notebookId, order: endOrder(this.pages(notebookId)), updated: now, device: this.device }
        this.applyHeader(moved)
        for (const element of elements) {
            this.applyElement(moved.id, element)
        }
        this.deletePage(pageId)
        return moved.id
    }

    arrangeFolders(notebookIds) {
        notebookIds.forEach((notebookId, index) => {
            if (this.notebook(notebookId) && this.notebook(notebookId).order !== index) {
                this.updateNotebook(notebookId, { order: index })
            }
        })
    }

    arrangePages(pageIds) {
        pageIds.forEach((pageId, index) => {
            if (this.page(pageId) && this.page(pageId).order !== index) {
                this.updatePage(pageId, { order: index })
            }
        })
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
        this.updatePage(pageId, { extent })
    }

    addStrokes(pageId, tool, color, pieces, width = tokens.tools[tool].width) {
        const page = this.page(pageId)
        const shown = pieces.filter((points) => points.length > 0)
        if (!page || this.isReadOnly(pageId) || shown.length === 0) {
            return
        }
        const now = this.timestamp()
        const layer = layerForTool(tool)
        const added = shown.map((points) => {
            const element = {
                id: makeIdentifier("e", timestampMilliseconds(now)),
                type: "stroke",
                layer,
                order: nextOrder(this.pagesById.get(pageId), layer),
                tool,
                color,
                width,
                points,
                updated: now,
                device: this.device,
                deleted: false,
            }
            this.applyElement(pageId, element)
            return element
        })
        this.record({ before: [], after: added }, pageId)
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

    transformElements(elementIds, pageId, transform) {
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
            const changed = transform(element)
            if (!changed) {
                continue
            }
            const next = { ...changed, updated: now, device: this.device }
            this.applyElement(pageId, next)
            step.before.push(element)
            step.after.push(next)
        }
        if (step.after.length) {
            this.record(step, pageId)
        }
    }

    moveElements(elementIds, pageId, offset) {
        this.transformElements(elementIds, pageId, (element) => translatedElement(element, offset))
    }

    scaleElements(elementIds, pageId, anchor, factor) {
        this.transformElements(elementIds, pageId, (element) => scaledElement(element, anchor, factor))
    }

    setStrokeWidth(elementIds, pageId, width) {
        this.transformElements(elementIds, pageId, (element) => (element.type === "stroke" && element.width !== width ? { ...element, width } : null))
    }

    placeText(box) {
        const session = this.textEditing
        if (!session || JSON.stringify(session.element.box) === JSON.stringify(box)) {
            return
        }
        session.element = { ...session.element, box, updated: this.timestamp(), device: this.device }
        if (session.isApplied) {
            this.applyElement(session.pageId, session.element)
        } else {
            this.changed()
        }
    }

    beginText(pageId, point, fontSize = tokens.text.font_size) {
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
            font_size: fontSize,
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

    styleText(changes) {
        const session = this.textEditing
        if (!session) {
            return
        }
        session.element = { ...session.element, ...changes, updated: this.timestamp(), device: this.device }
        if (session.isApplied) {
            this.applyElement(session.pageId, session.element)
        } else {
            this.changed()
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
        const original = session.original
        const isChanged = original?.content !== session.element.content
            || original?.font_size !== session.element.font_size
            || original?.color !== session.element.color
            || JSON.stringify(original?.box) !== JSON.stringify(session.element.box)
        if (isChanged) {
            this.record({ before: original ? [original] : [], after: [session.element] }, session.pageId)
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

    noteInput(pageId) {
        this.onInput?.(pageId)
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
        this.scheduleNotebook(notebook.id, true)
        this.changed()
    }

    applyHeader(header) {
        const existing = this.pagesById.get(header.id)
        const page = existing ? { ...mergeHeader(this.header(existing), header), elements: existing.elements } : { ...header, elements: [] }
        this.pagesById.set(header.id, page)
        this.schedulePage(page, true)
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
        this.schedulePage(page, true)
        this.changed()
    }

    absorbRemote(path, value) {
        const kind = repositoryPathKind(path)
        if (kind?.kind === "notebook") {
            const existing = this.notebooks.get(value.id)
            this.notebooks.set(value.id, existing ? mergeNotebook(existing, value) : value)
            this.scheduleNotebook(value.id, false)
        } else if (kind?.kind === "page") {
            const existing = this.pagesById.get(value.id)
            if (!existing) {
                this.pagesById.set(value.id, value)
            } else {
                const byId = new Map(existing.elements.map((element) => [element.id, element]))
                for (const element of value.elements ?? []) {
                    const local = byId.get(element.id)
                    byId.set(element.id, local ? mergeElement(local, element) : element)
                }
                const header = mergeHeader(this.header(existing), this.header(value))
                const elements = [...byId.values()].sort((first, second) => (first.id === second.id ? 0 : isOrderedBefore(first, second) ? -1 : 1))
                const merged = { ...header, elements }
                for (const element of elements) {
                    if (isNewer(element.updated, element.device, merged.updated, merged.device)) {
                        merged.updated = element.updated
                        merged.device = element.device
                    }
                }
                this.pagesById.set(value.id, merged)
            }
            this.schedulePage(this.pagesById.get(value.id), false)
        }
    }

    encodedFile(path) {
        const kind = repositoryPathKind(path)
        if (kind?.kind === "notebook") {
            const notebook = this.notebooks.get(kind.notebookId)
            return notebook ? encodeNotebook(notebook) : null
        }
        if (kind?.kind === "page") {
            const page = this.pagesById.get(kind.pageId)
            return page && page.notebook === kind.notebookId ? encodePage(page) : null
        }
        return null
    }

    markDirty(path) {
        this.changeCounter += 1
        const isNew = !this.dirtyPaths.has(path)
        this.dirtyPaths.set(path, this.changeCounter)
        if (isNew) {
            this.saveDirtyPaths()
        }
    }

    settle(paths) {
        let isChanged = false
        for (const [path, counter] of paths) {
            if (this.dirtyPaths.get(path) === counter) {
                this.dirtyPaths.delete(path)
                isChanged = true
            }
        }
        if (isChanged) {
            this.saveDirtyPaths()
        }
    }

    scheduleNotebook(notebookId, isLocal) {
        const path = notebookPath(notebookId)
        if (isLocal) {
            this.markDirty(path)
            this.onChange?.(notebookId)
        }
        this.schedule(path, () => encodeNotebook(this.notebooks.get(notebookId)))
    }

    schedulePage(page, isLocal) {
        const path = pagePath(page.notebook, page.id)
        if (isLocal) {
            this.markDirty(path)
            this.onChange?.(page.id)
        }
        this.schedule(path, () => encodePage(this.pagesById.get(page.id)))
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
        return Promise.all(writes.map(([path, encode]) => writeFile(path, encode()).catch((error) => {
            this.lastError = String(error)
            this.changed()
        })))
    }
}
