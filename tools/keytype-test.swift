// keytype-test — experiment: can we inject multi-line text as RAW KEYSTROKES
// (no clipboard, no bracketed paste) so Claude Code shows it inline instead of
// collapsing it to "[Pasted N lines]", with Shift+Enter for newlines so it never
// submits?
//
// Run from a SEPARATE terminal tab, then tab to your Claude Code input within 5s:
//     swift tools/keytype-test.swift
//
// It types 5 lines via CGEventKeyboardSetUnicodeString (one event per ≤18-char
// chunk) and Shift+Enter between them. It NEVER presses plain Enter, so nothing
// should submit — you inspect the result in the input box.
//
// SUCCESS  = all 5 lines appear inline (no placeholder), as 5 separate lines,
//            special chars intact, long line intact, nothing submitted.
// REPORT if: a "[Pasted N lines]" placeholder appears / it submits early / chars
//            are dropped or wrong / an autocomplete menu pops / Shift+Enter fails.
//
// If NOTHING types at all: the terminal running this needs Accessibility
// (System Settings → Privacy & Security → Accessibility → add your terminal app).

import Foundation
import CoreGraphics

let src = CGEventSource(stateID: .hidSystemState)
let tap: CGEventTapLocation = .cgAnnotatedSessionEventTap
let gap: useconds_t = 6000 // 6ms between events

func typeChunk(_ s: String) {
    let u = Array(s.utf16)
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
    down?.post(tap: tap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
    up?.post(tap: tap)
}

func typeLine(_ line: String) {
    // Chunk to ≤18 UTF-16 units — a single key event's unicode string is only
    // reliably delivered up to ~20 units.
    var i = line.startIndex
    while i < line.endIndex {
        let j = line.index(i, offsetBy: 18, limitedBy: line.endIndex) ?? line.endIndex
        typeChunk(String(line[i..<j]))
        usleep(gap)
        i = j
    }
}

func shiftEnter() {
    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true) // 0x24 = Return
    down?.flags = .maskShift
    down?.post(tap: tap)
    let up = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
    up?.flags = .maskShift
    up?.post(tap: tap)
    usleep(gap)
}

let payload = [
    "KEYTYPE TEST line 1/5 — if you can read this inline, no placeholder = win.",
    "line 2: the quick brown fox jumps over the lazy dog 1234567890",
    "line 3: symbols mid-line a:b c;d e_f g-h i.j k(l)m n=o p+q done",
    "line 4 (long, 1000 x's — long enough to trigger the paste placeholder): "
        + String(repeating: "x", count: 1000) + " <-end-of-long-line",
    "line 5/5 — END (no trailing Enter, so this should NOT submit)",
]

func err(_ s: String) { FileHandle.standardError.write(s.data(using: .utf8)!) }

err("\nTab to your Claude Code input now. Typing in ")
for n in stride(from: 5, through: 1, by: -1) {
    err("\(n)… ")
    Thread.sleep(forTimeInterval: 1)
}
err("GO\n")

for (idx, line) in payload.enumerated() {
    typeLine(line)
    if idx < payload.count - 1 { shiftEnter() }
}
err("done — inspect the input box (nothing should have been submitted).\n")
