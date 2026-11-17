import AppKit

/// Builds the menu's items from the current state. See "Dropdown" in `docs/PRD.md`.
@MainActor
enum StatusMenu {
    struct Settings {
        var style: MenuBarStyle
        var animationTitle: String
        var animationOn: Bool
        var launchAtLoginTitle: String
        var launchAtLoginOn: Bool
        var checkForUpdatesOn: Bool
        /// A newer release to offer at the top of the menu.
        var update: UpdateChecker.Update?
    }

    /// The menu's items. Agent rows carry their pane ID as `representedObject`, the "Menu bar shows"
    /// choices the style's raw value, and the update item the release page's URL. Actions go to `target`.
    /// `now` is when the background jobs' running times are measured to.
    static func items(for state: AgentStore.State, settings: Settings, target: AnyObject?, now: Date = Date()) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let update = settings.update {
            let item = NSMenuItem(title: "Update available: \(update.version)…", action: #selector(StatusItemController.openUpdate(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = update.url
            items.append(item)
            items.append(.separator())
        }

        switch state {
        case .loading:
            items.append(note("Loading…"))
        case .notRunning:
            items.append(note("herdr server is not running"))
            items.append(note("Start it by running \"herdr\" in a terminal"))
        case .failed(let message):
            items.append(note("Couldn't read agents from herdr"))
            items.append(note(message))
        case .loaded(let agents):
            items.append(note(AgentRow.header(agentCount: agents.count)))
            if !agents.isEmpty {
                items.append(.separator())
                for row in AgentRow.rows(for: agents, matching: settings.style) {
                    let item = NSMenuItem(title: row.title, action: #selector(StatusItemController.selectAgent(_:)), keyEquivalent: "")
                    item.target = target
                    item.representedObject = row.agent.paneId
                    item.image = DotsImage.menuIcon(for: row.agent.agentStatus, hasBackgroundJobs: !row.agent.backgroundJobs.isEmpty)
                    if #available(macOS 27, *) {
                        // From macOS 27, AppKit hides menu item images unless the item asks for them.
                        item.preferredImageVisibility = .visible
                    }
                    item.state = row.agent.focused ? .on : .off
                    if let summary = row.backgroundSummary(now: now) {
                        if #available(macOS 14.4, *) {
                            item.subtitle = summary
                        } else {
                            item.toolTip = summary
                        }
                    }
                    items.append(item)
                }
            }
        }

        items.append(.separator())

        let styles = NSMenu()
        for style in MenuBarStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(StatusItemController.selectStyle(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = style.rawValue
            item.state = style == settings.style ? .on : .off
            styles.addItem(item)
        }
        let stylesItem = NSMenuItem(title: "Menu bar shows", action: nil, keyEquivalent: "")
        stylesItem.submenu = styles
        items.append(stylesItem)

        let animation = NSMenuItem(title: settings.animationTitle, action: #selector(StatusItemController.toggleAnimation(_:)), keyEquivalent: "")
        animation.target = target
        animation.state = settings.animationOn ? .on : .off
        items.append(animation)

        let launch = NSMenuItem(title: settings.launchAtLoginTitle, action: #selector(StatusItemController.toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = target
        launch.state = settings.launchAtLoginOn ? .on : .off
        items.append(launch)

        let updates = NSMenuItem(title: "Check for updates", action: #selector(StatusItemController.toggleCheckForUpdates(_:)), keyEquivalent: "")
        updates.target = target
        updates.state = settings.checkForUpdatesOn ? .on : .off
        items.append(updates)

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        items.append(quit)

        return items
    }

    /// A line of text that can't be clicked. The menu greys out items without an action.
    private static func note(_ title: String) -> NSMenuItem {
        NSMenuItem(title: title, action: nil, keyEquivalent: "")
    }
}
