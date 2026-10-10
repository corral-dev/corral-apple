#!/usr/bin/env python3
"""Read-only Corral client diagnostics. No UI, pairing or network mutations."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import sys
import time

VERSION = "1.1"


class Failure(Exception):
    def __init__(self, code, message, hint, exit_code=1, meta=None):
        self.code, self.message, self.hint, self.exit_code = code, message, hint, exit_code
        self.meta = meta or {}


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Failure("usage", message, "Run --help to inspect supported commands.", 2)


def parser():
    p = Parser(description=__doc__)
    p.add_argument("--json", action="store_true", help="Structured output (automatic without a TTY).")
    p.add_argument("--directory", type=Path, help="Report directory, e.g. a copied iPhone diagnostics directory.")
    p.add_argument("--version", action="version", version=VERSION)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("describe", help="Offline command capabilities and safety contract.")
    sub.add_parser("doctor", help="Read-only local toolchain and diagnostic coverage check.")
    status = sub.add_parser("status", help="All retained clients, with freshness and process evidence.")
    status.add_argument("--active", action="store_true", help="Only fresh, locally alive clients; copied phone PIDs remain unverified.")
    events = sub.add_parser("events", help="Bounded timeline of one exact client run.")
    events.add_argument("--run", required=True, help="clientRun from status (never auto-select a host).")
    events.add_argument("--limit", type=int, default=30, help="Newest 1–128 events; default 30.")
    sub.add_parser("verify", help="Require at least one fresh, locally alive, ready client with data attached.")
    return p


def read_reports(directory):
    if not directory.is_dir():
        raise Failure("no_evidence", "No client diagnostic directory.",
                      "Launch the installed diagnostic-enabled Corral app, or pass --directory with copied iPhone reports.", 3)
    files = sorted(directory.glob("client-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
    # This reader also bounds work when given an unrelated oversized directory.
    reports, failures = [], []
    for path in files[:16]:
        try:
            if path.stat().st_size > 256 * 1024:
                raise ValueError("oversized report")
            raw = json.loads(path.read_text())
            if raw.get("schemaVersion") != 1:
                raise ValueError("unsupported schema")
            if not isinstance(raw.get("state"), dict) or not isinstance(raw.get("events"), list):
                raise ValueError("invalid report shape")
            if not isinstance(raw.get("clientRun"), str) or not isinstance(raw.get("processID"), int) or not 0 < raw["processID"] < 2**31:
                raise ValueError("missing client identity")
            timestamp = raw.get("updatedAt")
            if not isinstance(timestamp, (int, float)) or not math.isfinite(timestamp):
                raise ValueError("invalid timestamp")
            reports.append(raw)
        except (ValueError, OSError, TypeError) as exc:
            failures.append({"file": path.name, "reason": type(exc).__name__})
    coverage = {"filesFound": len(files), "filesRead": min(len(files), 16),
                "validReports": len(reports), "partial": bool(failures) or len(files) > 16,
                "failures": failures, "fileLimit": 16}
    return reports, coverage


def confirms_data_hello(raw):
    try:
        version = tuple(int(part) for part in raw.get("version", "").split("."))
    except (ValueError, AttributeError):
        return False
    if len(version) != 3:
        return False
    minimum = {"macOS": (0, 3, 8), "iOS": (1, 0, 108)}.get(raw.get("platform"))
    return minimum is not None and version >= minimum


def summary(raw):
    age = time.time() - raw["updatedAt"]
    # PID is only meaningful for reports from this Mac. Copied phone reports require live device evidence.
    local = raw.get("platform") == "macOS"
    alive = None
    if local:
        try:
            os.kill(raw["processID"], 0)
            alive = True
        except ProcessLookupError:
            alive = False
        except PermissionError:
            alive = None
    return {k: raw.get(k) for k in ("clientRun", "processID", "platform", "version", "build", "updatedAt", "state", "counters", "completedWaits", "maxWaitMs", "slowWaits")} | {
        "ageSeconds": round(age, 2), "fresh": 0 <= age <= 20,
        "processAlive": alive, "confirmsDataHello": confirms_data_hello(raw), "liveEvidence": "local_pid" if local else "not_checked",
        "totalEvents": raw.get("totalEvents", 0), "retainedEvents": len(raw["events"])}


def run(args):
    if args.command == "describe":
        return {"version": VERSION, "schemaVersion": 1, "risk": "read", "sideEffects": [],
                "commands": [{"name": name, "risk": "read", "options": [
                    {"flags": action.option_strings, "required": action.required,
                     "default": action.default, "help": action.help}
                    for action in command._actions if action.dest != "help"]}
                    for group in parser()._actions if isinstance(group, argparse._SubParsersAction)
                    for name, command in group.choices.items()],
                "exitCodes": {"0": "success", "1": "unhealthy_or_invalid_evidence", "2": "usage", "3": "not_found"},
                "freshnessSeconds": 20, "maxReports": 16,
                "note": "Ready transport does not prove conversation rendering, delivery or physical interaction."}, {}
    directory = args.directory or Path((os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config"))) / "corral-mac" / "diagnostics"
    if args.command == "doctor":
        tools = {name: shutil.which(name) for name in ("python3", "swift", "xcodebuild", "xcodegen", "ios-deliver")}
        return {"tools": tools, "missingTools": [k for k, v in tools.items() if not v],
                "reportsAvailable": directory.is_dir(), "directory": str(directory),
                "nextCommands": [[sys.executable, str(Path(__file__).resolve()), "status"]]}, {}
    reports, coverage = read_reports(directory)
    if not reports:
        raise Failure("no_evidence", "No readable schema-1 reports.", "Launch Corral and retry; malformed files are not live evidence.", 3, meta=coverage)
    if args.command == "events":
        if not 1 <= args.limit <= 128:
            raise Failure("usage", "--limit must be 1–128.", "Use the bounded default of 30.", 2)
        selected = next((r for r in reports if r["clientRun"] == args.run), None)
        if selected is None:
            raise Failure("run_not_found", "That client run is not retained.", "Read status and select an exact clientRun.", 3)
        events = selected["events"][-args.limit:]
        return {"client": summary(selected), "events": events}, coverage | {
            "returned": len(events), "retained": len(selected["events"]),
            "totalEvents": selected.get("totalEvents"), "truncated": len(selected["events"]) > len(events)}
    clients = [summary(r) for r in reports]
    if args.command == "status" and args.active:
        matched = [c for c in clients if c["fresh"] and c["processAlive"] is True]
        return {"clients": matched}, coverage | {"matched": len(matched), "returned": len(matched),
            "omittedReports": len(clients) - len(matched), "filter": "fresh_local_alive"}
    if args.command == "verify" and (coverage["partial"] or not any(
            c["fresh"] and c["processAlive"] is True and c["confirmsDataHello"] and c["state"].get("connection") == "ready"
            and c["state"].get("dataAttached") is True for c in clients)):
        raise Failure("not_verified", "No complete evidence of a fresh, ready local client with data attached.",
                      "Read status/events; confirmed data health requires Mac 0.3.8 / iPhone 1.0.108 or newer. Copied phone reports require device/host checks.", meta=coverage)
    return {"clients": clients}, coverage


def main():
    args = None
    try:
        args = parser().parse_args()
        data, meta = run(args)
        result, exit_code = {"ok": True, "data": data, "error": None, "meta": meta | {"schemaVersion": 1}}, 0
    except Failure as exc:
        result, exit_code = {"ok": False, "data": None,
            "error": {"code": exc.code, "message": exc.message, "hint": exc.hint}, "meta": exc.meta | {"schemaVersion": 1}}, exc.exit_code
    except (OSError, ValueError, TypeError) as exc:
        result, exit_code = {"ok": False, "data": None, "error": {"code": "invalid_evidence",
            "message": type(exc).__name__, "hint": "Check report access and schema; never treat unreadable evidence as healthy."},
            "meta": {"schemaVersion": 1}}, 1
    if (args and args.json) or not (sys.stdin.isatty() and sys.stdout.isatty()):
        print(json.dumps(result, separators=(",", ":")))
    elif result["ok"]:
        data = result["data"]
        if "clients" in data:
            for client in data["clients"]:
                state = client["state"]
                freshness = "fresh" if client["fresh"] else "stale"
                print(f"{client['clientRun']}  {state.get('connection')}  {state.get('transport') or '-'}  data={state.get('dataAttached')}  {freshness}  age={client['ageSeconds']}s")
        elif "events" in data:
            for event in data["events"]:
                print(f"{event.get('sequence')}  {event.get('event')}  {event.get('plane', '-')}  {event.get('durationMs', '-')} ms")
        elif "tools" in data:
            for name, path in data["tools"].items():
                print(f"{name}: {path or 'missing'}")
            print(f"Reports available: {data['reportsAvailable']}")
        else:
            print("Corral client diagnostics, schema 1; read-only.")
            print("Commands: describe, doctor, status, events --run ID [--limit 30], verify.")
    else:
        print(result["error"]["message"] + "\n" + result["error"]["hint"])
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
