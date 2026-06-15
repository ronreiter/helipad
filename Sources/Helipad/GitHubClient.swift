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
                reviewRequests(first: 1) { totalCount }
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
