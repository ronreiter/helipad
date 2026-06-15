import SwiftUI
import AppKit

struct PanelView: View {
    @ObservedObject var store: PRStore

    enum Tab {
        case blockedOnMe
        case needsReview
        case imBlocking  // PRs where I am a requested reviewer
        case archived
        case all
    }

    @State private var tab: Tab = .blockedOnMe
    @State private var showAbout = false
    @State private var showShortcuts = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// Set true for ~4s when the Blocking list drains to empty.
    @State private var showConfetti = false
    /// Previous count, used to detect the >0 → 0 transition (not 0 → 0).
    @State private var lastBlockingCount: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            tabPicker
            Divider()
            content
        }
        .frame(minWidth: 490, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(shortcutSurface)
        .overlay {
            if showConfetti {
                ConfettiView()
                    .transition(.opacity)
                    .id(UUID())  // force a fresh particle set each fire
            }
        }
        .onChange(of: store.imBlockingPRs.count) { newCount in
            // Fire only on a real transition from "some" to "none" — never on
            // launch (lastBlockingCount nil) and never on 0 → 0.
            if let prev = lastBlockingCount, prev > 0, newCount == 0 {
                triggerConfetti()
            }
            lastBlockingCount = newCount
        }
        .onAppear {
            // Seed the previous count so the very first onChange doesn't fire
            // if we hydrated from cache with 0 already.
            if lastBlockingCount == nil {
                lastBlockingCount = store.imBlockingPRs.count
            }
        }
    }

    private func triggerConfetti() {
        withAnimation { showConfetti = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            withAnimation { showConfetti = false }
        }
    }

    /// Invisible Buttons that exist only to register keyboard shortcuts.
    /// SwiftUI dispatches keyboardShortcut even on zero-opacity / hit-disabled
    /// views as long as they're in the view tree.
    private var shortcutsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard shortcuts")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("⌘R").font(.callout.monospaced())
                    Text("Refresh PRs")
                }
                GridRow {
                    Text("⌘F").font(.callout.monospaced())
                    Text("Focus search")
                }
                GridRow {
                    Text("Esc").font(.callout.monospaced())
                    Text("Clear search")
                }
                GridRow {
                    Text("⌘1").font(.callout.monospaced())
                    Text("Blocked on me")
                }
                GridRow {
                    Text("⌘2").font(.callout.monospaced())
                    Text("Needs review")
                }
                GridRow {
                    Text("⌘3").font(.callout.monospaced())
                    Text("Archived")
                }
                GridRow {
                    Text("⌘4").font(.callout.monospaced())
                    Text("All")
                }
                GridRow {
                    Text("⇧⌘?").font(.callout.monospaced())
                    Text("Toggle this help")
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(minWidth: 240)
    }

    private var shortcutSurface: some View {
        ZStack {
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Focus search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Clear search") {
                if !searchText.isEmpty { searchText = "" }
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button("Blocked on me") { tab = .blockedOnMe }
                .keyboardShortcut("1", modifiers: .command)
            Button("Needs review") { tab = .needsReview }
                .keyboardShortcut("2", modifiers: .command)
            Button("Archived") { tab = .archived }
                .keyboardShortcut("3", modifiers: .command)
            Button("All") { tab = .all }
                .keyboardShortcut("4", modifiers: .command)
            Button("Help") { showShortcuts.toggle() }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            // Hidden easter-egg / demo shortcut for the Blocking-cleared confetti.
            Button("Fire confetti") { triggerConfetti() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Search PRs", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
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
        // Binding routes through a no-animation transaction so flipping tabs
        // doesn't trigger the segmented picker's implicit selection animation
        // (the visible "loading each time" beat).
        let tabBinding = Binding<Tab>(
            get: { tab },
            set: { newValue in
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) { tab = newValue }
            }
        )
        return Picker("", selection: tabBinding) {
            Text("Blocked on me (\(store.blockedOnMePRs.count)\(more))").tag(Tab.blockedOnMe)
            Text("Needs review (\(store.needsReviewPRs.count)\(more))").tag(Tab.needsReview)
            Text("Blocking (\(store.prsToReview.count))").tag(Tab.imBlocking)
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
            Menu {
                Button("All repos") {
                    store.showAllRepos()
                }
                .disabled(store.selectedRepos.isEmpty)
                if !store.availableRepos.isEmpty {
                    Menu("Only…") {
                        ForEach(store.availableRepos, id: \.self) { repo in
                            Button(repo) {
                                store.showOnlyRepo(repo)
                            }
                        }
                    }
                    Divider()
                    ForEach(store.availableRepos, id: \.self) { repo in
                        Toggle(repo, isOn: Binding(
                            get: { store.selectedRepos.contains(repo) },
                            set: { _ in store.toggleRepo(repo) }
                        ))
                    }
                }
            } label: {
                repoFilterLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button {
                store.toggleGroupByCluster()
            } label: {
                Image(systemName: store.groupByCluster
                    ? "square.stack.3d.up.fill"
                    : "square.stack.3d.up")
            }
            .buttonStyle(.borderless)
            .help(store.groupByCluster ? "Show flat list" : "Group by cluster")
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
                showShortcuts.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Keyboard shortcuts (⇧⌘?)")
            .popover(isPresented: $showShortcuts, arrowEdge: .bottom) {
                shortcutsPopover
            }
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
                    if store.groupByCluster && searchText.isEmpty {
                        let (groups, solos) = store.cluster(visiblePRs)
                        ForEach(groups) { group in
                            ClusterSection(cluster: group, isArchivedTab: tab == .archived, store: store)
                            Divider().padding(.leading, 12)
                        }
                        ForEach(solos) { pr in
                            PRRow(
                                pr: pr,
                                isArchived: tab == .archived,
                                localFolder: store.localFolder(for: pr),
                                nickname: store.nickname(for: pr),
                                originalTitle: store.originalTitle(for: pr),
                                store: store
                            )
                            .equatable()
                            Divider().padding(.leading, 12)
                        }
                    } else {
                    ForEach(visiblePRs) { pr in
                        PRRow(
                            pr: pr,
                            isArchived: tab == .archived,
                            localFolder: store.localFolder(for: pr),
                            nickname: store.nickname(for: pr),
                            originalTitle: store.originalTitle(for: pr),
                            store: store
                        )
                        .equatable()
                        Divider()
                            .padding(.leading, 12)
                    }
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
            // search spans all non-archived PRs, ignoring status filters but
            // still honoring the repo filter (which is a global toggle).
            return store.prs.filter {
                !store.archivedURLs.contains($0.url)
                    && (store.selectedRepos.isEmpty || store.selectedRepos.contains($0.repository.nameWithOwner))
                    && matchesSearch($0)
            }
        }
        switch tab {
        case .blockedOnMe: return store.blockedOnMePRs
        case .needsReview: return store.needsReviewPRs
        case .imBlocking:  return store.imBlockingPRs
        case .archived: return store.archivedPRs
        case .all: return store.activePRs
        }
    }

    private func matchesSearch(_ pr: PullRequest) -> Bool {
        pr.title.localizedCaseInsensitiveContains(searchText)
            || pr.repository.nameWithOwner.localizedCaseInsensitiveContains(searchText)
            || String(pr.number).contains(searchText)
            || store.nickname(for: pr)?.localizedCaseInsensitiveContains(searchText) == true
    }

    private func shortRepoName(_ nameWithOwner: String) -> String {
        nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner
    }

    @ViewBuilder
    private var repoFilterLabel: some View {
        if store.selectedRepos.isEmpty {
            Image(systemName: "folder")
        } else if store.selectedRepos.count == 1, let repo = store.selectedRepos.first {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                Text(shortRepoName(repo)).font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                Text("\(store.selectedRepos.count)").font(.caption)
            }
        }
    }

    private var emptyMessage: String {
        switch tab {
        case .blockedOnMe: return "Nothing blocked on you"
        case .needsReview: return "Nothing waiting for review"
        case .imBlocking:  return "No PRs awaiting your review"
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

struct PRRow: View, Equatable {
    let pr: PullRequest
    let isArchived: Bool
    /// Resolved (and cached) by PRStore so the row body doesn't stat the
    /// filesystem on every render.
    let localFolder: URL?
    /// Passed from PanelView so nickname changes trigger a row rebuild via ==.
    let nickname: String?
    let originalTitle: String?
    /// Unowned for SwiftUI: store is reference-typed and lives for the app
    /// lifetime — not part of the Equatable comparison so `.equatable()` can
    /// short-circuit row rebuilds.
    let store: PRStore
    @State private var isHovering = false
    @State private var isFindingSession = false
    @State private var showNicknameEditor = false
    @State private var nicknameInput = ""
    @State private var showTitleEditor = false
    @State private var titleInput = ""

    static func == (lhs: PRRow, rhs: PRRow) -> Bool {
        lhs.pr == rhs.pr
            && lhs.isArchived == rhs.isArchived
            && lhs.localFolder == rhs.localFolder
            && lhs.nickname == rhs.nickname
            && lhs.originalTitle == rhs.originalTitle
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
            Group {
                if let nickname {
                    Text(nickname)
                        .font(.callout.bold())
                        .lineLimit(2)
                }
                Text(pr.title)
                    .font(nickname != nil ? .caption : .callout)
                    .foregroundStyle(nickname != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(nickname != nil ? 1 : 2)
                    .onTapGesture(count: 2) {
                        titleInput = pr.title
                        showTitleEditor = true
                    }
                    .popover(isPresented: $showTitleEditor, arrowEdge: .bottom) {
                        TitleEditorView(text: $titleInput, hasOriginal: originalTitle != nil) {
                            store.renameTitle(titleInput, for: pr)
                            showTitleEditor = false
                        } onClear: {
                            store.clearTitleRename(for: pr)
                            showTitleEditor = false
                        }
                    }
            }
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
                    nicknameInput = nickname ?? ""
                    showNicknameEditor = true
                } label: {
                    Label("Alias", systemImage: nickname != nil ? "tag.fill" : "tag")
                }
                .popover(isPresented: $showNicknameEditor, arrowEdge: .bottom) {
                    NicknameEditorView(text: $nicknameInput, hasExisting: nickname != nil) {
                        store.setNickname(nicknameInput, for: pr)
                        showNicknameEditor = false
                    } onClear: {
                        store.setNickname("", for: pr)
                        showNicknameEditor = false
                    }
                }
                Button {
                    store.toggleArchived(pr)
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

struct TitleEditorView: View {
    @Binding var text: String
    let hasOriginal: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename PR")
                .font(.headline)
            TextField("PR title", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focused)
                .onSubmit { onSave() }
            HStack {
                Button("Clear") { onClear() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(!hasOriginal)
                Spacer()
                Button("Rename") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

struct NicknameEditorView: View {
    @Binding var text: String
    let hasExisting: Bool
    let onSave: () -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alias")
                .font(.headline)
            TextField("Add an alias…", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .focused($focused)
                .onSubmit { onSave() }
            HStack {
                Button("Clear") { onClear() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(!hasExisting)
                Spacer()
                Button("Save") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}

struct ClusterSection: View {
    let cluster: Cluster
    let isArchivedTab: Bool
    @ObservedObject var store: PRStore
    @State private var expanded = false
    @State private var isHovering = false

    private static let colorPresets: [(name: String, hue: Double)] = [
        ("Red",    0.00),
        ("Orange", 0.08),
        ("Yellow", 0.14),
        ("Green",  0.33),
        ("Teal",   0.48),
        ("Blue",   0.58),
        ("Purple", 0.75),
        ("Pink",   0.92),
    ]

    /// Accent color = user choice if set, else hash-based default. Same
    /// cluster always gets the same color so the eye learns the mapping.
    private var accent: Color {
        Color(hue: store.clusterHue(cluster.id), saturation: 0.55, brightness: 0.9)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accent)
                    .frame(width: 12)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.caption)
                    .foregroundStyle(accent)
                Text(cluster.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(cluster.prs.count) PRs")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.15)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                ZStack(alignment: .leading) {
                    accent.opacity(isHovering ? 0.18 : 0.12)
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .onHover { isHovering = $0 }
            .contextMenu {
                Button("Rename cluster…") { promptRename() }
                if store.clusterNames[cluster.id.key] != nil {
                    Button("Reset to default name") {
                        store.renameCluster(cluster.id, to: "")
                    }
                }
                Divider()
                Menu("Color") {
                    ForEach(Self.colorPresets, id: \.name) { preset in
                        Button {
                            store.setClusterColor(cluster.id, hue: preset.hue)
                        } label: {
                            Label(preset.name, systemImage: "circle.fill")
                                .foregroundStyle(Color(hue: preset.hue, saturation: 0.55, brightness: 0.9))
                        }
                    }
                    if store.clusterColors[cluster.id.key] != nil {
                        Divider()
                        Button("Reset color") {
                            store.setClusterColor(cluster.id, hue: nil)
                        }
                    }
                }
            }
            if expanded {
                VStack(spacing: 0) {
                    ForEach(cluster.prs) { pr in
                        PRRow(
                            pr: pr,
                            isArchived: isArchivedTab,
                            localFolder: store.localFolder(for: pr),
                            nickname: store.nickname(for: pr),
                            originalTitle: store.originalTitle(for: pr),
                            store: store
                        )
                        .equatable()
                        if pr.url != cluster.prs.last?.url {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(
                    Rectangle()
                        .fill(accent)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity, alignment: .leading),
                    alignment: .leading
                )
            }
        }
        .padding(.top, 4)
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = "Rename cluster"
        alert.informativeText = "Used only inside Helipad; the GitHub PRs aren't touched."
        let field = NSTextField(string: cluster.displayName)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.renameCluster(cluster.id, to: field.stringValue)
        }
    }
}
