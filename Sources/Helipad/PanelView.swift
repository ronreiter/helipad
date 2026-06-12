import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: PRStore

    enum Tab {
        case blockedOnMe
        case needsReview
        case archived
        case all
    }

    @State private var tab: Tab = .blockedOnMe
    @State private var showAbout = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            tabPicker
            Divider()
            content
        }
        .frame(minWidth: 430, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search PRs", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .onChange(of: searchText) { text in
                    if !text.isEmpty {
                        tab = .all
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var tabPicker: some View {
        let more = store.hasMore ? "+" : ""
        return Picker("", selection: $tab) {
            Text("Blocked on me (\(store.blockedOnMePRs.count)\(more))").tag(Tab.blockedOnMe)
            Text("Needs review (\(store.needsReviewPRs.count)\(more))").tag(Tab.needsReview)
            Text("Archived (\(store.archivedPRs.count)\(more))").tag(Tab.archived)
            Text("All (\(store.activePRs.count)\(more))").tag(Tab.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "h.circle.fill")
                .foregroundStyle(.orange)
            Text("Helipad")
                .font(.headline)
            Spacer()
            if let updated = store.lastUpdated {
                Text(updated, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                ForEach(PullRequest.Status.allCases, id: \.self) { status in
                    Toggle(status.label, isOn: Binding(
                        get: { store.enabledFilters.contains(status) },
                        set: { _ in
                            store.toggleFilter(status)
                            selectTab(forFilters: store.enabledFilters)
                        }
                    ))
                }
            } label: {
                Image(systemName: store.enabledFilters.count == PullRequest.Status.allCases.count
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                store.refresh()
            } label: {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isLoading)
            Button {
                showAbout.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showAbout) {
                VStack(spacing: 10) {
                    Image(systemName: "h.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Helipad")
                        .font(.title3.bold())
                    Text("Your open Claude Code PRs,\nalways on screen.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Link("github.com/ronreiter/helipad",
                         destination: URL(string: "https://github.com/ronreiter/helipad")!)
                        .font(.callout)
                }
                .padding(20)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage, store.prs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                Text(error)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.prs.isEmpty && store.lastUpdated == nil {
            ProgressView("Loading PRs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visiblePRs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: tab == .archived ? "archivebox" : "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(tab == .archived ? Color.secondary : Color.green)
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visiblePRs) { pr in
                        PRRow(pr: pr, isArchived: tab == .archived) {
                            if tab == .archived {
                                store.unarchive(pr)
                            } else {
                                store.archive(pr)
                            }
                        }
                        Divider()
                            .padding(.leading, 12)
                    }
                    if store.hasMore {
                        // Auto-load only when the list is long enough that
                        // reaching this row means the user scrolled; on short
                        // lists the row is always visible and would otherwise
                        // drain every page in a constant-spinner loop.
                        if visiblePRs.count >= 15 {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            // new identity per page so onAppear re-fires
                            .id(store.prs.count)
                            .onAppear {
                                store.loadMore()
                            }
                        } else {
                            HStack {
                                Spacer()
                                if store.isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Button("Load more…") {
                                        store.loadMore()
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    private var visiblePRs: [PullRequest] {
        if !searchText.isEmpty {
            // search spans all non-archived PRs, ignoring status filters
            return store.prs.filter {
                !store.archivedURLs.contains($0.url) && matchesSearch($0)
            }
        }
        switch tab {
        case .blockedOnMe: return store.blockedOnMePRs
        case .needsReview: return store.needsReviewPRs
        case .archived: return store.archivedPRs
        case .all: return store.activePRs
        }
    }

    private func matchesSearch(_ pr: PullRequest) -> Bool {
        pr.title.localizedCaseInsensitiveContains(searchText)
            || pr.repository.nameWithOwner.localizedCaseInsensitiveContains(searchText)
            || String(pr.number).contains(searchText)
    }

    private var emptyMessage: String {
        switch tab {
        case .blockedOnMe: return "Nothing blocked on you"
        case .needsReview: return "Nothing waiting for review"
        case .archived: return "No archived PRs"
        case .all: return "No PRs match the filters"
        }
    }

    /// Filter changes jump to the tab that matches the selection; custom
    /// combinations land on All PRs.
    func selectTab(forFilters filters: Set<PullRequest.Status>) {
        if filters == PullRequest.Status.blockedOnMe {
            tab = .blockedOnMe
        } else if filters == [.needsReview] {
            tab = .needsReview
        } else {
            tab = .all
        }
    }
}

struct PRRow: View {
    let pr: PullRequest
    let isArchived: Bool
    let onArchiveToggle: () -> Void
    @State private var isHovering = false
    @State private var isFindingSession = false

    private var localFolder: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("GitHub")
            .appendingPathComponent(pr.repoShortName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(pr.repoShortName) #\(pr.number)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(pr.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(pr.title)
                .font(.callout)
                .lineLimit(2)
            HStack(spacing: 6) {
                ciBadge
                reviewBadge
                if pr.hasConflicts {
                    badge("Conflicts", systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            }
            HStack(spacing: 6) {
                Spacer()
                Button {
                    onArchiveToggle()
                } label: {
                    Label(isArchived ? "Unarchive" : "Archive",
                          systemImage: isArchived ? "tray.and.arrow.up" : "archivebox")
                }
                Button {
                    if let folder = localFolder {
                        NSWorkspace.shared.open(folder)
                    }
                } label: {
                    Label("Folder", systemImage: "folder")
                }
                .disabled(localFolder == nil)
                Button {
                    openSession()
                } label: {
                    if isFindingSession {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Label("Session", systemImage: "terminal")
                    }
                }
                .disabled(isFindingSession)
                Button {
                    openPR()
                } label: {
                    Label("Open PR", systemImage: "arrow.up.right.square")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
    }

    private func openPR() {
        if let url = URL(string: pr.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSession() {
        isFindingSession = true
        let pr = self.pr
        DispatchQueue.global(qos: .userInitiated).async {
            SessionFinder.open(for: pr)
            DispatchQueue.main.async {
                isFindingSession = false
            }
        }
    }

    @ViewBuilder
    private var ciBadge: some View {
        switch pr.ciState {
        case "SUCCESS":
            badge("CI", systemImage: "checkmark.circle.fill", color: .green)
        case "FAILURE", "ERROR":
            badge("CI", systemImage: "xmark.circle.fill", color: .red)
        case "PENDING", "EXPECTED":
            badge("CI", systemImage: "circle.dotted", color: .yellow)
        default:
            badge("No CI", systemImage: "minus.circle", color: .gray)
        }
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch pr.effectiveReviewDecision {
        case "APPROVED":
            badge("Approved", systemImage: "checkmark.seal.fill", color: .green)
        case "CHANGES_REQUESTED":
            badge("Changes requested", systemImage: "arrow.uturn.backward.circle.fill", color: .red)
        default:
            badge("Needs review", systemImage: "eye", color: .blue)
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
