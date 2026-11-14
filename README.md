# herdr-menubar

A macOS menu bar app that shows the live state of the AI coding agents running in [herdr](https://herdr.dev), and takes you to any of them in one click.

Small colored dots in the menu bar: one per agent, or one per state followed by how many agents are in it.

## What it does

- **The menu bar** shows either one count per state or one dot per agent; you pick under "Menu bar shows" in the menu. Dots stay in herdr's order, so each agent keeps its place and only its color changes. Both update the moment an agent changes state: the app subscribes to herdr's events instead of polling.

  | Dot | State | Meaning |
  | --- | --- | --- |
  | Red | blocked | Waiting for your answer or approval |
  | Green | working | Busy |
  | Blue | done | Finished, and you haven't looked at it yet |
  | Gray | idle | Ready for input, already seen |
  | Gray ring | unknown | herdr can't tell |

- **One row per agent** in the menu, with its state dot, title and folder. A checkmark marks the agent that's focused in herdr.
- **Click to focus**: clicking an agent switches herdr to it and brings Ghostty to the front.
- **Notifications** when an agent gets blocked or finishes. Clicking one does the same as clicking the agent in the menu. You don't get one for the agent you're already looking at.
- **Launch at login**, from a toggle in the menu.

It's deliberately small: it isn't a terminal, it never sends input to agents, and it has no settings window.

## Requirements

- macOS 14 or later.
- herdr running on the same Mac. Built and tested with herdr 0.9.5 (socket protocol 22).
- Ghostty, for bringing the terminal to the front when you click an agent. herdr switches to the agent in any terminal; only bringing the window forward is Ghostty-specific.
- To build: Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Install

```bash
git clone https://github.com/maciekChmura/herdr-menubar.git
cd herdr-menubar
scripts/install.sh
```

The script builds the Release version, installs it as `/Applications/HerdrMenubar.app` and launches it. Run it again after pulling changes to update the app; "Launch at login" stays on.

Then:

- Allow notifications when macOS asks. If it never asks, turn them on in System Settings → Notifications → HerdrMenubar.
- To start the app when you log in, turn on "Launch at login" in its menu.

### Signing

Builds are ad-hoc signed by default, so you don't need an Apple developer account. To sign with your own certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your team ID. That file is gitignored.

## Configuration

The app looks for herdr's socket in this order:

1. The `HerdrSocketPath` setting: `defaults write io.github.maciekchmura.HerdrMenubar HerdrSocketPath /path/to/herdr.sock`, or the launch argument `-HerdrSocketPath /path/to/herdr.sock`.
2. The `HERDR_SOCKET_PATH` environment variable, which herdr itself uses.
3. herdr's default, `~/.config/herdr/herdr.sock`.

## Development

- `docs/PRD.md`: the spec and the milestones.
- `docs/herdr/`: herdr's API schema, anonymized examples, and notes on how the API behaves on a live server.
- `CLAUDE.md`: build, test and run commands, and the rules coding agents follow in this repo.

To run the tests:

```bash
xcodegen generate
xcodebuild -scheme HerdrMenubar -configuration Debug -derivedDataPath build test
```

The tests use a fake herdr server on a temporary socket, so they never touch your real herdr session.
