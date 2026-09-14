// SPDX-License-Identifier: MIT
// Sourcepad — custom NSDocumentController to intercept file opens.
//
// AppKit's default 'odoc' Apple Event handler routes straight to
// NSDocumentController.openDocument(withContentsOf:display:completionHandler:),
// bypassing the app delegate's application(_:open:) entirely for document-based
// apps. Subclassing the controller is the only reliable hook.
//
// A file open never spawns a second NSWindow for an existing window's sake —
// it resolves a target EditorWindowController (by policy) and adds itself as
// an in-window tab there (EditorWindowController.openTab). A brand-new
// NSWindow is only created when no target resolves at all.

import AppKit

@objc(SPDocumentController)
public final class DocumentController: NSDocumentController {

    /// How a newly opened document should relate to existing windows.
    public enum WindowJoinPolicy {
        /// Prefer an existing window whose workspace already contains this
        /// file's path; otherwise join the current key/frontmost Sourcepad
        /// window, if any.
        case auto
        /// Always join this specific window (e.g. a drag-drop target, or a
        /// sidebar click — the window that action unambiguously belongs to).
        case join(NSWindow)
        /// Never join — force a standalone window.
        case newWindow
    }

    /// The active/frontmost document, i.e. the active tab of the key window.
    /// Use this instead of `NSDocumentController.shared.currentDocument`
    /// (and instead of any `NSWindowController.document`) everywhere:
    /// `NSWindowController.document` is a single slot AppKit sets from the
    /// last `addWindowController(_:)` call, so once one EditorWindowController
    /// legitimately hosts several documents as tabs, that slot (and anything
    /// derived from it, including `currentDocument`) reflects whichever
    /// document was opened into the window most recently — not whichever tab
    /// is actually showing.
    public static var activeDocument: TextDocument? {
        (NSApp.keyWindow?.windowController as? EditorWindowController)?.activeDocument
    }

    public override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        openDocument(withContentsOf: url, display: displayDocument, joinPolicy: .auto, completionHandler: completionHandler)
    }

    public func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        joinPolicy: WindowJoinPolicy,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        DebugLog.log("DocumentController.openDocument: \(url.path)")
        // display:false — we always attach/show the window ourselves below,
        // since we need to resolve the join target BEFORE deciding whether a
        // new NSWindow is needed at all (Apple's own display:true path would
        // otherwise call makeWindowControllers() internally before we get a
        // chance to route this into an existing window's tab strip).
        super.openDocument(withContentsOf: url, display: false) { doc, alreadyOpen, error in
            if let error {
                DebugLog.log("  open failed: \(error)")
            } else if let textDoc = doc as? TextDocument {
                DebugLog.log("  opened: \(textDoc) alreadyOpen=\(alreadyOpen) wcCount=\(textDoc.windowControllers.count)")
                DispatchQueue.main.async {
                    if textDoc.windowControllers.isEmpty {
                        Self.attach(textDoc, joinPolicy: joinPolicy, url: url, display: displayDocument)
                    } else if displayDocument, let wc = textDoc.windowControllers.first as? EditorWindowController {
                        wc.activateTab(textDoc)
                        wc.window?.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            completionHandler(doc, alreadyOpen, error)
        }
    }

    /// Attaches a freshly-read, window-less document: joins the resolved
    /// target window as a new tab, or — only when no target resolves —
    /// creates one brand-new window to host it.
    private static func attach(_ doc: TextDocument, joinPolicy: WindowJoinPolicy, url: URL, display: Bool) {
        if let targetWC = resolveTarget(for: url, joinPolicy: joinPolicy, excluding: nil) {
            doc.addWindowController(targetWC)
            targetWC.openTab(doc, activate: display)
            DebugLog.log("  attach: opened \(url.lastPathComponent) as a tab in \(String(describing: targetWC.window))")
            if display {
                targetWC.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let workspace = resolveWorkspace(for: url, joinPolicy: joinPolicy)
        let wc = EditorWindowController(workspace: workspace)
        doc.addWindowController(wc)
        wc.openTab(doc, activate: true)
        wc.showWindow(nil)
        DebugLog.log("  attach: no target found for \(url.lastPathComponent), opened a new window")
        if display {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// File > Reopen Closed Tab (⌘⇧T). Pops the most recently closed URL
    /// and re-opens it. Disabled when history is empty.
    @objc public func sourcepadReopenClosedTab(_ sender: Any?) {
        guard let url = ClosedTabHistory.shared.popLatest() else {
            NSSound.beep()
            return
        }
        openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { DebugLog.log("reopen closed tab failed: \(url.path) — \(error)") }
        }
    }

    /// File > Open in New Window… — bypasses tab-joining entirely, since
    /// forcing every open into an existing window's tab strip otherwise
    /// removes the only way to deliberately get a standalone window.
    @objc public func sourcepadOpenInNewWindow(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                self.openDocument(withContentsOf: url, display: true, joinPolicy: .newWindow) { _, _, error in
                    if let error { DebugLog.log("open in new window failed: \(url.path) — \(error)") }
                }
            }
        }
    }

    // MARK: - Window-join resolution

    private static func existingEditorWindowControllers() -> [EditorWindowController] {
        NSApp.windows.compactMap { $0.windowController as? EditorWindowController }
    }

    /// A window "contains" `url` when one of its workspace roots is `url`
    /// itself or an ancestor directory of it.
    private static func windowContaining(_ url: URL, excluding: NSWindow?) -> EditorWindowController? {
        let std = url.standardizedFileURL.path
        return existingEditorWindowControllers().first { wc in
            guard wc.window !== excluding else { return false }
            return wc.workspace.roots.contains { root in
                let rootPath = root.standardizedFileURL.path
                return std == rootPath || std.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            }
        }
    }

    /// Resolves the window a new open should join, per policy. `excluding` is
    /// the new document's own window, when one already exists (never true
    /// anymore before attach() — kept for API symmetry / future callers).
    private static func resolveTarget(for url: URL, joinPolicy: WindowJoinPolicy, excluding: NSWindow?) -> EditorWindowController? {
        switch joinPolicy {
        case .newWindow:
            return nil
        case .join(let w):
            guard w !== excluding else { return nil }
            guard let wc = w.windowController as? EditorWindowController else {
                DebugLog.log("  resolveTarget(.join): w.windowController is \(String(describing: w.windowController)), not an EditorWindowController")
                return nil
            }
            return wc
        case .auto:
            if let match = windowContaining(url, excluding: excluding) { return match }
            if let key = NSApp.keyWindow, key !== excluding, let wc = key.windowController as? EditorWindowController { return wc }
            if let main = NSApp.mainWindow, main !== excluding, let wc = main.windowController as? EditorWindowController { return wc }
            return existingEditorWindowControllers().first { $0.window !== excluding }
        }
    }

    private static func resolveWorkspace(for url: URL, joinPolicy: WindowJoinPolicy) -> Workspace {
        resolveTarget(for: url, joinPolicy: joinPolicy, excluding: nil)?.workspace
            ?? WorkspaceManager.shared.activeWorkspace
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(sourcepadReopenClosedTab(_:)) {
            return ClosedTabHistory.shared.hasEntries
        }
        return super.validateMenuItem(menuItem)
    }
}
