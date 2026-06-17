import Foundation

enum GitHubClientError: Error, LocalizedError {
    case ghNotFound
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .ghNotFound:
            return "gh CLI not found (install with: brew install gh)"
        case .commandFailed(let message):
            return message
        }
    }
}

struct GitHubClient {
    /// Which set of PRs to query. Separate searches because the Claude-Code
    /// authored filter doesn't apply to PRs by other people that you're
    /// requested to review.
    enum Kind {
        case authored        // PRs I authored via Claude Code
        case reviewRequested // PRs blocking me as a reviewer

        var searchString: String {
            switch self {
            case .authored:
                return #"is:pr is:open draft:false author:@me \"Generated with Claude Code\" in:body sort:updated-desc"#
            case .reviewRequested:
                // `user-review-requested` excludes PRs requested via a team
                // you happen to belong to — only PRs where you are tagged as
                // an individual reviewer count.
                return "is:pr is:open draft:false user-review-requested:@me sort:updated-desc"
            }
        }
    }

    private static func query(for kind: Kind) -> String {
        """
        query($cursor: String) {
          search(query: "\(kind.searchString)", type: ISSUE, first: 25, after: $cursor) {
            issueCount
            pageInfo { hasNextPage endCursor }
            nodes {
              ... on PullRequest {
                title
                url
                number
                isDraft
                reviewDecision
                latestReviews(first: 20) { nodes { state author { __typename } } }
                mergeable
                updatedAt
                headRefName
                repository { nameWithOwner }
                commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
              }
            }
          }
        }
        """
    }

    static let maxPages = 20

    static func ghPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func updateTitle(_ title: String, number: Int, repo: String) throws {
        guard let gh = ghPath() else { throw GitHubClientError.ghNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["pr", "edit", String(number), "--title", title, "--repo", repo]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw GitHubClientError.commandFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Fetches one page, retrying once (GitHub's search API 502s intermittently).
    static func fetchPageWithRetry(kind: Kind = .authored, cursor: String?) throws -> SearchResponse.Search {
        do {
            return try fetchPage(kind: kind, cursor: cursor)
        } catch {
            return try fetchPage(kind: kind, cursor: cursor)
        }
    }

    /// Reference to a PR by `repo` (owner/name) + `number` — enough to look up
    /// `state` without re-running search. Used to verify whether locally-cached
    /// PRs deeper than the freshness window are still open.
    struct PRRef: Hashable {
        let url: String
        let owner: String
        let repo: String
        let number: Int

        init?(url: String, nameWithOwner: String, number: Int) {
            let parts = nameWithOwner.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            self.url = url
            self.owner = String(parts[0])
            self.repo = String(parts[1])
            self.number = number
        }
    }

    /// Returns the subset of `refs` whose PRs are still OPEN on GitHub.
    /// One batched GraphQL call (aliases per ref) instead of N round trips.
    /// On API failure, falls back to keeping all refs — better to show a
    /// stale-but-likely-still-open PR than to wrongly drop a live one.
    static func openURLs(among refs: [PRRef]) -> Set<String> {
        guard !refs.isEmpty else { return [] }
        guard let gh = ghPath() else { return Set(refs.map(\.url)) }

        var pieces: [String] = []
        for (i, ref) in refs.enumerated() {
            pieces.append(
                "r\(i): repository(owner: \"\(ref.owner)\", name: \"\(ref.repo)\") { pullRequest(number: \(ref.number)) { url state } }"
            )
        }
        let query = "query { \(pieces.joined(separator: "\n")) }"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "-f", "query=\(query)"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { return Set(refs.map(\.url)) }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return Set(refs.map(\.url)) }

        // Response shape: { "data": { "r0": { "pullRequest": { "url": "...", "state": "OPEN" } | null }, ... } }
        guard let root = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            return Set(refs.map(\.url))
        }
        var open: Set<String> = []
        for value in data.values {
            guard let repo = value as? [String: Any],
                  let pr = repo["pullRequest"] as? [String: Any],
                  let url = pr["url"] as? String,
                  let state = pr["state"] as? String,
                  state == "OPEN" else { continue }
            open.insert(url)
        }
        return open
    }

    /// Fetches everything (used by --dump).
    static func fetchPullRequests() throws -> (total: Int, prs: [PullRequest]) {
        var prs: [PullRequest] = []
        var total = 0
        var cursor: String?

        for _ in 0..<maxPages {
            let search = try fetchPageWithRetry(cursor: cursor)
            prs.append(contentsOf: search.nodes)
            total = search.issueCount
            guard search.pageInfo.hasNextPage, let next = search.pageInfo.endCursor else {
                break
            }
            cursor = next
        }
        return (total, prs)
    }

    private static func fetchPage(kind: Kind, cursor: String?) throws -> SearchResponse.Search {
        guard let gh = ghPath() else {
            throw GitHubClientError.ghNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        var arguments = ["api", "graphql", "-f", "query=\(query(for: kind))"]
        if let cursor {
            arguments += ["-f", "cursor=\(cursor)"]
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "gh exited with status \(process.terminationStatus)"
            throw GitHubClientError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(SearchResponse.self, from: outputData)
        return response.data.search
    }
}
