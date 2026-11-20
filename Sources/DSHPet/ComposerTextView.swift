import AppKit

/// The hint belongs to the editor so its baseline follows AppKit's text layout.
final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            guard oldValue != placeholder else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    private let draftUndoManager = UndoManager()
    override var undoManager: UndoManager? { draftUndoManager }

    private var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        let previousModifiers = keyModifiers
        keyModifiers = event.modifierFlags
        defer { keyModifiers = previousModifiers }
        super.keyDown(with: event)
    }

    func shouldSubmit(for command: Selector) -> Bool {
        guard !hasMarkedText(), !keyModifiers.contains(.shift) else { return false }
        return command == #selector(NSResponder.insertNewline(_:))
            || command == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
    }

    // The Edit menu sends these selectors through the responder chain. Keep
    // the editor's undo state local, rather than using the window's manager.
    @objc func undo(_ sender: Any?) {
        if !hasMarkedText() { draftUndoManager.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if !hasMarkedText() { draftUndoManager.redo() }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return draftUndoManager.canUndo && !hasMarkedText()
        case #selector(redo(_:)): return draftUndoManager.canRedo && !hasMarkedText()
        default: return super.validateUserInterfaceItem(item)
        }
    }

    func replaceDraft(with draft: String) {
        guard string != draft, !hasMarkedText() else { return }
        string = draft
        draftUndoManager.removeAllActions()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty,
              let font, let layoutManager, let textContainer else { return }

        // Use the same line fragment origin as typed text. The font supplies
        // the natural side bearing between the insertion point and first glyph.
        let padding = textContainer.lineFragmentPadding
        let origin = textContainerOrigin
        let x = origin.x + padding
        let right = bounds.maxX - textContainerInset.width - padding
        guard right > x else { return }
        let rect = NSRect(x: x, y: origin.y, width: right - x,
                          height: layoutManager.defaultLineHeight(for: font))
        guard dirtyRect.intersects(rect) else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: paragraph,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
