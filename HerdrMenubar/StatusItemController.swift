import AppKit

/// The menu bar item and its menu, built with AppKit.
///
/// SwiftUI's `MenuBarExtra` can't host Core Animation layers, and redrawing its label for every animation
/// frame cost about 40% of a CPU core. Here the dots are layers (`StatusDotsView`) that macOS animates.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: AgentStore
    private let rexStore: RexStore
    private let notifier = Notifier()
    private let launchAtLogin = LaunchAtLogin()
    private let animation = DotAnimationSettings()
    private let updates = UpdateChecker()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dotsView = StatusDotsView()
    private let menu = NSMenu()
    private var isMenuOpen = false

    private static let styleKey = "MenuBarStyle"

    private var style: MenuBarStyle {
        MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "") ?? .counts
    }

    override init() {
        store = AgentStore(client: HerdrClient(socketPath: HerdrClient.resolveSocketPath()))
        rexStore = RexStore(client: RexClient(socketPath: RexClient.resolveSocketPath()))
        super.init()

        statusItem.button?.addSubview(dotsView)
        menu.delegate = self
        statusItem.menu = menu

        store.onAgentsChanged = { [weak self] _ in self?.refresh() }
        store.onAlerts = { [weak self] alerts in self?.post(alerts) }
        rexStore.onAgentsChanged = { [weak self] _ in self?.refresh() }
        rexStore.onAlerts = { [weak self] alerts in self?.post(alerts) }
        // Clicking a notification does the same as clicking the agent's row.
        notifier.onOpen = { [weak self] paneId in self?.focus(paneId: paneId) }
        animation.onChange = { [weak self] in self?.refresh() }
        updates.onChange = { [weak self] in
            guard let self, self.isMenuOpen else { return }
            self.rebuildMenu()
        }

        notifier.requestAuthorization()
        refresh()
        store.start()
        rexStore.start()
        updates.start()
    }

    /// What herdr and rex report. See "Menu bar label" and "Dropdown" in `docs/PRD.md`.
    private var sources: AgentSources {
        AgentSources(herdr: store.state, rex: rexStore.state)
    }

    // MARK: Menu bar item

    private func refresh() {
        updateStatusItem()
        if isMenuOpen { rebuildMenu() }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let height = NSStatusBar.system.thickness
        switch MenuBarLabel(sources.combined, style: style) {
        case .symbol(let name):
            // When the dots come back, they start fresh rather than fading from what they showed before.
            dotsView.reset()
            dotsView.isHidden = true
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            statusItem.length = NSStatusItem.variableLength
            button.setAccessibilityLabel(name == MenuBarLabel.unreachableSymbol ? "Neither herdr nor rex is running" : "No agents")
        case .dots(let panes):
            show(.dots(panes), in: button, height: height)
            button.setAccessibilityLabel(MenuBarLabel.spokenSummary(
                of: MenuBarLabel.statusCounts(of: panes.map(\.status)),
                inBackground: panes.count(where: \.hasBackgroundJobs)
            ))
        case .counts(let counts, let inBackground):
            show(.counts(counts, inBackground: inBackground), in: button, height: height)
            button.setAccessibilityLabel(MenuBarLabel.spokenSummary(of: counts, inBackground: inBackground))
        }
    }

    private func show(_ content: StatusDotsView.Content, in button: NSStatusBarButton, height: CGFloat) {
        button.image = nil
        dotsView.isHidden = false
        let width = dotsView.show(content, animationsEnabled: animation.isEnabled, height: height)
        dotsView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        statusItem.length = width
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLogin.refresh()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuildMenu() {
        let settings = StatusMenu.Settings(
            style: style,
            animationTitle: animation.toggleTitle,
            animationOn: animation.userEnabled,
            launchAtLoginTitle: launchAtLogin.title,
            launchAtLoginOn: launchAtLogin.isEnabled,
            checkForUpdatesOn: updates.isEnabled,
            update: updates.available
        )
        menu.items = StatusMenu.items(for: sources, settings: settings, target: self)
    }

    @objc func selectAgent(_ sender: NSMenuItem) {
        guard let paneId = sender.representedObject as? String else { return }
        focus(paneId: paneId)
    }

    @objc func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, MenuBarStyle(rawValue: raw) != nil else { return }
        UserDefaults.standard.set(raw, forKey: Self.styleKey)
        // The dots belong to the other style; start fresh so nothing fades or pops.
        dotsView.reset()
        refresh()
    }

    @objc func toggleAnimation(_ sender: NSMenuItem) {
        animation.userEnabled.toggle()
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin.set(!launchAtLogin.isEnabled)
    }

    @objc func toggleCheckForUpdates(_ sender: NSMenuItem) {
        updates.isEnabled.toggle()
    }

    /// Opens the release page of the update the menu offers.
    @objc func openUpdate(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Actions

    /// Focuses the agent in its server and brings the app that shows it to the front, or beeps if the server
    /// refused. See "Clicking an agent" in `docs/PRD.md`.
    private func focus(paneId: String) {
        // An agent that's gone, such as from an old notification, is left to herdr to refuse, as before rex.
        let source = sources.agent(withPaneId: paneId)?.source ?? .herdr
        Task {
            let focused = switch source {
            case .herdr: await store.focus(paneId: paneId)
            case .rex: await rexStore.focus(paneId: paneId)
            }
            if focused {
                TerminalApp.showing(source).activate()
            } else {
                NSSound.beep()
            }
        }
    }

    private func post(_ alerts: [AgentAlert]) {
        for alert in alerts where alert.shouldPost(terminalIsFrontmost: TerminalApp.showing(alert.agent.source).isFrontmost) {
            notifier.post(alert)
        }
    }
}
