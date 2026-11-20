# rex API reference

Captured from Rex 0.1.0-preview.21 (control API revision 18) on 2026-11-20. Work from these notes instead of guessing at the API.

## Where the full reference is

The server documents its own API, so it always matches the running version:

- `rex api list` and `rex api describe METHOD --json`: every method with its JSON Schemas and examples.
- `GET /llms.txt` on the server's socket: the whole control protocol as Markdown, with every method and event. Fetch it with `curl --unix-socket "$HOME/Library/Application Support/rex/server.sock" http://localhost/llms.txt`.
- [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status): the OSC 7501 escape sequence that programs use to report their state.
- [Events](https://www.superlogical.com/rex/docs/reference/events): every event and its fields.

The repo is public. Keep the examples below anonymized: no real paths, titles, labels or session IDs.

## Wire protocol: verified against the live server

- **Socket**: Unix domain socket at `~/Library/Application Support/rex/server.sock`. `rex whoami --json` prints it as `endpoint`, URL-encoded.
- **HTTP on the socket**: the server answers HTTP. `GET /api/control` upgrades to the control connection, a WebSocket. Any host name works in the request.
- **Handshake**: send `Sec-WebSocket-Protocol: rex.control.v1`. The server answers `101 Switching Protocols` and capitalizes the headers its own way, as in `Sec-Websocket-Accept`, so read them case-insensitively. It only compresses when the client asks for `permessage-deflate`.
- **One long-lived connection** carries requests, responses and events. Every message is one JSON object in one WebSocket text frame.
- **Hello first**: within 5 seconds, send `{"type":"hello","api_revision":18,"api_min_revision":18,"client":{"kind":"other","platform":"macos","name":"…","version":"…"}}`. Keep it under 512 bytes. The server answers `{"type":"welcome","protocol":"rex.control.v1",…}`. Don't send `"kind":"app"`: `rex do` and `rex -C` pick "the" app client automatically when only one is connected.
- **Requests**: `{"type":"request","id":"<string>","method":"<method>","payload":{…}}`. Responses come back as `{"type":"response","id":"<same id>","seq":N,"payload":{…}}` or with `"error":{"code":…,"message":…,"status":…}` instead of `payload`. Responses can arrive out of order.
- **Events**: `session.attach_all` with `{"event_scope":"all"}` starts every event from the whole server. Use `all`, not `session`: `session` leaves out `block_event`, and status changes are block events. Events are wrapped twice:

  ```json
  {"type":"event","seq":7,"payload":{"type":"session_event","payload":{
    "session_id":"session:<uuid>",
    "event":{"type":"block_event","payload":{
      "block_id":"block:<uuid>","creator_name":"com.superlogical.terminal","name":"program_status_changed",
      "payload":{"id":"","reason":"report","record":{"state":"working","app":"claude-code", …}}}}}}}
  ```

- **`event_scope: all` includes client events**: every `rex` CLI command anyone runs connects as a new client, so `client_joined`, `client_left`, `client_connected` and `client_disconnected` arrive all the time. Ignore them.
- **Not many events**: in 45 seconds with two Claude Code agents, only `size_changed` and `process_changed` arrived, two of each. A status change sends one `program_status_changed`.
- **Keepalive**: the server pings every 120 seconds. Answer with a pong. Over the Unix socket, a stopped server closes the connection, so the client notices at once.
- **Block methods** go through `block.method` with `{"session_id","block_id","method":"<short name>","args":{}}`. After `session.attach_all`, the connection can call methods in every session.

## Agent state: verified with Claude Code 2.1.329

- **Claude Code reports its state itself** with OSC 7501, as `app=claude-code`. No hook is needed: the `rex skill setup` hook only tells the agent which session and pane it's in.
- **`program_status`** on a terminal block lists its records. `msg` says what the agent is doing, such as "Running the test suite". `owner` is the terminal's foreground process when the report arrived:

  ```json
  {"records":[{"state":"working","app":"claude-code","effective_app":"claude-code","msg":"Running the test suite",
    "updated_at":"2026-11-20T14:21:30.835281+01:00","owner":{"pid":12345,"name":"2.1.329"}}]}
  ```

  Claude Code's process is named after its version, so `owner.name` is a version number.
- **`process`** returns `foreground` with `pid`, `name` and `cwd`. While Claude Code runs, the foreground process is Claude Code itself, and it's the record's owner.
- **`title`** returns `{"title": …}`. Claude Code sets it to a short summary of the task, without a spinner.
- **States**: `idle`, `working`, `done`, `blocked` (with `kind`: `permission`, `question` or `auth`) and `error`. Rex's docs say to treat an unknown state as `idle`.
- **While it works**, Claude Code reports `working` again at each step, each time with a new `msg`, so `program_status_changed` arrives every few seconds while an agent is busy, without a change of state.
- **When its turn ends**, Claude Code reports `done`, without a `msg`. The record stayed `done` for 8 minutes, until the next prompt turned it `working`, with no `idle` in between.
- **Background shells get records of their own.** While a command started with `run_in_background` runs, Claude Code keeps a child record per shell, with the shell's task ID as `id`, the command's description as `title` and the state `working`. The root record says `working` with a `msg` such as "1 shell still running". So in rex, unlike herdr, an agent waiting for a background command shows as working.

## Record lifetime: verified with a test script on a private server

A script that reported each state in turn, in a terminal of its own, showed:

- Each report replaces its record. `program_status_changed` carries the new record and `"reason":"report"`.
- A record with an `id`, such as `sub`, sits beside the root record, whose `id` is empty or missing.
- When the program exits, `working` and `blocked` records are removed, with `program_status_removed` and `"reason":"child_exited"`. Then the block closes with `child_exited`, `block_closed` and `window_closed`.
- **An `idle` record outlives its program.** A program that reported `idle` and exited back to the shell left the record behind, with an `owner` that no longer exists. That's why this app ignores an `idle`, `working` or `blocked` record whose owner isn't the terminal's foreground process any more. `done` and `error` records are meant to outlive their program, so they stay.

## Focusing an agent's terminal

- `session.focus_block` with `{"session_id","block_id"}` focuses the block in its session and makes its window the active one.
- To make Rex.app show that session, ask the app with `client.perform`: `{"client_id":"<app client>","action":"session.select","args":{"session_id":…}}`. Find the app with `client.list` and `{"kinds":["app"]}`. Rex.app performs actions only when Remote Control is on in Settings > Server > Client Info. It's off by default; otherwise the call fails with `refused`.
- Rex.app's bundle ID is `com.superlogical.rex`.
- Verified with a real click: `session.focus_block` succeeded, and with Remote Control off, `session.select` failed with `refused`, as expected.

## Testing against a private server

Run a private server on its own socket and state directory, so nothing touches the user's sessions:

```bash
D="$PWD/build/rex-test"; mkdir -p "$D/state"
rex server run --listen "unix://$D/rex.sock" --state-dir "$D/state" --restore=false
rex -S "unix://$D/rex.sock" new Demo -- ./some-script.sh
```

The socket path must be absolute and shorter than 104 bytes, so keep it under the repo's `build/` folder rather than the scratchpad. Don't point other commands at it through `REX_SERVER`: if that address doesn't answer, `rex` falls back to the user's own server without an error. Pass `-S` and check `rex -S … whoami --json` first.

## Not yet verified

- **Whether Claude Code reports `blocked` at a permission prompt**, and with which `kind`.
- **When a `done` record turns `idle`**: when the user focuses the terminal, types in it, or sends the next prompt.

Whoever verifies one of these should move it to the sections above.
