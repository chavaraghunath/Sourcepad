// SPDX-License-Identifier: MIT
// Sourcepad — "Clone Git Repository…" sheet, presented from the Welcome
// window. Collects a remote URL + destination folder, shells GitClone, and
// hands the cloned local folder back to the caller on success.

import AppKit

public final class GitCloneSheet: NSWindowController {

    private let urlField = NSTextField()
    private let destinationLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Cloning…")
    private let cloneButton = NSButton(title: "Clone", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let buttonRow: NSStackView
    private let progressRow: NSStackView

    private var destinationParent: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())

    private var onCloned: ((URL) -> Void)?

    public init() {
        buttonRow = NSStackView()
        progressRow = NSStackView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Clone Git Repository"
        super.init(window: window)
        window.contentViewController = makeContentViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Presents the sheet over `parent`. `onCloned` fires (on the main
    /// queue) with the cloned folder once the clone succeeds; the sheet
    /// dismisses itself either way.
    public func present(over parent: NSWindow, onCloned: @escaping (URL) -> Void) {
        self.onCloned = onCloned
        destinationLabel.stringValue = "In: \(destinationParent.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        guard let sheet = window else { return }
        parent.beginSheet(sheet)
    }

    private func makeContentViewController() -> NSViewController {
        let vc = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 210))

        let urlLabel = NSTextField(labelWithString: "Repository URL")
        urlLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        urlLabel.textColor = .secondaryLabelColor

        urlField.placeholderString = "https://github.com/owner/repo.git"
        urlField.font = .systemFont(ofSize: 13)
        urlField.target = self
        urlField.action = #selector(cloneTapped)

        destinationLabel.font = .systemFont(ofSize: 11.5)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseDestination))
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small

        let destRow = NSStackView(views: [destinationLabel, NSView(), chooseButton])
        destRow.orientation = .horizontal
        destRow.alignment = .centerY

        errorLabel.font = .systemFont(ofSize: 11.5)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"  // Escape

        cloneButton.bezelStyle = .rounded
        cloneButton.target = self
        cloneButton.action = #selector(cloneTapped)
        cloneButton.keyEquivalent = "\r"

        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(cloneButton)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        progressRow.addArrangedSubview(spinner)
        progressRow.addArrangedSubview(statusLabel)
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.isHidden = true

        let content = NSStackView(views: [urlLabel, urlField, destRow, errorLabel, progressRow, buttonRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setCustomSpacing(16, after: destRow)

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 460),
            urlField.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            destRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            destRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        vc.view = root
        return vc
    }

    @objc private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = destinationParent
        guard let sheet = window else { return }
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.destinationParent = url
            self.destinationLabel.stringValue = "In: \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        }
    }

    @objc private func cancelTapped() {
        guard let sheet = window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    @objc private func cloneTapped() {
        let urlString = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        errorLabel.isHidden = true
        guard !urlString.isEmpty else {
            showError("Enter a repository URL.")
            return
        }
        let folderName = GitClone.suggestedFolderName(for: urlString)
        setCloning(true)
        GitClone.clone(remoteURL: urlString, into: destinationParent, folderName: folderName) { [weak self] result in
            guard let self else { return }
            self.setCloning(false)
            switch result {
            case .success(let localURL):
                guard let sheet = self.window, let parent = sheet.sheetParent else { return }
                parent.endSheet(sheet)
                self.onCloned?(localURL)
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }

    private func setCloning(_ cloning: Bool) {
        progressRow.isHidden = !cloning
        buttonRow.isHidden = cloning
        urlField.isEnabled = !cloning
        if cloning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}
