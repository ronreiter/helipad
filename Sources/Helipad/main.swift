import AppKit
import SwiftUI

// --dump: fetch once, print to stdout, exit (for testing without the GUI)
if CommandLine.arguments.contains("--dump") {
    do {
        let result = try GitHubClient.fetchPullRequests()
        print("total: \(result.total)")
        for pr in result.prs {
            let ci = pr.ciState ?? "NO_CI"
            let review = pr.reviewDecision ?? "NONE"
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
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
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
            systemSymbolName: "sparkles.rectangle.stack",
            accessibilityDescription: "Helipad"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Panel", action: #selector(togglePanel), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

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
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
