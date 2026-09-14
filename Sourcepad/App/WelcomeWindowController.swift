// SPDX-License-Identifier: MIT
// Sourcepad — the window shown when there's nothing open: at launch (when
// session restore has nothing to restore) and whenever the last document
// window closes and the Dock icon is clicked again.
//
// This is deliberately NOT an NSDocument. Earlier, "nothing open" was
// represented by an actual blank "Untitled" TextDocument — a real closeable
// document that then got tangled up in tab/window-close semantics (closing
// it looked like "the app won't close" or "closing a file closes the whole
// window"). This window carries no document at all, so closing it is just
// closing a window: standard macOS behavior, no save prompt, no document
// bookkeeping, and the app stays running per
// AppDelegate.applicationShouldTerminateAfterLastWindowClosed.

import AppKit

public final class WelcomeWindowController: NSWindowController, NSWindowDelegate {

    public static let shared = WelcomeWindowController()

    private static let contentSize = NSSize(width: 1270, height: 0)  // height set by content
    private static let columnWidth: CGFloat = 540
    private let recentSection = NSStackView()
    private let recentEmptyLabel = NSTextField(labelWithString: "Folders and workspaces you open will show up here.")
    private var cloneSheet: GitCloneSheet?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false  // see EditorWindowController.init for why
        window.setFrameAutosaveName("SourcepadWelcomeWindow")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = makeContentViewController()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    public override func showWindow(_ sender: Any?) {
        refreshRecents()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - Content

    private func makeContentViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView()
        root.wantsLayer = true

        // MARK: Header — icon, name, version.
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let title = NSTextField(labelWithString: "Sourcepad")
        title.font = .systemFont(ofSize: 36, weight: .semibold)
        title.textColor = .labelColor

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let caption = NSTextField(labelWithString: version.map { "Version \($0) — open a file or folder to get started." }
                                                     ?? "Open a file or folder to get started.")
        caption.font = .systemFont(ofSize: 13.5)
        caption.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [title, caption])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let header = NSStackView(views: [icon, titleStack])
        header.orientation = .horizontal
        header.spacing = 22
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Start section.
        let startHeader = sectionLabel("Start")
        let startRows = NSStackView(views: [
            WelcomeRow(symbol: "folder", tint: .systemPurple, title: "Open Folder…",
                      subtitle: "Open a project folder as a workspace") { [weak self] in self?.chooseFolder() },
            WelcomeRow(symbol: "square.stack.3d.up.fill", tint: .systemTeal, title: "Open Workspace…",
                      subtitle: "Switch to a saved multi-folder workspace") { [weak self] in self?.openWorkspacePicker() },
            WelcomeRow(symbol: "doc", tint: .systemOrange, title: "Open File…",
                      subtitle: "Open a single file") { [weak self] in self?.openFile() },
            WelcomeRow(symbol: "arrow.triangle.branch", tint: .systemGreen, title: "Clone Git Repository…",
                      subtitle: "Clone a repository and open it") { [weak self] in self?.presentCloneSheet() },
            WelcomeRow(symbol: "person.crop.circle", tint: .labelColor, title: "Sign in to GitHub",
                      subtitle: "Authenticate the gh CLI for private repos") { [weak self] in self?.signInToGitHub() },
        ])
        startRows.orientation = .vertical
        startRows.spacing = 4

        let startSection = NSStackView(views: [startHeader, startRows])
        startSection.orientation = .vertical
        startSection.alignment = .leading
        startSection.spacing = 8

        // MARK: Recent section.
        let recentHeader = sectionLabel("Recent")
        recentSection.orientation = .vertical
        recentSection.spacing = 2

        recentEmptyLabel.font = .systemFont(ofSize: 12)
        recentEmptyLabel.textColor = .tertiaryLabelColor

        let recentBlock = NSStackView(views: [recentHeader, recentSection])
        recentBlock.orientation = .vertical
        recentBlock.alignment = .leading
        recentBlock.spacing = 8

        let leftColumn = NSStackView(views: [startSection, recentBlock])
        leftColumn.orientation = .vertical
        leftColumn.alignment = .leading
        leftColumn.spacing = 26
        leftColumn.translatesAutoresizingMaskIntoConstraints = false

        // MARK: "Learn Sourcepad" column — the right-hand orientation panel.
        let learnHeader = sectionLabel("Learn Sourcepad")
        let learnRows = NSStackView(views: Self.tips.map { tip in
            TipRow(symbol: tip.symbol, title: tip.title, shortcut: tip.shortcut, detail: tip.detail)
        })
        learnRows.orientation = .vertical
        learnRows.spacing = 20
        learnRows.translatesAutoresizingMaskIntoConstraints = false

        let rightColumn = NSStackView(views: [learnHeader, learnRows])
        rightColumn.orientation = .vertical
        rightColumn.alignment = .leading
        rightColumn.spacing = 12
        rightColumn.translatesAutoresizingMaskIntoConstraints = false

        let verticalDivider = NSBox()
        verticalDivider.boxType = .separator
        verticalDivider.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [leftColumn, verticalDivider, rightColumn])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 56
        body.translatesAutoresizingMaskIntoConstraints = false

        // MARK: Assemble.
        let divider1 = NSBox(); divider1.boxType = .separator
        let content = NSStackView(views: [header, divider1, body])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 32
        content.edgeInsets = NSEdgeInsets(top: 46, left: 56, bottom: 50, right: 56)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(20, after: header)

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.contentSize.width),
            // divider1 spans edge-to-edge (ignores content's edgeInsets on
            // purpose, for a full-bleed rule). body does NOT get the same
            // treatment — it must stay inset like every other section, so
            // it's left to NSStackView's normal edgeInsets-driven placement
            // rather than pinned to content's raw (uninset) edges.
            divider1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // body's own width must be pinned explicitly (content's leading
            // alignment doesn't stretch arranged subviews) so rightColumn's
            // implied width below resolves to something real instead of
            // shrink-wrapping to its widest label.
            body.widthAnchor.constraint(equalToConstant: Self.contentSize.width - 56 - 56),

            leftColumn.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            startRows.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            startRows.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),
            recentSection.leadingAnchor.constraint(equalTo: leftColumn.leadingAnchor),
            recentSection.trailingAnchor.constraint(equalTo: leftColumn.trailingAnchor),

            verticalDivider.widthAnchor.constraint(equalToConstant: 1),
            verticalDivider.topAnchor.constraint(equalTo: body.topAnchor),
            verticalDivider.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor),

            // rightColumn's width is implied by the stack's own leading/trailing
            // chain (content is width-pinned via root.widthAnchor above), so no
            // explicit width constraint is needed here.
            learnRows.leadingAnchor.constraint(equalTo: rightColumn.leadingAnchor),
            learnRows.trailingAnchor.constraint(equalTo: rightColumn.trailingAnchor),
        ])

        vc.view = root
        return vc
    }

    private struct Tip { let symbol: String; let title: String; let shortcut: String; let detail: String }

    /// Real shortcuts, pulled from MainMenu.swift — kept in sync by hand
    /// since the menu is built imperatively rather than from a shared table.
    private static let tips: [Tip] = [
        Tip(symbol: "command", title: "Command Palette", shortcut: "⇧⌘P",
            detail: "Run any command by name"),
        Tip(symbol: "magnifyingglass", title: "Quick Open", shortcut: "⌘P",
            detail: "Jump to any file by typing its name"),
        Tip(symbol: "number", title: "Go to Symbol", shortcut: "⌘T",
            detail: "Jump to a function, class, or type across the workspace"),
        Tip(symbol: "doc.text.magnifyingglass", title: "Find in Files", shortcut: "⇧⌘F",
            detail: "Search across every file in the workspace"),
        Tip(symbol: "terminal", title: "Toggle Terminal", shortcut: "⌃`",
            detail: "Open an embedded shell without leaving the editor"),
        Tip(symbol: "sparkles", title: "Toggle Agent Panel", shortcut: "⌃⌘A",
            detail: "Chat with Claude, Codex, or a local model about this code"),
        Tip(symbol: "text.cursor", title: "Add Cursor to Next Occurrence", shortcut: "⌘D",
            detail: "Select and edit multiple matches at once"),
    ]

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Recently opened folders/workspaces/clones — never individual files.
    /// A workspace only appears once it's been explicitly opened via
    /// Open Folder…/Open Workspace…/a completed clone (`lastOpenedAt` set),
    /// and only if it actually has folder roots (the empty "Default"
    /// workspace never appears here).
    private func recentWorkspaces() -> [Workspace] {
        WorkspaceManager.shared.workspaces
            .filter { $0.lastOpenedAt != nil && !$0.roots.isEmpty }
            .sorted { $0.lastOpenedAt! > $1.lastOpenedAt! }
    }

    private func refreshRecents() {
        recentSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let workspaces = Array(recentWorkspaces().prefix(6))
        if workspaces.isEmpty {
            recentSection.addArrangedSubview(recentEmptyLabel)
        } else {
            for ws in workspaces {
                let subtitle: String
                if let first = ws.roots.first {
                    let path = first.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    subtitle = ws.roots.count > 1 ? "\(path) and \(ws.roots.count - 1) more" : path
                } else {
                    subtitle = ""
                }
                let icon = NSWorkspace.shared.icon(forFile: ws.roots.first?.path ?? "/")
                let row = WelcomeRow(image: icon, title: ws.name, subtitle: subtitle) { [weak self] in
                    self?.openWorkspace(ws)
                }
                recentSection.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: recentSection.widthAnchor).isActive = true
            }
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if let fitting = window?.contentViewController?.view.fittingSize {
            let wasVisible = window?.isVisible ?? false
            window?.setContentSize(NSSize(width: Self.contentSize.width, height: fitting.height))
            if !wasVisible { window?.center() }
        }
    }

    // MARK: - Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let self, !panel.urls.isEmpty else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { DebugLog.log("welcome: open file failed: \(url.path) — \(error)") }
                }
            }
            self.close()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            var ws = WorkspaceManager.shared.addRoot(url, to: Workspace(name: url.lastPathComponent))
            ws = WorkspaceManager.shared.touch(ws.id) ?? ws
            self?.seedWindow(with: ws)
        }
    }

    /// Popover list of every saved workspace with at least one folder root
    /// (the empty "Default" workspace isn't a meaningful pick here).
    private func openWorkspacePicker() {
        let candidates = WorkspaceManager.shared.workspaces.filter { !$0.roots.isEmpty }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Saved Workspaces Yet"
            alert.informativeText = "Open a folder first — Sourcepad will remember it here as a workspace you can switch back to."
            if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
            return
        }
        let menu = NSMenu(title: "Workspaces")
        for ws in candidates.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let subtitle = ws.roots.count == 1 ? ws.roots[0].lastPathComponent : "\(ws.roots.count) folders"
            let item = NSMenuItem(title: "\(ws.name) — \(subtitle)",
                                  action: #selector(workspacePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.id
            menu.addItem(item)
        }
        guard let contentView = window?.contentView else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 56, y: contentView.bounds.height - 260), in: contentView)
    }

    @objc private func workspacePicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let ws = WorkspaceManager.shared.workspaces.first(where: { $0.id == id }) else { return }
        openWorkspace(ws)
    }

    private func openWorkspace(_ ws: Workspace) {
        let touched = WorkspaceManager.shared.touch(ws.id) ?? ws
        seedWindow(with: touched)
    }

    /// Opens a window scoped to `workspace` with no document at all — a real
    /// sidebar/folder tree, NoDocumentContent in the editor area, no tabs.
    /// DocumentController's window-join resolution finds this window by
    /// workspace-root containment like any other (it enumerates NSApp.windows,
    /// not NSDocumentController's document list), so the first file opened
    /// into this folder just becomes this window's first tab — see
    /// DocumentController.attach(_:joinPolicy:url:display:).
    private func seedWindow(with workspace: Workspace) {
        let wc = EditorWindowController(workspace: workspace)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        close()
    }

    private func presentCloneSheet() {
        guard let window else { return }
        let sheet = GitCloneSheet()
        cloneSheet = sheet
        sheet.present(over: window) { [weak self] localURL in
            guard let self else { return }
            self.cloneSheet = nil
            var ws = WorkspaceManager.shared.addRoot(localURL, to: Workspace(name: localURL.lastPathComponent))
            ws = WorkspaceManager.shared.touch(ws.id) ?? ws
            self.seedWindow(with: ws)
        }
    }

    private func signInToGitHub() {
        GitHubAuth.signIn(presentingFrom: window)
    }


    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Just a window close — no document, nothing to save, nothing else
        // to tear down. The app stays running per
        // applicationShouldTerminateAfterLastWindowClosed; the Dock icon
        // reopens this window via applicationShouldHandleReopen.
        true
    }
}

// MARK: - Hoverable action/recent-file row

/// A borderless, hover-highlighted, clickable row: an icon (either a tinted
/// SF Symbol tile for an action, or a plain file icon for a recent file)
/// beside a title/subtitle pair. AppKit has no built-in "list row button"
/// that supports a two-line label, so this composes one from a tracking
/// area (hover) + a click handler, following the same appearance-adaptive
/// layer pattern used by SidebarRootView (updateLayer, not a baked-in color).
private final class WelcomeRow: NSView {

    private let onClick: () -> Void
    private let background = NSView()
    private var trackingArea: NSTrackingArea?

    /// Action-row style: SF Symbol in a tinted rounded tile.
    convenience init(symbol: String, tint: NSColor, title: String, subtitle: String, onClick: @escaping () -> Void) {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(config)
        self.init(icon: image, tint: tint, title: title, subtitle: subtitle, onClick: onClick)
    }

    /// Recent-file style: a plain file icon, no tint tile.
    convenience init(image: NSImage, title: String, subtitle: String, onClick: @escaping () -> Void) {
        self.init(icon: image, tint: nil, title: title, subtitle: subtitle, onClick: onClick)
    }

    private init(icon: NSImage?, tint: NSColor?, title: String, subtitle: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        background.wantsLayer = true
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let iconContainer: NSView
        let imageView = NSImageView(image: icon ?? NSImage())
        imageView.translatesAutoresizingMaskIntoConstraints = false

        if let tint {
            // SF Symbol, already rendered at a fixed point size by the
            // caller — draw at that natural size, don't stretch it.
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = tint
            let tile = NSView()
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 9
            tile.layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(imageView)
            iconContainer = tile
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: 40),
                tile.heightAnchor.constraint(equalToConstant: 40),
                imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            ])
        } else {
            // A real file icon from NSWorkspace — proportionally fit it into
            // a fixed slot instead of drawing at its (often much larger)
            // native resolution.
            imageView.imageScaling = .scaleProportionallyDown
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(imageView)
            iconContainer = slot
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: 40),
                slot.heightAnchor.constraint(equalToConstant: 40),
                imageView.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 22),
                imageView.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconContainer)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),

            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            background.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),

            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 11),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private func setHighlighted(_ highlighted: Bool) {
        background.layer?.cornerRadius = 8
        background.layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }
}

// MARK: - Learn-Sourcepad tip row

/// A static (non-interactive) row in the "Learn Sourcepad" column: an icon,
/// a title with its keyboard shortcut shown as a badge, and a one-line
/// description underneath.
private final class TipRow: NSView {

    init(symbol: String, title: String, shortcut: String, detail: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Render every symbol at the same point size before placing it, then
        // center it in a fixed-width slot — SF Symbols have different
        // natural bounding-box proportions (⌘ is nearly square, a terminal
        // glyph is wide, a text-cursor glyph is narrow), so stretching each
        // into an identical width/height box (the earlier approach) made
        // their ink look inconsistently placed from row to row.
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let iconImage = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfig)
        let iconView = NSImageView(image: iconImage ?? NSImage())
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let iconSlot = NSView()
        iconSlot.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(shortcutLabel)
        NSLayoutConstraint.activate([
            shortcutLabel.topAnchor.constraint(equalTo: badge.topAnchor, constant: 2),
            shortcutLabel.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2),
            shortcutLabel.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            shortcutLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
        ])

        let titleRow = NSStackView(views: [titleLabel, badge])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .centerY

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleRow, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconSlot)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconSlot.widthAnchor.constraint(equalToConstant: 24),
            iconSlot.heightAnchor.constraint(equalToConstant: 20),
            iconSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconSlot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            iconView.centerXAnchor.constraint(equalTo: iconSlot.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconSlot.centerYAnchor),

            textStack.leadingAnchor.constraint(equalTo: iconSlot.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
