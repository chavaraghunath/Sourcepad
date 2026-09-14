# Editor-shell UX roadmap

Internal engineering reference. Sourcepad's shell is modeled on established
code-editor conventions (multi-document tabs, command palette, sidebar,
status bar, panel area); this document records the concrete behaviors those
conventions imply and tracks which ones Sourcepad has versus still needs, so
gaps get closed by design rather than by accident. Product-facing copy still
follows [DESIGN.md §8](DESIGN.md#8-guardrails): describe what a feature
*does*, never which product it resembles — this file is an engineering
reference, not user-facing text.

Priority tiers: **P0** blocks basic daily-driver usability today, **P1** is a
clearly-felt gap for anyone who's used a modern editor, **P2** is polish.

---

## P0 — Multi-document single-window model — DONE (native tab-grouping)

Root cause of UAT items #2/#3: every open path funneled through
`NSDocumentController.openDocument` → `TextDocument.makeWindowControllers()`
→ a brand-new `NSWindow`, and grouping was left to macOS's native
window-tabbing, which only activates under certain System Settings/user
gestures — so a file often opened as a fully separate window, and a tab's
close button called `window.performClose(nil)` on that window's sole
document, i.e. "closing a tab" tore down the whole window.

**Shipped fix**: `DocumentController` now resolves a `WindowJoinPolicy`
(`.auto` / `.join(window)` / `.newWindow`) for every open and explicitly
calls `NSWindow.addTabbedWindow(_:ordered:)` to force-group the new
document's window into the right existing one — this works regardless of
the user's system tabbing preference. `.auto` prefers a window whose
workspace already contains the file's path, falling back to the current
key/frontmost window. Each window's `NSDocument`/save/undo/title machinery
is untouched (still one document per window controller); only the grouping
decision changed, so closing one native tab already correctly closes just
that tab. `File ▸ Open in New Window…` was added since forced joining
otherwise removes the only way to deliberately get a standalone window.

This also surfaced and fixed a deeper gap: Sourcepad had **no per-window
workspace** — `WorkspaceManager.shared.activeWorkspace` was a single
process-wide singleton, so opening a folder in one window changed every open
window's sidebar. Each window now owns its own `Workspace` (folder roots),
threaded through `EditorWindowController` → `EditorViewController` →
`SidebarViewController`; the deep index-dependent subsystems (agent
completions, backlinks, tags, todos, symbol/file search) deliberately keep
one live index that follows window focus rather than running N simultaneous
indexers — see `CHANGELOG.md` [Unreleased] for the full entry.

**Deliberately not built** (would be the next step only if a fully custom,
VS Code-pixel-identical tab strip is wanted beyond native macOS tabs):

- **`EditorGroup`** — one pane owning an ordered tab list + MRU order +
  pinned/preview state + active document, so a window could show its own
  custom pill strip instead of native tabs. `EditorPaneViewController` would
  need to become multi-document: holds `[EditorGroup]`/tab array instead of
  one `weak var document`, switches the visible `SciTextView` content when
  the active tab changes.
- **`DocumentTabBar`** becoming a real multiplexing strip: one pill per open
  document in the group, add/remove without touching the window. Today it
  still shows exactly one pill and is hidden once native tabs exist (see its
  header comment) — that stays correct as long as native tabs are the tab
  UI.
- A second `NSDocument` genuinely needing isolated undo/save state — needs a
  decision on how `NSDocument`'s one-doc-per-window assumption is
  reconciled (likely: one `NSWindowController` hosts multiple
  `NSDocument`s' views, with save/dirty routed per active tab rather than
  per window).
- **Preview tabs**: single-click opens in an italicized, reusable preview tab
  that gets replaced by the next single-click open; double-click (or
  editing) promotes it to a permanent tab. Avoids tab-list churn from fast
  single-click browsing in the sidebar. Native macOS tabs don't have this
  concept — would need a custom strip to get it.

If this is ever wanted, it's a much larger change than the native-tabbing
fix — it touches `Document/TextDocument.swift`,
`Document/DocumentController.swift`, `Editor/EditorPaneViewController.swift`,
`Editor/DocumentTabBar.swift`, and `Editor/EditorWindowController.swift`.
Recommend treating it as its own scoped, reviewed change rather than
default behavior, since the native-tabbing fix already resolves the actual
UAT-reported bugs (separate windows, tab-close tearing down the session).

## P0 — Agent chat markdown (UAT item #1)

Fixed: `Agent/AgentMarkdown.swift` now strips and styles header (`#`…`######`)
and list (`-`/`*`/`+`/`1.`) markers with real size/weight/indentation instead
of leaving them as literal characters. Foundation's
`AttributedString(markdown:)` in `.inlineOnlyPreservingWhitespace` mode
(still used for the remaining inline text) only ever handled bold/italic/
inline-code/links, never block structure — that gap is what UAT saw.

## P1 — Tab strip details (once P0's multi-doc model lands)

- Pin / unpin; separate "sticky" (pin-to-left, icon-only) state.
- Close button: dirty-dot ↔ close-x swap on hover.
- Context menu: Close, Close Others, Close to the Right, Close Saved,
  Close All, Pin/Unpin.
- Drag-to-reorder within a group; drag across groups/windows.
- Overflow: shrink-to-fit width first, scroll as fallback (no dropdown
  needed to match convention — sidebar's file tree is the "all open files"
  view).
- Keyboard: ⌘W close active tab, ⌘⇧T reopen last closed, ⌃Tab / ⌃⇧Tab cycle
  MRU, ⌘1/⌘2/… focus group N (relevant once split groups exist).

## P1 — Sidebar

- Single-click select = open in preview tab (same rule as tab strip);
  double-click promotes to permanent tab.
- Inline rename (F2 or slow second click) instead of a dialog.
- Context menu: New File/Folder, Rename, Copy/Cut/Paste, Copy Path, Copy
  Relative Path, Reveal in Finder, Open in Terminal, Delete.
- Remember scroll position + expanded/collapsed state per workspace across
  restarts (width persistence already exists — verify scroll/expansion
  does too).

## P1 — Status bar

Sourcepad doesn't yet have a persistent status bar. Convention: left
cluster = git branch/dirty state + problem counts (clickable); right
cluster = line:col, indentation, encoding, EOL, language mode — each
independently clickable, opening a picker or jumping focus. This is
high-visibility (scanned constantly) and currently the single most-felt
missing chrome piece after tabs.

## P2 — Discoverability polish

- Command palette (⌘⇧P): fuzzy match + MRU ordering + prefix routing
  (`>` commands, `@` file symbols, `#` workspace symbols, `:` go-to-line) —
  reusing one input surface rather than separate dialogs.
- Breadcrumbs bar above the editor (path + symbol path, each segment a
  sibling-file/symbol dropdown).
- Split editor groups (each with its own independent tab strip/preview/
  pinned state) — depends on the P0 multi-group model already supporting
  >1 `EditorGroup` per window.
- Zen mode, minimap already may exist via Scintilla — verify vs. audit as
  a follow-up rather than assume.

## Explicitly out of scope for this pass

Extension API / third-party status-bar contributions, auxiliary
(detached-tab) windows, multi-cursor/column selection (separate editor-core
concern, not shell chrome).
