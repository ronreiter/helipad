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
    query {
      search(query: "is:pr is:open draft:false author:@me \\"Generated with Claude Code\\" in:body sort:updated-desc", type: ISSUE, first: 50) {
        issueCount
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

    static func ghPath() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func fetchPullRequests() throws -> (total: Int, prs: [PullRequest]) {
        guard let gh = ghPath() else {
            throw GitHubClientError.ghNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "-f", "query=\(query)"]

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
        return (response.data.search.issueCount, response.data.search.nodes)
    }
}
