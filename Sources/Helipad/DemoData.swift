import Foundation

/// Canned pull requests for `--demo` mode, used to take marketing screenshots
/// without exposing real repository names or PR titles.
enum DemoData {
    static let totalCount = 12

    static var prs: [PullRequest] {
        [
            pr(repo: "acme/acme-web", number: 482,
               title: "feat: add dark mode toggle to settings",
               minutesAgo: 4, ci: "SUCCESS", review: "APPROVED"),
            pr(repo: "acme/payments-service", number: 217,
               title: "fix: retry webhook delivery with exponential backoff",
               minutesAgo: 18, ci: "SUCCESS", review: nil),
            pr(repo: "acme/api-gateway", number: 310,
               title: "fix: rate limiter returns 429 with Retry-After header",
               minutesAgo: 41, ci: "SUCCESS", review: nil, mergeable: "CONFLICTING"),
            pr(repo: "acme/auth-service", number: 88,
               title: "fix: rotate refresh tokens on password change",
               minutesAgo: 52, ci: "SUCCESS", review: "APPROVED", mergeable: "CONFLICTING"),
            pr(repo: "acme/mobile-app", number: 1024,
               title: "feat: offline sync for drafts and pending uploads",
               minutesAgo: 67, ci: "FAILURE", review: "CHANGES_REQUESTED"),
            pr(repo: "acme/infra", number: 91,
               title: "chore: migrate CI pipeline to GitHub Actions",
               minutesAgo: 95, ci: "PENDING", review: nil),
            pr(repo: "acme/docs", number: 58,
               title: "docs: quickstart guide and API authentication examples",
               minutesAgo: 130, ci: "SUCCESS", review: "APPROVED"),
            pr(repo: "acme/search-service", number: 145,
               title: "perf: cache query embeddings, cut p99 latency by 40%",
               minutesAgo: 210, ci: "SUCCESS", review: nil),
        ]
    }

    /// One demo PR lives in the Archived tab so it doesn't show as empty.
    static var archivedURLs: Set<String> {
        ["https://github.com/acme/legacy-cleanup/pull/12"]
    }

    static var archivedPR: PullRequest {
        pr(repo: "acme/legacy-cleanup", number: 12,
           title: "chore: delete unused feature flags",
           minutesAgo: 400, ci: "SUCCESS", review: "APPROVED")
    }

    private static func pr(
        repo: String,
        number: Int,
        title: String,
        minutesAgo: Double,
        ci: String?,
        review: String?,
        mergeable: String = "MERGEABLE"
    ) -> PullRequest {
        PullRequest(
            title: title,
            url: "https://github.com/\(repo)/pull/\(number)",
            number: number,
            isDraft: false,
            reviewDecision: review,
            mergeable: mergeable,
            updatedAt: Date().addingTimeInterval(-minutesAgo * 60),
            repository: .init(nameWithOwner: repo),
            commits: .init(nodes: ci.map { [.init(commit: .init(statusCheckRollup: .init(state: $0)))] } ?? [])
        )
    }
}
