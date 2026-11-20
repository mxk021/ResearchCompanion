import AppKit

// Compile with Sources/DSHPet/ComposerTextView.swift. No profiles or data needed.
@main
private struct ComposerCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 58))
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 8, height: 7)
        editor.textColor = .labelColor
        editor.allowsUndo = true
        editor.isRichText = false
        editor.backgroundColor = .textBackgroundColor

        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        precondition(window.makeFirstResponder(editor))

        let placeholder = "输入问题；Enter 发送，Shift+Enter 换行"
        editor.placeholder = placeholder
        let emptyRange = NSRange(location: 0, length: 0)
        precondition(editor.string.isEmpty && editor.selectedRange() == emptyRange)
        precondition(editor.accessibilityPlaceholderValue() == placeholder)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            editor.appearance = NSAppearance(named: appearance)
            editor.placeholder = ""
            let plain = render(editor)
            editor.placeholder = placeholder
            let hinted = render(editor)
            let changed = changedPixels(from: plain, to: hinted)
            let caret = window.convertFromScreen(editor.firstRect(forCharacterRange: emptyRange, actualRange: nil))
            let caretX = editor.convert(caret, from: nil).minX
            let firstInkX = CGFloat(changed.map(\.0).min()!) / CGFloat(hinted.pixelsWide) * editor.bounds.width
            precondition(firstInkX >= caretX, "Hint ink extends before the insertion point in \(appearance)")

            editor.placeholder = "输"
            let hintRows = changedPixels(from: plain, to: render(editor)).map(\.1)
            editor.replaceDraft(with: "输")
            let typedPixels = changedPixels(from: plain, to: render(editor))
            let textRows = typedPixels.map(\.1)
            let typedInkX = CGFloat(typedPixels.map(\.0).min()!) / CGFloat(hinted.pixelsWide) * editor.bounds.width
            precondition(abs(firstInkX - typedInkX) <= 1, "Hint and typed first glyph start at different positions")
            precondition(abs(hintRows.min()! - textRows.min()!) <= 1, "Hint baseline differs from typed text in \(appearance)")
            editor.replaceDraft(with: "")
            editor.placeholder = placeholder
        }

        // Model updates must not replace marked text while the input method
        // is still composing. Only its committed result becomes typed text.
        let noReplacedRange = NSRange(location: NSNotFound, length: 0)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: noReplacedRange)
        precondition(editor.hasMarkedText())
        editor.replaceDraft(with: "stale update")
        precondition(editor.hasMarkedText() && editor.string == "zhong")
        editor.insertText("中", replacementRange: noReplacedRange)
        precondition(!editor.hasMarkedText() && editor.string == "中")
        let committed = render(editor)
        editor.placeholder = ""
        precondition(changedPixels(from: committed, to: render(editor)).isEmpty, "Hint remained over committed text")

        editor.replaceDraft(with: "")
        editor.insertText("第一行\n第二行", replacementRange: noReplacedRange)
        precondition(editor.string == "第一行\n第二行")
        editor.breakUndoCoalescing()
        let undoItem = NSMenuItem(title: "撤销", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
        precondition(editor.validateMenuItem(undoItem))
        precondition(NSApplication.shared.sendAction(undoItem.action!, to: editor, from: undoItem))
        precondition(editor.string.isEmpty, "Native undo did not restore the draft")
        precondition(editor.validateMenuItem(redoItem))
        precondition(NSApplication.shared.sendAction(redoItem.action!, to: editor, from: redoItem))
        precondition(editor.string == "第一行\n第二行", "Native redo did not restore the edit")
        editor.replaceDraft(with: "新的草稿")
        precondition(!editor.validateMenuItem(undoItem), "Undo still reaches replaced drafts")
        editor.insertText("?", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        precondition(NSApplication.shared.sendAction(undoItem.action!, to: editor, from: undoItem))
        precondition(editor.string == "新的草稿", "Undo in new draft reached a replaced draft")

        let submitTracking = SubmitTracking()
        editor.delegate = submitTracking
        editor.replaceDraft(with: "第一行")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.keyDown(with: returnEvent(in: window, modifiers: [.shift]))
        precondition(submitTracking.count == 0 && editor.string == "第一行\n", "Shift+Return sent or failed to insert a newline")
        editor.keyDown(with: returnEvent(in: window, modifiers: []))
        precondition(submitTracking.count == 1 && editor.string == "第一行\n", "Return failed to submit or inserted a newline")
        print("PASS native editor layout in light and dark, marked-text commit, Return and Shift+Return, scoped undo")
    }

    @MainActor private class SubmitTracking: NSObject, NSTextViewDelegate {
        var count = 0

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let editor = textView as? ComposerTextView, editor.shouldSubmit(for: commandSelector) else {
                return false
            }
            count += 1
            return true
        }
    }

    @MainActor private static func returnEvent(in window: NSWindow, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    @MainActor private static func render(_ view: NSView) -> NSBitmapImageRep {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func changedPixels(from plain: NSBitmapImageRep, to hinted: NSBitmapImageRep) -> [(Int, Int)] {
        var changed: [(Int, Int)] = []
        for y in 0..<hinted.pixelsHigh {
            for x in 0..<hinted.pixelsWide where plain.colorAt(x: x, y: y) != hinted.colorAt(x: x, y: y) {
                changed.append((x, y))
            }
        }
        return changed
    }
}
