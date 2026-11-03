import { codeLanguage } from "./syntaxHighlighter.js"

export const headingScales = [2, 1.5, 1]
export const underlineTag = "<u>"
export const dashedUnderlineTag = "<u class=\"dashed\">"
export const underlineCloseTag = "</u>"
export const escapable = new Set(["\\", "`", "*", "_", "~", "[", "]", "(", ")", "#", "+", "-", ".", "!", ">", "<", "{"])
const indentPerLevel = 2

export const plainStyle = Object.freeze({
    isBold: false,
    isItalic: false,
    isCode: false,
    isStruck: false,
    isLink: false,
    isUnderlined: false,
    isDashedUnderlined: false,
    linkTarget: null,
    codeLanguage: null,
})

const emphasisMarkers = [
    { marker: "**", flag: "isBold" },
    { marker: "__", flag: "isBold" },
    { marker: "~~", flag: "isStruck" },
    { marker: "*", flag: "isItalic" },
    { marker: "_", flag: "isItalic" },
]

export function makeStyle(changes = {}) {
    return { ...plainStyle, ...changes }
}

export function sameStyle(first, second) {
    return Object.keys(plainStyle).every((key) => (first[key] ?? plainStyle[key]) === (second[key] ?? plainStyle[key]))
}

export function pushRun(runs, text, style) {
    if (!text) {
        return
    }
    const last = runs[runs.length - 1]
    if (last && sameStyle(last.style, style)) {
        last.text += text
    } else {
        runs.push({ text, style: { ...style } })
    }
}

function isWordCharacter(character) {
    return Boolean(character) && /[\p{L}\p{N}]/u.test(character)
}

function isSpace(character) {
    return character === undefined || /\s/.test(character)
}

function startsAt(characters, index, marker) {
    if (index + marker.length > characters.length) {
        return false
    }
    for (let offset = 0; offset < marker.length; offset += 1) {
        if (characters[index + offset] !== marker[offset]) {
            return false
        }
    }
    return true
}

function containsFrom(characters, marker, index) {
    for (let position = index; position + marker.length <= characters.length; position += 1) {
        if (startsAt(characters, position, marker)) {
            return true
        }
    }
    return false
}

function indexOfFrom(characters, character, index) {
    for (let position = index; position < characters.length; position += 1) {
        if (characters[position] === character) {
            return position
        }
    }
    return -1
}

function linkAt(characters, index) {
    const close = indexOfFrom(characters, "]", index + 1)
    if (characters[index] !== "[" || close <= index + 1) {
        return null
    }
    const open = close + 1
    const end = indexOfFrom(characters, ")", open + 1)
    if (characters[open] !== "(" || end <= open + 1) {
        return null
    }
    const target = characters.slice(open + 1, end)
    if (target.some((character) => /\s/.test(character))) {
        return null
    }
    return { label: characters.slice(index + 1, close).join(""), target: target.join(""), length: end - index + 1 }
}

export function languageAttribute(characters, index) {
    if (characters[index] !== "{" || characters[index + 1] !== ".") {
        return null
    }
    const close = indexOfFrom(characters, "}", index + 2)
    if (close < 0) {
        return null
    }
    const language = codeLanguage(characters.slice(index + 2, close).join(""))
    return language ? { language, length: close - index + 1 } : null
}

export function fenceLanguage(line) {
    const characters = Array.from(line)
    let start = 0
    while (characters[start] === " " || characters[start] === "\t") {
        start += 1
    }
    return codeLanguage(characters.slice(start + 3).join(""))
}

export function inlineRuns(text, base = plainStyle) {
    const characters = Array.from(text)
    const runs = []
    const style = { ...base }
    const closers = {}
    const underlines = []
    const underlineOpeners = [{ tag: Array.from(dashedUnderlineTag), flag: "isDashedUnderlined" }, { tag: Array.from(underlineTag), flag: "isUnderlined" }]
    const underlineCloser = Array.from(underlineCloseTag)
    let buffer = ""
    let index = 0
    const flush = () => {
        pushRun(runs, buffer, style)
        buffer = ""
    }
    while (index < characters.length) {
        const character = characters[index]
        if (character === "\\" && index + 1 < characters.length && escapable.has(characters[index + 1])) {
            buffer += characters[index + 1]
            index += 2
            continue
        }
        if (character === "`") {
            const closing = indexOfFrom(characters, "`", index + 1)
            if (closing > index + 1) {
                flush()
                const code = { ...style, isCode: true }
                const codeText = characters.slice(index + 1, closing).join("")
                index = closing + 1
                const attribute = languageAttribute(characters, index)
                if (attribute) {
                    code.codeLanguage = attribute.language
                    index += attribute.length
                }
                pushRun(runs, codeText, code)
                continue
            }
        }
        if (character === "[") {
            const found = linkAt(characters, index)
            if (found) {
                flush()
                for (const run of inlineRuns(found.label, { ...style, isLink: true, linkTarget: found.target })) {
                    pushRun(runs, run.text, run.style)
                }
                index += found.length
                continue
            }
        }
        if (character === "<") {
            const flag = underlines[underlines.length - 1]
            if (flag && startsAt(characters, index, underlineCloser)) {
                flush()
                style[flag] = false
                underlines.pop()
                index += underlineCloser.length
                continue
            }
            const opener = underlineOpeners.find((candidate) => !style[candidate.flag] && startsAt(characters, index, candidate.tag) && containsFrom(characters, underlineCloser, index + candidate.tag.length))
            if (opener) {
                flush()
                style[opener.flag] = true
                underlines.push(opener.flag)
                index += opener.tag.length
                continue
            }
        }
        const matches = emphasisMarkers.filter(({ marker }) => startsAt(characters, index, Array.from(marker)))
        const before = index > 0 ? characters[index - 1] : undefined
        const following = (marker) => characters[index + marker.length]
        const closing = matches.find(({ marker, flag }) => style[flag] && closers[flag] === marker && !isSpace(before) && !(marker[0] === "_" && isWordCharacter(following(marker))))
        if (closing) {
            flush()
            style[closing.flag] = false
            closers[closing.flag] = null
            index += closing.marker.length
            continue
        }
        const emphasis = matches[0]
        if (emphasis) {
            const { marker, flag } = emphasis
            const after = following(marker)
            const isUnderscore = marker[0] === "_"
            if (!style[flag] && containsFrom(characters, Array.from(marker), index + marker.length) && !isSpace(after) && !(isUnderscore && isWordCharacter(before))) {
                flush()
                style[flag] = true
                closers[flag] = marker
                index += marker.length
                continue
            }
        }
        buffer += character
        index += 1
    }
    flush()
    return runs
}

export function leadingSpaces(characters) {
    let count = 0
    while (characters[count] === " " || characters[count] === "\t") {
        count += 1
    }
    return count
}

export function headingLevel(characters) {
    let hashes = 0
    while (characters[hashes] === "#") {
        hashes += 1
    }
    return hashes >= 1 && hashes <= 6 && hashes < characters.length && /\s/.test(characters[hashes]) ? hashes : null
}

export function isRule(characters) {
    const marks = characters.filter((character) => !/\s/.test(character))
    return marks.length >= 3 && "-*_".includes(marks[0]) && marks.every((character) => character === marks[0])
}

export function listMarker(characters, start) {
    return start + 1 < characters.length && "-*+".includes(characters[start]) && /\s/.test(characters[start + 1]) ? start + 1 : null
}

export function skippingSpaces(characters, index) {
    let position = index
    while (position < characters.length && /\s/.test(characters[position])) {
        position += 1
    }
    return position
}

function trimmedStart(characters, index) {
    return characters.slice(skippingSpaces(characters, index)).join("")
}

export function isTaskBox(rest) {
    return rest.length >= 3 && rest[0] === "[" && rest[2] === "]" && " xX".includes(rest[1]) && (rest.length === 3 || /\s/.test(rest[3]))
}

export function markdownBlocks(content) {
    const blocks = []
    let isInFence = false
    let fence = null
    for (const text of content.split("\n")) {
        const line = Array.from(text)
        const indent = leadingSpaces(line)
        const level = Math.floor(indent / indentPerLevel) + 1
        if (line.slice(indent).join("").startsWith("```")) {
            isInFence = !isInFence
            fence = isInFence ? fenceLanguage(text) : null
            continue
        }
        if (isInFence) {
            blocks.push({ kind: "code", scale: 1, indent: 0, marker: null, isChecked: false, runs: [{ text, style: makeStyle({ isCode: true, codeLanguage: fence }) }], language: fence })
            continue
        }
        const hashes = headingLevel(line)
        if (hashes) {
            const scale = headingScales[Math.min(hashes, headingScales.length) - 1]
            blocks.push({ kind: "heading", scale, indent: 0, marker: null, isChecked: false, runs: inlineRuns(trimmedStart(line, hashes), makeStyle({ isBold: true })) })
            continue
        }
        if (isRule(line)) {
            blocks.push({ kind: "rule", scale: 1, indent: 0, marker: null, isChecked: false, runs: [] })
            continue
        }
        const afterMarker = listMarker(line, indent)
        if (afterMarker !== null) {
            const rest = Array.from(trimmedStart(line, afterMarker))
            if (isTaskBox(rest)) {
                const isChecked = rest[1] !== " "
                blocks.push({ kind: "task", scale: 1, indent: level, marker: isChecked ? "☑" : "☐", isChecked, runs: inlineRuns(trimmedStart(rest, 3)) })
            } else {
                blocks.push({ kind: "bullet", scale: 1, indent: level, marker: "•", isChecked: false, runs: inlineRuns(rest.join("")) })
            }
            continue
        }
        let digits = 0
        while (/\d/.test(line[indent + digits] ?? "")) {
            digits += 1
        }
        const separator = indent + digits
        if (digits > 0 && separator + 1 < line.length && ".)".includes(line[separator]) && /\s/.test(line[separator + 1])) {
            blocks.push({ kind: "numbered", scale: 1, indent: level, marker: line.slice(indent, separator + 1).join(""), isChecked: false, runs: inlineRuns(trimmedStart(line, separator + 1)) })
            continue
        }
        if (line[0] === ">") {
            const rest = line.length > 1 && line[1] === " " ? line.slice(2).join("") : line.slice(1).join("")
            blocks.push({ kind: "quote", scale: 1, indent: 1, marker: null, isChecked: false, runs: inlineRuns(rest, makeStyle({ isItalic: true })) })
            continue
        }
        blocks.push({ kind: "paragraph", scale: 1, indent: 0, marker: null, isChecked: false, runs: inlineRuns(text) })
    }
    return blocks
}
