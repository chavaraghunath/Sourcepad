# Changelog

All notable changes to Sourcepad are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

The version in this file, the `VERSION` file at the repo root, and the app's
`CFBundleShortVersionString` (stamped at build time by
`Sourcepad/Build/build.sh` from `VERSION`) must always agree — that's the
single source of truth for "what version is this build." A git tag `vX.Y.Z`
marks the commit each release was cut from.

## [Unreleased]

Changes merged since `v0.1.0` that haven't been cut into a tagged release yet.

### Changed
- **Replaced native multi-window tab-grouping with real in-window tabs.**
  Every opened file used to get its own `NSWindow`, visually glued to others
  via macOS's `NSWindow.addTabbedWindow` — the root cause of a long run of
  bugs this cycle (wrong workspace assigned, files popping a second window
  before "snapping" into place, a window silently losing its identity and
  becoming unjoinable). A window now genuinely hosts N open documents as
  tabs in one `NSSplitViewController` content area; opening a file never
  creates a second `NSWindow` for an existing window's sake — it only adds
  or activates a tab. `DocumentTabBar` is now a real multi-tab strip
  (click to switch, × to close) instead of a single-document pill, and each
  window opts out of macOS's native window-tab grouping entirely
  (`tabbingMode = .disallowed`). ⌘W closes the active tab; the window itself
  only closes once every open tab's unsaved-changes prompt is resolved.
- Explorer, Editor, and the Agent panel are all visible by default when a
  window opens (previously the agent panel started collapsed, requiring
  ⌃⌘A).

### Added
- Inline `@` file mentions and `/` commands in the agent chat input.
- Agent CLI catalog: install, update, sign-in, and configure supported CLIs
  from Settings.
- Sidebar file tree now refreshes live via FSEvents, plus a manual "Refresh"
  context-menu item.
- `DESIGN.md` and `OPERATIONS.md` reference guides.
- Block-level markdown (headers, bulleted/numbered lists) now renders with
  real styling in agent chat bubbles instead of showing raw `#`/`-` markers
  (`Agent/AgentMarkdown.swift`) — inline styling (bold/italic/code/links) was
  already handled.
- `CHANGELOG.md` and a repo-root `VERSION` file as the canonical version
  record; `build.sh` now stamps the running app's version/build number from
  `VERSION` + commit count instead of a static template value.
- Per-window workspaces: each editor window now has its own folder root(s)
  instead of every window sharing one global active workspace — opening a
  folder in one window no longer changes another window's sidebar.
- `File ▸ Open in New Window…` — explicitly opens a standalone window,
  now that other opens prefer joining an existing one (see below).
- `UX_ROADMAP.md`: internal editor-shell UX gap analysis and prioritized
  follow-up list.
- Welcome window Start section: Open Workspace… (pick a previously-opened
  saved workspace), Clone Git Repository… (URL + destination sheet, shells
  `git clone`), and Sign in to GitHub (hands off to `gh auth login` in
  Terminal). Recent now lists folders/workspaces/clones you've actually
  opened, not individual files — each `Workspace` gained a `lastOpenedAt`
  stamp to drive it.
- A non-document Welcome window (`App/WelcomeWindowController.swift`) shown
  at launch and whenever the last window closes and the Dock icon is
  clicked — icon/title header, tinted-icon Start actions (New File / Open
  File… / Open Folder…) with hover highlighting, a Recent-files list with
  real file icons and abbreviated paths, and a "Learn Sourcepad" column of
  real keyboard shortcuts (Command Palette, Quick Open, Find in Files,
  Terminal, Agent panel, multi-cursor). Replaces the previous "silently
  open a blank Untitled document" launch behavior. Sized up ~35% with a
  consistent SF Symbol icon column (each icon rendered at one common point
  size and centered in a fixed slot, rather than stretched into a fixed
  box) so the "Learn Sourcepad" list reads as one aligned column instead of
  jagged icon placement. Fixed a layout bug where the Start/Recent column
  wasn't picking up the window's left margin (an explicit constraint was
  overriding it).

### Fixed
- New Folder button in directory-open pickers was disabled.
- Find bar controls could clip off the right edge before Replace toggled.
- `codex` exec resume: options are now placed before the `resume` subcommand.
- Opening a file now joins the current (or best-matching, by folder) window
  as a native macOS tab instead of always opening a separate window; closing
  a tab now only closes that tab, not the whole window/session.
- Closing a window no longer silently reopens a blank one behind your back
  (that made the close button look broken); the app now behaves like a
  normal Mac app — it stays running with no windows, and the Dock icon (or
  ⌘N / File ▸ Open) brings a window back on demand.
- "Open Folder…"/"Open Workspace…"/a completed clone no longer show a
  phantom "Untitled" tab at all, even before you open a file — windows can
  now genuinely hold zero documents (a real sidebar/workspace, `NoDocumentContent`
  in the editor area, no tab pill). The first real file you open in that
  workspace promotes the window in place (same frame, same position)
  instead of tab-joining next to a placeholder. (Earlier this session, a
  narrower fix only discarded the placeholder *after* a real file joined —
  this replaces that with the actual fix: no placeholder document is ever
  created.)
- Clicking a file in the sidebar (or Outline/Tasks jump-to, or New File)
  could open it into the wrong window/workspace entirely — it went through
  the generic auto-join policy (guess by key/main window) instead of the
  window the sidebar actually belongs to, which is known unambiguously at
  click time. Now explicit — a sidebar action always joins its own window.
- A window that drops from 2+ native tabs down to exactly 1 (its sibling
  tab closed) now correctly shows a tab strip again instead of going blank
  — closing a tab wasn't re-checking whether the fallback single-tab strip
  needed to reappear.
- Sourcepad's windows now opt out of macOS's own automatic window-state
  restoration (`NSWindow.isRestorable = false`). It was silently replaying
  whatever windows/tabs were open at last quit on the next launch — via a
  completely separate mechanism from Sourcepad's own deliberate session
  restore — bypassing tab-join/workspace resolution and producing
  confusing, hard-to-reproduce window states across relaunches.

## [0.1.0] - 2026-06-17

Baseline release. Native macOS text/code editor: Scintilla/Lexilla engine,
~150-language syntax highlighting with automatic light/dark theming, native
document tabs, find/replace, sidebar file tree, project indexing, an
embedded terminal, and an agent chat panel wired to local (MLX) and external
agent CLIs. See `README.md` for the current feature list and `git log
v0.1.0` for the full commit history leading up to this tag.

[Unreleased]: https://github.com/chavaraghunath/sourcepad/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/chavaraghunath/sourcepad/releases/tag/v0.1.0
