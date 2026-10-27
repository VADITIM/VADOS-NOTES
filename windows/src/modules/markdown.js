const headingScales = [1.6, 1.35, 1.15]
const indentPerLevel = 2
const plainStyle = { isBold: false, isItalic: false, isCode: false, isStruck: false, isLink: false }

const emphasisMarkers = [
    { marker: "**", flag: "isBold" },
    { marker: "__", flag: "isBold" },
    { marker: "~~", flag: "isStruck" },
    { marker: "*", flag: "isItalic" },
    { marker: "_", flag: "isItalic" },
]

function sameStyle(first, second) {
    return Object.keys(plainStyle).every((key) => first[key] === second[key])
}

function pushRun(runs, text, style) {
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

export function inlineRuns(text, baseStyle = plainStyle) {
    const runs = []
    const style = { ...baseStyle }
    const closers = {}
    let buffer = ""
    let index = 0
    const flush = () => {
        pushRun(runs, buffer, style)
        buffer = ""
    }
    while (index < text.length) {
        const character = text[index]
        if (character === "\\" && index + 1 < text.length && /[\\`*_~[\]()#+\-.!>]/.test(text[index + 1])) {
            buffer += text[index + 1]
            index += 2
            continue
        }
        if (character === "`") {
            const closing = text.indexOf("`", index + 1)
            if (closing > index + 1) {
                flush()
                pushRun(runs, text.slice(index + 1, closing), { ...style, isCode: true })
                index = closing + 1
                continue
            }
        }
        if (character === "[") {
            const link = /^\[([^\]]+)\]\(([^)\s]+)\)/.exec(text.slice(index))
            if (link) {
                flush()
                for (const run of inlineRuns(link[1], { ...style, isLink: true })) {
                    pushRun(runs, run.text, run.style)
                }
                index += link[0].length
                continue
            }
        }
        const emphasis = emphasisMarkers.find(({ marker }) => text.startsWith(marker, index))
        if (emphasis) {
            const { marker, flag } = emphasis
            const before = text[index - 1]
            const after = text[index + marker.length]
            const isUnderscore = marker[0] === "_"
            if (style[flag] && closers[flag] === marker && !/\s/.test(before ?? " ") && !(isUnderscore && isWordCharacter(after))) {
                flush()
                style[flag] = false
                closers[flag] = null
                index += marker.length
                continue
            }
            const remainder = text.slice(index + marker.length)
            const hasClosing = remainder.includes(marker)
            if (!style[flag] && hasClosing && after && !/\s/.test(after) && !(isUnderscore && isWordCharacter(before))) {
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

export function markdownBlocks(content) {
    const blocks = []
    let isInFence = false
    for (const line of content.split("\n")) {
        if (/^\s*```/.test(line)) {
            isInFence = !isInFence
            blocks.push({ kind: "fence", runs: [] })
            continue
        }
        if (isInFence) {
            blocks.push({ kind: "code", scale: 1, indent: 0, runs: [{ text: line, style: { ...plainStyle, isCode: true } }] })
            continue
        }
        const heading = /^(#{1,6})\s+(.*)$/.exec(line)
        if (heading) {
            const level = Math.min(heading[1].length, headingScales.length)
            blocks.push({ kind: "heading", scale: headingScales[level - 1], indent: 0, runs: inlineRuns(heading[2], { ...plainStyle, isBold: true }) })
            continue
        }
        if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
            blocks.push({ kind: "rule", scale: 1, indent: 0, runs: [] })
            continue
        }
        const task = /^(\s*)[-*+]\s+\[( |x|X)\]\s+(.*)$/.exec(line)
        if (task) {
            blocks.push({ kind: "task", scale: 1, indent: Math.floor(task[1].length / indentPerLevel) + 1, isChecked: task[2] !== " ", marker: task[2] === " " ? "☐" : "☑", runs: inlineRuns(task[3]) })
            continue
        }
        const bullet = /^(\s*)[-*+]\s+(.*)$/.exec(line)
        if (bullet) {
            blocks.push({ kind: "bullet", scale: 1, indent: Math.floor(bullet[1].length / indentPerLevel) + 1, marker: "•", runs: inlineRuns(bullet[2]) })
            continue
        }
        const numbered = /^(\s*)(\d+)([.)])\s+(.*)$/.exec(line)
        if (numbered) {
            blocks.push({ kind: "numbered", scale: 1, indent: Math.floor(numbered[1].length / indentPerLevel) + 1, marker: `${numbered[2]}${numbered[3]}`, runs: inlineRuns(numbered[4]) })
            continue
        }
        const quote = /^>\s?(.*)$/.exec(line)
        if (quote) {
            blocks.push({ kind: "quote", scale: 1, indent: 1, runs: inlineRuns(quote[1], { ...plainStyle, isItalic: true }) })
            continue
        }
        blocks.push({ kind: "paragraph", scale: 1, indent: 0, runs: inlineRuns(line) })
    }
    return blocks.filter((block) => block.kind !== "fence")
}
