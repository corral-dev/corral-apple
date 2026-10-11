#!/usr/bin/env python3
"""Run an isolated Corral host that serves only fictional sample conversations.

Started by ``capture.py`` with a disposable ``HOME`` and state directories; it
never reads the developer's real assistant history, pairing state, tmux panes
or relay. It writes native-format history files for Claude Code, Codex and Pi,
creates a fresh host identity, mints a pairing code, prints one JSON line with
the pairing link and session keys, then serves until terminated.

Run with the CLI's Python environment and ``cli/src`` on ``PYTHONPATH``.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# Isolation is set by the caller before this interpreter starts, because SessKit
# resolves runtime history paths from HOME at import time. Refuse to run otherwise.
_REQUIRED_ENV = ("HOME", "CORRAL_CACHE_DIR", "CORRAL_STATE_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME")
_FORBIDDEN_ENV = ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "OPENCODE_DATA_DIR", "PI_CODING_AGENT_DIR")

HOST_NAME = "Studio Mac"


def _check_isolation() -> Path:
    home = Path(os.environ.get("HOME", "")).resolve()
    root = Path(os.environ.get("CORRAL_README_CAPTURE_ROOT", "")).resolve()
    if not os.environ.get("CORRAL_README_CAPTURE_ROOT") or root not in home.parents:
        sys.exit("demo_host: HOME must live inside CORRAL_README_CAPTURE_ROOT")
    for name in _REQUIRED_ENV:
        value = os.environ.get(name, "")
        if not value or root not in Path(value).resolve().parents and Path(value).resolve() != root:
            sys.exit(f"demo_host: {name} must point inside the capture root")
    for name in _FORBIDDEN_ENV:
        if os.environ.get(name):
            sys.exit(f"demo_host: unset {name} before capture")
    if os.environ.get("CORRAL_ISOLATE_MANAGED_HOSTS") != "1":
        sys.exit("demo_host: CORRAL_ISOLATE_MANAGED_HOSTS=1 is required")
    return home


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _write_jsonl(path: Path, rows: list[dict], mtime: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))
    os.utime(path, (mtime, mtime))


# Each turn is (role, text) or ("tool", name, input, output).
SESSIONS = [
    {
        "runtime": "claude", "project": "webapp", "age": 40, "title": "Fix the login race",
        "turns": [
            ("user", "Users get logged out when two tabs refresh at the same time. Find the cause and fix it."),
            ("assistant", "I'll trace how the session cookie is refreshed."),
            ("tool", "Bash", {"command": "rg -n \"refreshSession\" src"}, "src/auth/session.ts:42:export async function refreshSession(req) {\nsrc/auth/middleware.ts:18:  await refreshSession(req)"),
            ("assistant", "## Cause\n\nBoth tabs call `refreshSession()` with the same refresh token. The second request arrives after the token rotated, so the server treats it as reuse and revokes the session.\n\n## Fix\n\n- Serialize refreshes per session with a short-lived lock.\n- Return the freshly rotated token to the waiting request instead of failing it.\n\n```ts\nconst token = await refreshLock.run(session.id, () => rotate(session))\n```"),
            ("user", "Looks good. Add a regression test."),
            ("tool", "Bash", {"command": "npm test -- auth"}, "PASS  tests/auth/refresh.test.ts\n  ✓ concurrent refreshes keep the session (38 ms)\n\nTests: 24 passed, 24 total"),
            ("assistant", "Added `concurrent refreshes keep the session`. It failed before the fix and passes now; the full auth suite is green."),
        ],
    },
    {
        "runtime": "codex", "project": "webapp", "age": 6 * 60, "title": "Review the login changes",
        "turns": [
            ("user", "Review the refresh-lock change for cancellation and retry bugs."),
            ("tool", "shell", {"command": "git diff --stat main"}, " src/auth/refresh-lock.ts | 41 +++++\n src/auth/session.ts      | 12 +-\n 2 files changed, 47 insertions(+), 6 deletions(-)"),
            ("assistant", "**Findings**\n\n1. If the holder is cancelled, waiters stay blocked until the lock times out. Release the lock in `finally`.\n2. A failed rotation is cached for every waiter. Clear the entry on error so the next request retries.\n\nEverything else looks correct."),
        ],
    },
    {
        "runtime": "pi", "project": "api-server", "age": 22 * 60, "title": "Add rate limits to the public API",
        "turns": [
            ("user", "Add per-key rate limits to the public API: 100 requests per minute."),
            ("assistant", "I'll add a token-bucket limiter in the gateway middleware and return `429` with a `Retry-After` header."),
            ("tool", "bash", {"command": "go test ./internal/ratelimit/..."}, "ok  \tapi-server/internal/ratelimit\t0.412s"),
            ("assistant", "Rate limiting is in place. Requests over the limit get `429 Too Many Requests` and a `Retry-After` value in seconds."),
        ],
    },
    {
        "runtime": "claude", "project": "mobile-app", "age": 55 * 60, "title": "Dark mode for the settings screen",
        "turns": [
            ("user", "The settings screen ignores dark mode. Fix the colors."),
            ("assistant", "The screen hard-codes `#FFFFFF` backgrounds. I replaced them with semantic system colors, so both appearances follow the system setting."),
        ],
    },
    {
        "runtime": "codex", "project": "api-server", "age": 3 * 3600, "title": "Export reports to CSV",
        "turns": [
            ("user", "Add CSV export to the reports endpoint."),
            ("assistant", "`GET /reports/:id.csv` now streams the report with headers, quoting values that contain commas or quotes."),
        ],
    },
    {
        "runtime": "pi", "project": "webapp", "age": 7 * 3600, "title": "Speed up the dashboard query",
        "turns": [
            ("user", "The dashboard takes 4 seconds to load. Find the slow query."),
            ("assistant", "The activity query scanned the whole events table. A composite index on `(team_id, created_at)` brings it from 3.8 s to 45 ms."),
        ],
    },
    {
        "runtime": "claude", "project": "docs-site", "age": 26 * 3600, "title": "Write the getting-started guide",
        "turns": [
            ("user", "Draft a getting-started guide: install, first project, deploy."),
            ("assistant", "The guide is in `docs/getting-started.md` with three short sections and copyable commands."),
        ],
    },
]


def _claude_rows(sid: str, cwd: str, title: str, turns: list, start: float) -> list[dict]:
    rows: list[dict] = []
    parent = None
    ts = start
    base = {"isSidechain": False, "userType": "external", "cwd": cwd, "sessionId": sid,
            "version": "2.1.0", "gitBranch": "main"}
    for turn in turns:
        ts += 20
        if turn[0] == "user":
            row = {**base, "parentUuid": parent, "type": "user", "uuid": str(uuid.uuid4()),
                   "timestamp": _iso(ts), "message": {"role": "user", "content": turn[1]}}
            rows.append(row)
            parent = row["uuid"]
        elif turn[0] == "assistant":
            row = {**base, "parentUuid": parent, "type": "assistant", "uuid": str(uuid.uuid4()),
                   "timestamp": _iso(ts), "message": {
                       "id": f"msg_{uuid.uuid4().hex[:20]}", "type": "message", "role": "assistant",
                       "model": "claude-opus-4-1", "content": [{"type": "text", "text": turn[1]}],
                       "stop_reason": "end_turn"}}
            rows.append(row)
            parent = row["uuid"]
        else:
            _, name, tool_input, output = turn
            call_id = f"toolu_{uuid.uuid4().hex[:20]}"
            use = {**base, "parentUuid": parent, "type": "assistant", "uuid": str(uuid.uuid4()),
                   "timestamp": _iso(ts), "message": {
                       "id": f"msg_{uuid.uuid4().hex[:20]}", "type": "message", "role": "assistant",
                       "model": "claude-opus-4-1",
                       "content": [{"type": "tool_use", "id": call_id, "name": name, "input": tool_input}],
                       "stop_reason": "tool_use"}}
            result = {**base, "parentUuid": use["uuid"], "type": "user", "uuid": str(uuid.uuid4()),
                      "timestamp": _iso(ts + 2), "message": {"role": "user", "content": [
                          {"tool_use_id": call_id, "type": "tool_result", "content": output, "is_error": False}]},
                      "toolUseResult": {"stdout": output, "stderr": "", "interrupted": False}}
            rows += [use, result]
            parent = result["uuid"]
    rows.append({"type": "ai-title", "aiTitle": title, "sessionId": sid})
    return rows


def _codex_rows(sid: str, cwd: str, turns: list, start: float) -> list[dict]:
    rows: list[dict] = [{"timestamp": _iso(start), "type": "session_meta", "payload": {
        "id": sid, "timestamp": _iso(start), "cwd": cwd, "originator": "codex_cli_rs",
        "cli_version": "0.50.0", "source": "cli", "thread_source": "user", "model_provider": "openai"}}]
    ts = start
    for turn in turns:
        ts += 20
        if turn[0] in ("user", "assistant"):
            kind = "input_text" if turn[0] == "user" else "output_text"
            rows.append({"timestamp": _iso(ts), "type": "response_item", "payload": {
                "type": "message", "role": turn[0], "content": [{"type": kind, "text": turn[1]}]}})
        else:
            _, name, tool_input, output = turn
            call_id = f"call_{uuid.uuid4().hex[:16]}"
            rows.append({"timestamp": _iso(ts), "type": "response_item", "payload": {
                "type": "function_call", "name": name, "call_id": call_id,
                "arguments": json.dumps({"command": ["bash", "-lc", tool_input["command"]]})}})
            rows.append({"timestamp": _iso(ts + 2), "type": "response_item", "payload": {
                "type": "function_call_output", "call_id": call_id,
                "output": json.dumps({"output": output, "metadata": {"exit_code": 0}})}})
    rows.append({"timestamp": _iso(ts + 1), "type": "event_msg", "payload": {"type": "task_complete"}})
    return rows


def _pi_rows(sid: str, cwd: str, title: str, turns: list, start: float) -> list[dict]:
    rows: list[dict] = [{"type": "session", "version": 3, "id": sid, "timestamp": _iso(start), "cwd": cwd},
                        {"type": "session_info", "id": uuid.uuid4().hex[:8], "name": title, "timestamp": _iso(start)}]
    parent = rows[-1]["id"]
    ts = start
    for turn in turns:
        ts += 20
        entry_id = uuid.uuid4().hex[:8]
        if turn[0] == "user":
            message = {"role": "user", "content": [{"type": "text", "text": turn[1]}], "timestamp": int(ts * 1000)}
        elif turn[0] == "assistant":
            message = {"role": "assistant", "content": [{"type": "text", "text": turn[1]}], "provider": "anthropic",
                       "model": "claude-sonnet-4-5", "stopReason": "stop", "timestamp": int(ts * 1000)}
        else:
            _, name, tool_input, output = turn
            call_id = f"toolu_{uuid.uuid4().hex[:12]}"
            rows.append({"type": "message", "id": entry_id, "parentId": parent, "timestamp": _iso(ts), "message": {
                "role": "assistant", "content": [{"type": "toolCall", "id": call_id, "name": name, "arguments": tool_input}],
                "provider": "anthropic", "model": "claude-sonnet-4-5", "stopReason": "toolUse", "timestamp": int(ts * 1000)}})
            parent, entry_id = entry_id, uuid.uuid4().hex[:8]
            message = {"role": "toolResult", "toolCallId": call_id, "toolName": name,
                       "content": [{"type": "text", "text": output}], "isError": False, "timestamp": int(ts * 1000 + 2000)}
        rows.append({"type": "message", "id": entry_id, "parentId": parent, "timestamp": _iso(ts), "message": message})
        parent = entry_id
    return rows


def write_fixtures(home: Path) -> list[str]:
    """Write every sample session in its runtime's native layout; return session keys."""
    now = time.time()
    keys: list[str] = []
    codex_index: list[dict] = []
    for spec in SESSIONS:
        cwd = home / "work" / spec["project"]
        cwd.mkdir(parents=True, exist_ok=True)
        end = now - spec["age"]
        start = end - 20 * (len(spec["turns"]) + 1)
        sid = str(uuid.uuid4())
        runtime = spec["runtime"]
        if runtime == "claude":
            slug = str(cwd).replace("/", "-").replace(".", "-")
            path = home / ".claude" / "projects" / slug / f"{sid}.jsonl"
            _write_jsonl(path, _claude_rows(sid, str(cwd), spec["title"], spec["turns"], start), end)
        elif runtime == "codex":
            day = datetime.fromtimestamp(start)
            stamp = day.strftime("%Y-%m-%dT%H-%M-%S")
            path = home / ".codex" / "sessions" / day.strftime("%Y/%m/%d") / f"rollout-{stamp}-{sid}.jsonl"
            _write_jsonl(path, _codex_rows(sid, str(cwd), spec["turns"], start), end)
            codex_index.append({"id": sid, "thread_name": spec["title"], "updated_at": _iso(end)})
        else:
            slug = "--" + str(cwd).strip("/").replace("/", "-") + "--"
            stamp = _iso(start).replace(":", "-").replace(".", "-")
            path = home / ".pi" / "agent" / "sessions" / slug / f"{stamp}_{sid}.jsonl"
            _write_jsonl(path, _pi_rows(sid, str(cwd), spec["title"], spec["turns"], start), end)
        keys.append(f"{runtime}:{sid}")
    if codex_index:
        _write_jsonl(home / ".codex" / "session_index.jsonl", codex_index, now)
    return keys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, required=True, help="loopback/LAN port for the demo host")
    args = parser.parse_args()
    home = _check_isolation()
    keys = write_fixtures(home)

    from corral.remote import config as remote_config
    from corral.remote import crypto, pairing

    state = remote_config.load_state()
    state.host_name = HOST_NAME
    state.relay_enabled = False
    state.relay_url = ""
    state.local_enabled = True
    state.local_port = args.port
    state.wanted = True
    remote_config.save_state(state)
    public_key = crypto.public_key_bytes(remote_config.load_or_create_identity())
    code = crypto.new_pairing_code()
    remote_config.write_pairing(code, 600)
    url = pairing.build_payload(state, code, public_key, args.port)
    print(json.dumps({"pair_url": url, "session_keys": keys}), flush=True)

    import asyncio

    from corral.remote.daemon import RemoteDaemon

    try:
        asyncio.run(RemoteDaemon(remote_config.load_state()).run())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
