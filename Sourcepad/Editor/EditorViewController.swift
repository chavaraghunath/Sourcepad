// SPDX-License-Identifier: MIT
// Sourcepad — NSSplitViewController hosting (sidebar, editor, preview).
// Sidebar and preview start collapsed; both toggle via menu/toolbar.
//
// The editor column is a real multi-document tab strip: a window can hold
// any number of open TextDocuments, each with its own EditorContent kept
// alive in memory, and switching tabs just swaps which content view is
// visible — no second NSWindow is ever involved (see DocumentController).

import AppKit

public final class EditorViewController: NSSplitViewController {

    private static let sidebarVisibleKey = "Sourcepad.sidebarVisible"

    public let sidebarPane: SidebarViewController
    public let previewPane: PreviewPaneViewController
    /// The VS Code–style tab strip shown above the editor content.
    public let documentTabBar: DocumentTabBar
    private let editorColumn: EditorColumnViewController
    /// Shown whenever this window has zero open tabs (a real workspace/sidebar
    /// with nothing open yet — see NoDocumentContent.swift).
    private let noDocumentContent = NoDocumentContent()

    private let sidebarItem: NSSplitViewItem
    private let editorItem: NSSplitViewItem
    private let previewItem: NSSplitViewItem

    private var pendingRender: DispatchWorkItem?

    // MARK: - Open tabs

    private var contentByDocument: [ObjectIdentifier: EditorContent] = [:]
    public private(set) var openDocuments: [TextDocument] = []
    public private(set) weak var activeDocument: TextDocument?

    private var activeContent: EditorContent? {
        activeDocument.flatMap { contentByDocument[ObjectIdentifier($0)] }
    }
    /// Scintilla-specific facet of the ACTIVE tab, nil for non-text content
    /// or an empty window. Existing call sites (find bar, auto-pair, quick
    /// find) reach the active tab's pane through this.
    public var editorPane: EditorPaneViewController? { activeContent as? EditorPaneViewController }

    public init(workspace: Workspace) {
        let sp = SidebarViewController(workspace: workspace)
        let pp = PreviewPaneViewController()
        self.sidebarPane = sp
        self.previewPane = pp

        let si = NSSplitViewItem(sidebarWithViewController: sp)
        si.minimumThickness = 180
        si.maximumThickness = 480
        si.canCollapse = true
        si.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        si.holdingPriority = NSLayoutConstraint.Priority(270)
        self.sidebarItem = si

        let bar = DocumentTabBar()
        self.documentTabBar = bar
        let column = EditorColumnViewController(tabBar: bar, initialContent: noDocumentContent)
        self.editorColumn = column
        let ei = NSSplitViewItem(viewController: column)
        ei.minimumThickness = 320
        ei.holdingPriority = NSLayoutConstraint.Priority(250)
        self.editorItem = ei

        let pi = NSSplitViewItem(viewController: pp)
        pi.minimumThickness = 240
        pi.canCollapse = true
        pi.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        pi.holdingPriority = NSLayoutConstraint.Priority(260)
        self.previewItem = pi

        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        addSplitViewItem(si)
        addSplitViewItem(ei)
        addSplitViewItem(pi)

        let sidebarVisible = UserDefaults.standard.object(forKey: Self.sidebarVisibleKey) as? Bool ?? true
        si.isCollapsed = !sidebarVisible
        pi.isCollapsed = true

        // Sidebar opens files via NSDocumentController. Explicitly join THIS
        // window rather than going through the generic `.auto` policy's
        // key/main-window guessing — a sidebar click unambiguously means
        // "open this in the window whose sidebar I clicked."
        sp.onOpen = { [weak self] url in
            guard let dc = NSDocumentController.shared as? DocumentController else { return }
            let policy: DocumentController.WindowJoinPolicy = (self?.view.window).map { .join($0) } ?? .auto
            dc.openDocument(withContentsOf: url, display: true, joinPolicy: policy) { _, _, error in
                if let error { NSLog("[Sourcepad] sidebar open failed: \(url.path) — \(error)") }
            }
        }

        bar.onSelect = { [weak self] doc in self?.activateTab(doc) }
        bar.onClose = { [weak self] doc in self?.requestCloseTab(doc) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    public func setDocumentTabBarVisible(_ visible: Bool) {
        editorColumn.setTabBarVisible(visible)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        documentTabBar.refresh()
        invalidateRestorableState()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Tabs

    /// Opens `document` as a tab in this window (creating its EditorContent
    /// on first open, reusing it if already open here), optionally making it
    /// the active/visible tab.
    @discardableResult
    public func openTab(_ document: TextDocument, activate: Bool = true) -> EditorContent {
        let key = ObjectIdentifier(document)
        if let existing = contentByDocument[key] {
            if activate { activateTab(document) }
            return existing
        }
        let content = EditorContentFactory.makeContent(for: document)
        contentByDocument[key] = content
        openDocuments.append(document)
        // Content types backed by a real NSView (Scintilla in particular)
        // only initialize their view-dependent state — e.g.
        // EditorPaneViewController.sciView, an implicitly-unwrapped optional
        // set inside loadView() — once their view is actually loaded.
        // documentContentsDidLoad() touches that state, so force the view to
        // load first; previously this "just worked" only because the single
        // content instance was already wired into the window's view
        // hierarchy before it was ever asked to load its document.
        if let contentVC = content as? NSViewController {
            editorColumn.addContent(contentVC)
            _ = contentVC.view
        }
        content.documentContentsDidLoad()
        // EditorContent is a class-bound protocol; binding onTextChanged on a
        // `let` reference mutates the underlying instance. Guard against
        // stale callbacks from a since-closed or now-background tab.
        content.onTextChanged = { [weak self, weak document] in
            guard let self, let document, self.activeDocument === document else { return }
            self.schedulePreviewRender(immediate: false)
        }
        documentTabBar.setDocuments(openDocuments, active: activeDocument)
        if activate {
            activateTab(document)
        }
        return content
    }

    /// Makes `document`'s tab the visible one. No-op if it isn't open here.
    public func activateTab(_ document: TextDocument) {
        guard contentByDocument[ObjectIdentifier(document)] != nil else { return }
        activeDocument = document
        showActiveContent()
        documentTabBar.setDocuments(openDocuments, active: document)
        if sidebarPane.workspace.roots.isEmpty, let url = document.fileURL {
            sidebarPane.setRoot(url.deletingLastPathComponent())
        }
        if let url = document.fileURL,
           PreviewRenderer.kind(forFilename: url.lastPathComponent, fallbackLexer: nil) == .image
           || PreviewRenderer.kind(forFilename: url.lastPathComponent, fallbackLexer: nil) == .svg {
            previewItem.isCollapsed = false
        }
        if !previewItem.isCollapsed { schedulePreviewRender(immediate: true) }
        view.window?.toolbar?.validateVisibleItems()
        (view.window?.windowController as? EditorWindowController)?.syncWindowChrome()
        invalidateRestorableState()
    }

    /// Runs the standard NSDocument unsaved-changes prompt for `document`,
    /// then — only if it actually closed — detaches it from this window and
    /// removes its tab. Used by both the tab strip's × and ⌘W (which closes
    /// just the active tab, not the whole window — see RootContentViewController).
    public func requestCloseTab(_ document: TextDocument) {
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)),
                           contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard shouldClose, let textDoc = document as? TextDocument else { return }
        // Detach BEFORE close(): NSDocument's default close() unconditionally
        // closes every window controller still in windowControllers (bypassing
        // windowShouldClose — only performClose consults that delegate
        // method), and every open tab's document shares this ONE window
        // controller. Left attached, closing the last tab would silently
        // force the whole shared window closed out from under any other
        // window state. Detaching first means close() has nothing left to
        // auto-close.
        if let wc = view.window?.windowController as? EditorWindowController {
            textDoc.removeWindowController(wc)
        }
        textDoc.close()
        removeTab(textDoc)
    }

    /// Pure bookkeeping/UI removal of a tab — the caller (a close-tab request,
    /// or the window closing all its documents) is responsible for having
    /// already run any save-prompt and closed the NSDocument itself.
    public func removeTab(_ document: TextDocument) {
        let key = ObjectIdentifier(document)
        guard let content = contentByDocument.removeValue(forKey: key) else { return }
        let wasActive = activeDocument === document
        let index = openDocuments.firstIndex { $0 === document }
        openDocuments.removeAll { $0 === document }
        if let vc = content as? NSViewController {
            editorColumn.removeContent(vc)
        }
        if wasActive {
            let neighbor = index.flatMap { i in openDocuments[safe: min(i, openDocuments.count - 1)] }
            activeDocument = neighbor
            showActiveContent()
        }
        documentTabBar.setDocuments(openDocuments, active: activeDocument)
        view.window?.toolbar?.validateVisibleItems()
        (view.window?.windowController as? EditorWindowController)?.syncWindowChrome()
        invalidateRestorableState()
    }

    private func showActiveContent() {
        let vc: NSViewController
        if let content = activeContent, let contentVC = content as? NSViewController {
            vc = contentVC
        } else {
            vc = noDocumentContent
        }
        editorColumn.setActiveContent(vc)
        view.window?.makeFirstResponder(vc.view)
    }

    /// The pane for a SPECIFIC document, regardless of whether it's the
    /// active/visible tab — used by background operations (agent edits,
    /// goto-line from Find in Files/Outline, LSP actions) that must reach
    /// the right document even when it isn't frontmost.
    public func editorPane(for document: TextDocument) -> EditorPaneViewController? {
        contentByDocument[ObjectIdentifier(document)] as? EditorPaneViewController
    }

    public func currentCaretByte(for document: TextDocument) -> Int {
        contentByDocument[ObjectIdentifier(document)]?.currentCaretByte() ?? 0
    }

    public func documentContentsDidLoad(for document: TextDocument) {
        contentByDocument[ObjectIdentifier(document)]?.documentContentsDidLoad()
        documentTabBar.refresh()
        if document === activeDocument, !previewItem.isCollapsed { schedulePreviewRender(immediate: true) }
        view.window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Methods proxied to the ACTIVE tab's content

    public var currentText: String { activeContent?.currentText ?? "" }
    public func markSavePoint() { activeContent?.markSavePoint() }
    public func setLexer(_ name: String?) {
        activeContent?.setLexer(name)
        if !previewItem.isCollapsed { schedulePreviewRender(immediate: true) }
    }
    public var activeLexer: String? { activeContent?.activeLexer }

    // MARK: - Preview toggle

    public var canShowPreview: Bool {
        guard let doc = activeDocument, let content = activeContent else { return false }
        guard content.supportsPreview else { return false }
        return PreviewRenderer.kind(
            forFilename: doc.fileURL?.lastPathComponent ?? "",
            fallbackLexer: content.activeLexer
        ) != nil
    }

    public var isShowingPreview: Bool { !previewItem.isCollapsed }

    public func togglePreview() {
        guard canShowPreview else {
            NSSound.beep()
            return
        }
        previewItem.animator().isCollapsed = !previewItem.isCollapsed
        if !previewItem.isCollapsed {
            schedulePreviewRender(immediate: true)
        }
        view.window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Sidebar toggle

    public var isShowingSidebar: Bool { !sidebarItem.isCollapsed }

    public func toggleSidebar() {
        sidebarItem.animator().isCollapsed = !sidebarItem.isCollapsed
        UserDefaults.standard.set(!sidebarItem.isCollapsed, forKey: Self.sidebarVisibleKey)
        view.window?.toolbar?.validateVisibleItems()
    }

    public func setSidebarRoot(_ url: URL) {
        sidebarPane.setRoot(url)
        if sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
        }
        view.window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Menu-action entry points (nil-target selectors)

    @objc public func sourcepadToggleSidebar(_ sender: Any?) {
        toggleSidebar()
    }

    @objc public func sourcepadOpenFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setSidebarRoot(url)
        }
    }

    // MARK: - Preview rendering

    private func schedulePreviewRender(immediate: Bool) {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreviewNow() }
        pendingRender = work
        let delay: DispatchTimeInterval = immediate ? .milliseconds(0) : .milliseconds(300)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func renderPreviewNow() {
        guard !previewItem.isCollapsed, let document = activeDocument, let content = activeContent else { return }
        let filename = document.fileURL?.lastPathComponent ?? ""
        guard let kind = PreviewRenderer.kind(forFilename: filename, fallbackLexer: content.activeLexer) else { return }
        let source = content.currentText
        let baseURL = document.fileURL?.deletingLastPathComponent()
        let isDark = ThemeMode.from(view.effectiveAppearance) == .dark
        previewPane.render(source: source, kind: kind, baseURL: baseURL, isDark: isDark,
                           fileURL: document.fileURL)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Editor column (tab strip stacked above the editor content)

/// Stacks `DocumentTabBar` above a swappable editor content area so the tabs
/// render directly over the editor pane. The strip collapses to zero height
/// when hidden, leaving the editor flush to the top.
final class EditorColumnViewController: NSViewController {

    private let tabBar: DocumentTabBar
    private let contentContainer = NSView()
    private var activeContentVC: NSViewController
    private var tabBarHeight: NSLayoutConstraint!
    private static let stripHeight: CGFloat = 34

    init(tabBar: DocumentTabBar, initialContent: NSViewController) {
        self.tabBar = tabBar
        self.activeContentVC = initialContent
        super.init(nibName: nil, bundle: nil)
        addChild(initialContent)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let root = NSView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabBar)
        root.addSubview(contentContainer)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: Self.stripHeight)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBarHeight,
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root
        pin(activeContentVC.view)
    }

    func setTabBarVisible(_ visible: Bool) {
        tabBar.isHidden = !visible
        tabBarHeight.constant = visible ? Self.stripHeight : 0
    }

    /// Registers a content view controller as a child so it's ready to be
    /// shown, without making it visible yet.
    func addContent(_ vc: NSViewController) {
        addChild(vc)
    }

    func removeContent(_ vc: NSViewController) {
        if vc === activeContentVC {
            vc.view.removeFromSuperview()
        }
        vc.removeFromParent()
    }

    /// Swaps which content view is visible in the container.
    func setActiveContent(_ vc: NSViewController) {
        guard vc !== activeContentVC else { return }
        if vc.parent !== self { addChild(vc) }
        activeContentVC.view.removeFromSuperview()
        activeContentVC = vc
        guard isViewLoaded else { return }
        pin(vc.view)
    }

    private func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }
}
