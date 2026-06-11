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

    static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True if the session is currently running as a background agent
    /// (those can't be resumed directly — they're attached via `claude agents`).
    static func isActiveBackgroundAgent(_ session: Session) -> Bool {
        guard let claude = claudePath() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["agents", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            let json = try? JSONSerialization.jsonObject(with: output),
            let sessions = json as? [[String: Any]]
        else { return false }
        return sessions.contains { $0["sessionId"] as? String == session.id }
    }

    static func openInTerminal(_ session: Session) {
        let dir = FileManager.default.fileExists(atPath: session.cwd)
            ? session.cwd
            : FileManager.default.homeDirectoryForCurrentUser.path
        let claudeCommand = isActiveBackgroundAgent(session)
            ? "claude agents"
            : "claude --resume \(session.id)"
        let command = "cd '\(dir)' && \(claudeCommand)"
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
