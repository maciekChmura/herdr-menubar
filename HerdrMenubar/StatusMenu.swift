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
    }

    /// The menu's items. Agent rows carry their pane ID as `representedObject`, and so do the
    /// "Menu bar shows" choices with the style's raw value. Actions go to `target`.
    static func items(for state: AgentStore.State, settings: Settings, target: AnyObject?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

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
                    item.image = DotsImage.menuIcon(for: row.agent.agentStatus)
                    if #available(macOS 27, *) {
                        // From macOS 27, AppKit hides menu item images unless the item asks for them.
                        item.preferredImageVisibility = .visible
                    }
                    item.state = row.agent.focused ? .on : .off
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
