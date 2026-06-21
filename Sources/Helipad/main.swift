import AppKit
import Combine
import CoreText
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

// How Helipad presents its window. Menu bar (a dropdown popover anchored to the
// status item) is the default; floating panel is the always-on-top window.
enum DisplayMode: String {
    case menuBar
    case floatingPanel

    static let defaultsKey = "HelipadDisplayMode"

    static var current: DisplayMode {
        let raw = UserDefaults.standard.string(forKey: defaultsKey)
        return raw.flatMap(DisplayMode.init(rawValue:)) ?? .menuBar
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: DisplayMode.defaultsKey)
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: FloatingPanel?
    private var popover: NSPopover?
    private var statusItem: NSStatusItem!
    private let store = PRStore()
    private var mode = DisplayMode.current
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon(blockedCount: store.blockedOnMePRs.count)

        // Repaint the menu-bar icon whenever the blocked-on-me count changes.
        store.$blockedOnMePRs
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in
                MainActor.assumeIsolated { self?.updateStatusIcon(blockedCount: count) }
            }
            .store(in: &cancellables)

        if !store.isDemo {
            Notifier.shared.start()
        }
        store.start()
        applyMode()
    }

    /// The Helipad logo in the menu bar — recolored red, with a count badge
    /// (1–9, then "9+"), when PRs are blocked on the user; the normal logo
    /// otherwise.
    private func updateStatusIcon(blockedCount count: Int) {
        guard let button = statusItem.button else { return }
        if count > 0 {
            button.image = logoImage(red: true)
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " \(count > 9 ? "9+" : "\(count)")",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                ]
            )
        } else {
            button.image = logoImage(red: false)
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    /// Renders the Helipad logo (squircle, white landing ring, orange beacon
    /// dots, bold H) at menu-bar size. `red: true` swaps the dark asphalt
    /// squircle for a red one to flag PRs blocked on the user. Proportions
    /// mirror packaging/make-icon.swift, expressed relative to the content side.
    private func logoImage(red: Bool) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let margin: CGFloat = 1
            let rect = CGRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)
            let cs = rect.width
            let center = CGPoint(x: side / 2, y: side / 2)

            // squircle background with a subtle vertical gradient
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cs * 0.22, cornerHeight: cs * 0.22, transform: nil))
            ctx.clip()
            let colors = (red
                ? [CGColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1),
                   CGColor(red: 0.55, green: 0.06, blue: 0.06, alpha: 1)]
                : [CGColor(red: 0.16, green: 0.18, blue: 0.23, alpha: 1),
                   CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)]) as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: CGPoint(x: center.x, y: rect.maxY), end: CGPoint(x: center.x, y: rect.minY), options: [])
            ctx.restoreGState()

            // landing ring
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
            ctx.setLineWidth(cs * 0.05)
            let ringR = (cs / 2) * 0.72
            ctx.strokeEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))

            // orange beacon dots at the four corners, outside the ring
            ctx.setFillColor(CGColor(red: 0.91, green: 0.57, blue: 0.36, alpha: 1))
            let beaconOff = (cs / 2) * 0.885
            let beaconR = cs * 0.035
            for (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
                let x = center.x + beaconOff * dx * 0.7071
                let y = center.y + beaconOff * dy * 0.7071
                ctx.fillEllipse(in: CGRect(x: x - beaconR, y: y - beaconR, width: beaconR * 2, height: beaconR * 2))
            }

            // the H
            let font = NSFont(name: "HelveticaNeue-Bold", size: cs * 0.5) ?? NSFont.boldSystemFont(ofSize: cs * 0.5)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "H", attributes: [.font: font, .foregroundColor: NSColor.white]
            ))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
            CTLineDraw(line, ctx)
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Mode application

    private func applyMode() {
        // Tear down whichever presentation isn't active.
        popover?.performClose(nil)
        popover = nil
        panel?.orderOut(nil)
        panel = nil
        statusItem.menu = nil

        switch mode {
        case .menuBar:
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentSize = NSSize(width: 490, height: 560)
            popover.contentViewController = NSHostingController(rootView: PanelView(store: store))
            self.popover = popover
        case .floatingPanel:
            let panel = FloatingPanel(contentView: NSHostingView(rootView: PanelView(store: store)))
            self.panel = panel
            positionPanelTopRight()
            panel.orderFrontRegardless()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let menuBarItem = NSMenuItem(title: "Open in Menu Bar", action: #selector(useMenuBarMode), keyEquivalent: "")
        menuBarItem.state = mode == .menuBar ? .on : .off
        menu.addItem(menuBarItem)

        let panelItem = NSMenuItem(title: "Open as Floating Panel", action: #selector(useFloatingPanelMode), keyEquivalent: "")
        panelItem.state = mode == .floatingPanel ? .on : .off
        menu.addItem(panelItem)

        menu.addItem(.separator())
        if mode == .floatingPanel {
            menu.addItem(NSMenuItem(title: "Show/Hide Panel", action: #selector(togglePanel), keyEquivalent: "p"))
        }
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(notificationsMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    // MARK: - Status item interaction

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true

        if isRightClick || mode == .floatingPanel {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
    }

    // NSMenuDelegate: clear the menu after it closes so left-clicks resume
    // toggling the popover in menu-bar mode.
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func togglePopover() {
        guard let popover, let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func useMenuBarMode() {
        guard mode != .menuBar else { return }
        mode = .menuBar
        mode.save()
        applyMode()
    }

    @objc private func useFloatingPanelMode() {
        guard mode != .floatingPanel else { return }
        mode = .floatingPanel
        mode.save()
        applyMode()
    }

    private func positionPanelTopRight() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.maxX - panel.frame.width - 20,
            y: frame.maxY - panel.frame.height - 20
        )
        panel.setFrameOrigin(origin)
    }

    @objc private func togglePanel() {
        guard let panel else { return }
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
        let enable = NSMenuItem(title: "Enable notifications…", action: #selector(enableNotifications), keyEquivalent: "")
        enable.target = self
        submenu.addItem(enable)
        submenu.addItem(.separator())
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

    @objc private func enableNotifications() {
        Notifier.shared.promptForAuthorization()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
