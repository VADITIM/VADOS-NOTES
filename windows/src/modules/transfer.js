import { elementBounds } from "./canvas.js"
import { create, microLabel, pressable, segmented, setEnabled, slabButton } from "./components.js"
import { exportCells } from "./exports.js"
import { importFailureMessage, importImage, importPageSizes, isImportInverted, readPdf, subscribeImports } from "./imports.js"
import { importElement } from "./library.js"
import { cellHeight, cellWidth, liveElements } from "./model.js"
import { animate, duration } from "./motion.js"
import * as preferences from "./preferences.js"
import { renderCell } from "./renderer.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { tokens } from "./tokens.js"

const largestCellWidth = 150
const dragSlop = 6
const staggeredPages = 12

function cellKey(column, row) {
    return `${column}:${row}`
}

function readingOrder(first, second) {
    return first.row - second.row || first.column - second.column
}

function pickPdf() {
    return new Promise((resolve) => {
        const input = create("input")
        input.type = "file"
        input.accept = "application/pdf,.pdf"
        input.addEventListener("change", () => resolve(input.files?.[0] ?? null))
        input.addEventListener("cancel", () => resolve(null))
        input.click()
    })
}

function pageCount(index, total) {
    return `${index + 1}/${total}`
}

export function transferSheet(app, request) {
    const library = app.library
    const page = () => library.page(request.pageId)
    const isEditable = !library.isReadOnly(request.pageId)
    let mode = request.mode === "import" && !isEditable ? "view" : request.mode ?? "view"
    let document_ = null
    const placements = { export: new Map(), import: new Map() }
    let gesture = null
    let chosenPdfPage = null

    const isViewing = () => mode === "view"
    const placed = () => placements[mode] ?? new Map()
    const capacity = () => (mode === "export" ? Infinity : document_?.pages.length ?? 0)
    const byIndex = () => [...placed().values()].sort((first, second) => first.index - second.index)
    const cellHolding = (index) => [...placed().values()].find((placement) => placement.index === index) ?? null
    const nextIndex = () => {
        const used = new Set([...placed().values()].map((placement) => placement.index))
        let index = 0
        while (used.has(index)) {
            index += 1
        }
        return index < capacity() ? index : null
    }
    const compact = () => {
        if (mode === "export") {
            byIndex().forEach((placement, index) => placement.index = index)
        }
    }
    const extent = () => {
        const current = page()?.extent ?? { cols: 1, rows: 1 }
        if (mode === "import" && document_) {
            return { cols: current.cols, rows: current.rows + Math.ceil(document_.pages.length / current.cols) }
        }
        return current
    }
    const cellAtPosition = (position) => {
        const { cols } = extent()
        return { column: position % cols, row: Math.floor(position / cols) }
    }
    const total = () => {
        if (isViewing()) {
            const { cols, rows } = extent()
            return cols * rows
        }
        return mode === "export" ? placed().size : document_?.pages.length ?? 0
    }

    const selectAll = () => {
        const current = page()
        placements.export.clear()
        if (!current) {
            return
        }
        const all = []
        for (let row = 0; row < current.extent.rows; row += 1) {
            for (let column = 0; column < current.extent.cols; column += 1) {
                all.push({ column, row })
            }
        }
        all.sort(readingOrder).forEach((cell, index) => placements.export.set(cellKey(cell.column, cell.row), { ...cell, index }))
    }
    const placeAfterNote = () => {
        const current = page()
        placements.import.clear()
        if (!current || !document_) {
            return
        }
        document_.pages.forEach((_, index) => {
            const column = index % current.extent.cols
            const row = current.extent.rows + Math.floor(index / current.extent.cols)
            placements.import.set(cellKey(column, row), { column, row, index })
        })
    }
    selectAll()

    const previewPage = () => {
        const current = page()
        if (!current || mode !== "import" || !document_) {
            return current
        }
        const now = new Date().toISOString()
        const shown = byIndex().map((placement) => importElement(document_.asset, placement.index, document_.pages[placement.index], now, library.device, placement.row, placement.column, document_.inverted?.[placement.index] === true))
        return { ...current, extent: extent(), elements: [...current.elements, ...shown] }
    }
    const sourcePage = (index) => {
        const now = new Date().toISOString()
        return { extent: { cols: 1, rows: 1 }, elements: [importElement(document_.asset, index, document_.pages[index], now, library.device, 0, 0, document_.inverted?.[index] === true)] }
    }

    const fileTitle = create("span", "pdf-choice-title", "Choose PDF")
    const fileDetail = microLabel("No file chosen")
    const chooser = create("button", "pdf-choice transfer-chooser", glyph("note_add", { color: tokens.semantic.import }), create("div", "pdf-choice-text", fileTitle, fileDetail))
    pressable(chooser)
    const choose = async () => {
        const file = await pickPdf()
        if (!file) {
            return
        }
        fileTitle.textContent = file.name
        try {
            document_ = await readPdf(file)
            fileDetail.textContent = `${document_.pages.length} PAGE${document_.pages.length === 1 ? "" : "S"}`
            fileDetail.style.color = ""
            placeAfterNote()
        } catch (error) {
            document_ = null
            placements.import.clear()
            fileDetail.textContent = importFailureMessage(error)
            fileDetail.style.color = tokens.semantic.destructive
        }
        render(true)
    }
    chooser.addEventListener("click", choose)

    const modeControl = segmented([{ value: "view", title: "View all" }, { value: "export", title: "Export" }, { value: "import", title: "Import" }], mode, (value) => {
        mode = value
        chosenPdfPage = null
        render(true)
        if (mode === "import" && !document_) {
            choose()
        }
    })
    if (!isEditable) {
        setEnabled(modeControl.children[3], false)
    }
    const noteImports = () => (page() ? liveElements(page()).filter((element) => element.type === "import") : [])
    const hasPdfPages = () => noteImports().length > 0 || (mode === "import" && Boolean(document_))
    const isShowingInverted = () => {
        if (mode === "import" && document_) {
            return document_.inverted.length > 0 && document_.inverted.every(Boolean)
        }
        const imports = noteImports()
        return imports.length > 0 && imports.every((element) => isImportInverted(element, preferences.paperStyle() === "dark"))
    }
    const appearanceControl = segmented([{ value: false, title: "Normal" }, { value: true, title: "Inverted" }], isShowingInverted(), (isInverted) => {
        if (document_) {
            document_ = { ...document_, inverted: document_.pages.map(() => isInverted) }
        }
        library.setInverted(noteImports().map((element) => element.id), request.pageId, isInverted)
        render(false)
    })
    let armedRemoval = null
    const lastCells = (isColumns) => {
        const { cols, rows } = page()?.extent ?? { cols: 1, rows: 1 }
        return isColumns ? Array.from({ length: rows }, (_, row) => cellKey(cols - 1, row)) : Array.from({ length: cols }, (_, column) => cellKey(column, rows - 1))
    }
    const isLastFilled = (isColumns) => {
        const keys = new Set(lastCells(isColumns))
        return liveElements(page()).some((element) => {
            const bounds = elementBounds(element)
            return bounds && keys.has(cellKey(Math.floor((bounds.x + bounds.width / 2) / cellWidth), Math.floor((bounds.y + bounds.height / 2) / cellHeight)))
        })
    }
    const shrink = (isColumns) => {
        const current = page()
        if (!current) {
            return
        }
        if (armedRemoval !== isColumns && isLastFilled(isColumns)) {
            armedRemoval = isColumns
            render(false)
            return
        }
        armedRemoval = null
        library.removeCell(request.pageId, isColumns, isColumns ? current.extent.cols - 1 : current.extent.rows - 1)
    }
    const growZone = (isColumns) => {
        const removal = create("button", "transfer-shrink", glyph("minus", { color: tokens.semantic.destructive, size: 14 }))
        removal.setAttribute("aria-label", isColumns ? "Remove the last column" : "Remove the last row")
        pressable(removal)
        removal.addEventListener("click", () => shrink(isColumns))
        const addition = create("button", "transfer-grow", glyph(isColumns ? "add_column" : "add_row", { color: tokens.semantic.create, size: 18 }))
        addition.setAttribute("aria-label", isColumns ? "Add column" : "Add row")
        pressable(addition)
        addition.addEventListener("click", () => {
            armedRemoval = null
            library.expand(request.pageId, isColumns)
        })
        const zone = create("div", `transfer-zone ${isColumns ? "is-column" : "is-row"}`, removal, addition)
        zone.removal = removal
        return zone
    }
    const growColumn = growZone(true)
    const growRow = growZone(false)
    const confirm = slabButton("Export", tokens.semantic.import, () => submit())

    const stripList = create("div", "transfer-strip-list")
    const stripEmpty = microLabel("No pages", tokens.palette.text_muted)
    stripEmpty.classList.add("transfer-strip-empty")
    const strip = create("div", "transfer-strip", chooser, stripList, stripEmpty)
    let stripItems = []
    let stripSource = ""

    const grid = create("div", "transfer-grid")
    let cells = []

    const pdfColumn = create("div", "transfer-pdf-column")
    let pdfItems = []
    let pdfSignature = ""
    const pdfGroups = () => {
        const current = page()
        if (!current) {
            return []
        }
        const imports = current.elements.filter((element) => element.type === "import" && element.asset)
        const accents = tokens.imports.accents
        return [...new Set(imports.map((element) => element.asset))].map((asset, position) => {
            const elements = imports.filter((element) => element.asset === asset)
            const live = elements.filter((element) => !element.deleted)
            const sourceName = elements.find((element) => element.source_name)?.source_name ?? null
            const measured = importPageSizes(asset)
            const known = Math.max(...elements.map((element) => element.source_page ?? 0)) + 1
            const sizes = measured?.length ? measured : Array.from({ length: known }, (_, index) => elements.find((element) => element.source_page === index)?.source_size_mm ?? [cellWidth, cellHeight])
            return { asset, sourceName, name: sourceName ?? `PDF ${position + 1}`, accent: accents[position % accents.length], elements, live, sizes, used: new Set(live.map((element) => element.source_page ?? 0)) }
        })
    }
    const isGroupInverted = (group) => {
        if (!group.live.length) {
            return group.elements.at(-1)?.inverted === true
        }
        return group.live.every((element) => isImportInverted(element, preferences.paperStyle() === "dark"))
    }
    const choosePdfPage = (asset, index) => {
        if (!isEditable) {
            return
        }
        chosenPdfPage = chosenPdfPage?.asset === asset && chosenPdfPage.index === index ? null : { asset, index }
        render(false)
    }
    const placeChosenPdfPage = (cell) => {
        const group = pdfGroups().find((candidate) => candidate.asset === chosenPdfPage?.asset)
        const size = group?.sizes[chosenPdfPage.index]
        if (!group || !size || !isEditable) {
            return
        }
        const index = chosenPdfPage.index
        chosenPdfPage = null
        library.placeImportPage(group.asset, index, size, group.sourceName, isGroupInverted(group), request.pageId, cell)
        render(false)
    }
    const layoutPdfColumn = (groups) => {
        const signature = groups.map((group) => `${group.asset}|${group.name}|${group.sizes.length}`).join(",")
        if (signature === pdfSignature) {
            return
        }
        pdfSignature = signature
        pdfItems = []
        pdfColumn.replaceChildren(...groups.map((group) => {
            const title = create("span", "transfer-pdf-title", group.name)
            const count = microLabel("")
            count.style.color = group.accent
            const invert = create("button", "transfer-pdf-invert", glyph("invert", { color: "currentColor", size: 15 }))
            pressable(invert)
            invert.addEventListener("click", () => {
                const current = pdfGroups().find((candidate) => candidate.asset === group.asset)
                if (current?.live.length) {
                    library.setInverted(current.live.map((element) => element.id), request.pageId, !isGroupInverted(current))
                }
            })
            const bar = create("span", "transfer-pdf-bar")
            const head = create("div", "transfer-pdf-head", bar, create("div", "transfer-pdf-heading", title, count), invert)
            const pages = group.sizes.map((size, index) => {
                const canvas = create("canvas", "transfer-canvas")
                const dot = create("span", "transfer-pdf-dot")
                const label = create("span", "transfer-pdf-label", pageCount(index, group.sizes.length))
                const element = create("div", "transfer-pdf-page", canvas, dot, label)
                element.addEventListener("click", () => choosePdfPage(group.asset, index))
                pdfItems.push({ asset: group.asset, index, canvas, dot, element })
                return element
            })
            const groupElement = create("div", "transfer-pdf-group", head, ...pages)
            groupElement.style.setProperty("--pdf-accent", group.accent)
            groupElement.count = count
            groupElement.invert = invert
            groupElement.asset = group.asset
            return groupElement
        }))
    }
    const updatePdfColumn = (groups) => {
        layoutPdfColumn(groups)
        for (const groupElement of pdfColumn.children) {
            const group = groups.find((candidate) => candidate.asset === groupElement.asset)
            const isInverted = isGroupInverted(group)
            groupElement.count.textContent = `${group.used.size}/${group.sizes.length}`
            groupElement.invert.classList.toggle("is-inverted", isInverted)
            groupElement.invert.setAttribute("aria-label", isInverted ? "Original PDF" : "Invert PDF")
            setEnabled(groupElement.invert, isEditable && group.live.length > 0)
        }
        for (const { asset, index, dot, element } of pdfItems) {
            const group = groups.find((candidate) => candidate.asset === asset)
            dot.classList.toggle("is-used", group.used.has(index))
            element.classList.toggle("is-chosen", chosenPdfPage?.asset === asset && chosenPdfPage.index === index)
        }
    }
    const drawPdfPages = () => {
        if (pdfColumn.hidden) {
            return
        }
        const groups = pdfGroups()
        const isDark = preferences.paperStyle() === "dark"
        const ratio = window.devicePixelRatio || 1
        for (const { asset, index, canvas } of pdfItems) {
            const group = groups.find((candidate) => candidate.asset === asset)
            const size = group?.sizes[index]
            const width = Math.round(canvas.clientWidth * ratio)
            const height = Math.round(canvas.clientHeight * ratio)
            if (!size || !width || !height) {
                continue
            }
            const image = importImage({ asset, source_page: index, source_size_mm: size, inverted: isGroupInverted(group) }, width / cellWidth, isDark, false)
            canvas.width = width
            canvas.height = height
            if (!image) {
                continue
            }
            const inset = 4 * ratio
            const scale = Math.min((width - inset * 2) / image.width, (height - inset * 2) / image.height)
            const drawnWidth = image.width * scale
            const drawnHeight = image.height * scale
            canvas.getContext("2d").drawImage(image, (width - drawnWidth) / 2, (height - drawnHeight) / 2, drawnWidth, drawnHeight)
        }
    }

    const assign = (index, target) => {
        const key = cellKey(target.column, target.row)
        const source = cellHolding(index)
        const occupant = placed().get(key)
        if (source) {
            placed().delete(cellKey(source.column, source.row))
        }
        if (occupant && source && occupant !== source) {
            placed().set(cellKey(source.column, source.row), { column: source.column, row: source.row, index: occupant.index })
        }
        placed().set(key, { column: target.column, row: target.row, index })
    }
    const swapIndices = (first, second) => {
        const firstCell = cellHolding(first)
        const secondCell = cellHolding(second)
        if (firstCell && secondCell) {
            firstCell.index = second
            secondCell.index = first
        }
    }

    const toggleRow = (row) => {
        if (isViewing()) {
            return
        }
        const rowCells = Array.from({ length: extent().cols }, (_, column) => ({ column, row }))
        const isFull = rowCells.every((cell) => placed().has(cellKey(cell.column, cell.row)))
        for (const cell of rowCells) {
            const key = cellKey(cell.column, cell.row)
            if (isFull) {
                placed().delete(key)
            } else if (!placed().has(key)) {
                const index = nextIndex()
                if (index !== null) {
                    placed().set(key, { ...cell, index })
                }
            }
        }
        compact()
        render(false)
    }
    const paint = (cell, isSelecting) => {
        const key = cellKey(cell.column, cell.row)
        if (isSelecting && !placed().has(key)) {
            const index = nextIndex()
            if (index !== null) {
                placed().set(key, { column: cell.column, row: cell.row, index })
            }
        } else if (!isSelecting && placed().has(key)) {
            placed().delete(key)
            compact()
        }
        render(false)
    }

    const targetAt = (event) => {
        const element = document.elementFromPoint(event.clientX, event.clientY)
        const cell = element?.closest(".transfer-cell")
        if (cell && grid.contains(cell)) {
            return { kind: "cell", column: Number(cell.dataset.column), row: Number(cell.dataset.row), element: cell }
        }
        const item = element?.closest(".transfer-page")
        if (item && stripList.contains(item)) {
            return { kind: "page", index: Number(item.dataset.index), element: item }
        }
        return null
    }
    const accepts = (target) => {
        if (!target || target.element === gesture.sourceElement) {
            return false
        }
        if (target.kind === "cell") {
            return true
        }
        return isViewing() || (mode === "export" && gesture.source.kind === "page")
    }

    const moveGhost = (event) => {
        gesture.ghost.style.left = `${event.clientX - gesture.grab.x}px`
        gesture.ghost.style.top = `${event.clientY - gesture.grab.y}px`
        const target = targetAt(event)
        const next = accepts(target) ? target : null
        if (gesture.target?.element !== next?.element) {
            gesture.target?.element.classList.remove("is-target")
            gesture.target = next
            gesture.target?.element.classList.add("is-target")
        }
    }
    const lift = () => {
        const { sourceElement, canvas, start } = gesture
        const rect = sourceElement.getBoundingClientRect()
        const ghost = create("canvas", "transfer-ghost")
        ghost.width = canvas.width
        ghost.height = canvas.height
        ghost.getContext("2d").drawImage(canvas, 0, 0)
        ghost.style.width = `${rect.width}px`
        ghost.style.height = `${rect.height}px`
        document.body.append(ghost)
        gesture.ghost = ghost
        gesture.grab = { x: start.x - rect.left, y: start.y - rect.top }
        sourceElement.classList.add("is-lifted")
        moveGhost(gesture.lastEvent)
        animate(ghost, [{ scale: "1" }, { scale: String(tokens.motion.scales.hold_pop) }], { milliseconds: duration("state"), curveName: "back_out", fill: "forwards" })
    }
    const viewedCell = (target) => (target.kind === "cell" ? { column: target.column, row: target.row } : cellAtPosition(target.index))
    const drop = () => {
        const { ghost, source, sourceElement, target } = gesture
        target?.element.classList.remove("is-target")
        if (target && isViewing()) {
            library.swapCells(request.pageId, viewedCell(source), viewedCell(target))
        } else if (target) {
            const index = source.kind === "cell" ? placed().get(cellKey(source.column, source.row))?.index : source.index
            if (index !== undefined && target.kind === "cell") {
                assign(index, target)
            } else if (index !== undefined) {
                swapIndices(index, target.index)
            }
        }
        const landing = target?.element ?? sourceElement
        const rect = landing.getBoundingClientRect()
        const ghostRect = ghost.getBoundingClientRect()
        const milliseconds = duration("state")
        const travel = `translate(${rect.left + rect.width / 2 - ghostRect.left - ghostRect.width / 2}px, ${rect.top + rect.height / 2 - ghostRect.top - ghostRect.height / 2}px)`
        animate(ghost, [{ transform: "translate(0, 0)", opacity: 1 }, { transform: travel, opacity: 0 }], { milliseconds, curveName: "power_two_in", fill: "forwards" })
        setTimeout(() => ghost.remove(), milliseconds)
        sourceElement.classList.remove("is-lifted")
        render(false)
        animate(landing, [{ scale: "0.9" }, { scale: "1" }], { milliseconds: duration("release"), curveName: "back_out" })
    }

    const beginGesture = (event, host, source, sourceElement, canvas) => {
        if (event.button !== 0) {
            return
        }
        host.setPointerCapture(event.pointerId)
        const isPlaced = source.kind === "cell" && placed().has(cellKey(source.column, source.row))
        const isCarryable = isViewing() || source.kind === "page" || isPlaced
        gesture = { start: { x: event.clientX, y: event.clientY }, lastEvent: event, source, sourceElement, canvas, isCarryable, isPainting: false, last: null }
        if (!isCarryable) {
            gesture.isPainting = true
            gesture.last = cellKey(source.column, source.row)
            paint(source, true)
        }
    }
    const moveGesture = (event) => {
        if (!gesture) {
            return
        }
        gesture.lastEvent = event
        if (gesture.ghost) {
            moveGhost(event)
            return
        }
        if (gesture.isPainting) {
            const target = targetAt(event)
            if (target?.kind === "cell" && cellKey(target.column, target.row) !== gesture.last) {
                gesture.last = cellKey(target.column, target.row)
                paint(target, true)
            }
            return
        }
        if (Math.hypot(event.clientX - gesture.start.x, event.clientY - gesture.start.y) > dragSlop) {
            lift()
        }
    }
    const endGesture = (event) => {
        if (!gesture) {
            return
        }
        if (gesture.ghost) {
            drop()
        } else if (!gesture.isPainting && !isViewing() && gesture.source.kind === "cell" && event.type === "pointerup") {
            paint(gesture.source, false)
        } else if (isViewing() && chosenPdfPage && event.type === "pointerup") {
            placeChosenPdfPage(viewedCell(gesture.source))
        }
        gesture = null
    }
    for (const host of [grid, stripList]) {
        host.addEventListener("pointermove", moveGesture)
        host.addEventListener("pointerup", endGesture)
        host.addEventListener("pointercancel", endGesture)
    }
    grid.addEventListener("pointerdown", (event) => {
        const target = targetAt(event)
        if (target?.kind !== "cell") {
            return
        }
        const entry = cells.find((cell) => cell.element === target.element)
        beginGesture(event, grid, { kind: "cell", column: target.column, row: target.row }, target.element, entry.canvas)
    })
    stripList.addEventListener("pointerdown", (event) => {
        const target = targetAt(event)
        if (target?.kind !== "page") {
            return
        }
        const item = stripItems.find((candidate) => candidate.element === target.element)
        beginGesture(event, stripList, { kind: "page", index: target.index }, target.element, item.canvas)
    })

    const drawCells = () => {
        const shown = previewPage()
        if (!shown) {
            return
        }
        const options = { showsGuides: preferences.showsGuides(), showsDividers: false, paperStyle: preferences.paperStyle() }
        for (const { canvas, column, row } of cells) {
            renderCell(canvas, shown, column, row, options)
        }
        drawPdfPages()
        for (const { canvas, index } of stripItems) {
            if (isViewing()) {
                const cell = cellAtPosition(index)
                renderCell(canvas, shown, cell.column, cell.row, options)
            } else if (mode === "import" && document_) {
                renderCell(canvas, sourcePage(index), 0, 0, options)
            } else {
                const placement = cellHolding(index)
                if (placement) {
                    renderCell(canvas, shown, placement.column, placement.row, options)
                }
            }
        }
    }

    const layoutGrid = () => {
        const current = page()
        const { cols, rows } = extent()
        cells = []
        const children = []
        for (let row = 0; row < rows; row += 1) {
            const rowButton = create("button", "transfer-row", String(row + 1).padStart(2, "0"))
            pressable(rowButton)
            rowButton.addEventListener("click", () => toggleRow(row))
            children.push(rowButton)
            for (let column = 0; column < cols; column += 1) {
                const canvas = create("canvas", "transfer-canvas")
                const badge = create("span", "transfer-badge")
                const element = create("div", `transfer-cell${current && row >= current.extent.rows ? " is-new" : ""}`, canvas, badge)
                element.dataset.column = String(column)
                element.dataset.row = String(row)
                cells.push({ canvas, column, row, element, badge })
                children.push(element)
            }
        }
        growColumn.style.gridColumn = String(cols + 2)
        growColumn.style.gridRow = `1 / span ${rows}`
        growRow.style.gridColumn = `2 / span ${cols}`
        growRow.style.gridRow = String(rows + 1)
        grid.replaceChildren(...children, growColumn, growRow)
        grid.dataset.shape = `${cols}x${rows}`
    }

    const layoutStrip = () => {
        const count = isViewing() ? total() : mode === "import" ? document_?.pages.length ?? 0 : placed().size
        const source = `${mode}|${document_?.asset ?? ""}`
        if (source === stripSource && count === stripItems.length) {
            return
        }
        const isNewSource = source !== stripSource
        stripSource = source
        stripItems = Array.from({ length: count }, (_, index) => {
            const existing = stripItems[index]
            if (existing && !isNewSource) {
                return existing
            }
            const canvas = create("canvas", "transfer-canvas")
            const badge = create("span", "transfer-badge")
            const element = create("div", "transfer-page", canvas, badge)
            element.dataset.index = String(index)
            return { canvas, badge, element, index }
        })
        stripList.replaceChildren(...stripItems.map((item) => item.element))
        if (isNewSource) {
            stripItems.forEach((item, position) => animate(item.element, [{ opacity: 0, transform: "translateY(12px)" }, { opacity: 1, transform: "translateY(0)" }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out", delay: Math.min(position, staggeredPages) * duration("rise_stagger") }))
        }
    }

    const setShown = (element, isShown) => {
        if (element.hidden === !isShown) {
            return
        }
        if (isShown) {
            element.hidden = false
            animate(element, [{ opacity: 0, transform: "scale(0.94)" }, { opacity: 1, transform: "scale(1)" }], { milliseconds: duration("state"), curveName: "back_out" })
        } else {
            element.hidden = true
        }
    }

    const render = (isAnimated) => {
        const { cols, rows } = extent()
        if (grid.dataset.shape !== `${cols}x${rows}`) {
            layoutGrid()
        }
        layoutStrip()
        const count = total()
        const viewing = isViewing()
        const groups = viewing ? pdfGroups() : []
        pdfColumn.hidden = groups.length === 0
        body.classList.toggle("has-pdfs", groups.length > 0)
        if (groups.length) {
            updatePdfColumn(groups)
        }
        const isGrowing = viewing && isEditable && Boolean(page())
        grid.style.gridTemplateColumns = `auto repeat(${cols}, minmax(0, ${largestCellWidth}px))${isGrowing ? " 56px" : ""}`
        growColumn.hidden = !isGrowing
        growRow.hidden = !isGrowing
        growColumn.removal.hidden = cols <= 1
        growRow.removal.hidden = rows <= 1
        growColumn.classList.toggle("is-armed", armedRemoval === true)
        growRow.classList.toggle("is-armed", armedRemoval === false)
        const doomed = new Set(viewing && armedRemoval !== null ? lastCells(armedRemoval) : [])
        grid.classList.toggle("is-viewing", viewing)
        for (const { element, badge, column, row } of cells) {
            const placement = viewing ? null : placed().get(cellKey(column, row))
            element.classList.toggle("is-doomed", doomed.has(cellKey(column, row)))
            element.classList.toggle("is-selected", Boolean(placement))
            element.classList.toggle("is-shown", viewing)
            badge.textContent = viewing ? pageCount(row * cols + column, count) : placement ? pageCount(placement.index, count) : ""
        }
        for (const { element, badge, index } of stripItems) {
            element.classList.toggle("is-selected", !viewing && Boolean(cellHolding(index)))
            element.classList.toggle("is-shown", viewing)
            badge.textContent = pageCount(index, count)
        }
        const isImport = mode === "import"
        chooser.hidden = !isImport
        stripEmpty.hidden = stripItems.length > 0 || isImport
        setShown(confirm, !viewing)
        const chosen = placed().size
        confirm.setTitle(isImport ? `Import ${chosen} of ${document_?.pages.length ?? 0}` : `Export ${chosen} page${chosen === 1 ? "" : "s"}`)
        setEnabled(confirm, chosen > 0)
        appearanceControl.style.display = hasPdfPages() ? "" : "none"
        appearanceControl.select(isShowingInverted(), true)
        requestAnimationFrame(drawCells)
        if (isAnimated) {
            animate(grid, [{ opacity: 0.4 }, { opacity: 1 }], { milliseconds: duration("state"), curveName: "power_two_out" })
        }
    }

    const submit = async () => {
        const current = page()
        const ordered = byIndex()
        if (!current || !ordered.length) {
            return
        }
        if (mode === "export") {
            setEnabled(confirm, false)
            await exportCells(current, library.noteTitle(current), ordered, { showsGuides: preferences.showsGuides(), showsDividers: preferences.showsDividers(), paperStyle: preferences.paperStyle() })
            app.navigator.show(null)
            return
        }
        if (mode === "import" && document_) {
            library.placeDocument(document_, request.pageId, ordered)
            app.navigator.show(null)
        }
    }

    const header = create("div", "transfer-header", modeControl, appearanceControl, confirm)
    const body = create("div", "transfer-body", pdfColumn, strip, grid)
    const module = create("div", "settings-module transfer-module", create("div", "settings-module-header", microLabel(page() ? library.noteTitle(page()) : "Note")), header, body)
    squircle(module, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    const panels = create("div", "settings-panels", module)
    const sheet = create("div", "settings-sheet transfer-sheet", panels)
    sheet.addEventListener("pointerdown", (event) => {
        if (event.target === sheet || event.target === panels) {
            app.navigator.show(null)
        }
    })
    const unsubscribeImports = subscribeImports(() => requestAnimationFrame(() => {
        if (isViewing() && !pdfColumn.hidden) {
            updatePdfColumn(pdfGroups())
        }
        drawCells()
    }))
    const resize = () => requestAnimationFrame(drawCells)
    window.addEventListener("resize", resize)
    sheet.unsubscribe = () => {
        unsubscribeImports()
        window.removeEventListener("resize", resize)
        gesture?.ghost?.remove()
    }
    sheet.refresh = () => render(false)
    sheet.riseParts = () => [header, pdfColumn, strip, grid].forEach((part, position) => animate(part, [{ opacity: 0, transform: "translateY(16px)" }, { opacity: 1, transform: "translateY(0)" }], { milliseconds: duration("overlay_enter"), curveName: "power_two_out", delay: duration("rise_delay") + position * duration("chrome_stagger") }))
    confirm.hidden = isViewing()
    render(false)
    if (mode === "import") {
        choose()
    }
    return sheet
}
