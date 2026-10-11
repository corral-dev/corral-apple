#!/usr/bin/env python3
"""Check the README capture privacy gate and that every fictional session parses.

The fixtures go through the CLI's real SessKit parsers in a disposable HOME;
the GUI capture itself needs an awake display and runs through capture.py.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "readme-captures"))
import capture  # noqa: E402

terms = capture.private_terms(["Secret Project"])
assert capture.privacy_violations(["Studio Mac", "webapp", "Fix the login race"], terms) == []
assert capture.privacy_violations([f"cwd {Path.home()}/x"], terms)
assert capture.privacy_violations(["connected via 203.0.113.20"], terms)
assert capture.privacy_violations(["the secret project plan"], terms)

with tempfile.TemporaryDirectory(prefix="corral-readme-test-") as directory:
    root = Path(directory).resolve()
    home = root / "home"
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CORRAL_", "XDG_"))
           and k not in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "OPENCODE_DATA_DIR", "PI_CODING_AGENT_DIR")}
    env.update({"HOME": str(home), "XDG_CONFIG_HOME": str(root / "c"), "XDG_DATA_HOME": str(root / "d"),
                "XDG_CACHE_HOME": str(root / "x"), "CORRAL_CACHE_DIR": str(root / "cc"),
                "CORRAL_STATE_DIR": str(root / "s"), "CORRAL_README_CAPTURE_ROOT": str(root),
                "CORRAL_ISOLATE_MANAGED_HOSTS": "1"})
    script = ("import demo_host, json; h = demo_host._check_isolation(); "
              "print(json.dumps(demo_host.write_fixtures(h)))")
    run = lambda *a: subprocess.run([capture.cli_python(), *a], env=env, cwd=home, check=True,  # noqa: E731
                                    capture_output=True, text=True).stdout
    env["PYTHONPATH"] = str(ROOT / "scripts" / "readme-captures")
    keys = json.loads(run("-c", script))
    listed = json.loads(run("-m", "sesskit", "list", "--limit", "50"))["data"]
    listed = listed.get("sessions", listed) if isinstance(listed, dict) else listed
    titles = {s["title"] for s in listed}
    expected = {spec["title"] for spec in __import__("demo_host").SESSIONS}
    assert titles == expected, titles
    for key in keys:
        events = json.loads(run("-m", "sesskit", "share", key))["data"]
        events = events.get("events", events) if isinstance(events, dict) else events
        kinds = [e.get("kind") or e.get("type") for e in events]
        assert "user_message" in kinds and "assistant_message" in kinds, (key, kinds)
print(f"readme captures: privacy gate and {len(keys)} fictional sessions OK")
