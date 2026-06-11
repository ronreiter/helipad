import Foundation
import AppKit

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
        let agents = activeAgents()
        let repoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("GitHub/\(pr.repoShortName)").path

        // 1. Background-job registry: each job's state.json lists the PRs it
        //    worked on — the most direct PR-to-session link.
        if let jobID = jobID(linkedTo: marker) {
            if let agent = agents.first(where: { $0.shortID == jobID }) {
                openInTerminal(directory: agent.cwd, command: "claude attach \(agent.shortID)")
            } else {
                // finished job — resume by short ID works from any directory
                openInTerminal(directory: repoDir, command: "claude --resume \(jobID)")
            }
            return
        }

        // 2. A running agent whose transcript mentions the PR.
        if let agent = agents.first(where: { transcriptMentions(agent: $0, marker: marker) }) {
            openInTerminal(directory: agent.cwd, command: "claude attach \(agent.shortID)")
            return
        }

        // 3. Claude Code's own PR-to-session tracking (global, picker fallback).
        openInTerminal(directory: repoDir, command: "claude --from-pr \(pr.url)")
    }

    /// Searches ~/.claude/jobs/<id>/state.json files for a PR link; returns
    /// the most recently active matching job's short ID.
    static func jobID(linkedTo marker: String) -> String? {
        let jobsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs")
        guard let jobs = try? FileManager.default.contentsOfDirectory(atPath: jobsDir.path) else {
            return nil
        }
        var best: (id: String, mtime: Date)?
        for job in jobs {
            let statePath = jobsDir.appendingPathComponent("\(job)/state.json").path
            guard
                let data = FileManager.default.contents(atPath: statePath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let children = json["children"] as? [[String: Any]]
            else { continue }
            let mentionsPR = children.contains {
                ($0["kind"] as? String) == "pr" && (($0["href"] as? String)?.hasSuffix(marker) ?? false)
            }
            guard mentionsPR else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: statePath)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            if best == nil || mtime > best!.mtime {
                best = (job, mtime)
            }
        }
        return best?.id
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
        let escaped = full
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            script = """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "\(escaped)"
                end tell
            end tell
            """
        } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-na", "Ghostty", "--args", "-e", "/bin/zsh", "-ic", full]
            try? open.run()
            return
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        }
        let osascript = Process()
        osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osascript.arguments = ["-e", script]
        try? osascript.run()
    }
}
