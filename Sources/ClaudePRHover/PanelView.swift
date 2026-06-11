import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: PRStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 400, height: 520)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.orange)
            Text("Claude PRs")
                .font(.headline)
            if store.totalCount > 0 {
                Text("\(store.totalCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.25)))
            }
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
        if let error = store.errorMessage {
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
        } else if store.prs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("No open Claude PRs")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.prs) { pr in
                        PRRow(pr: pr)
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }
}

struct PRRow: View {
    let pr: PullRequest
    @State private var isHovering = false

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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .onHover { isHovering = $0 }
        .onTapGesture {
            if let url = URL(string: pr.url) {
                NSWorkspace.shared.open(url)
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
