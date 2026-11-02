const defaultUnit = 4
const pairs = { "{": "}", "(": ")", "[": "]" }
const closers = new Set(["}", ")", "]"])
const pythonExits = new Set(["return", "pass", "break", "continue", "raise"])

const grammars = {
    javascript: { lineComment: "//", blockComment: ["/*", "*/"], quotes: ["`", "\"", "'"] },
    csharp: { lineComment: "//", blockComment: ["/*", "*/"], quotes: ["\"\"\"", "\"", "'"] },
    java: { lineComment: "//", blockComment: ["/*", "*/"], quotes: ["\"\"\"", "\"", "'"] },
    python: { lineComment: "#", blockComment: null, quotes: ["\"\"\"", "'''", "\"", "'"] },
}

const languageNames = {
    javascript: "javascript", js: "javascript", jsx: "javascript", mjs: "javascript",
    csharp: "csharp", cs: "csharp", "c#": "csharp",
    java: "java",
    python: "python", py: "python",
}

const fencePattern = /^\s*```/

function language(identifier) {
    return languageNames[identifier.trim().toLowerCase()] ?? null
}

function isBlank(text) {
    return /^[ \t]+$/.test(text)
}

export function indentUnit(lines) {
    const widths = lines
        .filter((line) => /\S/.test(line))
        .map((line) => /^ */.exec(line)[0].length)
        .filter((width) => width > 0)
    if (widths.length === 0) {
        return defaultUnit
    }
    return Math.min(Math.max(Math.min(...widths), 2), 8)
}

function leading(line) {
    return /^[ \t]*/.exec(line)[0]
}

function dedented(indent, unit) {
    if (indent.endsWith("\t")) {
        return indent.slice(0, -1)
    }
    const spaces = / *$/.exec(indent)[0].length
    if (spaces === 0) {
        return indent
    }
    const target = Math.floor((spaces - 1) / unit) * unit
    return indent.slice(0, indent.length - (spaces - target))
}

function significant(text, languageName) {
    const grammar = grammars[languageName]
    if (!grammar) {
        return text
    }
    let result = ""
    let position = 0
    while (position < text.length) {
        if (text.startsWith(grammar.lineComment, position)) {
            break
        }
        if (grammar.blockComment && text.startsWith(grammar.blockComment[0], position)) {
            const end = text.indexOf(grammar.blockComment[1], position + grammar.blockComment[0].length)
            position = end < 0 ? text.length : end + grammar.blockComment[1].length
            continue
        }
        const quote = grammar.quotes.find((candidate) => text.startsWith(candidate, position))
        if (quote) {
            let end = position + quote.length
            while (end < text.length && !text.startsWith(quote, end)) {
                end += text[end] === "\\" ? 2 : 1
            }
            position = Math.min(text.length, end + quote.length)
            continue
        }
        result += text[position]
        position += 1
    }
    return result
}

function unclosedOpener(code) {
    const stack = []
    for (const character of code) {
        if (pairs[character]) {
            stack.push(character)
        } else if (closers.has(character) && pairs[stack[stack.length - 1]] === character) {
            stack.pop()
        }
    }
    return stack[stack.length - 1] ?? null
}

export function newlineEdit(before, after, languageName, unit) {
    const indent = leading(before)
    const code = significant(before, languageName)
    const trimmed = code.trim()
    const opener = unclosedOpener(code)
    const rest = after.replace(/^[ \t]*/, "")
    const removedAfter = after.length - rest.length
    if (opener || (languageName === "python" && trimmed.endsWith(":"))) {
        const inner = indent + " ".repeat(unit)
        if (opener && rest[0] === pairs[opener]) {
            const replacement = `\n${inner}\n${indent}`
            return { replacement, removedBefore: 0, removedAfter, caret: 1 + inner.length }
        }
        return { replacement: `\n${inner}`, removedBefore: 0, removedAfter, caret: 1 + inner.length }
    }
    const firstWord = /^[A-Za-z]*/.exec(trimmed)[0]
    const nextIndent = languageName === "python" && pythonExits.has(firstWord) ? dedented(indent, unit) : indent
    return { replacement: `\n${nextIndent}`, removedBefore: 0, removedAfter, caret: 1 + nextIndent.length }
}

export function closingEdit(before, character, unit) {
    if (!closers.has(character) || !isBlank(before)) {
        return null
    }
    const replacement = dedented(before, unit) + character
    return { replacement, removedBefore: before.length, removedAfter: 0, caret: replacement.length }
}

export function backspaceEdit(before, unit) {
    if (!/^ +$/.test(before)) {
        return null
    }
    const target = Math.floor((before.length - 1) / unit) * unit
    return { replacement: "", removedBefore: before.length - target, removedAfter: 0, caret: 0 }
}

export function tabEdit(before, unit) {
    const replacement = " ".repeat(unit - (before.length % unit))
    return { replacement, removedBefore: 0, removedAfter: 0, caret: replacement.length }
}

function codeLine(lines, index) {
    let fence = null
    for (let position = 0; position < index; position += 1) {
        if (fencePattern.test(lines[position])) {
            fence = fence === null ? position : null
        }
    }
    if (fence === null || fencePattern.test(lines[index])) {
        return null
    }
    let last = index
    while (last + 1 < lines.length && !fencePattern.test(lines[last + 1])) {
        last += 1
    }
    return {
        language: language(lines[fence].trim().slice(3)),
        unit: indentUnit(lines.slice(fence + 1, last + 1)),
    }
}

function codeContext(value, selectionStart, selectionEnd) {
    const lines = value.split("\n")
    const lineIndex = value.slice(0, selectionStart).split("\n").length - 1
    const lineStart = value.lastIndexOf("\n", selectionStart - 1) + 1
    const lineEnd = lineStart + lines[lineIndex].length
    if (selectionEnd > lineEnd) {
        return null
    }
    const block = codeLine(lines, lineIndex)
    if (!block) {
        return null
    }
    return { ...block, before: value.slice(lineStart, selectionStart), after: value.slice(selectionEnd, lineEnd) }
}

function placed(edit, selectionStart, selectionEnd) {
    if (!edit) {
        return null
    }
    const start = selectionStart - edit.removedBefore
    return { start, end: selectionEnd + edit.removedAfter, replacement: edit.replacement, caret: start + edit.caret }
}

export function codeKeyEdit(value, selectionStart, selectionEnd, event) {
    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey || event.isComposing) {
        return null
    }
    const isBackspace = event.key === "Backspace"
    if (!["Enter", "Tab", "Backspace"].includes(event.key) || (isBackspace && selectionStart !== selectionEnd)) {
        return null
    }
    const context = codeContext(value, selectionStart, selectionEnd)
    if (!context) {
        return null
    }
    if (event.key === "Enter") {
        return placed(newlineEdit(context.before, context.after, context.language, context.unit), selectionStart, selectionEnd)
    }
    if (event.key === "Tab") {
        return placed(tabEdit(context.before, context.unit), selectionStart, selectionEnd)
    }
    return placed(backspaceEdit(context.before, context.unit), selectionStart, selectionEnd)
}

export function codeTextEdit(value, selectionStart, selectionEnd, text) {
    if (selectionStart !== selectionEnd || !closers.has(text)) {
        return null
    }
    const context = codeContext(value, selectionStart, selectionEnd)
    return context ? placed(closingEdit(context.before, text, context.unit), selectionStart, selectionEnd) : null
}

export function applyCodeEdit(textarea, edit) {
    textarea.setSelectionRange(edit.start, edit.end)
    const isApplied = edit.replacement
        ? document.execCommand("insertText", false, edit.replacement)
        : document.execCommand("delete", false)
    if (!isApplied) {
        textarea.setRangeText(edit.replacement, edit.start, edit.end, "end")
        textarea.dispatchEvent(new Event("input", { bubbles: true }))
    }
    textarea.setSelectionRange(edit.caret, edit.caret)
}
