import Foundation
import Combine

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PullRequest] = []
    @Published var totalCount: Int = 0
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isLoading = false

    @Published var archivedURLs: Set<String>
    @Published var isLoadingMore = false
    @Published var hasMore = false

    @Published var enabledFilters: Set<PullRequest.Status>

    private var cursor: String?
    private var loadMoreFailures = 0
    private var autoFillCount = 0
    /// Auto-fetch at most this many pages beyond the first per refresh;
    /// deeper pages load only when the user actually scrolls. Keeps the
    /// 5-minute refresh at ~3 API calls instead of draining all pages.
    private static let maxAutoFillPages = 2
    private var timer: Timer?
    static let refreshInterval: TimeInterval = 300
    private static let archivedKey = "archivedPRs"
    private static let filtersKey = "statusFilters"
    private static let notifiedKey = "notifiedBlockedPRs"

    /// URLs already notified as blocked-on-me; persisted so neither the
    /// periodic refresh nor an app restart fires the same PR twice.
    private var notifiedBlockedURLs: Set<String>
    /// False only on a first-ever run, where the existing backlog of blocked
    /// PRs is seeded silently instead of firing a notification per PR.
    private var notificationsSeeded: Bool
    private var armNotificationsOnNextRefresh = false

    /// PRs filtered by the user's custom filter selection ("All PRs" tab).
    var activePRs: [PullRequest] {
        prs.filter { !archivedURLs.contains($0.url) && !$0.statuses.isDisjoint(with: enabledFilters) }
    }

    /// Approved or changes-requested: the ball is in the author's court.
    var blockedOnMePRs: [PullRequest] {
        prs.filter { !archivedURLs.contains($0.url) && !$0.statuses.isDisjoint(with: PullRequest.Status.blockedOnMe) }
    }

    var needsReviewPRs: [PullRequest] {
        prs.filter { !archivedURLs.contains($0.url) && $0.statuses.contains(.needsReview) }
    }

    var archivedPRs: [PullRequest] {
        prs.filter { archivedURLs.contains($0.url) }
    }

    let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        if isDemo {
            archivedURLs = DemoData.archivedURLs
            enabledFilters = Set(PullRequest.Status.allCases)
            notifiedBlockedURLs = []
            notificationsSeeded = true
            return
        }
        let notified = UserDefaults.standard.stringArray(forKey: Self.notifiedKey)
        notifiedBlockedURLs = Set(notified ?? [])
        notificationsSeeded = notified != nil
        // "dismissedPRs" is the legacy key from when archiving was "Remove"
        let stored = UserDefaults.standard.stringArray(forKey: Self.archivedKey)
            ?? UserDefaults.standard.stringArray(forKey: "dismissedPRs")
            ?? []
        archivedURLs = Set(stored)
        if let raw = UserDefaults.standard.stringArray(forKey: Self.filtersKey) {
            enabledFilters = Set(raw.compactMap(PullRequest.Status.init))
        } else {
            enabledFilters = PullRequest.Status.needsAttention
        }
    }

    func toggleFilter(_ status: PullRequest.Status) {
        if enabledFilters.contains(status) {
            enabledFilters.remove(status)
        } else {
            enabledFilters.insert(status)
        }
        guard !isDemo else { return }
        UserDefaults.standard.set(enabledFilters.map(\.rawValue), forKey: Self.filtersKey)
    }

    func archive(_ pr: PullRequest) {
        archivedURLs.insert(pr.url)
        persistArchived()
    }

    func unarchive(_ pr: PullRequest) {
        archivedURLs.remove(pr.url)
        persistArchived()
    }

    private func persistArchived() {
        guard !isDemo else { return }
        UserDefaults.standard.set(Array(archivedURLs), forKey: Self.archivedKey)
    }

    func start() {
        if isDemo {
            prs = DemoData.prs + [DemoData.archivedPR]
            totalCount = DemoData.totalCount
            lastUpdated = Date()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Reloads the first page; further pages load on demand via loadMore().
    func refresh() {
        guard !isLoading, !isDemo else { return }
        if armNotificationsOnNextRefresh {
            notificationsSeeded = true
            armNotificationsOnNextRefresh = false
        }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let search = try GitHubClient.fetchPageWithRetry(cursor: nil)
                await MainActor.run {
                    self.prs = search.nodes
                    self.totalCount = search.issueCount
                    self.cursor = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
                    self.hasMore = self.cursor != nil
                    self.lastUpdated = Date()
                    self.errorMessage = nil
                    self.isLoading = false
                    self.autoFillCount = 0
                    self.notifyNewlyBlocked()
                    self.fillIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    /// Appends the next page (infinite scroll).
    func loadMore() {
        guard !isLoading, !isLoadingMore, !isDemo, let cursor else { return }
        isLoadingMore = true
        Task.detached(priority: .userInitiated) {
            do {
                let search = try GitHubClient.fetchPageWithRetry(cursor: cursor)
                await MainActor.run {
                    let known = Set(self.prs.map(\.url))
                    self.prs.append(contentsOf: search.nodes.filter { !known.contains($0.url) })
                    self.cursor = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
                    self.hasMore = self.cursor != nil
                    self.isLoadingMore = false
                    self.loadMoreFailures = 0
                    self.notifyNewlyBlocked()
                    self.fillIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.isLoadingMore = false
                    // GitHub search 502s in streaks; retry shortly, bounded
                    self.loadMoreFailures += 1
                    if self.loadMoreFailures < 5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            self.fillIfNeeded()
                        }
                    }
                }
            }
        }
    }

    /// Fires one notification per PR newly blocked on the author.
    /// A URL leaves the notified set only when the PR is actually loaded and
    /// no longer blocked (so it can notify again on a future re-block);
    /// mere absence — a refresh resetting to page one, or an unloaded page —
    /// never drops it, which is what prevents duplicate notifications.
    private func notifyNewlyBlocked() {
        let blockedURLs = Set(blockedOnMePRs.map(\.url))
        if !notificationsSeeded {
            // First-ever run: adopt the existing backlog silently. Arm only
            // on the next refresh so the auto-fill pages of this first load
            // seed too instead of notifying.
            notifiedBlockedURLs.formUnion(blockedURLs)
            armNotificationsOnNextRefresh = true
        } else {
            for pr in blockedOnMePRs where !notifiedBlockedURLs.contains(pr.url) {
                Notifier.shared.notifyBlocked(pr)
                notifiedBlockedURLs.insert(pr.url)
            }
            let seenUnblocked = Set(prs.map(\.url)).subtracting(blockedURLs)
            notifiedBlockedURLs.subtract(seenUnblocked)
        }
        UserDefaults.standard.set(Array(notifiedBlockedURLs), forKey: Self.notifiedKey)
    }

    /// Filters can hide most of a page, leaving a tab too short to scroll —
    /// top up a couple of pages automatically; the rest loads on scroll.
    private func fillIfNeeded() {
        guard autoFillCount < Self.maxAutoFillPages else { return }
        if hasMore && min(blockedOnMePRs.count, needsReviewPRs.count, activePRs.count) < 30 {
            autoFillCount += 1
            loadMore()
        }
    }
}
