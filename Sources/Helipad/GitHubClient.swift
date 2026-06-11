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
    static let query = """
    query($cursor: String) {
      search(query: "is:pr is:open draft:false author:@me \\"Generated with Claude Code\\" in:body sort:updated-desc", type: ISSUE, first: 50, after: $cursor) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          ... on PullRequest {
            title
            url
            number
            isDraft
            reviewDecision
            mergeable
            updatedAt
            repository { nameWithOwner }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
      }
    }
    """

    static let maxPages = 10

    static func ghPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetchPullRequests() throws -> (total: Int, prs: [PullRequest]) {
        var prs: [PullRequest] = []
        var total = 0
        var cursor: String?

        for _ in 0..<maxPages {
            let search: SearchResponse.Search
            do {
                search = try fetchPage(cursor: cursor)
            } catch {
                // GitHub's search API 502s intermittently; one retry per page
                search = try fetchPage(cursor: cursor)
            }
            prs.append(contentsOf: search.nodes)
            total = search.issueCount
            guard search.pageInfo.hasNextPage, let next = search.pageInfo.endCursor else {
                break
            }
            cursor = next
        }
        return (total, prs)
    }

    private static func fetchPage(cursor: String?) throws -> SearchResponse.Search {
        guard let gh = ghPath() else {
            throw GitHubClientError.ghNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        var arguments = ["api", "graphql", "-f", "query=\(query)"]
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
