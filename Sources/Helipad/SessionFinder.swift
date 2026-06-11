import Foundation

/// Opens the Claude Code session behind a PR.
///
/// If a currently running background agent's transcript mentions the PR, we
/// attach to it live (`claude attach`). Otherwise we defer to Claude Code's
/// own PR-to-session tracking (`claude --from-pr`), which resumes the linked
/// session or opens a search picker.
struct SessionFinder {
    struct ActiveAgent {
        let shortID: String
        let sessionID: String
        let cwd: String
    }

    static func open(for pr: PullRequest) {
        let marker = "\(pr.repository.nameWithOwner)/pull/\(pr.number)"
        if let agent = activeAgents().first(where: { transcriptMentions(agent: $0, marker: marker) }) {
            openInTerminal(directory: agent.cwd, command: "claude attach \(agent.shortID)")
        } else {
            let repoDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("GitHub/\(pr.repoShortName)").path
            openInTerminal(directory: repoDir, command: "claude --from-pr \(pr.url)")
        }
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

    static func activeAgents() -> [ActiveAgent] {
        guard let claude = claudePath() else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["agents", "--json"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard
            let json = try? JSONSerialization.jsonObject(with: output),
            let sessions = json as? [[String: Any]]
        else { return [] }
        return sessions.compactMap { entry in
            guard
                let shortID = entry["id"] as? String,
                let sessionID = entry["sessionId"] as? String,
                let cwd = entry["cwd"] as? String
            else { return nil }
            return ActiveAgent(shortID: shortID, sessionID: sessionID, cwd: cwd)
        }
    }

    /// The transcript lives under the project dir where the session STARTED,
    /// which may differ from the agent's current cwd (e.g. after entering a
    /// worktree) — so scan all project dirs for <session id>.jsonl.
    private static func transcriptPath(sessionID: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else {
            return nil
        }
        for dir in dirs {
            let candidate = projects.appendingPathComponent("\(dir)/\(sessionID).jsonl").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func transcriptMentions(agent: ActiveAgent, marker: String) -> Bool {
        guard let transcript = transcriptPath(sessionID: agent.sessionID) else { return false }

        let grep = Process()
        grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-q", "-F", marker, transcript]
        grep.standardOutput = Pipe()
        grep.standardError = Pipe()
        guard (try? grep.run()) != nil else { return false }
        grep.waitUntilExit()
        return grep.terminationStatus == 0
    }

    static func openInTerminal(directory: String, command: String) {
        let dir = FileManager.default.fileExists(atPath: directory)
            ? directory
            : FileManager.default.homeDirectoryForCurrentUser.path
        let full = "cd '\(dir)' && \(command)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(full.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        try? osascript.run()
    }
}
