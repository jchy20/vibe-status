import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model: DashboardModel
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

    init(client: any DashboardClient = UnconfiguredDashboardClient()) {
        model = DashboardModel(client: client)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        configureStatusItem()
        configurePopover()
        updateStatusItem()
        observeMenuBarCounts()
        observeSystemSleepAndWake()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        Task {
            await model.stop()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if popover.isShown {
            makePopoverKey()
        }
    }

    @objc
    private func workspaceWillSleep(_ notification: Notification) {
        model.suspend()
    }

    @objc
    private func workspaceDidWake(_ notification: Notification) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.model.resume()
        }
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        makePopoverKey()
    }

    private func makePopoverKey() {
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("Opens Vibe Status")
        statusItem = item
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.contentViewController = NSHostingController(
            rootView: DashboardPopoverView(model: model)
        )
    }

    private func observeSystemSleepAndWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func updateStatusItem() {
        guard let statusItem, let button = statusItem.button else { return }
        let counts = model.menuBarCounts
        let image = MenuBarStatusRenderer.image(for: counts)
        statusItem.length = image.size.width + 2
        button.image = image
        button.setAccessibilityLabel(MenuBarStatusRenderer.accessibilityLabel(for: counts))
    }

    private func observeMenuBarCounts() {
        withObservationTracking {
            _ = model.menuBarCounts
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.observeMenuBarCounts()
            }
        }
    }
}
