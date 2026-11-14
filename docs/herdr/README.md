# herdr API reference

Captured from herdr 0.9.5 (socket protocol 22, `schema_version` 1) on 2026-11-14. Work from these files instead of guessing at the API.

## Files

- `api.schema.json`: output of `herdr api schema --output`. JSON Schemas for requests, success and error responses, events and subscription events.
- `agent-list-example.json`: output of `herdr agent list`, anonymized.
- `snapshot-example.json`: output of `herdr api snapshot`, anonymized.

The examples contain agents in the `idle`, `working` and `unknown` states. No agent was `blocked` or `done` when they were captured. Agents in those states use the same `AgentInfo` object; only `agent_status` differs. Some fields are optional: `completion_seq`, for example, is present only on agents that have completed at least once.

The repo is public, so the examples were anonymized: paths, terminal titles, tab and workspace labels, and session IDs are placeholders. Keep it that way when you regenerate them.

## Wire protocol: verified against the live server

- **Socket**: Unix domain socket at `~/.config/herdr/herdr.sock` (also shown by `herdr status`).
- **Framing**: newline-delimited JSON, one object per line.
- **Request**: `{"id": "<string>", "method": "<method>", "params": {...}}`. `params` is required; send `{}` when a method takes none.
- **Response**: `{"id": "<same id>", "result": {...}}`, or an error shaped like `error_response` in the schema.
- **One request per connection**: the server closes the connection after it replies to an ordinary request. A second write on the same connection fails with a broken pipe. Open a new connection for each call.
- **Subscriptions**: `events.subscribe` keeps its connection open. The server first acknowledges with `{"id": "<id>", "result": {"type": "subscription_started"}}`.
- **`pane.agent_status_changed` needs a `pane_id`**: there is no single subscription for every agent's status. The other `pane.*` subscriptions (`pane.created`, `pane.closed`, `pane.updated`, `pane.exited`, `pane.agent_detected`) take no parameters.

## Not yet verified

- **Event envelope**: according to the schema, each event after the acknowledgement is `{"event": "<kind>", "data": {...}}`. No event arrived during a 30-second probe, so this hasn't been seen on the wire.
- **Which events fire on a status change**: only `pane.agent_status_changed` is certain to fire. It's unknown whether `pane.updated` fires as well, and how often (for example, on every terminal title change).
- **`agent.focus` target**: the CLI accepts an agent name. It hasn't been tested whether the API also accepts a `pane_id` as `target`.

Whoever verifies one of these should move it to the section above.

## What the states mean

From herdr's own agent guide (`herdr --skill`):

- `blocked`: herdr recognized an approval or question UI. The agent is waiting for the user.
- `done` and `idle` both mean the agent is ready for input. `done` means it finished and hasn't been seen yet. Explicit focus commands (`agent.focus`) mark the agent as seen; reads don't. Each TUI client tracks seen completions separately, so its "Done" badge can differ from what the API reports.
- `working`: the agent is busy.
- `unknown`: an agent is present, but herdr can't classify its state confidently. It doesn't mean the agent finished.

## Regenerating

Run these while agents are in as many different states as possible, then anonymize the output before committing it:

```bash
herdr api schema --output docs/herdr/api.schema.json
herdr agent list > agent-list.raw.json      # already prints JSON; there is no --json flag
herdr api snapshot > snapshot.raw.json
```
