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
    private var timer: Timer?
    static let refreshInterval: TimeInterval = 300
    private static let archivedKey = "archivedPRs"
    private static let filtersKey = "statusFilters"

    var activePRs: [PullRequest] {
        prs.filter { !archivedURLs.contains($0.url) && !$0.statuses.isDisjoint(with: enabledFilters) }
    }

    var archivedPRs: [PullRequest] {
        prs.filter { archivedURLs.contains($0.url) }
    }

    let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        if isDemo {
            archivedURLs = DemoData.archivedURLs
            enabledFilters = Set(PullRequest.Status.allCases)
            return
        }
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
                }
            } catch {
                await MainActor.run {
                    self.isLoadingMore = false
                }
            }
        }
    }
}
