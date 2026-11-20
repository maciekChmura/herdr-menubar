# herdr-menubar

A macOS menu bar app that shows the live state of the AI coding agents running in [herdr](https://herdr.dev) and [Rex](https://www.superlogical.com/rex), and takes you to any of them in one click.

Small colored dots in the menu bar: one per agent, or one per state followed by how many agents are in it.

## What it does

- **The menu bar** shows either one count per state or one dot per agent; you pick under "Menu bar shows" in the menu. Dots stay in the servers' order, herdr's agents first, so each agent keeps its place and only its color changes. Both update the moment an agent changes state: the app follows each server's events instead of polling.

  | Dot | State | Meaning |
  | --- | --- | --- |
  | Red | blocked | Waiting for your answer or approval |
  | Green | working | Busy |
  | Blue | done | Finished, and you haven't looked at it yet |
  | Gray | idle | Ready for input, already seen |
  | Gray ring | unknown | herdr can't tell |

- **herdr and Rex side by side**: the app follows both servers on this Mac, and either may be missing. In Rex, every terminal whose program reports its state counts, which Claude Code does without any setup. When both servers have agents, the menu lists them under "herdr" and "rex".

- **Background jobs**: when an agent ends its turn but leaves a command running in the background, such as a long test run, its dot gets a green ring until the command ends. herdr can't see the command and reports the agent as done or idle, so the app finds it in the process tree. In counts mode, a green ring with a number shows how many agents have one.
- **One row per agent** in the menu, with its state dot, title and folder. A checkmark marks the agent that's focused in herdr. Under a Rex agent's row is what it says it's doing, such as "Running the test suite", and under any agent's row its background jobs, such as "In background: npm test (12m)".
- **Click to focus**: clicking an agent switches herdr to it and brings Ghostty to the front. For a Rex agent, it focuses the agent's terminal and brings Rex to the front; to also switch Rex to the agent's session, turn on Remote Control in Rex's settings (Settings → Server → Client Info).
- **Notifications** when an agent gets blocked or finishes. Clicking one does the same as clicking the agent in the menu. You don't get one for the herdr agent you're already looking at.
- **Gentle animation**: working dots and the rings of background jobs breathe, a blocked dot sends out a faint ring, a dot pops when its agent finishes, and colors fade on every change. Core Animation plays it, so it costs almost no CPU. Turn it off with "Animate dots" in the menu; it's also off while macOS's Reduce motion is on.
- **Launch at login**, from a toggle in the menu.
- **Update check**: once a day the app asks GitHub whether a newer release is out. If one is, "Update available" at the top of the menu opens its release page. It never downloads or installs anything itself. It's the app's only connection to the internet; turn it off with "Check for updates" in the menu.

It's deliberately small: it isn't a terminal, it never sends input to agents, and it has no settings window.

## Requirements

- macOS 14 or later.
- herdr or Rex running on the same Mac, or both. Built and tested with herdr 0.9.5 (socket protocol 22) and Rex 0.1.0-preview.21 (control API revision 18), with Claude Code 2.1.329.
- For herdr, Ghostty, for bringing the terminal to the front when you click an agent. herdr switches to the agent in any terminal; only bringing the window forward is Ghostty-specific.
- To build from source: Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Install

### Download

1. Download `HerdrMenubar-<version>.dmg` from the [latest release](https://github.com/maciekChmura/herdr-menubar/releases/latest).
2. Open it and drag HerdrMenubar onto Applications.
3. Open HerdrMenubar from Applications. The app isn't notarized by Apple, so the first time, macOS refuses to open it and says it can't verify the app. Click Done, go to System Settings → Privacy & Security, scroll down to the message about HerdrMenubar and click "Open Anyway". You only do this once.

   Or skip the warning: before you open the app, run this in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/HerdrMenubar.app
   ```

When a newer version is out, the app's menu says so at the top. To update, quit the app, download the new disk image and replace the app in Applications. macOS asks you to allow the new copy once more.

### From source

```bash
git clone https://github.com/maciekChmura/herdr-menubar.git
cd herdr-menubar
scripts/install.sh
```

The script builds the Release version, installs it as `/Applications/HerdrMenubar.app` and launches it. Run it again after pulling changes to update the app; "Launch at login" stays on.

Builds are ad-hoc signed by default, so you don't need an Apple developer account. To sign with your own certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and fill in your team ID. That file is gitignored.

### After installing

- Allow notifications when macOS asks. If it never asks, turn them on in System Settings → Notifications → HerdrMenubar.
- To start the app when you log in, turn on "Launch at login" in its menu.

## Configuration

The app looks for herdr's socket in this order:

1. The `HerdrSocketPath` setting: `defaults write io.github.maciekchmura.HerdrMenubar HerdrSocketPath /path/to/herdr.sock`, or the launch argument `-HerdrSocketPath /path/to/herdr.sock`.
2. The `HERDR_SOCKET_PATH` environment variable, which herdr itself uses.
3. herdr's default, `~/.config/herdr/herdr.sock`.

It looks for Rex's socket in the `RexSocketPath` setting, set the same way, and otherwise at Rex's default, `~/Library/Application Support/rex/server.sock`.

## Development

- `docs/PRD.md`: the spec and the milestones.
- `docs/herdr/`: herdr's API schema, anonymized examples, and notes on how the API behaves on a live server.
- `docs/rex/`: notes on Rex's control protocol and on how agents report their state, as verified on a live server.
- `CLAUDE.md`: build, test and run commands, and the rules coding agents follow in this repo.

To run the tests:

```bash
xcodegen generate
xcodebuild -scheme HerdrMenubar -configuration Debug -derivedDataPath build test
```

The tests use fake herdr and Rex servers on temporary sockets, so they never touch your real sessions.

To build the disk image for a release, set the version in `MARKETING_VERSION` in `project.yml`, then run `scripts/make-dmg.sh`. It writes `build/HerdrMenubar-<version>.dmg`. The app inside is always ad-hoc signed, even if `Config/Local.xcconfig` names your own certificate, so the image doesn't carry your name or team ID.

## License

MIT. See [LICENSE](LICENSE).

`docs/herdr/api.schema.json` is generated by [herdr](https://github.com/herdrdev/herdr), which is licensed under Apache-2.0.
