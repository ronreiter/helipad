import AppKit
import SwiftUI
import Carbon.HIToolbox

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
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 560),
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
        contentMinSize = NSSize(width: 430, height: 320)
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
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        registerGlobalHotkey()

        if !store.isDemo {
            Notifier.shared.start()
        }
        store.start()
        panel.orderFrontRegardless()
    }

    private func registerGlobalHotkey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard hotkeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.togglePanel() }
                return noErr
            },
            1, &spec, selfPtr, &eventHandlerRef
        )
        let hotkeyID = EventHotKeyID(signature: 0x484C_5044 /* HLPD */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_P),
            UInt32(cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
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

    @objc func togglePanel() {
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
