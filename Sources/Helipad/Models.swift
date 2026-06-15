import Foundation

struct PullRequest: Identifiable, Codable, Equatable {
    /// Equality is by the fields the UI renders — lets `.equatable()` on
    /// PRRow skip rebuilds when a refresh returns the same PR unchanged.
    static func == (lhs: PullRequest, rhs: PullRequest) -> Bool {
        lhs.url == rhs.url
            && lhs.title == rhs.title
            && lhs.isDraft == rhs.isDraft
            && lhs.effectiveReviewDecision == rhs.effectiveReviewDecision
            && lhs.mergeable == rhs.mergeable
            && lhs.updatedAt == rhs.updatedAt
            && lhs.ciState == rhs.ciState
            && lhs.headRefName == rhs.headRefName
    }

    var title: String
    let url: String
    let number: Int
    let isDraft: Bool
    let reviewDecision: String?
    let latestReviews: LatestReviews?
    let mergeable: String?
    let updatedAt: Date
    /// Branch name (GraphQL `headRefName`) — used to parse a Shortcut story
    /// ID (`sc-NNNNN`) for auto-clustering. Optional so cached PRs from
    /// older versions still decode.
    let headRefName: String?
    let repository: Repository
    let commits: Commits

    var id: String { url }

    struct Repository: Codable {
        let nameWithOwner: String
    }

    struct Commits: Codable {
        let nodes: [CommitNode]
    }

    struct CommitNode: Codable {
        let commit: Commit
    }

    struct Commit: Codable {
        let statusCheckRollup: StatusCheckRollup?
    }

    struct StatusCheckRollup: Codable {
        let state: String
    }

    struct LatestReviews: Codable {
        let nodes: [Review]
    }

    struct Review: Codable {
        let state: String
        let author: ReviewAuthor?
    }

    struct ReviewAuthor: Codable {
        let typename: String

        /// Copilot's auto-reviewer (and other bots) comment on essentially
        /// every PR; only humans put the ball back in the author's court.
        var isBot: Bool { typename == "Bot" }

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
        }
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

    /// GitHub's aggregate `reviewDecision` flips to REVIEW_REQUIRED whenever a
    /// required reviewer (e.g. a CODEOWNERS team) is still pending — which
    /// hides a review a human already completed. We classify from the latest
    /// review per human reviewer instead: any completed human review puts the
    /// ball back in the author's court, no matter what other reviews are still
    /// pending. Changes-requested wins over an approval, which wins over a
    /// plain comment; bots are ignored.
    var effectiveReviewDecision: String? {
        let states = Set((latestReviews?.nodes ?? [])
            .filter { $0.author?.isBot != true }
            .map(\.state))
        if states.contains("CHANGES_REQUESTED") { return "CHANGES_REQUESTED" }
        if states.contains("APPROVED") { return "APPROVED" }
        if states.contains("COMMENTED") { return "COMMENTED" }
        return reviewDecision
    }

    enum Status: String, CaseIterable {
        case approved
        case changesRequested
        case commented
        case conflicts
        case ciFailed
        case needsReview
        case ciPending
        case ciPassing

        var label: String {
            switch self {
            case .approved: return "Approved"
            case .changesRequested: return "Changes requested"
            case .commented: return "Commented"
            case .conflicts: return "Conflicts"
            case .ciFailed: return "CI failed"
            case .needsReview: return "Needs review"
            case .ciPending: return "CI running"
            case .ciPassing: return "CI passing"
            }
        }

        /// Statuses that mean the ball is in the author's court.
        static let blockedOnMe: Set<Status> = [.approved, .changesRequested, .commented]

        /// Statuses that mean the PR needs the author's attention.
        static let needsAttention: Set<Status> = [.approved, .changesRequested, .commented]
    }

    var statuses: Set<Status> {
        var result: Set<Status> = []
        switch effectiveReviewDecision {
        case "APPROVED": result.insert(.approved)
        case "CHANGES_REQUESTED": result.insert(.changesRequested)
        case "COMMENTED": result.insert(.commented)
        default: result.insert(.needsReview)
        }
        switch ciState {
        case "SUCCESS": result.insert(.ciPassing)
        case "FAILURE", "ERROR": result.insert(.ciFailed)
        case "PENDING", "EXPECTED": result.insert(.ciPending)
        default: break
        }
        if hasConflicts {
            result.insert(.conflicts)
        }
        return result
    }
}

struct SearchResponse: Codable {
    let data: SearchData

    struct SearchData: Codable {
        let search: Search
    }

    struct Search: Codable {
        let issueCount: Int
        let pageInfo: PageInfo
        let nodes: [PullRequest]
    }

    struct PageInfo: Codable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}
