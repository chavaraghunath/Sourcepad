// SPDX-License-Identifier: MIT
// Sourcepad — GitHub sign-in via the `gh` CLI.
//
// `gh auth login` is an interactive, arrow-key-driven prompt — not something
// worth reimplementing as a native flow. We just resolve `gh` (same PATH
// probing the agent CLIs use) and hand off to a real Terminal.app window so
// the user completes the normal `gh` device/browser flow themselves.

import AppKit

public enum GitHubAuth {

    public static func locateGH() -> URL? {
        AgentExecutable.locate("gh")
    }

    public static var isSignedIn: Bool {
        guard let gh = locateGH() else { return false }
        let p = Process()
        p.executableURL = gh
        p.arguments = ["auth", "status"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Opens Terminal.app running `gh auth login` so the user can complete
    /// the interactive sign-in flow. Falls back to an install prompt when
    /// `gh` isn't found.
    public static func signIn(presentingFrom window: NSWindow?) {
        guard let gh = locateGH() else {
            presentInstallPrompt(from: window)
            return
        }
        let script = "tell application \"Terminal\"\n" +
            "  activate\n" +
            "  do script \"\(gh.path) auth login\"\n" +
            "end tell"
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            DebugLog.log("GitHubAuth: failed to open Terminal for gh auth login — \(error)")
        }
    }

    private static func presentInstallPrompt(from window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "GitHub CLI Not Found"
        alert.informativeText = "Sourcepad uses the GitHub CLI (gh) to sign you in. Install it with Homebrew, then try again:\n\nbrew install gh"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Install Command")
        alert.addButton(withTitle: "OK")
        let respond: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install gh", forType: .string)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }
}
