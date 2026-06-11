import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: PRStore

    enum Tab {
        case prs
        case archived
    }

    @State private var tab: Tab = .prs
    @State private var showAbout = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabPicker
            Divider()
            content
        }
        .frame(width: 430, height: 520)
        .background(.ultraThinMaterial)
    }

    private var tabPicker: some View {
        let more = store.hasMore ? "+" : ""
        return Picker("", selection: $tab) {
            Text("PRs (\(store.activePRs.count)\(more))").tag(Tab.prs)
            Text("Archived (\(store.archivedPRs.count)\(more))").tag(Tab.archived)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane.arrival")
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
                        set: { _ in store.toggleFilter(status) }
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
                    Image(systemName: "airplane.arrival")
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
                Image(systemName: tab == .prs ? "checkmark.circle" : "archivebox")
                    .font(.largeTitle)
                    .foregroundStyle(tab == .prs ? .green : .secondary)
                Text(tab == .prs ? "No open Claude PRs" : "No archived PRs")
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
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .onAppear {
                            store.loadMore()
                        }
                    }
                }
            }
        }
    }

    private var visiblePRs: [PullRequest] {
        tab == .prs ? store.activePRs : store.archivedPRs
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
        switch pr.reviewDecision {
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
