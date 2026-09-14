// SPDX-License-Identifier: MIT
// Sourcepad — one window can host many open documents as in-window tabs.
// Hosts the editor split view and a unified toolbar with sidebar toggle,
// navigation arrows, a search field, and a preview toggle.
//
// There is no native macOS window-tab grouping here — DocumentTabBar is the
// only tab UI, and a file open never spawns a second NSWindow for an
// existing window's sake (see Document/DocumentController.swift).

import AppKit

public final class EditorWindowController: NSWindowController,
                                           NSWindowDelegate,
                                           NSToolbarDelegate,
                                           NSSearchFieldDelegate {

    public let editorViewController: EditorViewController
    private weak var rootContentViewController: RootContentViewController?
    private weak var statusBar: StatusBarView?

    private weak var searchField: NSSearchField?
    private var localKeyMonitor: Any?

    /// True once every open document has approved closing and the window is
    /// actually allowed to close — see windowShouldClose/attemptCloseRemainingDocuments.
    private var closeApproved = false

    // Keeps every live EditorWindowController alive for exactly as long as
    // its window is open. A window with open documents is already retained
    // via TextDocument.addWindowController(_:) (NSDocument.windowControllers),
    // but a documentless workspace window (WelcomeWindowController.seedWindow)
    // has no NSDocument at all — without this, its local `wc` goes out of
    // scope and ARC deallocates the controller almost immediately. The
    // NSWindow itself would survive (its content view controller retains the
    // view hierarchy), but NSWindow.windowController is a weak back-reference,
    // so it would silently go nil, breaking every `window.windowController as?
    // EditorWindowController` lookup used to resolve join targets.
    private static var retainedControllers: [ObjectIdentifier: EditorWindowController] = [:]

    /// This window's own workspace (folder roots). Read-through to the
    /// sidebar, which is the single source of truth and stays live as the
    /// user opens folders / switches workspaces in this window.
    public var workspace: Workspace { editorViewController.sidebarPane.workspace }

    public var activeDocument: TextDocument? { editorViewController.activeDocument }
    public var openDocuments: [TextDocument] { editorViewController.openDocuments }

    public init(workspace: Workspace) {
        let vc = EditorViewController(workspace: workspace)
        self.editorViewController = vc

        let bar = StatusBarView()
        self.statusBar = bar

        let root = RootContentViewController(editor: vc, statusBar: bar)
        self.rootContentViewController = root

        let window = NSWindow(contentViewController: root)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1180, height: 720))
        // Hard ceiling on the window's real size. Without one, AppKit's
        // window-autolayout integration will grow the actual NSWindow frame
        // to satisfy an oversized intrinsic-content-size demand from
        // anywhere in the view tree, with no built-in sanity check — this is
        // exactly how a stale "NSWindow Frame SourcepadMainWindow" autosave
        // value was once found corrupted to 40,000+pt wide. Several views in
        // the agent panel (chat bubble width, the @-mention chip row) only
        // softly cap their width during active layout, which is plausible to
        // misbehave transiently while content is streaming in. Rather than
        // chase every such view, put a floor/ceiling on the window itself so
        // this class of bug can never again make the window unusable.
        // >= the split view's own combined minimums (sidebar 180 + editor
        // 320 + agent 280 = 780, both visible by default) — a smaller
        // contentMinSize would just fight those every time the user tries
        // to shrink the window.
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.contentMaxSize = NSSize(width: 3600, height: 2400)
        window.title = workspace.roots.first?.lastPathComponent ?? workspace.name
        // Every window is a fully independent session — never let macOS
        // visually merge separate EditorWindowControllers as native window
        // tabs. In-window tabs (DocumentTabBar) are the only tab model.
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("SourcepadMainWindow")
        window.center()

        // Sourcepad has its own deliberate session restore (App/SessionRestore.swift
        // — a controllable, UserDefaults-based list of open file URLs). AppKit's
        // separate, automatic OS-level window-state restoration (Saved Application
        // State) would otherwise silently replay whatever windows/tabs were open
        // at last quit on the next launch, bypassing DocumentController's join
        // resolution entirely — producing confusing, unreproducible window
        // states across relaunches. Opting out here makes our own
        // SessionRestore the single source of truth for "what reopens."
        window.isRestorable = false

        super.init(window: window)
        window.delegate = self
        window.registerForDraggedTypes([.fileURL])

        installToolbar(on: window)
        installAutoPairMonitor()
        editorViewController.setDocumentTabBarVisible(true)
        syncWindowChrome()
        Self.retainedControllers[ObjectIdentifier(window)] = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    deinit {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: - Tabs

    public func openTab(_ document: TextDocument, activate: Bool = true) {
        editorViewController.openTab(document, activate: activate)
        syncWindowChrome()
    }

    public func activateTab(_ document: TextDocument) {
        editorViewController.activateTab(document)
    }

    public func editorPane(for document: TextDocument) -> EditorPaneViewController? {
        editorViewController.editorPane(for: document)
    }

    /// Reflects the active tab (or this window's workspace, if empty) into
    /// the window title/edited-dot and the status bar. NSDocument's built-in
    /// synchronizeWindowTitleWithDocumentName() assumes one document per
    /// window controller — overridden as a no-op below — so this is the only
    /// thing driving window chrome now that a window can hold N documents.
    func syncWindowChrome() {
        guard let window else { return }
        if let doc = editorViewController.activeDocument {
            window.representedURL = doc.fileURL
            window.title = doc.displayName
            window.isDocumentEdited = doc.isDocumentEdited
        } else {
            window.representedURL = nil
            window.title = workspace.roots.first?.lastPathComponent ?? workspace.name
            window.isDocumentEdited = false
        }
        statusBar?.document = editorViewController.activeDocument
        statusBar?.editorPane = editorViewController.editorPane
        statusBar?.refresh()
    }

    public override func synchronizeWindowTitleWithDocumentName() {
        // No-op — see syncWindowChrome(). Apple's default implementation
        // assumes exactly one document per window controller.
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeApproved { return true }
        attemptCloseRemainingDocuments()
        return false
    }

    /// Runs each open document's standard unsaved-changes prompt one at a
    /// time (recursing on the shrinking list, since a cancel must abort the
    /// whole close). Only once every document has approved does the window
    /// actually close.
    private func attemptCloseRemainingDocuments() {
        guard let doc = editorViewController.openDocuments.first else {
            closeApproved = true
            window?.close()
            return
        }
        doc.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let textDoc = document as? TextDocument else { return }
        // Detach before close() — see the identical comment in
        // EditorViewController.document(_:shouldClose:contextInfo:). Here it
        // also avoids this window closing itself prematurely partway through
        // approving a multi-document close (attemptCloseRemainingDocuments
        // is what's actually supposed to close the window, once the list is
        // empty — not a side effect of an individual document's close()).
        textDoc.removeWindowController(self)
        textDoc.close()
        editorViewController.removeTab(textDoc)
        attemptCloseRemainingDocuments()
    }

    public func windowWillClose(_ notification: Notification) {
        // Kill any shells this window spawned so they don't outlive it.
        rootContentViewController?.terminalPanel.terminateAll()
        // Cancel any in-flight agent turn.
        rootContentViewController?.agentPanel.shutdown()

        // Standard macOS behavior: closing the last window just closes it —
        // the app stays running (see AppDelegate.applicationShouldTerminateAfterLastWindowClosed),
        // window-less, until the user asks for a new one (Dock click, which
        // AppDelegate.applicationShouldHandleReopen handles; ⌘N; File ▸ Open).

        if let window { Self.retainedControllers.removeValue(forKey: ObjectIdentifier(window)) }
    }

    // MARK: - Auto-pair monitor

    private func installAutoPairMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only act on events targeting our window.
            guard event.window === self.window else { return event }
            // Auto-pair only applies to the Scintilla path; non-text view
            // modes (placeholder / future grid / tree / hex) opt out.
            guard let pane = self.editorViewController.editorPane else { return event }
            let editorPaneView = pane.view
            guard let responder = self.window?.firstResponder as? NSView else { return event }
            guard responder === editorPaneView || responder.isDescendant(of: editorPaneView) else {
                return event
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.shift, .capsLock]) == [] else { return event }
            guard let chars = event.characters, chars.count == 1,
                  let first = chars.first,
                  AutoPair.pairs[first] != nil || AutoPair.closers.contains(first)
            else { return event }
            if pane.tryAutoPair(character: first) {
                return nil  // consume — we did the insert via the bridge
            }
            return event
        }
    }

    // MARK: - Toolbar identifiers

    private static let sidebarItemId = NSToolbarItem.Identifier("SourcepadSidebarToggle")
    private static let navItemId     = NSToolbarItem.Identifier("SourcepadNavigation")
    private static let searchItemId  = NSToolbarItem.Identifier("SourcepadSearch")
    private static let previewItemId = NSToolbarItem.Identifier("SourcepadPreviewToggle")
    private static let terminalItemId = NSToolbarItem.Identifier("SourcepadTerminalToggle")
    private static let agentItemId    = NSToolbarItem.Identifier("SourcepadAgentToggle")

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "SourcepadMain")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItemId, .space, Self.navItemId, Self.searchItemId, .flexibleSpace,
         Self.terminalItemId, Self.agentItemId, Self.previewItemId]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarItemId, Self.navItemId, Self.searchItemId, Self.terminalItemId,
         Self.agentItemId, Self.previewItemId, .flexibleSpace, .space]
    }

    public func toolbar(_ toolbar: NSToolbar,
                        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarItemId:  return makeSidebarItem(id: itemIdentifier)
        case Self.navItemId:      return makeNavItem(id: itemIdentifier)
        case Self.searchItemId:   return makeSearchItem(id: itemIdentifier)
        case Self.terminalItemId: return makeTerminalItem(id: itemIdentifier)
        case Self.agentItemId:    return makeAgentItem(id: itemIdentifier)
        case Self.previewItemId:  return makePreviewItem(id: itemIdentifier)
        default: return nil
        }
    }

    // MARK: - Toolbar items

    private func makeSidebarItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Show/Hide Sidebar (⌘0)"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "sidebar.leading",
                                 accessibilityDescription: "Toggle Sidebar")
        } else {
            item.image = NSImage(named: NSImage.touchBarSidebarTemplateName)
        }
        item.target = self
        item.action = #selector(toggleSidebarFromToolbar(_:))
        item.isBordered = true
        return item
    }

    private func makeNavItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        // Disabled placeholders — document navigation history isn't wired yet
        // but the chevrons keep the toolbar visually consistent with the spec.
        let back = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("SourcepadNavBack"))
        back.image = NSImage(systemSymbolName: "chevron.left",
                             accessibilityDescription: "Back") ?? NSImage()
        back.isEnabled = false
        back.action = nil
        back.label = ""

        let forward = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("SourcepadNavForward"))
        forward.image = NSImage(systemSymbolName: "chevron.right",
                                accessibilityDescription: "Forward") ?? NSImage()
        forward.isEnabled = false
        forward.action = nil
        forward.label = ""

        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = [back, forward]
        if #available(macOS 10.15, *) {
            group.controlRepresentation = .expanded
            group.selectionMode = .momentary
        }
        group.label = ""
        group.paletteLabel = "Navigation"
        return group
    }

    private func makeSearchItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        if #available(macOS 11.0, *) {
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.preferredWidthForSearchField = 480
            item.resignsFirstResponderWithCancel = true
            let field = item.searchField
            field.placeholderString = "Search (⌘ E)"
            field.delegate = self
            field.target = self
            field.action = #selector(searchSubmitted(_:))
            field.sendsSearchStringImmediately = false
            field.sendsWholeSearchString = false
            self.searchField = field
            return item
        } else {
            // Pre-Big Sur fallback — bare NSSearchField in a custom toolbar item.
            let field = NSSearchField()
            field.placeholderString = "Search"
            field.delegate = self
            field.target = self
            field.action = #selector(searchSubmitted(_:))
            self.searchField = field
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = field
            item.minSize = NSSize(width: 200, height: 22)
            item.maxSize = NSSize(width: 800, height: 22)
            return item
        }
    }

    private func makeTerminalItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Terminal"
        item.paletteLabel = "Terminal"
        item.toolTip = "Show/Hide Terminal (⌃`)"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "terminal",
                                 accessibilityDescription: "Toggle Terminal")
        } else {
            item.image = NSImage(named: NSImage.actionTemplateName)
        }
        item.target = self
        item.action = #selector(toggleTerminalFromToolbar(_:))
        item.isBordered = true
        return item
    }

    private func makeAgentItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Agent"
        item.paletteLabel = "Agent"
        item.toolTip = "Show/Hide Agent (⌃⌘A)"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "sparkles",
                                 accessibilityDescription: "Toggle Agent")
        } else {
            item.image = NSImage(named: NSImage.touchBarTextBoxTemplateName)
        }
        item.target = self
        item.action = #selector(toggleAgentFromToolbar(_:))
        item.isBordered = true
        return item
    }

    private func makePreviewItem(id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Preview"
        item.paletteLabel = "Preview"
        item.toolTip = "Toggle Preview (⇧⌘P)"
        if #available(macOS 11.0, *) {
            item.image = NSImage(systemSymbolName: "sidebar.right",
                                 accessibilityDescription: "Toggle Preview")
        } else {
            item.image = NSImage(named: NSImage.quickLookTemplateName)
        }
        item.target = self
        item.action = #selector(togglePreviewFromToolbar(_:))
        item.isBordered = true
        return item
    }

    // MARK: - Toolbar actions

    @objc private func toggleSidebarFromToolbar(_ sender: Any?) {
        editorViewController.toggleSidebar()
    }

    @objc private func togglePreviewFromToolbar(_ sender: Any?) {
        editorViewController.togglePreview()
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func toggleTerminalFromToolbar(_ sender: Any?) {
        rootContentViewController?.toggleTerminal()
    }

    @objc private func toggleAgentFromToolbar(_ sender: Any?) {
        rootContentViewController?.toggleAgent()
        window?.toolbar?.validateVisibleItems()
    }

    @objc private func searchSubmitted(_ sender: NSSearchField) {
        // Enter in the search field → advance to next match. Only meaningful
        // in the Scintilla path; placeholder content has nothing to find.
        editorViewController.editorPane?.quickFindAdvance(forward: true)
    }

    // MARK: - NSSearchFieldDelegate / NSControl

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        editorViewController.editorPane?.quickFind(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === searchField {
            if selector == #selector(cancelOperation(_:)) {
                searchField?.stringValue = ""
                if let paneView = editorViewController.editorPane?.view {
                    window?.makeFirstResponder(paneView)
                }
                return true
            }
        }
        return false
    }

    // MARK: - Focus toolbar search (Cmd-E / Cmd-F)

    @objc public func sourcepadFocusToolbarSearch(_ sender: Any?) {
        guard let field = searchField else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc public func sourcepadOpenFindInFiles(_ sender: Any?) {
        // Default search root = the sidebar's current root, fall back to the
        // active document's enclosing folder.
        let root = editorViewController.sidebarPane.rootURL
            ?? editorViewController.activeDocument?.fileURL?.deletingLastPathComponent()
        FindInFilesWindowController.shared.show(searchingIn: root)
    }

    // MARK: - NSWindow drag-and-drop (catches drops on title bar)

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil),
              let urls = items as? [URL], !urls.isEmpty,
              let dc = NSDocumentController.shared as? DocumentController,
              let window else { return false }
        for url in urls {
            dc.openDocument(withContentsOf: url, display: true, joinPolicy: .join(window)) { _, _, error in
                if let error { NSLog("[Sourcepad] window-drag-open failed: \(url.path) — \(error)") }
            }
        }
        return true
    }
}

extension EditorWindowController: NSToolbarItemValidation {
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Self.previewItemId: return editorViewController.canShowPreview
        case Self.sidebarItemId: return true
        case Self.terminalItemId: return true
        case Self.agentItemId: return true
        default: return true
        }
    }
}
