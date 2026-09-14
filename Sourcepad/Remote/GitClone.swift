// SPDX-License-Identifier: MIT
// Sourcepad — shells `git clone` for the Welcome window's "Clone Git
// Repository…" action. Runs off the main thread; reports back on it.

import Foundation

public enum GitClone {

    public enum CloneError: LocalizedError {
        case gitNotFound
        case destinationExists(URL)
        case processFailed(String)

        public var errorDescription: String? {
            switch self {
            case .gitNotFound: return "git was not found on this Mac."
            case .destinationExists(let url): return "\"\(url.lastPathComponent)\" already exists at that location."
            case .processFailed(let output): return output.isEmpty ? "git clone failed." : output
            }
        }
    }

    /// Derives a reasonable local folder name from a clone URL, e.g.
    /// "https://github.com/owner/repo.git" -> "repo".
    public static func suggestedFolderName(for urlString: String) -> String {
        var name = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastSlash = name.lastIndex(of: "/") { name = String(name[name.index(after: lastSlash)...]) }
        if let lastColon = name.lastIndex(of: ":"), !name.contains("/") { name = String(name[name.index(after: lastColon)...]) }
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name.isEmpty ? "repository" : name
    }

    /// Clones `remoteURL` into `<destinationParent>/<folderName>`. Calls
    /// `completion` on the main queue with the resulting local folder URL,
    /// or an error.
    public static func clone(
        remoteURL: String,
        into destinationParent: URL,
        folderName: String,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let target = destinationParent.appendingPathComponent(folderName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            DispatchQueue.main.async { completion(.failure(CloneError.destinationExists(target))) }
            return
        }
        guard let git = AgentExecutable.locate("git") ?? {
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git") ? URL(fileURLWithPath: "/usr/bin/git") : nil
        }() else {
            DispatchQueue.main.async { completion(.failure(CloneError.gitNotFound)) }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = git
            process.arguments = ["clone", "--", remoteURL, target.path]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        completion(.success(target))
                    } else {
                        completion(.failure(CloneError.processFailed(errText)))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
