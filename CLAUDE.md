# herdr-menubar

A native macOS menu bar app that shows the live state of the agents in the local herdr server. The spec and the milestone checklist are in `docs/PRD.md`.

## Working on this repo

- Read `docs/PRD.md` before starting. Work on one milestone at a time, in order.
- When you finish a milestone item, tick its checkbox in `docs/PRD.md` in the same commit.
- For the herdr API, use `docs/herdr/README.md` (verified protocol notes) and `docs/herdr/api.schema.json` (the full schema). Don't guess. When real behaviour differs from these files, or you verify something listed as unverified, update `docs/herdr/README.md`.
- The Xcode project is generated. Edit `project.yml` and run `xcodegen generate`. Never commit `*.xcodeproj`.
- Ask before adding any third-party dependency.

## Build and run

```bash
xcodegen generate                                                    # after changing project.yml or adding/removing files
xcodebuild -scheme HerdrMenubar -configuration Debug -derivedDataPath build build
xcodebuild -scheme HerdrMenubar -configuration Debug -derivedDataPath build test
pkill -x HerdrMenubar; open build/Build/Products/Debug/HerdrMenubar.app   # quit the running copy, launch the new one
```

- `scripts/install.sh` builds the Release version, quits any running copy, installs it to `/Applications` and launches it. That's the copy for everyday use and for "Launch at login", which registers the app at the path it's running from. The Debug commands above also quit the installed copy; run the script again to get it back.
- `xcodegen` reads the source folders when it runs, so run it again after you add or remove a Swift file. Otherwise the new file isn't compiled.
- `-derivedDataPath build` keeps all build output in `./build`, which is gitignored, so the `.app` path above stays stable.
- On this machine, `xcodebuild` prints `DVTCoreDeviceCore` and `CoreSimulator is out of date` errors. They come from Xcode's device and simulator support and don't affect macOS builds. Check for `** BUILD SUCCEEDED **` or `** TEST SUCCEEDED **` instead.
- The tests use the app as their test host, so running them briefly shows the app's icon in the menu bar. As a test host, the app doesn't connect to herdr or ask for notification permission (see `isTestHost`). Keep it that way: the test run quits the host seconds later, and macOS records a dismissed permission prompt as "not allowed". The only way back is System Settings → Notifications.
- Signing is ad-hoc by default (`Config/Signing.xcconfig`). To sign with your own Apple Development certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, which is gitignored, and fill in your team ID. Never commit a team ID.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Tests that need a herdr server use `FakeHerdrServer` (in `HerdrMenubarTests/HerdrClientTests.swift`) on a temporary socket, never the real one.
- To run against another socket path, for example to see the "not running" state, use `open build/Build/Products/Debug/HerdrMenubar.app --args -HerdrSocketPath /nonexistent/herdr.sock`. Quit the running copy first; otherwise `open` ignores the arguments.
- The app logs to the unified log. In zsh, `log` is a shell builtin, so call `/usr/bin/log`: `/usr/bin/log show --info --style compact --predicate 'subsystem == "io.github.maciekchmura.HerdrMenubar"' --last 1m`. It logs connecting, each change in the agent counts, and lost connections.
- Each herdr event is logged at debug level, which `log show` doesn't keep. Watch events live with `/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "io.github.maciekchmura.HerdrMenubar"'`.

## Don't disturb the live herdr session

The user's real agents run in the local herdr server, including the agent working on this repo.

- Never run `herdr server stop`, call `server.stop` or `server.live_handoff`, or close panes, tabs or workspaces.
- Never send keys, text or prompts to agents.
- Read-only calls are fine: `ping`, `agent.list`, `agent.get`, `session.snapshot` and `events.subscribe`.
- `agent.focus` changes what the user sees in their terminal. Call it only during a manual test the user asked for.
- To test "server not running", point the client at a socket path that doesn't exist. Don't stop the server.
- The repo is public. Anything committed that came from herdr must be anonymized: no real paths, project names, terminal titles or session IDs.

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for this repo, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses the five default triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
