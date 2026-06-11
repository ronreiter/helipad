import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: PRStore

    enum Tab {
        case prs
        case archived
    }

    @State private var tab: Tab = .prs

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
        Picker("", selection: $tab) {
            Text("PRs (\(store.activePRs.count))").tag(Tab.prs)
            Text("Archived (\(store.archivedPRs.count))").tag(Tab.archived)
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
    @State private var sessionNotFound = false

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
                        Label(sessionNotFound ? "No Session" : "Session", systemImage: "terminal")
                    }
                }
                .disabled(isFindingSession || sessionNotFound)
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
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
        .onTapGesture {
            openPR()
        }
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
            let session = SessionFinder.findSession(for: pr)
            if let session {
                SessionFinder.openInTerminal(session)
            }
            DispatchQueue.main.async {
                isFindingSession = false
                sessionNotFound = (session == nil)
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
