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
- **Event envelope**: after the acknowledgement, each event is one line shaped like `{"event": "<kind>", "data": {...}}`. A status change looks like this:

  ```json
  {"data":{"agent":"claude","agent_status":"done","pane_id":"w1:pB","workspace_id":"w1"},"event":"pane.agent_status_changed"}
  ```

- **A status change fires only `pane.agent_status_changed`.** In about 13 minutes, with 4 agents and several status and focus changes, `pane.updated` never fired. It isn't noisy, but it also isn't a signal for status changes.
- **Several events can arrive at once**: when two agents in the same tab went from `done` to `idle` together, both events arrived in the same instant.
- **No heartbeat**: while nothing changes, the subscription stays silent and open. In one stretch, more than 9 minutes passed between events.
- **Event names don't always match subscription types**: subscribing to `pane.focused`, `tab.focused` or `workspace.focused` delivers events named `pane_focused`, `tab_focused` and `workspace_focused`, with an extra `type` field in `data`. Status events keep the dotted name `pane.agent_status_changed`.
- **`done` can turn `idle` without any focus event**: the two agents that went `done` to `idle` together did so with no `*_focused` event before them. Switching to a `done` agent in the herdr TUI turns it `idle`, with `pane_focused` and `pane.agent_status_changed` arriving together.
- **`agent.focus` and `agent.get` accept a pane ID as `target`**, for example `{"target": "w1:p6"}`. herdr switches the TUI to that pane and sends `pane_focused` about 10 ms later. Focusing the pane that's already focused succeeds and sends no event. An unknown target returns the error `agent_not_found`.

## Not yet verified

- **That `agent.focus` turns a `done` agent `idle`**: herdr's guide says explicit focus commands mark an agent as seen, but no `done` agent has been focused through the API yet.

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
