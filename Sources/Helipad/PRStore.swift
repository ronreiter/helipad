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

    private var timer: Timer?
    static let refreshInterval: TimeInterval = 300
    private static let archivedKey = "archivedPRs"

    var activePRs: [PullRequest] {
        prs.filter { !archivedURLs.contains($0.url) }
    }

    var archivedPRs: [PullRequest] {
        prs.filter { archivedURLs.contains($0.url) }
    }

    let isDemo = CommandLine.arguments.contains("--demo")

    init() {
        if isDemo {
            archivedURLs = DemoData.archivedURLs
            return
        }
        // "dismissedPRs" is the legacy key from when archiving was "Remove"
        let stored = UserDefaults.standard.stringArray(forKey: Self.archivedKey)
            ?? UserDefaults.standard.stringArray(forKey: "dismissedPRs")
            ?? []
        archivedURLs = Set(stored)
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

    func refresh() {
        guard !isLoading, !isDemo else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let result = try GitHubClient.fetchPullRequests()
                await MainActor.run {
                    self.prs = result.prs
                    self.totalCount = result.total
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
}
