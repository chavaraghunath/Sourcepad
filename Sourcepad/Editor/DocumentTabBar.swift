// SPDX-License-Identifier: MIT
// Sourcepad — a VS Code–style document tab strip above the editor.
//
// Every open document in a window gets one tab here; clicking a tab activates
// it (swaps the visible editor content), clicking × (or middle-click) closes
// it. This is the ONLY tab UI in the app — there is no native macOS
// window-tab grouping anymore (see Document/DocumentController.swift):
// one NSWindow, one tab strip, N documents.

import AppKit

public final class DocumentTabBar: NSView {

    public private(set) var documents: [TextDocument] = []
    public private(set) var activeDocument: TextDocument?

    /// Invoked when the user clicks a tab to activate it.
    public var onSelect: ((TextDocument) -> Void)?
    /// Invoked when the user clicks a tab's × (or middle-clicks it).
    public var onClose: ((TextDocument) -> Void)?

    private let stack = NSStackView()
    private let bottomBorder = NSView()
    private var cells: [TabCell] = []

    private static let barHeight: CGFloat = 34

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.barHeight))
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Build

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        // Clip rather than let an overflowing tab strip push past the bar's
        // bounds — plain layout (no NSScrollView: that path previously
        // under-constrained the strip's width to a `<=` inequality with
        // nothing else demanding a real size, so the whole strip — and every
        // tab in it — silently collapsed to zero width and never appeared).
        clipsToBounds = true

        bottomBorder.wantsLayer = true
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)

        stack.orientation = .horizontal
        stack.alignment = .bottom
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        applyColors()

        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Appearance

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
        cells.forEach { $0.applyColors() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: - Content

    /// Replaces the full tab set and which one is active, rebuilding cells.
    public func setDocuments(_ documents: [TextDocument], active: TextDocument?) {
        self.documents = documents
        self.activeDocument = active
        rebuild()
    }

    /// Re-reads title/icon/dirty state for the current documents without
    /// changing which ones are shown (cheaper than setDocuments when only a
    /// dirty-dot or filename changed).
    @objc public func refresh() {
        for cell in cells { cell.refresh(isActive: cell.document === activeDocument) }
    }

    private func rebuild() {
        cells.forEach { $0.removeFromSuperview() }
        cells = documents.map { doc in
            let cell = TabCell(document: doc)
            cell.onClick = { [weak self] in self?.onSelect?(doc) }
            cell.onClose = { [weak self] in self?.onClose?(doc) }
            return cell
        }
        cells.forEach { stack.addArrangedSubview($0) }
        refresh()
    }
}

// MARK: - One tab cell

private final class TabCell: NSView {
    weak var document: TextDocument?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?

    private let hit = TabHitView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let modifiedDot = NSView()
    private let closeButton = NSButton()
    private var isActive = false

    init(document: TextDocument) {
        self.document = document
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func build() {
        wantsLayer = true
        hit.wantsLayer = true
        hit.translatesAutoresizingMaskIntoConstraints = false
        hit.onClick = { [weak self] in self?.onClick?() }
        hit.onMiddleClick = { [weak self] in self?.onClose?() }
        hit.setAccessibilityRole(.button)
        addSubview(hit)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modifiedDot.wantsLayer = true
        modifiedDot.layer?.cornerRadius = 3
        modifiedDot.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.toolTip = "Close (⌘W)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 4
        closeButton.setAccessibilityLabel("Close tab")

        [icon, titleLabel, modifiedDot, closeButton].forEach { hit.addSubview($0) }

        NSLayoutConstraint.activate([
            hit.leadingAnchor.constraint(equalTo: leadingAnchor),
            hit.trailingAnchor.constraint(equalTo: trailingAnchor),
            hit.topAnchor.constraint(equalTo: topAnchor),
            hit.bottomAnchor.constraint(equalTo: bottomAnchor),
            // TabCell sits in a horizontal NSStackView with .bottom alignment,
            // which leaves each arranged subview's height at whatever it can
            // resolve on its own — and since `hit`'s height was only ever
            // pinned back to this view (circular, no concrete value), every
            // cell collapsed to zero height and simply never appeared. Anchor
            // a real height here instead.
            heightAnchor.constraint(equalToConstant: 30),
            hit.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            hit.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

            icon.leadingAnchor.constraint(equalTo: hit.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: hit.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: hit.centerYAnchor),

            modifiedDot.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            modifiedDot.centerYAnchor.constraint(equalTo: hit.centerYAnchor),
            modifiedDot.widthAnchor.constraint(equalToConstant: 6),
            modifiedDot.heightAnchor.constraint(equalToConstant: 6),

            closeButton.leadingAnchor.constraint(equalTo: modifiedDot.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: hit.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: hit.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        applyColors()
        setupTracking()
    }

    func refresh(isActive: Bool) {
        self.isActive = isActive
        let name = document?.displayName ?? document?.fileURL?.lastPathComponent ?? "Untitled"
        titleLabel.stringValue = name

        if let url = document?.fileURL {
            icon.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        }

        let edited = document?.isDocumentEdited ?? false
        modifiedDot.isHidden = !edited
        hit.setAccessibilityLabel(edited ? "\(name) (edited)" : name)
        hit.toolTip = document?.fileURL?.path ?? document?.displayName
        applyColors()
    }

    func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            hit.layer?.backgroundColor = (isActive ? NSColor.textBackgroundColor : NSColor.clear).cgColor
            modifiedDot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    @objc private func closeClicked() { onClose?() }

    private func setupTracking() {
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.20).cgColor
        closeButton.contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        closeButton.contentTintColor = .secondaryLabelColor
    }
}

// MARK: - Click-catching tab body

/// A small NSView that reports left-clicks (activate) and middle-clicks
/// (close) without swallowing clicks meant for the close button.
private final class TabHitView: NSView {
    var onClick: (() -> Void)?
    var onMiddleClick: (() -> Void)?

    // The close button is an NSButton, so AppKit hit-tests and delivers its
    // clicks directly to it — this only fires for the tab body / label / icon.
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() }
    }
}
