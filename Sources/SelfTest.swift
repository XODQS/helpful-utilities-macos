// SPDX-FileCopyrightText: 2026 Helpful Utilities contributors
// SPDX-License-Identifier: GPL-2.0-only

import AppKit
import Carbon

func runSelfTests() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HelpfulUtilitiesTest-\(UUID())")
    let store = LocalStore(directory: root)
    let board = NSPasteboard.withUniqueName()
    defer {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if !condition() {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }

    func put(_ value: String, concealed: Bool = false) {
        board.clearContents()
        board.setString(value, forType: .string)
        if concealed {
            board.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        }
    }

    let history = ClipboardHistory(board: board, store: store)
    if !IsSecureEventInputEnabled() {
        put("اختبار A")
        history.poll()
        put("test B")
        history.poll()
        put("اختبار A")
        history.poll()
        check(history.clips.map(\.text) == ["اختبار A", "test B"], "clipboard capture, order, and deduplication")
        put("synthetic sensitive value", concealed: true)
        history.poll()
        put(String(repeating: "x", count: ClipboardHistory.maxBytes + 1))
        history.poll()
        check(history.clips.count == 2, "concealed and oversize clips skipped")
        for i in 1...85 {
            put("item \(i)")
            history.poll()
        }
        check(history.clips.count == 80 && history.clips.first?.text == "item 85", "history bound")
        let reopened = ClipboardHistory(board: board, store: store)
        check(reopened.clips.count == 80, "history persists")
        reopened.copy(reopened.clips[3])
        reopened.poll()
        check(board.string(forType: .string) == "item 82" && reopened.clips.first?.text == "item 85",
              "restore clipboard without re-recording")
        reopened.clear()
        check(ClipboardHistory(board: board, store: store).clips.isEmpty, "clear persists")
    } else {
        print("SKIP: Clipboard polling tests because Secure Input is active")
    }

    let notes = NoteStore(store: store)
    check(notes.notes.count == 7, "seven independent notes")
    try! notes.save("ملاحظة عربية — **Markdown**", at: 6)
    try! notes.save("First note", at: 0)
    let saved = NoteStore(store: store).notes
    check(saved[0] == "First note" && saved[6] == "ملاحظة عربية — **Markdown**" && saved[1].isEmpty,
          "notes round-trip UTF-8")
    check(DesktopAccess.shortcutLabel(modifiers: 7, key: "A") == "⌃⌥⇧⌘A" &&
          DesktopAccess.shortcutLabel(modifiers: 8, key: "F3") == "F3", "AX shortcut modifiers")
    var gesture = CommandGesture()
    check(!gesture.update(down: true, time: 1), "first Command press does not trigger")
    check(!gesture.update(down: false, time: 1.05), "Command release does not trigger")
    check(gesture.update(down: true, time: 1.2), "quick second Command press triggers")
    check(!gesture.update(down: false, time: 1.4), "second release resets gesture")
    check(!gesture.update(down: true, time: 2), "later Command press starts a new gesture")

    var longPress = CommandGesture()
    check(longPress.update(down: true, time: 1, singleHold: true), "single-hold mode schedules on the first press")
    check(!longPress.update(down: true, time: 1.1, singleHold: true), "repeated flags do not reschedule the hold")
    check(!longPress.update(down: false, time: 1.2, singleHold: true), "releasing the key ends single-hold mode")
}
