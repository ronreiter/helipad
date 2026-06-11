import Foundation

/// Locates the local Claude Code session that worked on a PR by searching
/// ~/.claude/projects transcripts for the PR's URL path, then opens it in
/// Terminal via `claude --resume`.
struct SessionFinder {
    struct Session {
        let id: String
        let cwd: String
    }

    static func findSession(for pr: PullRequest) -> Session? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")
        let repoPath = home.appendingPathComponent("GitHub/\(pr.repoShortName)").path
        let encodedPrefix = repoPath.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return nil
        }
        let candidateDirs = entries
            .filter { $0.hasPrefix(encodedPrefix) }
            .map { projectsDir.appendingPathComponent($0).path }
        guard !candidateDirs.isEmpty else { return nil }

        let marker = "\(pr.repository.nameWithOwner)/pull/\(pr.number)"
        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-rl", "-F", "--include=*.jsonl", marker] + candidateDirs
        let stdout = Pipe()
        grep.standardOutput = stdout
        grep.standardError = Pipe()
        guard (try? grep.run()) != nil else { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        grep.waitUntilExit()

        let files = String(data: output, encoding: .utf8)?
            .split(separator: "\n")
            .map(String.init) ?? []
        guard !files.isEmpty else { return nil }

        // Most recently modified transcript = the session currently on it
        guard let file = files.max(by: { mtime($0) < mtime($1) }) else { return nil }

        let sessionID = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        let cwd = sessionCwd(transcript: file) ?? repoPath
        return Session(id: sessionID, cwd: cwd)
    }

    private static func mtime(_ path: String) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date ?? .distantPast
    }

    /// Reads the session's working directory from the transcript's "cwd" field.
    private static func sessionCwd(transcript: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 256 * 1024)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        guard let range = text.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(text[range])
        return match
            .replacingOccurrences(of: "\"cwd\":\"", with: "")
            .replacingOccurrences(of: "\"", with: "")
    }

    static func openInTerminal(_ session: Session) {
        let dir = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd
            : FileManager.default.homeDirectoryForCurrentUser.path
        let command = "cd '\(dir)' && claude --resume \(session.id)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        try? osascript.run()
    }
}
