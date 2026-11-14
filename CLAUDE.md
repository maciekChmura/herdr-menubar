# herdr-menubar

A native macOS menu bar app that shows the live state of the agents in the local herdr server. The spec and the milestone checklist are in `docs/PRD.md`.

## Working on this repo

- Read `docs/PRD.md` before starting. Work on one milestone at a time, in order.
- When you finish a milestone item, tick its checkbox in `docs/PRD.md` in the same commit.
- For the herdr API, use `docs/herdr/README.md` (verified protocol notes) and `docs/herdr/api.schema.json` (the full schema). Don't guess. When real behaviour differs from these files, or you verify something listed as unverified, update `docs/herdr/README.md`.
- The Xcode project is generated. Edit `project.yml` and run `xcodegen generate`. Never commit `*.xcodeproj`.
- Ask before adding any third-party dependency.

## Build and run

Milestone M0 replaces this section with the commands that actually work. Until then, the expected commands are:

```bash
brew install xcodegen        # once
xcodegen generate
xcodebuild -scheme HerdrMenubar -configuration Debug build
```

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
