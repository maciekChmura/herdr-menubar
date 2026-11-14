# herdr-menubar: product requirements

A native macOS menu bar app that shows the live state of the AI coding agents running in the local herdr server, and jumps to any of them in one click.

## Goals

- See at a glance how many agents are blocked, working, done and idle.
- Update the moment an agent changes state, using herdr's event subscription instead of a polling loop.
- Focus any agent in the open herdr TUI with one click.
- Get a macOS notification when an agent gets blocked or finishes.

## Non-goals (v1)

- Not a terminal: no embedded agent output, no sending prompts or keys to agents.
- No remote machines: only the herdr server on this Mac, not machines saved in `herdr machine` or reached over SSH.
- No starting or stopping agents, and no managing workspaces, tabs or panes.
- No changes to herdr's configuration, and no replacing herdr's own notifications.
- No App Store, sandboxing or auto-update.
- No settings window. The only setting is the "Launch at login" toggle in the menu.

## User

One person running herdr 0.9.x locally in Ghostty, with several Claude Code agents open at once.

## herdr integration

Before writing client code, read `docs/herdr/README.md`. It has the wire protocol as verified against the live server, the behaviour that is still unverified, and what each state means. The full API is in `docs/herdr/api.schema.json`.

The parts that shape the design:

- The socket is `~/.config/herdr/herdr.sock`, carrying newline-delimited JSON.
- Ordinary requests use one connection per request; the server closes it after replying.
- `events.subscribe` holds its own long-lived connection.
- `pane.agent_status_changed` must be subscribed to separately for each pane.

### Keeping state in sync

1. `agent.list` is the source of truth for which agents exist and what state they're in.
2. Open one subscription for `pane.created`, `pane.closed`, `pane.exited`, `pane.agent_detected`, `pane.updated` and `pane.focused`, plus one `pane.agent_status_changed` for each known agent pane. `pane.focused` keeps the checkmark on the focused agent current, because switching panes changes no agent's state.
3. On any event, fetch `agent.list` again, debounced by about 100 ms. If the set of agent panes changed, reopen the subscription with the new list of panes.
4. As a safety net, fetch `agent.list` every 30 seconds while connected, in case an event was missed. This is a fallback, not the update mechanism.
5. If the subscription connection drops (the server restarted, or `herdr update --handoff` ran), reconnect with backoff: 1 s, 2 s, 4 s and so on, capped at 30 s.

If milestone M2 finds that `pane.updated` fires too often to be useful, drop it from the subscription and note this in `docs/herdr/README.md`.

## States

| State | Meaning | Glyph |
| --- | --- | --- |
| `blocked` | herdr recognized an approval or question prompt. The agent is waiting for the user. | 🔴 |
| `working` | The agent is busy. | 🟢 |
| `done` | The agent finished and hasn't been seen yet. It turns `idle` once it's focused through herdr. | ✅ |
| `idle` | The agent is ready for input and has already been seen. | ⚪ |
| `unknown` | An agent is present, but herdr can't classify its state. | ❔ |

Any status string this app doesn't recognize is treated as `unknown`, so a newer herdr can't break decoding.

This order (blocked, working, done, idle, unknown) is used everywhere: in the menu bar label and when sorting the dropdown.

## Menu bar label

- Show one count for each state, in the order above, with zero counts left out. Example: `🔴1 🟢2 ✅3 ⚪1`.
- With no agents, show the SF Symbol `circle.dashed`.
- When the herdr server isn't reachable, show the SF Symbol `exclamationmark.circle`.

## Dropdown

Use `MenuBarExtra` with `.menuBarExtraStyle(.menu)`, which gives the standard native menu look.

1. **Header**: a disabled item with the agent count, such as "4 agents".
2. **Agent rows**: one item per agent, sorted by state in the order above, then by folder name. Each row shows:
   - the state glyph;
   - the title: `terminal_title_stripped`, or `agent` when the title is empty;
   - the folder: the last path component of `foreground_cwd`, falling back to `cwd`.

   Mark the agent whose `focused` is `true`, for example with a checkmark.
3. **Footer**: a "Launch at login" toggle (added in M6) and "Quit".

When the herdr server isn't reachable, replace the rows with one disabled item: "herdr server is not running". Add a second disabled line below it: "Start it by running `herdr`".

## Clicking an agent

1. Call `agent.focus` with that agent's `pane_id` as `target`. Whether the API accepts a pane ID there is unverified; if it doesn't, use the agent's name.
2. Bring Ghostty to the front (bundle ID `com.mitchellh.ghostty`). Keep this bundle ID in a single constant.
3. If the call fails, beep and log the error.

Focusing an agent marks it as seen, so a `done` agent turns `idle`. This is expected.

## Notifications

- Notify when an agent's state changes to `blocked` or `done`. Detect changes by comparing the previous `agent.list` result with the new one, matched by `pane_id`.
- Don't notify for states that are already present at launch or right after a reconnect. Only actual changes count.
- **Title**: "<folder>: needs input" for `blocked`, and "<folder>: done" for `done`. **Body**: the agent's title.
- Clicking a notification does the same as clicking that agent's row.
- Skip the notification when that agent is `focused` and Ghostty is the frontmost app. The user is already looking at it.
- Ask for notification permission on first launch.
- herdr's TUI may show its own notifications too. Duplicates are acceptable in v1.

## Platform and technical decisions

- **macOS 14 or later.** This is required for Observation (`@Observable`). `MenuBarExtra` and `SMAppService` need macOS 13.
- **Swift and SwiftUI**, with no third-party dependencies.
- **Socket I/O** through Network.framework (`NWEndpoint.unix(path:)`) or POSIX sockets. The socket path is injectable, so tests and the "not running" state can use a path that doesn't exist.
- **No Dock icon**: `LSUIElement = YES`.
- **App Sandbox off**: the sandbox would block access to the socket in `~/.config`.
- **Project generation**: the Xcode project is generated by xcodegen from `project.yml`. `*.xcodeproj` is in `.gitignore` and never committed.
- **Unit tests** (Swift Testing or XCTest) cover:
  - decoding `docs/herdr/agent-list-example.json`;
  - counting states and formatting the label;
  - sorting rows;
  - detecting the state changes that trigger notifications.

  Keep this logic in pure functions so it can be tested without a running server.

## Milestones

Work through these in order. Tick each checkbox in the same commit as the work it describes. A milestone is done when every item in its "Done when" list holds.

### M0: Scaffold

- [x] `project.yml` with an app target `HerdrMenubar` and a test target `HerdrMenubarTests`, macOS 14, `LSUIElement`, App Sandbox off.
- [x] A `MenuBarExtra` with a placeholder label and a "Quit" item.
- [x] The "Build and run" section of `CLAUDE.md` updated with the commands that actually work.

Done when:
- `xcodegen generate` followed by an `xcodebuild` build succeeds.
- The running app shows an item in the menu bar and no Dock icon.

### M1: herdr client and agent list

- [x] A `HerdrClient` that sends one request over a fresh connection and decodes the reply. The socket path is injectable.
- [x] An `Agent` model with `pane_id`, `agent`, `agent_status`, `cwd`, `foreground_cwd`, `terminal_title_stripped`, `focused`, `workspace_id` and `tab_id`. Unrecognized statuses decode as `unknown`.
- [x] A missing socket or refused connection produces a "not running" state, not a crash.

Done when:
- A test decodes `docs/herdr/agent-list-example.json`.
- At launch, the dropdown lists the titles of the current agents.
- Pointed at a socket path that doesn't exist, the app shows the "not running" state.

### M2: Live state in the menu bar

- [x] A subscription and refetch loop as described in "Keeping state in sync".
- [x] Label formatting as described in "Menu bar label".
- [x] Reconnect with backoff.

Done when:
- A real state change in herdr shows up in the menu bar within about one second, without polling.
- Label formatting, including hidden zero counts and the empty and unreachable cases, is unit-tested.
- After the subscription connection is closed, the client reconnects. Simulate the drop in the client; don't stop the server.
- `docs/herdr/README.md` records which events were seen to fire on a state change.

### M3: Dropdown

- [x] A header, agent rows, a marker on the focused agent, and the "not running" item, as described in "Dropdown".

Done when:
- The rows match the spec.
- Sorting is unit-tested.

### M4: Click to focus

- [x] `agent.focus`, then bring Ghostty to the front.

Done when:
- Clicking a row switches the herdr TUI to that agent and brings Ghostty to the front.
- A `done` agent turns `idle` after it's clicked.
- `docs/herdr/README.md` records which `target` format works.

### M5: Notifications

- [x] Change detection, the permission request, clicking a notification, and skipping notifications for the agent the user is already looking at, as described in "Notifications".

Done when:
- Change detection is unit-tested, including "no notifications at launch".
- A real agent that becomes `blocked` or `done` produces exactly one notification.

### M6: Launch at login

- [x] A "Launch at login" toggle in the dropdown, using `SMAppService.mainApp`.

Done when:
- The toggle shows the current registration state.
- After logging out and back in, the app is running.
