import Foundation

struct PullRequest: Identifiable, Decodable {
    let title: String
    let url: String
    let number: Int
    let isDraft: Bool
    let reviewDecision: String?
    let mergeable: String?
    let updatedAt: Date
    let repository: Repository
    let commits: Commits

    var id: String { url }

    struct Repository: Decodable {
        let nameWithOwner: String
    }

    struct Commits: Decodable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Decodable {
        let commit: Commit
    }

    struct Commit: Decodable {
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Decodable {
        let state: String
    }

    var repoShortName: String {
        repository.nameWithOwner.split(separator: "/").last.map(String.init) ?? repository.nameWithOwner
    }

    var ciState: String? {
        commits.nodes.first?.commit.statusCheckRollup?.state
    }

    var hasConflicts: Bool {
        mergeable == "CONFLICTING"
    }
}

struct SearchResponse: Decodable {
    let data: SearchData

    struct SearchData: Decodable {
        let search: Search
    }

    struct Search: Decodable {
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [PullRequest]
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}
