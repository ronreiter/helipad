import Foundation
import Combine

@MainActor
final class PRStore: ObservableObject {
    @Published var prs: [PullRequest] = []
    @Published var totalCount: Int = 0
    @Published var lastUpdated: Date?
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var timer: Timer?
    private var dismissedURLs: Set<String>
    static let refreshInterval: TimeInterval = 300
    private static let dismissedKey = "dismissedPRs"

    init() {
        dismissedURLs = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    func dismiss(_ pr: PullRequest) {
        dismissedURLs.insert(pr.url)
        UserDefaults.standard.set(Array(dismissedURLs), forKey: Self.dismissedKey)
        prs.removeAll { $0.url == pr.url }
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let result = try GitHubClient.fetchPullRequests()
                await MainActor.run {
                    self.prs = result.prs.filter { !self.dismissedURLs.contains($0.url) }
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
