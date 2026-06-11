import Foundation

struct PullRequest: Identifiable, Decodable {
    let title: String
    let url: String
    let number: Int
    let isDraft: Bool
    let reviewDecision: String?
    let reviewRequests: ReviewRequests?
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

    struct ReviewRequests: Decodable {
        let totalCount: Int
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

    /// reviewDecision stays CHANGES_REQUESTED after the author re-requests a
    /// review; a pending review request means the ball is back with the
    /// reviewer, so treat it as needing review.
    var effectiveReviewDecision: String? {
        if reviewDecision == "CHANGES_REQUESTED", (reviewRequests?.totalCount ?? 0) > 0 {
            return "REVIEW_REQUIRED"
        }
        return reviewDecision
    }

    enum Status: String, CaseIterable {
        case approved
        case changesRequested
        case conflicts
        case ciFailed
        case needsReview
        case ciPending
        case ciPassing

        var label: String {
            switch self {
            case .approved: return "Approved"
            case .changesRequested: return "Changes requested"
            case .conflicts: return "Conflicts"
            case .ciFailed: return "CI failed"
            case .needsReview: return "Needs review"
            case .ciPending: return "CI running"
            case .ciPassing: return "CI passing"
            }
        }

        /// Statuses that mean the ball is in the author's court.
        static let blockedOnMe: Set<Status> = [.approved, .changesRequested]

        /// Statuses that mean the PR needs the author's attention.
        static let needsAttention: Set<Status> = [.approved, .changesRequested]
    }

    var statuses: Set<Status> {
        var result: Set<Status> = []
        switch effectiveReviewDecision {
        case "APPROVED": result.insert(.approved)
        case "CHANGES_REQUESTED": result.insert(.changesRequested)
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
