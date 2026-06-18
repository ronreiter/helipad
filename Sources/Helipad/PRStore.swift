import Foundation
import Combine

/// Stable identifier for a PR cluster. A cluster's signal is recovered from
/// either the PR's branch name (Shortcut story ID) or the Claude Code session
/// it was opened from.
enum ClusterID: Hashable, Codable {
    case shortcut(String)    // normalized lowercase "sc-71872"
    case branchName(String)  // exact branch name (cross-repo match)
    case session(String)     // 8-char `daemonShort` from ~/.claude/jobs/*/state.json

    /// String key used for UserDefaults persistence of user-given names.
    var key: String {
        switch self {
        case .shortcut(let s):   return "sc:\(s)"
        case .branchName(let b): return "branch:\(b)"
        case .session(let s):    return "session:\(s)"
        }
    }
}

struct Cluster: Identifiable {
    let id: ClusterID
    let displayName: String
    let prs: [PullRequest]
}

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PullRequest] = []
    /// PRs where the user is a requested reviewer — "I'm blocking" tab.
    /// Fetched in parallel with `prs` on each refresh.
    @Published private(set) var prsToReview: [PullRequest] = []
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
    /// Titles as fetched from GitHub before any local rename, keyed by PR URL.
    @Published var originalTitles: [String: String] = [:]

    /// When true, the list view groups PRs into collapsible cluster sections
    /// instead of rendering flat.
    @Published var groupByCluster: Bool

    /// User-given cluster names (key = ClusterID.key, value = display name).
    @Published var clusterNames: [String: String]

    /// User-chosen accent hue per cluster (0..1). Missing key = hash-based default.
    @Published var clusterColors: [String: Double]

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
    private static let originalTitlesKey = "originalTitles"
    private static let notifiedKey = "notifiedBlockedPRs"
    private static let notifiedReviewKey = "notifiedReviewPRs"
    private static let alertReviewKey = "alertOnReviewRequested"
    private static let alertApprovedKey = "alertOnApproved"
    private static let alertChangesKey = "alertOnChangesRequested"
    private static let alertCommentedKey = "alertOnCommented"
    private static let cachedPRsKey = "cachedPRs"
    private static let cachedReviewPRsKey = "cachedReviewPRs"
    private static let cachedUpdatedKey = "cachedLastUpdated"
    private static let groupByClusterKey = "groupByCluster"
    private static let clusterNamesKey = "clusterNames"
    private static let clusterColorsKey = "clusterColors"

    /// PR URL → Claude Code session info, rebuilt from ~/.claude/jobs/*/state.json.
    private struct SessionInfo {
        let id: String         // 8-char daemonShort
        let name: String?      // user-set name from the registry
    }
    private var sessionByURL: [String: SessionInfo] = [:]

    /// URLs already notified as blocked-on-me; persisted so neither the
    /// periodic refresh nor an app restart fires the same PR twice.
    private var notifiedBlockedURLs: Set<String>
    /// False only on a first-ever run, where the existing backlog of blocked
    /// PRs is seeded silently instead of firing a notification per PR.
    private var notificationsSeeded: Bool
    private var armNotificationsOnNextRefresh = false

    /// URLs already notified as awaiting-my-review (the "Blocking" tab). Kept
    /// separate from `notifiedBlockedURLs`, under its own key, so the existing
    /// review backlog seeds silently on the first run *after this feature ships*
    /// instead of firing one alert per PR already awaiting review.
    private var notifiedReviewURLs: Set<String>
    private var reviewNotificationsSeeded: Bool
    private var armReviewNotificationsOnNextRefresh = false

    /// Which events post a macOS notification. All default on; toggled from the
    /// menu-bar Notifications submenu.
    @Published private(set) var alertOnReviewRequested: Bool
    @Published private(set) var alertOnApproved: Bool
    @Published private(set) var alertOnChangesRequested: Bool
    @Published private(set) var alertOnCommented: Bool

    /// Filtered views — kept as stored @Published arrays so SwiftUI body
    /// re-renders (e.g. tab switches) don't re-run the filter+statuses pass
    /// on every PR. Recomputed only when `prs`, `archivedURLs`,
    /// `enabledFilters`, or `selectedRepos` actually change.
    @Published private(set) var activePRs: [PullRequest] = []
    @Published private(set) var blockedOnMePRs: [PullRequest] = []
    @Published private(set) var needsReviewPRs: [PullRequest] = []
    @Published private(set) var imBlockingPRs: [PullRequest] = []
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

    /// Walk ~/.claude/jobs/*/state.json and build PR-URL → session map. Cheap
    /// (a few dozen small JSON files); called on every refresh so newly opened
    /// sessions show up automatically.
    private func reloadJobsRegistry() {
        sessionByURL.removeAll()
        let jobsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: jobsDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        for entry in entries {
            let stateFile = entry.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let short = json["daemonShort"] as? String else { continue }
            let name = json["name"] as? String
            let children = json["children"] as? [[String: Any]] ?? []
            for child in children {
                guard (child["kind"] as? String) == "pr",
                      let href = child["href"] as? String else { continue }
                sessionByURL[href] = SessionInfo(id: short, name: name)
            }
        }
    }

    /// Detect a Shortcut story ID anywhere in the branch name (case-insensitive).
    private func shortcutID(from branch: String?) -> String? {
        guard let branch else { return nil }
        guard let range = branch.range(
            of: #"sc-\d+"#,
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        return branch[range].lowercased()
    }

    /// Per-call helper used inside `cluster(_:)` once we know which branch
    /// names recur. Signal order: sc-id (most intentional, cross-repo by
    /// definition) → repeated branch name (cross-repo same-name match) → CC
    /// session.
    private func clusterID(of pr: PullRequest, branchCounts: [String: Int]) -> ClusterID? {
        if let sc = shortcutID(from: pr.headRefName) {
            return .shortcut(sc)
        }
        if let branch = pr.headRefName, (branchCounts[branch] ?? 0) >= 2 {
            return .branchName(branch)
        }
        if let info = sessionByURL[pr.url] {
            return .session(info.id)
        }
        return nil
    }

    private func defaultClusterName(for id: ClusterID, members: [PullRequest]) -> String {
        let first = members.first
        switch id {
        case .shortcut(let sc):
            if let title = first?.title {
                return "[\(sc)] \(title)"
            }
            return "[\(sc)]"
        case .branchName(let branch):
            if let title = first?.title {
                return "\(branch) — \(title)"
            }
            return branch
        case .session(let short):
            // Prefer the user's name from the CC registry if present.
            if let info = members.lazy.compactMap({ self.sessionByURL[$0.url] }).first,
               let name = info.name, !name.isEmpty {
                return "[\(short)] \(name)"
            }
            if let title = first?.title {
                return "[session \(short)] \(title)"
            }
            return "[session \(short)]"
        }
    }

    /// Group PRs into (named clusters of size ≥ 2) + (solos, in original
    /// order). Singletons fall through to the solo list — a cluster needs
    /// siblings to be worth a section header.
    func cluster(_ prs: [PullRequest]) -> (groups: [Cluster], solos: [PullRequest]) {
        // Tally non-sc-id branch names so we can detect cross-repo matches
        // (e.g. `feat/access-repartition` in two different repos).
        var branchCounts: [String: Int] = [:]
        for pr in prs {
            if let branch = pr.headRefName, shortcutID(from: branch) == nil {
                branchCounts[branch, default: 0] += 1
            }
        }
        var byID: [ClusterID: [PullRequest]] = [:]
        var unclustered: [PullRequest] = []
        for pr in prs {
            if let id = clusterID(of: pr, branchCounts: branchCounts) {
                byID[id, default: []].append(pr)
            } else {
                unclustered.append(pr)
            }
        }
        var solos = unclustered
        var groups: [Cluster] = []
        for (id, members) in byID {
            if members.count < 2 {
                solos.append(contentsOf: members)
                continue
            }
            let sorted = members.sorted { $0.updatedAt > $1.updatedAt }
            let name = clusterNames[id.key] ?? defaultClusterName(for: id, members: sorted)
            groups.append(Cluster(id: id, displayName: name, prs: sorted))
        }
        groups.sort { ($0.prs.first?.updatedAt ?? .distantPast) > ($1.prs.first?.updatedAt ?? .distantPast) }
        solos.sort { $0.updatedAt > $1.updatedAt }
        return (groups, solos)
    }

    func renameCluster(_ id: ClusterID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clusterNames.removeValue(forKey: id.key)
        } else {
            clusterNames[id.key] = trimmed
        }
        persistClusterNames()
    }

    /// Set the accent hue (0..1) for a cluster, or nil to reset to the
    /// hash-based default.
    func setClusterColor(_ id: ClusterID, hue: Double?) {
        if let hue {
            clusterColors[id.key] = hue
        } else {
            clusterColors.removeValue(forKey: id.key)
        }
        guard !isDemo else { return }
        if clusterColors.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.clusterColorsKey)
        } else {
            UserDefaults.standard.set(clusterColors, forKey: Self.clusterColorsKey)
        }
    }

    /// Hue (0..1) for a cluster — user-chosen if set, else green default.
    func clusterHue(_ id: ClusterID) -> Double {
        clusterColors[id.key] ?? 0.33
    }

    func toggleGroupByCluster() {
        groupByCluster.toggle()
        guard !isDemo else { return }
        UserDefaults.standard.set(groupByCluster, forKey: Self.groupByClusterKey)
    }

    func setAlertOnReviewRequested(_ on: Bool) {
        alertOnReviewRequested = on
        guard !isDemo else { return }
        UserDefaults.standard.set(on, forKey: Self.alertReviewKey)
    }

    func setAlertOnApproved(_ on: Bool) {
        alertOnApproved = on
        guard !isDemo else { return }
        UserDefaults.standard.set(on, forKey: Self.alertApprovedKey)
    }

    func setAlertOnChangesRequested(_ on: Bool) {
        alertOnChangesRequested = on
        guard !isDemo else { return }
        UserDefaults.standard.set(on, forKey: Self.alertChangesKey)
    }

    func setAlertOnCommented(_ on: Bool) {
        alertOnCommented = on
        guard !isDemo else { return }
        UserDefaults.standard.set(on, forKey: Self.alertCommentedKey)
    }

    private func persistClusterNames() {
        guard !isDemo else { return }
        UserDefaults.standard.set(clusterNames, forKey: Self.clusterNamesKey)
    }

    /// Rebuild the filtered lists. Call after any change to `prs`,
    /// `archivedURLs`, `enabledFilters`, or `selectedRepos`.
    private func recomputeFilteredLists() {
        let visible = prs.filter { !archivedURLs.contains($0.url) && passesRepo($0) }
        blockedOnMePRs = visible.filter { !statuses(of: $0).isDisjoint(with: PullRequest.Status.blockedOnMe) }
        needsReviewPRs = visible.filter { statuses(of: $0).contains(.needsReview) }
        activePRs = visible.filter { !statuses(of: $0).isDisjoint(with: enabledFilters) }
        // "I'm blocking" honors archive + repo filters; status filter is bypassed
        // (these PRs are already specifically awaiting your review).
        imBlockingPRs = prsToReview.filter { !archivedURLs.contains($0.url) && passesRepo($0) }
        // Archived tab unions archived PRs from both sources so archive works
        // regardless of which tab the PR came from.
        archivedPRs = (prs + prsToReview).filter { archivedURLs.contains($0.url) && passesRepo($0) }
        availableRepos = Array(Set((prs + prsToReview).map(\.repository.nameWithOwner))).sorted()
    }

    let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        if isDemo {
            archivedURLs = DemoData.archivedURLs
            enabledFilters = Set(PullRequest.Status.allCases)
            selectedRepos = []
            groupByCluster = false
            clusterNames = [:]
            clusterColors = [:]
            notifiedBlockedURLs = []
            notificationsSeeded = true
            notifiedReviewURLs = []
            reviewNotificationsSeeded = true
            alertOnReviewRequested = true
            alertOnApproved = true
            alertOnChangesRequested = true
            alertOnCommented = true
            return
        }
        let notified = UserDefaults.standard.stringArray(forKey: Self.notifiedKey)
        notifiedBlockedURLs = Set(notified ?? [])
        notificationsSeeded = notified != nil
        let notifiedReview = UserDefaults.standard.stringArray(forKey: Self.notifiedReviewKey)
        notifiedReviewURLs = Set(notifiedReview ?? [])
        reviewNotificationsSeeded = notifiedReview != nil
        alertOnReviewRequested = UserDefaults.standard.object(forKey: Self.alertReviewKey) as? Bool ?? true
        alertOnApproved = UserDefaults.standard.object(forKey: Self.alertApprovedKey) as? Bool ?? true
        alertOnChangesRequested = UserDefaults.standard.object(forKey: Self.alertChangesKey) as? Bool ?? true
        alertOnCommented = UserDefaults.standard.object(forKey: Self.alertCommentedKey) as? Bool ?? true
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
        originalTitles = (UserDefaults.standard.dictionary(forKey: Self.originalTitlesKey) as? [String: String]) ?? [:]
        groupByCluster = UserDefaults.standard.bool(forKey: Self.groupByClusterKey)
        clusterNames = (UserDefaults.standard.dictionary(forKey: Self.clusterNamesKey) as? [String: String]) ?? [:]
        clusterColors = (UserDefaults.standard.dictionary(forKey: Self.clusterColorsKey) as? [String: Double]) ?? [:]
        hydrateFromCache()
        reloadJobsRegistry()
        recomputeFilteredLists()
    }

    /// Repaint last-known PRs immediately on launch so the panel doesn't sit on
    /// "Loading PRs…" for a full network round trip. The pending refresh in
    /// start() overwrites this within ~1s.
    private func hydrateFromCache() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: Self.cachedPRsKey),
           let cached = try? decoder.decode([PullRequest].self, from: data) {
            prs = cached
            hasMore = false  // unknown; loadMore() requires a cursor anyway
        }
        if let data = UserDefaults.standard.data(forKey: Self.cachedReviewPRsKey),
           let cached = try? decoder.decode([PullRequest].self, from: data) {
            prsToReview = cached
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
        if let data = try? encoder.encode(prsToReview) {
            UserDefaults.standard.set(data, forKey: Self.cachedReviewPRsKey)
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

    func originalTitle(for pr: PullRequest) -> String? {
        originalTitles[pr.url]
    }

    func renameTitle(_ newTitle: String, for pr: PullRequest) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != pr.title else { return }
        if originalTitles[pr.url] == nil {
            originalTitles[pr.url] = pr.title
            UserDefaults.standard.set(originalTitles, forKey: Self.originalTitlesKey)
        }
        if let index = prs.firstIndex(where: { $0.url == pr.url }) {
            prs[index].title = trimmed
            statusCache.removeValue(forKey: pr.url)
            recomputeFilteredLists()
            persistCache()
        }
        Task.detached(priority: .userInitiated) {
            try? GitHubClient.updateTitle(trimmed, number: pr.number, repo: pr.repository.nameWithOwner)
        }
    }

    func clearTitleRename(for pr: PullRequest) {
        guard let original = originalTitles[pr.url] else { return }
        originalTitles.removeValue(forKey: pr.url)
        UserDefaults.standard.set(originalTitles, forKey: Self.originalTitlesKey)
        if let index = prs.firstIndex(where: { $0.url == pr.url }) {
            prs[index].title = original
            statusCache.removeValue(forKey: pr.url)
            recomputeFilteredLists()
            persistCache()
        }
        Task.detached(priority: .userInitiated) {
            try? GitHubClient.updateTitle(original, number: pr.number, repo: pr.repository.nameWithOwner)
        }
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
        if armReviewNotificationsOnNextRefresh {
            reviewNotificationsSeeded = true
            armReviewNotificationsOnNextRefresh = false
        }
        isLoading = true
        let cachedPRs = self.prs
        Task.detached(priority: .userInitiated) {
            // Fire both queries in parallel — they're independent searches.
            async let authored: SearchResponse.Search? = try? GitHubClient.fetchPageWithRetry(kind: .authored, cursor: nil)
            async let review:   SearchResponse.Search? = try? GitHubClient.fetchPageWithRetry(kind: .reviewRequested, cursor: nil)
            let authoredResult = await authored
            let reviewResult = await review

            // Verify the open state of any cached PR not in fresh page 1.
            // Without this, closed/merged PRs deeper than the freshness window
            // stick forever — the `is:open` search just omits them, which on
            // its own is indistinguishable from "still open but pushed below
            // the page-1 cutoff" inside mergeFirstPage.
            let stillOpenURLs: Set<String> = {
                guard let search = authoredResult else { return Set(cachedPRs.map(\.url)) }
                let freshURLs = Set(search.nodes.map(\.url))
                let candidates = cachedPRs
                    .filter { !freshURLs.contains($0.url) }
                    .compactMap { GitHubClient.PRRef(url: $0.url, nameWithOwner: $0.repository.nameWithOwner, number: $0.number) }
                guard !candidates.isEmpty else { return freshURLs }
                return freshURLs.union(GitHubClient.openURLs(among: candidates))
            }()

            await MainActor.run {
                self.reloadJobsRegistry()
                if let search = authoredResult {
                    self.mergeFirstPage(search.nodes,
                                        hasNextPage: search.pageInfo.hasNextPage,
                                        stillOpen: stillOpenURLs)
                    self.totalCount = search.issueCount
                    self.cursor = search.pageInfo.hasNextPage ? search.pageInfo.endCursor : nil
                    self.hasMore = self.cursor != nil
                    self.errorMessage = nil
                } else {
                    self.errorMessage = "Couldn't fetch your authored PRs"
                }
                if let search = reviewResult {
                    self.prsToReview = search.nodes
                    self.recomputeFilteredLists()  // refresh imBlockingPRs
                }
                self.lastUpdated = Date()
                self.isLoading = false
                self.autoFillCount = 0
                self.notifyNewlyBlocked()
                self.notifyNewReviewRequests()
                self.persistCache()
                self.fillIfNeeded()
            }
        }
    }

    /// Merge a fresh page-1 response into `self.prs` while preserving deeper
    /// pages already loaded. In-window PRs (updatedAt ≥ cutoff) MUST appear in
    /// `fresh` to survive — otherwise they're merged/closed and we drop them.
    /// Deeper-than-window PRs are kept only if they were verified still OPEN
    /// (`stillOpen`); without that check, closed PRs that happened to sit
    /// below page 1's cutoff would never leave the cache.
    /// When `!hasNextPage`, fresh is the entire universe of open PRs — nothing
    /// to preserve.
    private func mergeFirstPage(_ fresh: [PullRequest],
                                hasNextPage: Bool,
                                stillOpen: Set<String>) {
        guard let cutoff = fresh.map(\.updatedAt).min() else {
            // empty result — drop everything in the window (which is everything)
            prs = []
            statusCache.removeAll()
            recomputeFilteredLists()
            return
        }
        let preserved: [PullRequest]
        if !hasNextPage {
            preserved = []
        } else {
            preserved = prs.filter { $0.updatedAt < cutoff && stillOpen.contains($0.url) }
        }
        let merged = fresh + preserved
        // Sort updated-desc to match GitHub's ordering, in case a stale PR's
        // updatedAt now sits between fresh items.
        prs = merged.sorted { $0.updatedAt > $1.updatedAt }
        // Invalidate cached statuses for fresh URLs (their fields just changed).
        for pr in fresh { statusCache.removeValue(forKey: pr.url) }
        // Drop status cache entries for PRs that left the list entirely.
        let kept = Set(prs.map(\.url))
        statusCache = statusCache.filter { kept.contains($0.key) }
        recomputeFilteredLists()
    }

    /// Appends the next page (infinite scroll).
    func loadMore() {
        guard !isLoading, !isLoadingMore, !isDemo, let cursor else { return }
        isLoadingMore = true
        Task.detached(priority: .userInitiated) {
            do {
                let search = try GitHubClient.fetchPageWithRetry(kind: .authored, cursor: cursor)
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
                // A blocked PR is in exactly one of these states at a time
                // (effectiveReviewDecision is single-valued). Gate the alert on
                // its toggle, but mark notified regardless so turning a toggle
                // on later affects only future PRs — never a backlog blast.
                let s = statuses(of: pr)
                if s.contains(.approved), alertOnApproved {
                    Notifier.shared.notify(pr, title: "PR approved — ready to merge")
                } else if s.contains(.changesRequested), alertOnChangesRequested {
                    Notifier.shared.notify(pr, title: "Changes requested on your PR")
                } else if s.contains(.commented), alertOnCommented {
                    Notifier.shared.notify(pr, title: "New comment on your PR")
                }
                notifiedBlockedURLs.insert(pr.url)
            }
            let seenUnblocked = Set(prs.map(\.url)).subtracting(blockedURLs)
            notifiedBlockedURLs.subtract(seenUnblocked)
        }
        UserDefaults.standard.set(Array(notifiedBlockedURLs), forKey: Self.notifiedKey)
    }

    /// Fires one notification per PR newly awaiting your review (the "Blocking"
    /// tab). Tracks the full `prsToReview` queue — independent of the UI repo
    /// filter — so a filter change never re-fires and you never miss a PR
    /// blocking on you. Archived PRs are skipped (you dismissed them). Seeds
    /// silently on the first run after this feature ships via its own key.
    private func notifyNewReviewRequests() {
        let reviewURLs = Set(prsToReview.map(\.url))
        if !reviewNotificationsSeeded {
            notifiedReviewURLs.formUnion(reviewURLs)
            armReviewNotificationsOnNextRefresh = true
        } else {
            for pr in prsToReview where !notifiedReviewURLs.contains(pr.url) {
                if alertOnReviewRequested, !archivedURLs.contains(pr.url) {
                    Notifier.shared.notify(pr, title: "PR awaiting your review")
                }
                notifiedReviewURLs.insert(pr.url)
            }
            // `prsToReview` is the full current review queue (page 1, replaced
            // each refresh); anything no longer present has left your queue, so
            // drop it — a future re-request notifies again.
            notifiedReviewURLs.formIntersection(reviewURLs)
        }
        UserDefaults.standard.set(Array(notifiedReviewURLs), forKey: Self.notifiedReviewKey)
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
