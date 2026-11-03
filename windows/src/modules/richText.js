import {
    dashedUnderlineTag,
    escapable,
    fenceLanguage,
    headingLevel,
    headingScales,
    inlineRuns,
    isRule,
    isTaskBox,
    leadingSpaces,
    listMarker,
    makeStyle,
    pushRun,
    sameStyle,
    skippingSpaces,
    underlineCloseTag,
    underlineTag,
} from "./markdown.js"

const fullEscapes = new Set(["\\", "`", "*", "_", "~", "[", "<", "{"])
const trimmedMarks = [["isStruck", "strike"], ["isBold", "bold"], ["isItalic", "italic"]]

const markText = {
    underline: [underlineTag, underlineCloseTag],
    dashedUnderline: [dashedUnderlineTag, underlineCloseTag],
    strike: ["~~", "~~"],
    bold: ["**", "**"],
    italic: ["*", "*"],
}

function opening(mark) {
    return mark.startsWith("link:") ? "[" : markText[mark][0]
}

function closing(mark) {
    return mark.startsWith("link:") ? `](${mark.slice("link:".length)})` : markText[mark][1]
}

export function isFence(text) {
    return text.trim().startsWith("```")
}

export function isVerbatim(shape) {
    return shape.kind === "code" || shape.kind === "rule"
}

export function shapeScale(shape) {
    return shape.kind === "heading" ? headingScales[Math.min(shape.headingLevel, headingScales.length) - 1] : 1
}

export function lineShapes(lines) {
    let isInFence = false
    let fence = null
    return lines.map((text) => {
        const line = Array.from(text)
        const indent = leadingSpaces(line)
        if (line.slice(indent).join("").startsWith("```")) {
            isInFence = !isInFence
            const language = isInFence ? fenceLanguage(text) : fence
            fence = isInFence ? language : null
            return { kind: "code", prefixLength: line.length, headingLevel: 0, language }
        }
        if (isInFence) {
            return { kind: "code", prefixLength: line.length, headingLevel: 0, language: fence }
        }
        const hashes = headingLevel(line)
        if (hashes) {
            return { kind: "heading", prefixLength: skippingSpaces(line, hashes), headingLevel: hashes, language: null }
        }
        if (isRule(line)) {
            return { kind: "rule", prefixLength: line.length, headingLevel: 0, language: null }
        }
        const afterMarker = listMarker(line, indent)
        if (afterMarker !== null) {
            const start = skippingSpaces(line, afterMarker)
            if (isTaskBox(line.slice(start))) {
                return { kind: "task", prefixLength: skippingSpaces(line, start + 3), headingLevel: 0, language: null }
            }
            return { kind: "bullet", prefixLength: start, headingLevel: 0, language: null }
        }
        let digits = 0
        while (/\d/.test(line[indent + digits] ?? "")) {
            digits += 1
        }
        const separator = indent + digits
        if (digits > 0 && separator + 1 < line.length && ".)".includes(line[separator]) && /\s/.test(line[separator + 1])) {
            return { kind: "numbered", prefixLength: skippingSpaces(line, separator + 1), headingLevel: 0, language: null }
        }
        if (line[0] === ">") {
            return { kind: "quote", prefixLength: line.length > 1 && line[1] === " " ? 2 : 1, headingLevel: 0, language: null }
        }
        return { kind: "paragraph", prefixLength: 0, headingLevel: 0, language: null }
    })
}

export function prefixOf(text, shape) {
    return Array.from(text).slice(0, shape.prefixLength).join("")
}

export function richLines(markdown) {
    const texts = markdown.split("\n")
    const shapes = lineShapes(texts)
    return texts.map((text, index) => {
        const shape = shapes[index]
        if (isVerbatim(shape)) {
            return text ? [{ text, style: makeStyle() }] : []
        }
        const characters = Array.from(text)
        const runs = []
        pushRun(runs, characters.slice(0, shape.prefixLength).join(""), makeStyle())
        for (const run of inlineRuns(characters.slice(shape.prefixLength).join(""))) {
            pushRun(runs, run.text, run.style)
        }
        return runs
    })
}

export function richMarkdown(lines) {
    const texts = lines.map((runs) => runs.map((run) => run.text).join(""))
    const shapes = lineShapes(texts)
    return lines.map((runs, index) => {
        const shape = shapes[index]
        if (isVerbatim(shape)) {
            return texts[index]
        }
        return prefixOf(texts[index], shape) + inlineMarkdown(dropping(shape.prefixLength, runs))
    }).join("\n")
}

function sameRuns(first, second) {
    return first.length === second.length && first.every((run, index) => run.text === second[index].text && sameStyle(run.style, second[index].style))
}

export function inlineMarkdown(runs) {
    const normal = normalizedRuns(runs)
    const minimal = serialized(normal, new Set())
    if (sameRuns(inlineRuns(minimal), normal)) {
        return minimal
    }
    return serialized(normal, fullEscapes)
}

function marksOf(style) {
    const marks = []
    if (style.isLink && style.linkTarget) {
        marks.push(`link:${style.linkTarget}`)
    }
    if (style.isDashedUnderlined) {
        marks.push("dashedUnderline")
    } else if (style.isUnderlined) {
        marks.push("underline")
    }
    if (style.isStruck) {
        marks.push("strike")
    }
    if (style.isBold) {
        marks.push("bold")
    }
    if (style.isItalic) {
        marks.push("italic")
    }
    return marks
}

export function normalizedRuns(runs) {
    const characters = runs.flatMap((run) => Array.from(run.text).map((character) => ({ character, style: { ...makeStyle(), ...run.style } })))
    for (const item of characters) {
        if (!item.style.isLink || !item.style.linkTarget) {
            item.style.isLink = false
            item.style.linkTarget = null
        }
        if (!item.style.isCode) {
            item.style.codeLanguage = null
        }
        if (item.style.isDashedUnderlined) {
            item.style.isUnderlined = false
        }
    }
    for (const [flag, mark] of trimmedMarks) {
        const outerMarks = (index) => {
            const present = marksOf(characters[index].style)
            const position = present.indexOf(mark)
            return position < 0 ? null : present.slice(0, position).join("|")
        }
        let start = 0
        while (start < characters.length) {
            const outer = outerMarks(start)
            if (outer === null) {
                start += 1
                continue
            }
            let end = start
            while (end < characters.length && outerMarks(end) === outer) {
                end += 1
            }
            let low = start
            while (low < end && /\s/.test(characters[low].character)) {
                characters[low].style[flag] = false
                low += 1
            }
            let high = end - 1
            while (high >= low && /\s/.test(characters[high].character)) {
                characters[high].style[flag] = false
                high -= 1
            }
            start = end
        }
    }
    const result = []
    for (const item of characters) {
        pushRun(result, item.character, item.style)
    }
    return result
}

function serialized(runs, escapes) {
    let output = ""
    let open = []
    for (const run of runs) {
        const wanted = marksOf(run.style)
        let kept = 0
        while (kept < open.length && kept < wanted.length && open[kept] === wanted[kept]) {
            kept += 1
        }
        for (const mark of open.slice(kept).reverse()) {
            output += closing(mark)
        }
        for (const mark of wanted.slice(kept)) {
            output += opening(mark)
        }
        open = wanted
        output += run.style.isCode ? codeText(run.text, run.style.codeLanguage) : escaped(run.text, escapes)
    }
    for (const mark of [...open].reverse()) {
        output += closing(mark)
    }
    return output
}

function codeText(text, language) {
    const attribute = language ? `{.${language}}` : ""
    return text.split("`").map((piece) => (piece ? `\`${piece}\`${attribute}` : "")).join("\\`")
}

function escaped(text, escapes) {
    const characters = Array.from(text)
    let output = ""
    characters.forEach((character, index) => {
        const next = characters[index + 1]
        if (character === "\\") {
            if (escapes.has(character) || next === undefined || escapable.has(next)) {
                output += "\\"
            }
        } else if (escapes.has(character)) {
            output += "\\"
        }
        output += character
    })
    return output
}

function dropping(count, runs) {
    let remaining = count
    const result = []
    for (const run of runs) {
        const characters = Array.from(run.text)
        if (remaining >= characters.length) {
            remaining -= characters.length
            continue
        }
        result.push({ text: characters.slice(remaining).join(""), style: run.style })
        remaining = 0
    }
    return result
}
