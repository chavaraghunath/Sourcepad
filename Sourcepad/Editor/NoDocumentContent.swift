// SPDX-License-Identifier: MIT
// Sourcepad — EditorContent shown by a window that has a workspace (a real
// folder in its sidebar) but no open document tab yet — e.g. right after
// "Open Folder…"/"Open Workspace…"/a completed clone, before the user has
// clicked a file. Distinct from PlaceholderContent, which stands in for a
// not-yet-implemented *file* view mode; this one means "no file at all."

import AppKit

public final class NoDocumentContent: NSViewController, EditorContent {

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        root.wantsLayer = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .tertiaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 32, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "No File Open")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let detail = NSTextField(labelWithString: "Select a file in the sidebar, or press ⌘P to find one.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])

        self.view = root
    }

    // MARK: - EditorContent — inert; there's nothing to edit or save.

    public var contentView: NSView { view }
    public var currentText: String { "" }
    public func replaceWholeBuffer(with text: String) {}
    public var activeLexer: String? { nil }
    public func setLexer(_ name: String?) {}
    public var caretInfo: EditorCaretInfo {
        EditorCaretInfo(line0Based: 0, column0Based: 0, byteOffset: 0, lineCount: 0, bufferByteCount: 0, selectionByteCount: 0)
    }
    public var supportsPreview: Bool { false }
    public func documentContentsDidLoad() {}
    public func markSavePoint() {}
    public func currentCaretByte() -> Int { 0 }
    public var onTextChanged: (() -> Void)?
}
