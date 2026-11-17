# herdr-menubar: product requirements

A native macOS menu bar app that shows the live state of the AI coding agents running in the local herdr server, and jumps to any of them in one click.

## Goals

- See at a glance how many agents are blocked, working, done and idle.
- Update the moment an agent changes state, using herdr's event subscription instead of a polling loop.
- Focus any agent in the open herdr TUI with one click.
- Get a macOS notification when an agent gets blocked or finishes.
- See when an agent has finished its turn but left a command running in the background, such as a long test run, and will start working again when it ends.

## Non-goals (v1)

- Not a terminal: no embedded agent output, no sending prompts or keys to agents.
- No remote machines: only the herdr server on this Mac, not machines saved in `herdr machine` or reached over SSH.
- No starting or stopping agents, and no managing workspaces, tabs or panes.
- No changes to herdr's configuration, and no replacing herdr's own notifications.
- No App Store, no sandboxing, and no installing updates: the app only says when a newer release is out (see "Update check").
- No settings window. The only settings are in the menu: what the menu bar shows, "Animate dots", "Launch at login" and "Check for updates".

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

| State | Meaning | Dot |
| --- | --- | --- |
| `blocked` | herdr recognized an approval or question prompt. The agent is waiting for the user. | Red |
| `working` | The agent is busy. | Green |
| `done` | The agent finished and hasn't been seen yet. It turns `idle` once it's focused through herdr. | Blue |
| `idle` | The agent is ready for input and has already been seen. | Gray |
| `unknown` | An agent is present, but herdr can't classify its state. | Gray ring |

Any status string this app doesn't recognize is treated as `unknown`, so a newer herdr can't break decoding.

Every state is shown as a small dot, 10 points across, drawn by the app in the system colors (`systemRed`, `systemGreen`, `systemBlue`, `systemGray`). The same dots appear in the menu bar and in front of each row in the dropdown. Emoji aren't used: they're drawn at text size with their own shading. In the menu bar the dots are Core Animation layers; in the dropdown they're non-template images, so the menu keeps their colors.

This order (blocked, working, done, idle, unknown) is used for the counts in the menu bar and for sorting the dropdown.

A green ring around a dot isn't a state: it marks an agent with background jobs. See "Background jobs".

## Menu bar label

The user picks one of two styles under "Menu bar shows" in the menu. The choice is remembered across launches.

- **Counts per state** (the default): a dot and its count for each state, in the order above, with zero counts left out, such as "● 1  ● 3  ● 2". The numbers use the system text color, resolved when the menu bar draws them, so they match the menu bar even when the menu bar is light and the menu is dark. After the working count comes a green ring with the number of agents that have background jobs (added in M10), left out when it's zero. Those agents are still counted in their own state too.
- **One dot per agent**: one dot per agent, in the order herdr lists the agents. Each agent keeps its place, and only its color changes when its state changes. An agent with background jobs gets a green ring around its dot (added in M10).

In both styles:

- With no agents, show the SF Symbol `circle.dashed`.
- When the herdr server isn't reachable, show the SF Symbol `exclamationmark.circle`.

## Animation

The menu bar dots move gently, so it's easy to see at a glance that agents are busy or waiting:

- **working**: slow breathing. The dot fades to half and back every 2.5 s. All working dots breathe in step.
- **blocked**: every 2 s a faint ring spreads 3 points out from the dot and fades, over 1.2 s.
- **done**: one small pop when the agent finishes. The dot grows by 30% and settles back, in 0.35 s.
- **any state change**: the color fades from the old state to the new one over 0.3 s.
- **idle and unknown**: still.
- **background jobs** (added in M10): the green ring breathes like a working dot, in step with them.

The first time the dots are shown, after launch, a reconnect or switching the menu bar style, nothing fades or pops: only real changes do. In counts mode, the done dot pops when its count goes up.

Animations are off when the user turns off "Animate dots" in the menu, and while macOS's Reduce motion setting is on. The menu item then says so.

The animations are Core Animation animations that macOS plays outside the app, so they cost almost no CPU. A first version redrew the menu bar image for every frame through SwiftUI and cost about 40% of a CPU core, which is why the menu bar item and the menu are built with AppKit.

## Dropdown

An AppKit `NSMenu`, rebuilt each time it opens, and updated while it's open when the agents change.

1. **Update** (added in M9): only when a newer release is out, "Update available: 0.2.0…" followed by a separator. See "Update check".
2. **Header**: a disabled item with the agent count, such as "4 agents".
3. **Agent rows**: one item per agent, in the same order as the menu bar. In dots mode that's herdr's order, so the 2nd dot is the 2nd row. In counts mode the rows are sorted by state in the order above, like the counts, then by folder name. Each row shows:
   - the state dot, as the item's icon, with the green ring when the agent has background jobs;
   - the title: `terminal_title_stripped`, or `agent` when the title is empty;
   - the folder: the last path component of `foreground_cwd`, falling back to `cwd`;
   - the background jobs, if any (added in M10), as a second line such as "In background: npm test (12m)". The second line is the item's `subtitle`, which needs macOS 14.4; on older versions the text is the item's tooltip.

   Mark the agent whose `focused` is `true`, for example with a checkmark.
4. **Footer**: the "Menu bar shows" choice (added in M7), an "Animate dots" toggle (added in M8), a "Launch at login" toggle (added in M6), a "Check for updates" toggle (added in M9) and "Quit".

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

## Background jobs

An agent can start a long command in the background, such as a test run or a data export, end its turn and wait for it. herdr then reports the agent as `done` or `idle`, although the agent starts working again by itself when the command finishes. herdr can't see these commands: it reads the screen, and Claude Code only shows them as "· 2 shells" below its prompt. The app finds them in the process tree instead and marks the agent with a green ring. The agent's state stays as herdr reports it, so a `done` agent still notifies.

- **Which agents**: only `done` and `idle` ones. A working agent's commands are part of its work, and a blocked agent is waiting for the user.
- **Finding the jobs**: `pane.process_info` returns the pane's foreground process group. While the agent waits for input, that's the agent's own group. A background job is a process whose parent is in that group but which runs in a process group of its own. Claude Code starts every Bash command that way, while its MCP servers stay in its group. See `docs/herdr/README.md`.
- **At least 5 seconds old**: Claude Code's status line and hooks also run in process groups of their own, but for well under a second, so younger processes don't count. When one is skipped, check again once it would be 5 seconds old.
- **The command shown**: the first process under the job's shell that isn't a shell itself, such as `sleep 240`, or `npm test` in `( time npm test )`, which runs in a subshell. Paths are shortened to their last component, and an interpreter that runs a script by its path is left out, so `node /opt/homebrew/bin/npm test` shows as `npm test`. When the shell hasn't started anything, its own name.
- **When to check**: on every `agent.list` fetch. When a job ends, the agent wakes up and herdr's status event removes the ring. The 30-second safety fetch removes it if a job was stopped without waking the agent.
- When `pane.process_info` fails, that agent has no background jobs. The failure is logged and doesn't stop the rest of the fetch.

A background job isn't always something the agent waits for: a dev server left running also counts. The ring says that something the agent started is still running.

## Update check

The app is distributed as a disk image on the GitHub releases page. It tells the user when a newer one is out, and leaves downloading and installing to them.

- At launch, and then every 24 hours, fetch `https://api.github.com/repos/maciekChmura/herdr-menubar/releases/latest`. GitHub leaves drafts and pre-releases out of it.
- Compare the release's `tag_name`, such as `v0.2.0`, with the app's `CFBundleShortVersionString`, number by number, so 0.10.0 is newer than 0.9.0. Ignore tags that aren't plain numbers, such as `v0.3.0-beta`.
- When the release is newer, the menu offers it at the top (see "Dropdown"). Clicking it opens the release page, the reply's `html_url`, in the browser. Only `https://github.com/` URLs are opened.
- A 404 means the repo has no releases yet; that's not an error. When the check fails, for example offline, try again in an hour. Failures are logged and never shown.
- This is the app's only connection to the internet, so the "Check for updates" toggle in the menu turns it off. It's on by default and remembered across launches. Turning it off also hides an update the menu was offering.
- No notification: the menu item is enough, since the menu is opened often to switch agents.
- For testing, the `UpdateCheckURL` setting replaces the URL above, for example with another repo's `releases/latest`.

## Platform and technical decisions

- **macOS 14 or later.** This is required for Observation (`@Observable`). `SMAppService` needs macOS 13.
- **Swift**, with no third-party dependencies. The menu bar item (`NSStatusItem`) and the menu (`NSMenu`) are AppKit, so the dots can be Core Animation layers; see "Animation". SwiftUI only provides the app's entry point.
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

### M7: One dot per agent

- [x] A "Menu bar shows" choice in the menu between counts per state and one dot per agent, remembered across launches.
- [x] Every state is a dot (done is blue, unknown a gray ring), drawn by the app in the menu bar and in the dropdown rows instead of emoji.

Done when:
- The dots are unit-tested, including that a dot keeps its place when its agent changes state.
- Switching the choice changes the menu bar right away, and the choice survives a relaunch.

### M8: Animated dots

- [x] Breathing for working dots, a spreading ring for blocked dots, a pop when an agent finishes, and a color fade on every state change, as described in "Animation".
- [x] An "Animate dots" toggle in the menu, remembered across launches, and no animation while Reduce motion is on.
- [x] The menu bar item and the menu rebuilt in AppKit, so the animations run in Core Animation.

Done when:
- The animations are unit-tested: their timing, which dots get which animation, and that the first show neither fades nor pops.
- With agents working, the app uses close to 0% CPU.
- The menu still works as before: agent rows with dots and the checkmark, clicking an agent, the "Menu bar shows" choice, and both toggles.

### M9: Update check

- [x] A check for a newer GitHub release at launch and every 24 hours, as described in "Update check".
- [x] "Update available: <version>…" at the top of the menu, opening the release page, and a "Check for updates" toggle, remembered across launches.

Done when:
- Comparing versions and reading GitHub's reply are unit-tested, including tags that aren't plain numbers, a repo with no releases, and a failed check.
- Pointed at a repo whose latest release is newer, the menu offers it, and clicking it opens the release page.
- With "Check for updates" off, the app sends no request to GitHub.

### M10: Background jobs

- [x] Finding the background jobs of `done` and `idle` agents through `pane.process_info` and the process tree, as described in "Background jobs".
- [x] A green ring around the agent's dot in the menu bar and in its menu row, a ring with a count in counts mode, and the jobs on a second line under the agent's row.

Done when:
- Finding jobs is unit-tested: jobs in a group of their own, MCP servers in the agent's group left out, jobs younger than 5 seconds left out and checked again, the command shown, and no `pane.process_info` call for working agents.
- The ring, the count and the row's second line are unit-tested.
- A real agent that starts a command in the background and ends its turn gets the ring within a few seconds, and loses it when the command finishes.
- `docs/herdr/README.md` records `pane.process_info` and what herdr reports while a background command runs.
