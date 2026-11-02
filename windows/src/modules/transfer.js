import { create, linkButton, microLabel, pressable, segmented, setEnabled, slabButton } from "./components.js"
import { exportCells } from "./exports.js"
import { importFailureMessage, readPdf, subscribeImports } from "./imports.js"
import { importElement } from "./library.js"
import { animate, duration } from "./motion.js"
import * as preferences from "./preferences.js"
import { renderCell } from "./renderer.js"
import { glyph, squircle, squircleRadius } from "./shapes.js"
import { tokens } from "./tokens.js"

const largestCellWidth = 150

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

export function transferSheet(app, request) {
    const library = app.library
    const page = () => library.page(request.pageId)
    const isEditable = !library.isReadOnly(request.pageId)
    let mode = request.mode === "import" && isEditable ? "import" : "export"
    let document_ = null
    const exportSelection = new Map()
    const importSelection = new Map()
    let painting = null

    const selection = () => (mode === "export" ? exportSelection : importSelection)
    const ordered = () => [...selection().values()].sort(readingOrder)
    const extent = () => {
        const current = page()?.extent ?? { cols: 1, rows: 1 }
        if (mode === "import" && document_) {
            return { cols: current.cols, rows: current.rows + Math.ceil(document_.pages.length / current.cols) }
        }
        return current
    }
    const capacity = () => (mode === "export" ? Infinity : document_?.pages.length ?? 0)

    const selectAll = () => {
        const current = page()
        if (!current) {
            return
        }
        exportSelection.clear()
        for (let row = 0; row < current.extent.rows; row += 1) {
            for (let column = 0; column < current.extent.cols; column += 1) {
                exportSelection.set(cellKey(column, row), { column, row })
            }
        }
    }
    const placeAfterNote = () => {
        const current = page()
        importSelection.clear()
        if (!current || !document_) {
            return
        }
        document_.pages.forEach((_, index) => {
            const column = index % current.extent.cols
            const row = current.extent.rows + Math.floor(index / current.extent.cols)
            importSelection.set(cellKey(column, row), { column, row })
        })
    }
    selectAll()

    const previewPage = () => {
        const current = page()
        if (!current || mode !== "import" || !document_) {
            return current
        }
        const now = new Date().toISOString()
        const placed = ordered().map((cell, index) => importElement(document_.asset, index, document_.pages[index], now, library.device, cell.row, cell.column))
        return { ...current, extent: extent(), elements: [...current.elements, ...placed] }
    }

    const modeControl = segmented([{ value: "export", title: "Export" }, { value: "import", title: "Import" }], mode, (value) => {
        mode = value
        render(true)
        if (mode === "import" && !document_) {
            choose()
        }
    })
    if (!isEditable) {
        setEnabled(modeControl.children[2], false)
    }

    const fileTitle = create("span", "pdf-choice-title", "Choose PDF")
    const fileDetail = microLabel("No file chosen")
    const chooser = create("button", "pdf-choice", glyph("note_add", { color: tokens.semantic.import }), create("div", "pdf-choice-text", fileTitle, fileDetail))
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
            importSelection.clear()
            fileDetail.textContent = importFailureMessage(error)
            fileDetail.style.color = tokens.semantic.destructive
        }
        render(true)
    }
    chooser.addEventListener("click", choose)

    const allButton = linkButton({ glyphName: "check", title: "All", tint: tokens.semantic.view, action: () => {
        if (mode === "export") {
            selectAll()
        } else {
            placeAfterNote()
        }
        render(false)
    } })
    const noneButton = linkButton({ glyphName: "close", title: "None", tint: tokens.semantic.view, action: () => {
        selection().clear()
        render(false)
    } })
    const status = microLabel("", tokens.palette.text_muted)
    const confirm = slabButton("Export", tokens.semantic.import, () => submit())

    const grid = create("div", "transfer-grid")
    let canvases = []

    const toggleRow = (row) => {
        const cells = Array.from({ length: extent().cols }, (_, column) => ({ column, row }))
        const isFull = cells.every((cell) => selection().has(cellKey(cell.column, cell.row)))
        for (const cell of cells) {
            if (isFull) {
                selection().delete(cellKey(cell.column, cell.row))
            } else if (selection().size < capacity()) {
                selection().set(cellKey(cell.column, cell.row), cell)
            }
        }
        render(false)
    }
    const paint = (cell) => {
        const key = cellKey(cell.column, cell.row)
        if (painting.isSelecting && !selection().has(key) && selection().size < capacity()) {
            selection().set(key, cell)
        } else if (!painting.isSelecting) {
            selection().delete(key)
        }
        render(false)
    }
    const cellAt = (event) => {
        const target = document.elementFromPoint(event.clientX, event.clientY)?.closest(".transfer-cell")
        return target && grid.contains(target) ? { column: Number(target.dataset.column), row: Number(target.dataset.row) } : null
    }
    grid.addEventListener("pointerdown", (event) => {
        const cell = cellAt(event)
        if (!cell || event.button !== 0) {
            return
        }
        grid.setPointerCapture(event.pointerId)
        painting = { isSelecting: !selection().has(cellKey(cell.column, cell.row)), last: cellKey(cell.column, cell.row) }
        paint(cell)
    })
    grid.addEventListener("pointermove", (event) => {
        if (!painting) {
            return
        }
        const cell = cellAt(event)
        if (cell && cellKey(cell.column, cell.row) !== painting.last) {
            painting.last = cellKey(cell.column, cell.row)
            paint(cell)
        }
    })
    for (const name of ["pointerup", "pointercancel"]) {
        grid.addEventListener(name, () => painting = null)
    }

    const drawCells = () => {
        const shown = previewPage()
        if (!shown) {
            return
        }
        const options = { showsGuides: preferences.showsGuides(), showsDividers: false, paperStyle: preferences.paperStyle() }
        for (const { canvas, column, row } of canvases) {
            renderCell(canvas, shown, column, row, options)
        }
    }

    const layoutGrid = () => {
        const current = page()
        const { cols, rows } = extent()
        grid.style.gridTemplateColumns = `auto repeat(${cols}, minmax(0, ${largestCellWidth}px))`
        canvases = []
        const children = []
        for (let row = 0; row < rows; row += 1) {
            const rowButton = create("button", "transfer-row", String(row + 1).padStart(2, "0"))
            pressable(rowButton)
            rowButton.addEventListener("click", () => toggleRow(row))
            children.push(rowButton)
            for (let column = 0; column < cols; column += 1) {
                const canvas = create("canvas", "transfer-canvas")
                const badge = create("span", "transfer-badge")
                const cell = create("div", `transfer-cell${current && row >= current.extent.rows ? " is-new" : ""}`, canvas, badge)
                cell.dataset.column = String(column)
                cell.dataset.row = String(row)
                canvases.push({ canvas, column, row, cell, badge })
                children.push(cell)
            }
        }
        grid.replaceChildren(...children)
        grid.dataset.shape = `${cols}x${rows}`
    }

    const render = (isAnimated) => {
        const { cols, rows } = extent()
        if (grid.dataset.shape !== `${cols}x${rows}`) {
            layoutGrid()
        }
        const cells = ordered()
        const positions = new Map(cells.map((cell, index) => [cellKey(cell.column, cell.row), index]))
        for (const { cell, badge, column, row } of canvases) {
            const position = positions.get(cellKey(column, row))
            const isSelected = position !== undefined
            cell.classList.toggle("is-selected", isSelected)
            badge.textContent = isSelected ? String(position + 1) : ""
        }
        const isImport = mode === "import"
        chooser.hidden = !isImport
        confirm.setTitle(isImport ? `Import ${cells.length} of ${document_?.pages.length ?? 0}` : `Export ${cells.length} page${cells.length === 1 ? "" : "s"}`)
        status.textContent = (isImport ? "Each number is the PDF page placed in that cell" : "Each number is a page of the exported PDF").toUpperCase()
        setEnabled(confirm, cells.length > 0)
        requestAnimationFrame(drawCells)
        if (isAnimated) {
            animate(grid, [{ opacity: 0.4 }, { opacity: 1 }], { milliseconds: duration("state"), curveName: "power_two_out" })
        }
    }

    const submit = async () => {
        const current = page()
        const cells = ordered()
        if (!current || !cells.length) {
            return
        }
        if (mode === "export") {
            setEnabled(confirm, false)
            await exportCells(current, library.noteTitle(current), cells, { showsGuides: preferences.showsGuides(), showsDividers: preferences.showsDividers(), paperStyle: preferences.paperStyle() })
            app.navigator.show(null)
            return
        }
        if (document_) {
            library.placeDocument(document_, request.pageId, cells)
            app.navigator.show(null)
        }
    }

    const header = create("div", "transfer-header", modeControl, create("div", "transfer-actions", allButton, noneButton))
    const module = create("div", "settings-module transfer-module", create("div", "settings-module-header", microLabel(page() ? library.noteTitle(page()) : "Note"), status), header, chooser, grid, confirm)
    squircle(module, { radius: squircleRadius.panel, fill: tokens.palette.panel_solid, border: tokens.palette.border })
    const panels = create("div", "settings-panels", module)
    const sheet = create("div", "settings-sheet", panels)
    sheet.addEventListener("pointerdown", (event) => {
        if (event.target === sheet || event.target === panels) {
            app.navigator.show(null)
        }
    })
    const unsubscribeImports = subscribeImports(() => requestAnimationFrame(drawCells))
    const resize = () => requestAnimationFrame(drawCells)
    window.addEventListener("resize", resize)
    sheet.unsubscribe = () => {
        unsubscribeImports()
        window.removeEventListener("resize", resize)
    }
    sheet.refresh = () => render(false)
    render(false)
    if (mode === "import") {
        choose()
    }
    return sheet
}
