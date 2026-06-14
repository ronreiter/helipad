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

    /// Repos to show. Empty = all repos.
    @Published var selectedRepos: Set<String>

    /// Per-PR nicknames/notes keyed by PR URL.
    @Published var nicknames: [String: String] = [:]

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
    private static let selectedReposKey = "selectedRepos"
    private static let nicknamesKey = "prNicknames"
    private static let notifiedKey = "notifiedBlockedPRs"
    private static let cachedPRsKey = "cachedPRs"
    private static let cachedUpdatedKey = "cachedLastUpdated"

    /// URLs already notified as blocked-on-me; persisted so neither the
    /// periodic refresh nor an app restart fires the same PR twice.
    private var notifiedBlockedURLs: Set<String>
    /// False only on a first-ever run, where the existing backlog of blocked
    /// PRs is seeded silently instead of firing a notification per PR.
    private var notificationsSeeded: Bool
    private var armNotificationsOnNextRefresh = false

    /// Filtered views — kept as stored @Published arrays so SwiftUI body
    /// re-renders (e.g. tab switches) don't re-run the filter+statuses pass
    /// on every PR. Recomputed only when `prs`, `archivedURLs`,
    /// `enabledFilters`, or `selectedRepos` actually change.
    @Published private(set) var activePRs: [PullRequest] = []
    @Published private(set) var blockedOnMePRs: [PullRequest] = []
    @Published private(set) var needsReviewPRs: [PullRequest] = []
    @Published private(set) var archivedPRs: [PullRequest] = []
    @Published private(set) var availableRepos: [String] = []

    /// Cache of `pr.statuses` keyed by URL — cleared whenever `prs` is
    /// replaced. `pr.statuses` is a non-trivial computed (Models.swift:91);
    /// caching avoids 4× rebuilds per PR per render.
    private var statusCache: [String: Set<PullRequest.Status>] = [:]

    /// Cache of `~/GitHub/<repo>` existence keyed by short repo name. Saves a
    /// synchronous stat() per PRRow body evaluation.
    private var folderURLCache: [String: URL?] = [:]

    private func statuses(of pr: PullRequest) -> Set<PullRequest.Status> {
        if let cached = statusCache[pr.url] { return cached }
        let computed = pr.statuses
        statusCache[pr.url] = computed
        return computed
    }

    func localFolder(for pr: PullRequest) -> URL? {
        let key = pr.repoShortName
        if let cached = folderURLCache[key] {
            return cached
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("GitHub")
            .appendingPathComponent(key)
        let result: URL? = FileManager.default.fileExists(atPath: url.path) ? url : nil
        folderURLCache[key] = result
        return result
    }

    private func passesRepo(_ pr: PullRequest) -> Bool {
        selectedRepos.isEmpty || selectedRepos.contains(pr.repository.nameWithOwner)
    }

    /// Rebuild the filtered lists. Call after any change to `prs`,
    /// `archivedURLs`, `enabledFilters`, or `selectedRepos`.
    private func recomputeFilteredLists() {
        let visible = prs.filter { !archivedURLs.contains($0.url) && passesRepo($0) }
        blockedOnMePRs = visible.filter { !statuses(of: $0).isDisjoint(with: PullRequest.Status.blockedOnMe) }
        needsReviewPRs = visible.filter { statuses(of: $0).contains(.needsReview) }
        activePRs = visible.filter { !statuses(of: $0).isDisjoint(with: enabledFilters) }
        archivedPRs = prs.filter { archivedURLs.contains($0.url) && passesRepo($0) }
        availableRepos = Array(Set(prs.map(\.repository.nameWithOwner))).sorted()
    }

    let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        if isDemo {
            archivedURLs = DemoData.archivedURLs
            enabledFilters = Set(PullRequest.Status.allCases)
            selectedRepos = []
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
        selectedRepos = Set(UserDefaults.standard.stringArray(forKey: Self.selectedReposKey) ?? [])
        nicknames = (UserDefaults.standard.dictionary(forKey: Self.nicknamesKey) as? [String: String]) ?? [:]
        hydrateFromCache()
        recomputeFilteredLists()
    }

    /// Repaint last-known PRs immediately on launch so the panel doesn't sit on
    /// "Loading PRs…" for a full network round trip. The pending refresh in
    /// start() overwrites this within ~1s.
    private func hydrateFromCache() {
        if let data = UserDefaults.standard.data(forKey: Self.cachedPRsKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let cached = try? decoder.decode([PullRequest].self, from: data) {
                prs = cached
                hasMore = false  // unknown; loadMore() requires a cursor anyway
            }
        }
        if let date = UserDefaults.standard.object(forKey: Self.cachedUpdatedKey) as? Date {
            lastUpdated = date
        }
    }

    private func persistCache() {
        guard !isDemo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(prs) {
            UserDefaults.standard.set(data, forKey: Self.cachedPRsKey)
        }
        if let lastUpdated {
            UserDefaults.standard.set(lastUpdated, forKey: Self.cachedUpdatedKey)
        }
    }

    func toggleFilter(_ status: PullRequest.Status) {
        if enabledFilters.contains(status) {
            enabledFilters.remove(status)
        } else {
            enabledFilters.insert(status)
        }
        recomputeFilteredLists()
        guard !isDemo else { return }
        UserDefaults.standard.set(enabledFilters.map(\.rawValue), forKey: Self.filtersKey)
    }

    func toggleRepo(_ repo: String) {
        if selectedRepos.contains(repo) {
            selectedRepos.remove(repo)
        } else {
            selectedRepos.insert(repo)
        }
        recomputeFilteredLists()
        persistRepos()
    }

    func showOnlyRepo(_ repo: String) {
        selectedRepos = [repo]
        recomputeFilteredLists()
        persistRepos()
    }

    func showAllRepos() {
        selectedRepos.removeAll()
        recomputeFilteredLists()
        persistRepos()
    }

    private func persistRepos() {
        guard !isDemo else { return }
        if selectedRepos.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.selectedReposKey)
        } else {
            UserDefaults.standard.set(Array(selectedRepos), forKey: Self.selectedReposKey)
        }
    }

    func nickname(for pr: PullRequest) -> String? {
        nicknames[pr.url]
    }

    func setNickname(_ text: String, for pr: PullRequest) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: pr.url)
        } else {
            nicknames[pr.url] = trimmed
        }
        guard !isDemo else { return }
        UserDefaults.standard.set(nicknames, forKey: Self.nicknamesKey)
    }

    func archive(_ pr: PullRequest) {
        archivedURLs.insert(pr.url)
        recomputeFilteredLists()
        persistArchived()
    }

    func unarchive(_ pr: PullRequest) {
        archivedURLs.remove(pr.url)
        recomputeFilteredLists()
        persistArchived()
    }

    /// Single entry point used by PRRow so its action closure doesn't depend
    /// on the current tab — keeps the row Equatable-stable for SwiftUI diffing.
    func toggleArchived(_ pr: PullRequest) {
        if archivedURLs.contains(pr.url) {
            unarchive(pr)
        } else {
            archive(pr)
        }
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
            recomputeFilteredLists()
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    /// Reloads the first page and merges results into the cached list — fresh
    /// fields for known PRs, new PRs prepended, and PRs that *should* have
    /// appeared in page 1 but didn't (merged/closed since last refresh)
    /// dropped. PRs deeper than page 1's cutoff are preserved across refreshes
    /// so the user doesn't snap back to the top each cycle.
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
                    self.mergeFirstPage(search.nodes)
                    self.totalCount = search.issueCount
                    self.cursor = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
                    self.hasMore = self.cursor != nil
                    self.lastUpdated = Date()
                    self.errorMessage = nil
                    self.isLoading = false
                    self.autoFillCount = 0
                    self.notifyNewlyBlocked()
                    self.persistCache()
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

    /// Merge a fresh page-1 response into `self.prs` while preserving deeper
    /// pages already loaded. Strategy: PRs in the freshness window (newer than
    /// or equal to the oldest fresh PR) MUST appear in `fresh` to survive —
    /// otherwise they're merged/closed and we drop them. PRs older than that
    /// window are kept as-is.
    private func mergeFirstPage(_ fresh: [PullRequest]) {
        guard let cutoff = fresh.map(\.updatedAt).min() else {
            // empty result — drop everything in the window (which is everything)
            prs = []
            statusCache.removeAll()
            recomputeFilteredLists()
            return
        }
        // Keep deeper-than-window PRs as-is; in-window PRs come from `fresh`
        // (so missing ones — merged/closed since last refresh — get dropped).
        let preserved = prs.filter { $0.updatedAt < cutoff }
        let merged = fresh + preserved
        // Sort updated-desc to match GitHub's ordering, in case a stale PR's
        // updatedAt now sits between fresh items.
        prs = merged.sorted { $0.updatedAt > $1.updatedAt }
        // Invalidate cached statuses for fresh URLs (their fields just changed).
        for pr in fresh { statusCache.removeValue(forKey: pr.url) }
        recomputeFilteredLists()
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
                    self.recomputeFilteredLists()
                    self.notifyNewlyBlocked()
                    self.persistCache()
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
