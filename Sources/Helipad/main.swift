import AppKit
import SwiftUI

// --dump: fetch once, print to stdout, exit (for testing without the GUI)
if CommandLine.arguments.contains("--dump") {
    do {
        let result = try GitHubClient.fetchPullRequests()
        print("total: \(result.total)")
        for pr in result.prs {
            let ci = pr.ciState ?? "NO_CI"
            let review = pr.effectiveReviewDecision ?? "NONE"
            print("\(pr.repoShortName)#\(pr.number) [ci:\(ci)] [review:\(review)]\(pr.hasConflicts ? " [CONFLICTS]" : "") \(pr.title)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

final class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 490, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentMinSize = NSSize(width: 490, height: 320)
        setFrameAutosaveName("HelipadPanel")
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private let store = PRStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hostingView = NSHostingView(rootView: PanelView(store: store))
        panel = FloatingPanel(contentView: hostingView)
        positionPanelTopRight()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "h.circle.fill",
            accessibilityDescription: "Helipad"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Panel", action: #selector(togglePanel), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(notificationsMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        if !store.isDemo {
            Notifier.shared.start()
        }
        store.start()
        panel.orderFrontRegardless()
    }

    private func positionPanelTopRight() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - 20,
            y: frame.maxY - panel.frame.height - 20
        )
        panel.setFrameOrigin(origin)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    @objc private func refresh() {
        store.refresh()
    }

    /// Submenu of per-condition notification toggles. Checkmark reflects the
    /// persisted setting; clicking flips it.
    private func notificationsMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        let review = NSMenuItem(title: "Review requested", action: #selector(toggleReviewAlert(_:)), keyEquivalent: "")
        review.target = self
        review.state = store.alertOnReviewRequested ? .on : .off
        submenu.addItem(review)
        let approved = NSMenuItem(title: "My PR approved", action: #selector(toggleApprovedAlert(_:)), keyEquivalent: "")
        approved.target = self
        approved.state = store.alertOnApproved ? .on : .off
        submenu.addItem(approved)
        let changes = NSMenuItem(title: "My PR changes requested", action: #selector(toggleChangesAlert(_:)), keyEquivalent: "")
        changes.target = self
        changes.state = store.alertOnChangesRequested ? .on : .off
        submenu.addItem(changes)
        let commented = NSMenuItem(title: "My PR commented", action: #selector(toggleCommentedAlert(_:)), keyEquivalent: "")
        commented.target = self
        commented.state = store.alertOnCommented ? .on : .off
        submenu.addItem(commented)
        let root = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    @objc private func toggleReviewAlert(_ sender: NSMenuItem) {
        let on = !store.alertOnReviewRequested
        store.setAlertOnReviewRequested(on)
        sender.state = on ? .on : .off
    }

    @objc private func toggleApprovedAlert(_ sender: NSMenuItem) {
        let on = !store.alertOnApproved
        store.setAlertOnApproved(on)
        sender.state = on ? .on : .off
    }

    @objc private func toggleChangesAlert(_ sender: NSMenuItem) {
        let on = !store.alertOnChangesRequested
        store.setAlertOnChangesRequested(on)
        sender.state = on ? .on : .off
    }

    @objc private func toggleCommentedAlert(_ sender: NSMenuItem) {
        let on = !store.alertOnCommented
        store.setAlertOnCommented(on)
        sender.state = on ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
