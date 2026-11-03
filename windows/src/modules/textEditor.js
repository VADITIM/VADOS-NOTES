import { codeKeyEdit, codeTextEdit, indentUnit, newlineEdit } from "./codeIndentation.js"
import { makeStyle, pushRun, sameStyle } from "./markdown.js"
import { fontFamily, monoFamily, rhythmFontSize, rowGap, rowsFor, syntaxColors } from "./renderer.js"
import { isFence, isVerbatim, lineShapes, prefixOf, richLines, richMarkdown, shapeScale } from "./richText.js"
import { lineSyntaxTokens, syntaxTokens } from "./syntaxHighlighter.js"
import { tokens, withAlpha } from "./tokens.js"

export const inlineFlags = ["isBold", "isItalic", "isStruck", "isUnderlined", "isDashedUnderlined", "isCode"]
const prefixShade = 0.45
const formatCommands = { formatBold: "isBold", formatItalic: "isItalic", formatUnderline: "isUnderlined", formatStrikeThrough: "isStruck" }
const typingGroupMilliseconds = 1000
const historyLimit = 200
const measuringContext = document.createElement("canvas").getContext("2d")
const ascentCache = new Map()

function textOf(runs) {
    return runs.map((run) => run.text).join("")
}

function flatten(lines) {
    const runs = []
    lines.forEach((line, index) => {
        if (index > 0) {
            pushRun(runs, "\n", makeStyle())
        }
        for (const run of line) {
            pushRun(runs, run.text, run.style)
        }
    })
    return runs
}

function sliceRuns(runs, start, end) {
    const result = []
    let position = 0
    for (const run of runs) {
        const runEnd = position + run.text.length
        const low = Math.max(start, position)
        const high = Math.min(end, runEnd)
        if (high > low) {
            pushRun(result, run.text.slice(low - position, high - position), run.style)
        }
        position = runEnd
    }
    return result
}

function unflatten(runs) {
    const lines = [[]]
    for (const run of runs) {
        run.text.split("\n").forEach((piece, index) => {
            if (index > 0) {
                lines.push([])
            }
            pushRun(lines[lines.length - 1], piece, run.style)
        })
    }
    return lines
}

function fontAscent(family, weight, isItalic) {
    const key = `${family}|${weight}|${isItalic}`
    if (!ascentCache.has(key)) {
        measuringContext.font = `${isItalic ? "italic " : ""}${weight} 100px ${family}`
        const metrics = measuringContext.measureText("Hg")
        ascentCache.set(key, { ascent: (metrics.fontBoundingBoxAscent ?? 112) / 100, descent: (metrics.fontBoundingBoxDescent ?? 36) / 100 })
    }
    return ascentCache.get(key)
}

export class RichTextEditor {
    constructor({ onChange, onStyleState }) {
        this.onChange = onChange
        this.onStyleState = onStyleState
        this.lines = [[]]
        this.markdown = ""
        this.selection = { start: 0, end: 0 }
        this.typingStyle = makeStyle()
        this.look = { zoom: 1, color: tokens.text.color, paperStyle: "dark", writingFont: "Space Mono" }
        this.reported = null
        this.history = []
        this.future = []
        this.committedSelection = { start: 0, end: 0 }
        this.element = document.createElement("div")
        this.element.className = "text-editor-field"
        this.element.contentEditable = "true"
        this.element.spellcheck = true
        this.element.addEventListener("beforeinput", (event) => this.beforeInput(event))
        this.element.addEventListener("compositionend", () => this.absorbDom())
        this.element.addEventListener("input", (event) => {
            if (!event.isComposing && this.isDomDirty) {
                this.absorbDom()
            }
        })
        this.element.addEventListener("keydown", (event) => this.keyDown(event))
        this.element.addEventListener("copy", (event) => this.copy(event, false))
        this.element.addEventListener("cut", (event) => this.copy(event, true))
        document.addEventListener("selectionchange", this.selectionListener = () => this.selectionChanged())
    }

    destroy() {
        document.removeEventListener("selectionchange", this.selectionListener)
    }

    get text() {
        return this.lines.map(textOf).join("\n")
    }

    load(markdown) {
        this.markdown = markdown
        this.lines = richLines(markdown)
        const length = this.text.length
        this.selection = { start: Math.min(this.selection.start, length), end: Math.min(this.selection.start, length) }
        this.committedSelection = { ...this.selection }
        this.history = []
        this.future = []
        this.render()
        this.refreshTypingStyle()
        this.report()
    }

    setLook(look) {
        const next = { ...this.look, ...look }
        if (JSON.stringify(next) === JSON.stringify(this.look)) {
            return
        }
        this.look = next
        this.render()
    }

    focus() {
        this.element.focus({ preventScroll: true })
        this.restoreSelection()
    }

    lineStarts() {
        const starts = []
        let location = 0
        for (const line of this.lines) {
            starts.push(location)
            location += textOf(line).length + 1
        }
        return starts
    }

    lineIndexAt(offset) {
        const starts = this.lineStarts()
        let index = 0
        while (index + 1 < starts.length && starts[index + 1] <= offset) {
            index += 1
        }
        return index
    }

    shapeAt(offset) {
        return lineShapes(this.lines.map(textOf))[this.lineIndexAt(offset)]
    }

    styleAt(offset) {
        const runs = flatten(this.lines)
        let position = 0
        for (const run of runs) {
            if (offset < position + run.text.length) {
                return run.style
            }
            position += run.text.length
        }
        return makeStyle()
    }

    characterAt(offset) {
        return this.text[offset]
    }

    refreshTypingStyle() {
        const caret = this.selection.start
        const isLineStart = caret === 0 || this.characterAt(caret - 1) === "\n"
        const ahead = this.characterAt(caret)
        const isCodeAhead = ahead !== undefined && ahead !== "\n" && this.styleAt(caret).isCode
        const shape = this.shapeAt(caret)
        const style = isLineStart ? (isCodeAhead ? this.styleAt(caret) : makeStyle()) : this.styleAt(caret - 1)
        this.typingStyle = isVerbatim(shape) ? makeStyle() : { ...style }
    }

    replace(start, end, text, style = this.typingStyle, caret = start + text.length) {
        const runs = flatten(this.lines)
        const inserted = []
        text.split("\n").forEach((piece, index) => {
            if (index > 0) {
                pushRun(inserted, "\n", makeStyle())
            }
            pushRun(inserted, piece, style)
        })
        const next = []
        for (const run of [...sliceRuns(runs, 0, start), ...inserted, ...sliceRuns(runs, end, Infinity)]) {
            pushRun(next, run.text, run.style)
        }
        this.lines = unflatten(next)
        this.selection = { start: caret, end: caret }
        this.commit()
    }

    restyleRange(start, end, change) {
        const runs = flatten(this.lines)
        const next = []
        for (const run of [...sliceRuns(runs, 0, start), ...sliceRuns(runs, start, end).map((run) => ({ text: run.text, style: run.text === "\n" ? run.style : change(run.style) })), ...sliceRuns(runs, end, Infinity)]) {
            pushRun(next, run.text, run.style)
        }
        this.lines = unflatten(next)
        this.commit({ keepsTypingStyle: false })
    }

    commit({ keepsTypingStyle = false, isHistory = false } = {}) {
        this.render()
        if (!keepsTypingStyle) {
            this.refreshTypingStyle()
        }
        this.report()
        const next = richMarkdown(this.lines)
        if (next !== this.markdown) {
            if (!isHistory) {
                this.remember()
            }
            this.markdown = next
            this.onChange(next)
        }
        this.editKind = null
        this.committedSelection = { ...this.selection }
    }

    remember() {
        const now = performance.now()
        const isGrouped = this.editKind === "typing" && this.lastEditKind === "typing" && now - this.lastEditTime < typingGroupMilliseconds
        if (!isGrouped) {
            this.history.push({ markdown: this.markdown, selection: this.committedSelection })
            if (this.history.length > historyLimit) {
                this.history.shift()
            }
        }
        this.future = []
        this.lastEditKind = this.editKind
        this.lastEditTime = now
    }

    undo() {
        this.step(this.history, this.future)
    }

    redo() {
        this.step(this.future, this.history)
    }

    step(source, target) {
        const entry = source.pop()
        if (!entry) {
            return
        }
        target.push({ markdown: this.markdown, selection: { ...this.selection } })
        this.lines = richLines(entry.markdown)
        const length = this.text.length
        this.selection = { start: Math.min(entry.selection.start, length), end: Math.min(entry.selection.end, length) }
        this.lastEditKind = null
        this.commit({ isHistory: true })
    }

    offsetFromDom(node, offset) {
        const lineElements = [...this.element.children]
        let lineElement = node === this.element ? null : node
        while (lineElement && lineElement.parentNode !== this.element) {
            lineElement = lineElement.parentNode
        }
        if (!lineElement) {
            const starts = this.lineStarts()
            const index = Math.min(offset, lineElements.length) - 1
            return index < 0 ? 0 : starts[index] + textOf(this.lines[index] ?? []).length
        }
        const lineIndex = lineElements.indexOf(lineElement)
        const lineStart = this.lineStarts()[lineIndex] ?? 0
        if (node === lineElement) {
            let total = 0
            for (const child of [...lineElement.childNodes].slice(0, offset)) {
                total += child.nodeName === "BR" ? 0 : child.textContent.length
            }
            return lineStart + total
        }
        let span = node
        while (span.parentNode !== lineElement) {
            span = span.parentNode
        }
        const before = [...lineElement.childNodes].slice(0, [...lineElement.childNodes].indexOf(span)).reduce((total, child) => total + (child.nodeName === "BR" ? 0 : child.textContent.length), 0)
        const inside = node.nodeType === Node.TEXT_NODE ? offset : [...node.childNodes].slice(0, offset).reduce((total, child) => total + child.textContent.length, 0)
        return lineStart + before + inside
    }

    domFromOffset(offset) {
        const lineIndex = this.lineIndexAt(offset)
        const lineElement = this.element.children[lineIndex]
        if (!lineElement) {
            return { node: this.element, offset: 0 }
        }
        let remaining = offset - this.lineStarts()[lineIndex]
        for (const span of lineElement.childNodes) {
            if (span.nodeName === "BR") {
                continue
            }
            const length = span.textContent.length
            if (remaining <= length && span.firstChild) {
                return { node: span.firstChild, offset: remaining }
            }
            remaining -= length
        }
        return { node: lineElement, offset: lineElement.childNodes.length }
    }

    readSelection() {
        const selection = document.getSelection()
        if (!selection?.rangeCount || !this.element.contains(selection.anchorNode)) {
            return null
        }
        const range = selection.getRangeAt(0)
        const start = this.offsetFromDom(range.startContainer, range.startOffset)
        const end = this.offsetFromDom(range.endContainer, range.endOffset)
        return { start: Math.min(start, end), end: Math.max(start, end) }
    }

    restoreSelection() {
        if (document.activeElement !== this.element) {
            return
        }
        const selection = document.getSelection()
        const start = this.domFromOffset(this.selection.start)
        const end = this.domFromOffset(this.selection.end)
        const range = document.createRange()
        range.setStart(start.node, start.offset)
        range.setEnd(end.node, end.offset)
        selection.removeAllRanges()
        selection.addRange(range)
    }

    selectionChanged() {
        if (this.isRendering) {
            return
        }
        const read = this.readSelection()
        if (!read || (read.start === this.selection.start && read.end === this.selection.end)) {
            return
        }
        this.selection = read
        this.committedSelection = { ...read }
        this.lastEditKind = null
        this.refreshTypingStyle()
        this.report()
    }

    absorbDom() {
        this.isDomDirty = false
        const lines = [...this.element.children].map((lineElement) => {
            const runs = []
            for (const child of lineElement.childNodes) {
                if (child.nodeName === "BR") {
                    continue
                }
                const style = child.dataset?.style ? JSON.parse(child.dataset.style) : this.typingStyle
                pushRun(runs, child.textContent.replaceAll("\n", ""), makeStyle(style))
            }
            return runs
        })
        this.lines = lines.length ? lines : [[]]
        this.selection = this.readSelection() ?? this.selection
        this.commit()
    }

    beforeInput(event) {
        if (event.isComposing || event.inputType === "insertCompositionText") {
            this.isDomDirty = true
            return
        }
        event.preventDefault()
        const flag = formatCommands[event.inputType]
        if (flag) {
            this.perform({ kind: "inline", flag })
            return
        }
        if (event.inputType === "historyUndo") {
            this.undo()
            return
        }
        if (event.inputType === "historyRedo") {
            this.redo()
            return
        }
        this.editKind = event.inputType === "insertText" ? "typing" : null
        const targets = event.getTargetRanges?.() ?? []
        let range = this.readSelection() ?? this.selection
        const isCharacterDelete = event.inputType === "deleteContentBackward" || event.inputType === "deleteContentForward"
        if (targets.length && event.inputType.startsWith("delete") && !(isCharacterDelete && range.start === range.end)) {
            const start = this.offsetFromDom(targets[0].startContainer, targets[0].startOffset)
            const end = this.offsetFromDom(targets[0].endContainer, targets[0].endOffset)
            range = { start: Math.min(start, end), end: Math.max(start, end) }
        }
        this.selection = range
        let text = event.data ?? event.dataTransfer?.getData("text/plain") ?? ""
        if (event.inputType === "insertParagraph" || event.inputType === "insertLineBreak") {
            text = "\n"
        }
        text = text.replaceAll("\r\n", "\n").replaceAll("\r", "\n")
        if (event.inputType.startsWith("delete") && range.start === range.end) {
            const content = this.text
            if (event.inputType.includes("Backward") && range.start > 0) {
                const isPair = /[\uDC00-\uDFFF]/.test(content[range.start - 1]) && range.start > 1
                range = { start: range.start - (isPair ? 2 : 1), end: range.end }
            } else if (event.inputType.includes("Forward") && range.end < content.length) {
                const isPair = /[\uD800-\uDBFF]/.test(content[range.end])
                range = { start: range.start, end: range.end + (isPair ? 2 : 1) }
            }
        }
        if (text === "\n" && range.start === range.end) {
            const language = this.inlineCodeLanguage(range.start)
            if (language) {
                this.openBlock(language, range.start, true)
                return
            }
        }
        if (text.length === 1 && text !== "\n") {
            const edit = codeTextEdit(this.text, range.start, range.end, text)
            if (edit) {
                this.replace(edit.start, edit.end, edit.replacement, makeStyle(), edit.caret)
                return
            }
        }
        const style = this.isPasting(event) ? makeStyle() : this.typingStyle
        this.replace(range.start, range.end, text, style)
    }

    isPasting(event) {
        return event.inputType === "insertFromPaste" || event.inputType === "insertFromDrop"
    }

    keyDown(event) {
        event.stopPropagation()
        if (event.key === "Escape") {
            this.onEscape?.()
            return
        }
        const key = event.key.toLowerCase()
        if ((event.ctrlKey || event.metaKey) && (key === "z" || key === "y")) {
            event.preventDefault()
            if (key === "y" || event.shiftKey) {
                this.redo()
            } else {
                this.undo()
            }
            return
        }
        const range = this.readSelection() ?? this.selection
        const edit = codeKeyEdit(this.text, range.start, range.end, event)
        if (edit) {
            event.preventDefault()
            this.replace(edit.start, edit.end, edit.replacement, makeStyle(), edit.caret)
            return
        }
        if (event.key === "Tab") {
            event.preventDefault()
        }
    }

    copy(event, isCut) {
        const range = this.readSelection() ?? this.selection
        if (range.start === range.end) {
            return
        }
        event.preventDefault()
        event.clipboardData.setData("text/plain", this.text.slice(range.start, range.end))
        if (isCut) {
            this.replace(range.start, range.end, "")
        }
    }

    inlineCodeLanguage(caret) {
        if (this.shapeAt(caret).kind === "code" || !this.typingStyle.isCode || !this.typingStyle.codeLanguage) {
            return null
        }
        const lineIndex = this.lineIndexAt(caret)
        const isAllCode = this.lines[lineIndex].every((run) => run.style.isCode || !/\S/.test(run.text))
        return isAllCode ? this.typingStyle.codeLanguage : null
    }

    openBlock(language, caret, isBreakingLine) {
        const lineIndex = this.lineIndexAt(caret)
        const lineStart = this.lineStarts()[lineIndex]
        const lineText = textOf(this.lines[lineIndex])
        const before = lineText.slice(0, caret - lineStart)
        let after = lineText.slice(caret - lineStart)
        let caretInLine = before.length
        let middle = ""
        if (isBreakingLine) {
            const edit = newlineEdit(before, after, language, indentUnit([before, after]))
            after = after.slice(edit.removedAfter)
            middle = edit.replacement
            caretInLine += edit.caret
        }
        const opening = "```" + language + "\n"
        const block = opening + before + middle + after + "\n```"
        this.replace(lineStart, lineStart + lineText.length, block, makeStyle(), lineStart + opening.length + caretInLine)
    }

    perform(command) {
        this.selection = this.readSelection() ?? this.selection
        switch (command.kind) {
        case "inline": this.toggle(command.flag); break
        case "line": this.setLines(command.lineKind); break
        case "code": this.setCode(command.language); break
        default: break
        }
        this.focus()
    }

    toggled(style, flag, isOn) {
        const result = { ...style, [flag]: isOn }
        if (isOn && flag === "isUnderlined") {
            result.isDashedUnderlined = false
        }
        if (isOn && flag === "isDashedUnderlined") {
            result.isUnderlined = false
        }
        if (flag === "isCode" && !isOn) {
            result.codeLanguage = null
        }
        return result
    }

    piecesIn(start, end) {
        return sliceRuns(flatten(this.lines), start, end).filter((run) => /[^\n]/.test(run.text))
    }

    toggle(flag) {
        const { start, end } = this.selection
        if (start === end) {
            this.typingStyle = this.toggled(this.typingStyle, flag, !this.typingStyle[flag])
            this.report()
            return
        }
        const isOn = !this.piecesIn(start, end).every((run) => run.style[flag])
        this.restyleRange(start, end, (style) => this.toggled(style, flag, isOn))
        this.selection = { start, end }
        this.restoreSelection()
        this.report()
    }

    touchedLines() {
        const texts = this.lines.map(textOf)
        const starts = this.lineStarts()
        const { start, end } = this.selection
        return texts.map((text, index) => index).filter((index) => starts[index] + texts[index].length >= start && starts[index] <= end)
    }

    applyEdits(edits, keeping) {
        let start = keeping.start
        let end = keeping.end
        for (const edit of [...edits].sort((first, second) => first.start - second.start)) {
            const delta = edit.replacement.length - (edit.end - edit.start)
            if (edit.end <= start) {
                start += delta
            } else if (edit.start < start) {
                start = edit.start + edit.replacement.length
            }
            if (edit.start === edit.end && edit.start === end && end > start) {
                continue
            }
            if (edit.end <= end) {
                end += delta
            } else if (edit.start < end) {
                end = edit.start + edit.replacement.length
            }
        }
        let runs = flatten(this.lines)
        for (const edit of [...edits].sort((first, second) => second.start - first.start)) {
            const next = []
            for (const run of [...sliceRuns(runs, 0, edit.start), { text: edit.replacement, style: makeStyle() }, ...sliceRuns(runs, edit.end, Infinity)]) {
                pushRun(next, run.text, run.style)
            }
            runs = next
        }
        this.lines = unflatten(runs)
        const length = this.text.length
        const location = Math.min(Math.max(0, start), length)
        this.selection = { start: location, end: Math.max(location, Math.min(end, length)) }
        this.commit()
        this.restoreSelection()
    }

    setLines(kind) {
        const texts = this.lines.map(textOf)
        const shapes = lineShapes(texts)
        const starts = this.lineStarts()
        const touched = this.touchedLines().filter((index) => !isVerbatim(shapes[index]))
        if (!touched.length) {
            return
        }
        const isRemoving = touched.every((index) => shapes[index].kind === kind)
        const edits = touched.map((index, number) => {
            let replacement = "- "
            if (isRemoving) {
                replacement = ""
            } else if (kind === "heading") {
                replacement = "# "
            } else if (kind === "numbered") {
                replacement = `${number + 1}. `
            }
            return { start: starts[index], end: starts[index] + prefixOf(texts[index], shapes[index]).length, replacement }
        })
        this.applyEdits(edits, this.selection)
    }

    fencedBlocks(texts) {
        const blocks = []
        let open = null
        texts.forEach((text, index) => {
            if (!isFence(text)) {
                return
            }
            if (open === null) {
                open = index
            } else {
                blocks.push({ open, close: index })
                open = null
            }
        })
        if (open !== null) {
            blocks.push({ open, close: null })
        }
        return blocks
    }

    setCode(language) {
        const texts = this.lines.map(textOf)
        const starts = this.lineStarts()
        const selection = this.selection
        const touched = this.touchedLines()
        const blocks = this.fencedBlocks(texts).filter((block) => touched.some((index) => index >= block.open && index <= (block.close ?? texts.length - 1)))
        const total = this.text.length
        if (blocks.length) {
            const edits = []
            for (const block of blocks) {
                if (language) {
                    edits.push({ start: starts[block.open], end: starts[block.open] + texts[block.open].length, replacement: "```" + language })
                    continue
                }
                for (const index of [block.open, block.close].filter((value) => value !== null)) {
                    const isLast = index === texts.length - 1
                    const location = isLast && index > 0 ? starts[index] - 1 : starts[index]
                    edits.push({ start: location, end: Math.min(location + texts[index].length + 1, total), replacement: "" })
                }
            }
            this.applyEdits(edits, selection)
            return
        }
        if (selection.start !== selection.end && this.text.slice(selection.start, selection.end).includes("\n") && language) {
            const first = touched[0]
            const last = touched[touched.length - 1]
            const lastEnd = starts[last] + texts[last].length
            this.applyEdits([{ start: starts[first], end: starts[first], replacement: "```" + language + "\n" }, { start: lastEnd, end: lastEnd, replacement: "\n```" }], { start: starts[first], end: lastEnd })
            return
        }
        let target = selection
        if (selection.start === selection.end) {
            const isInSpan = selection.start > 0 && this.styleAt(selection.start - 1).isCode
            const line = touched[0]
            if (!isInSpan) {
                if (language && line !== undefined && this.shapeAt(selection.start).kind !== "code" && !/\S/.test(texts[line])) {
                    this.openBlock(language, selection.start, false)
                    return
                }
                this.typingStyle = { ...this.typingStyle, isCode: Boolean(language), codeLanguage: language ?? null }
                this.report()
                return
            }
            const lineStart = starts[line]
            let low = selection.start - 1
            const spanStyle = this.styleAt(low)
            while (low > lineStart && sameStyle(this.styleAt(low - 1), spanStyle)) {
                low -= 1
            }
            let high = selection.start
            while (high < lineStart + texts[line].length && sameStyle(this.styleAt(high), spanStyle)) {
                high += 1
            }
            target = { start: low, end: high }
        }
        this.restyleRange(target.start, target.end, (style) => ({ ...style, isCode: Boolean(language), codeLanguage: language ?? null }))
        this.selection = selection
        this.restoreSelection()
        this.report()
    }

    report() {
        const { start, end } = this.selection
        const shape = this.shapeAt(start)
        const state = { style: makeStyle(), lineKind: shape.kind, codeLanguage: null }
        if (start !== end) {
            const pieces = this.piecesIn(start, end)
            const languages = new Set()
            for (const flag of inlineFlags) {
                state.style[flag] = pieces.length > 0 && pieces.every((run) => run.style[flag])
            }
            pieces.forEach((run) => languages.add(run.style.codeLanguage ?? null))
            if (state.style.isCode && languages.size === 1) {
                state.codeLanguage = [...languages][0]
            }
        } else {
            state.style = { ...this.typingStyle }
            state.codeLanguage = this.typingStyle.isCode ? this.typingStyle.codeLanguage ?? null : null
        }
        if (shape.kind === "code") {
            state.codeLanguage = shape.language
        }
        state.isPlainText = !state.style.isCode && state.lineKind !== "code"
        const key = JSON.stringify(state)
        if (key === this.reported) {
            return
        }
        this.reported = key
        this.onStyleState?.(state)
    }

    runFontFamily(style, isInCodeBlock) {
        return style.isCode || isInCodeBlock || this.look.writingFont === "Space Mono" ? monoFamily : fontFamily(this.look.writingFont)
    }

    render() {
        this.isRendering = true
        const { zoom, color, paperStyle } = this.look
        const syntax = syntaxColors(paperStyle)
        const texts = this.lines.map(textOf)
        const shapes = lineShapes(texts)
        const blockTokens = texts.map(() => null)
        let start = 0
        while (start < texts.length) {
            const language = shapes[start].kind === "code" && !isFence(texts[start]) ? shapes[start].language : null
            if (!language) {
                start += 1
                continue
            }
            let end = start
            while (end < texts.length && shapes[end].kind === "code" && !isFence(texts[end]) && shapes[end].language === language) {
                end += 1
            }
            lineSyntaxTokens(texts.slice(start, end), language).forEach((lineTokens, index) => {
                blockTokens[start + index] = lineTokens
            })
            start = end
        }
        const fontSize = rhythmFontSize()
        const lift = tokens.text.baseline_lift
        const monoAscent = fontAscent(monoFamily, 400, false).ascent
        const fragment = document.createDocumentFragment()
        this.lines.forEach((runs, index) => {
            const shape = shapes[index]
            const text = texts[index]
            const scale = shapeScale(shape)
            const rows = rowsFor(scale)
            const lineHeight = rowGap() * rows * zoom
            const sizePixels = fontSize * scale * zoom
            const isCodeBlock = shape.kind === "code" && !isFence(text)
            const lineElement = document.createElement("div")
            lineElement.className = "text-editor-line"
            lineElement.spellcheck = shape.kind !== "code"
            lineElement.style.lineHeight = `${lineHeight}px`
            lineElement.style.minHeight = `${lineHeight}px`
            lineElement.style.fontSize = `${sizePixels}px`
            if (isCodeBlock) {
                lineElement.style.background = syntax.background
            }
            const prefixLength = isVerbatim(shape) ? (isFence(text) || shape.kind === "rule" ? text.length : 0) : prefixOf(text, shape).length
            const target = (monoAscent * fontSize - lift + rowGap() * (rows - 1)) * zoom
            let position = 0
            const pieces = []
            for (const run of runs) {
                const runEnd = position + run.text.length
                if (position < prefixLength && runEnd > prefixLength) {
                    pieces.push({ text: run.text.slice(0, prefixLength - position), style: run.style, start: position, isPrefix: true })
                    pieces.push({ text: run.text.slice(prefixLength - position), style: run.style, start: prefixLength, isPrefix: false })
                } else {
                    pieces.push({ text: run.text, style: run.style, start: position, isPrefix: position < prefixLength })
                }
                position = runEnd
            }
            for (const piece of pieces) {
                const tokensHere = isCodeBlock && blockTokens[index]
                    ? blockTokens[index].filter((token) => token.end > piece.start && token.start < piece.start + piece.text.length).map((token) => ({ start: Math.max(0, token.start - piece.start), end: Math.min(piece.text.length, token.end - piece.start), kind: token.kind }))
                    : !piece.isPrefix && !isVerbatim(shape) && piece.style.isCode && piece.style.codeLanguage ? syntaxTokens(piece.text, piece.style.codeLanguage) : []
                let cursor = 0
                const parts = []
                for (const token of tokensHere) {
                    if (token.start > cursor) {
                        parts.push({ text: piece.text.slice(cursor, token.start), kind: null })
                    }
                    parts.push({ text: piece.text.slice(token.start, token.end), kind: token.kind })
                    cursor = token.end
                }
                if (cursor < piece.text.length) {
                    parts.push({ text: piece.text.slice(cursor), kind: null })
                }
                for (const part of parts) {
                    lineElement.append(this.span(part.text, piece.style, part.kind, { shape, isPrefix: piece.isPrefix, isCodeBlock, sizePixels, target, lineHeight, color, syntax }))
                }
            }
            if (!lineElement.childNodes.length) {
                lineElement.append(document.createElement("br"))
            }
            fragment.append(lineElement)
        })
        this.element.replaceChildren(fragment)
        this.element.style.color = color
        this.restoreSelection()
        this.isRendering = false
    }

    span(text, style, syntaxKind, { shape, isPrefix, isCodeBlock, sizePixels, target, lineHeight, color, syntax }) {
        const look = { ...style }
        if (isPrefix) {
            Object.assign(look, makeStyle({ isBold: shape.kind === "heading" }))
        } else if (isVerbatim(shape)) {
            Object.assign(look, makeStyle({ isCode: shape.kind === "code" }))
        } else {
            look.isBold = look.isBold || shape.kind === "heading"
            look.isItalic = look.isItalic || shape.kind === "quote"
        }
        const element = document.createElement("span")
        element.textContent = text
        element.dataset.style = JSON.stringify(isPrefix || isVerbatim(shape) ? makeStyle() : style)
        const family = this.runFontFamily(look, isCodeBlock)
        const weight = look.isBold ? 700 : 400
        element.style.fontFamily = family
        element.style.fontWeight = String(weight)
        element.style.fontStyle = look.isItalic ? "italic" : "normal"
        const metrics = fontAscent(family, weight, look.isItalic)
        const natural = (lineHeight - (metrics.ascent + metrics.descent) * sizePixels) / 2 + metrics.ascent * sizePixels
        element.style.position = "relative"
        element.style.top = `${target - natural}px`
        const isDimmed = isPrefix || shape.kind === "rule"
        element.style.color = syntaxKind ? syntax[syntaxKind] : isDimmed ? withAlpha(color, prefixShade) : color
        const decorations = []
        if (look.isStruck) {
            decorations.push("line-through")
        }
        if (look.isDashedUnderlined || look.isUnderlined || look.isLink) {
            decorations.push("underline")
        }
        element.style.textDecorationLine = decorations.join(" ") || "none"
        element.style.textDecorationStyle = look.isDashedUnderlined ? "dashed" : "solid"
        if (look.isCode && !isCodeBlock && !isVerbatim(shape)) {
            element.style.background = syntax.background
            element.spellcheck = false
        }
        return element
    }
}
