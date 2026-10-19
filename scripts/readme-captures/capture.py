#!/usr/bin/env python3
"""Capture README screenshots of the Mac and iPhone clients from fictional data only.

The clients never see real conversations, paths or machines:

1. ``demo_host.py`` runs a real Corral host inside a disposable HOME that holds
   only fictional Claude Code, Codex and Pi sessions. It has its own identity,
   no relay, no autostart and no access to real tmux panes.
2. Debug clients pair with that host through ``CORRAL_INSPECTION_PAIR_URL`` and
   open screens by launch option; nothing drives the pointer or takes focus.
   - Mac: an empty ``XDG_CONFIG_HOME``; the window is captured by id, after a
     fixed settle. The preferences domain is exported before and restored
     after, saved window state is ignored, and the installed app is relaunched
     if it was running.
   - iPhone: a freshly created simulator booted headless (no Simulator window),
     with its own keychain and data and a fixed 9:41 status bar; it is deleted
     after the run. The script waits for the paired host card before any
     relaunch, then polls each shot until its fictional content is visible
     (fixed sleeps wedge the list on a cold simulator).
3. Every image passes an OCR privacy gate that fails on the account name, real
   name, computer names, home path, email, IP addresses or any ``--deny`` term,
   and a size check. Failed images are deleted.

Run from ``apple/``::

    python3 scripts/readme-captures/capture.py --copy-to ../cli/docs/screenshots
    python3 scripts/readme-captures/capture.py --clients iphone --appearance dark

Outputs go to ``docs/screenshots/`` (``<client>-<shot>-<appearance>.png``).
The default build is a clean export of the committed client, so commit UI
changes first; ``--source worktree`` captures uncommitted work for review only.
For the Mac, the display must be awake and unlocked.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
APPLE = HERE.parents[1]
CLI = APPLE.parent / "cli"
BUNDLE_ID = "com.x0c.corral"
APP_EXECUTABLE_SUFFIX = "Corral.app/Contents/MacOS/Corral"
INSTALLED_APP = Path("/Applications/Corral.app")
DERIVED_DATA = APPLE / ".derivedData-readme"  # --source worktree only
CAPTURE_ROOT = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "corral" / "development" / "readme-capture"

# Shot name -> sessions to open, by index into demo_host.SESSIONS, plus fictional
# strings that must be OCR-visible before the shot counts. Mac opens them side
# by side; iPhone opens the first one, or the session list when empty.
MAC_SHOTS = {"split": [0, 1]}
IPHONE_SHOTS = {
    "sessions": {"indexes": [], "markers": ["Studio Mac", "logged out"]},
    "chat": {"indexes": [0], "markers": ["Cause", "refreshSession"]},
}
# Pairing on a cold simulator takes a while; terminating mid-pairing wedges the
# session list on its spinner forever (the feed never starts its retry loop),
# so the script waits for the host card before any relaunch, then polls every
# shot for its content instead of trusting a fixed sleep.
IPHONE_PAIR_TIMEOUT = 120.0
IPHONE_CONTENT_TIMEOUT = 100.0
IPHONE_CONTENT_ATTEMPTS = 3
IPHONE_POLL_INTERVAL = 5.0
IPHONE_STABILIZE = 4.0
IPHONE_DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
SIMULATOR_NAME = "Corral README Capture"


def log(message: str) -> None:
    print(f"[readme-capture] {message}", file=sys.stderr, flush=True)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kwargs)


# --------------------------------------------------------------------------- privacy


def _command_output(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def private_terms(extra: list[str]) -> list[str]:
    """Strings that must never appear in a public screenshot."""
    home = str(Path.home())
    terms = {
        getpass.getuser(),
        home,
        _command_output(["id", "-F"]),
        socket.gethostname(),
        socket.gethostname().split(".")[0],
        _command_output(["scutil", "--get", "ComputerName"]),
        _command_output(["scutil", "--get", "LocalHostName"]),
        _command_output(["git", "config", "--global", "user.email"]),
        _command_output(["git", "config", "--global", "user.name"]),
        # Split so the public-source export preflight (which rejects a literal
        # "/Users/<name>" path) does not trip on this OCR forbidden term.
        "/" + "Users/",
        "/private/",
        "readme-capture",
        *extra,
        *[t for t in os.environ.get("CORRAL_CAPTURE_DENY", "").split(",")],
    }
    # Each word of a multi-word real name is checked on its own as well.
    for name in list(terms):
        if name and " " in name and "/" not in name:
            terms.update(part for part in name.split() if len(part) >= 4)
    return sorted({t.strip() for t in terms if t and len(t.strip()) >= 3}, key=str.lower)


IP_PATTERN = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")


def privacy_violations(lines: list[str], terms: list[str]) -> list[str]:
    found = []
    folded = [line.casefold() for line in lines]
    for term in terms:
        needle = term.casefold()
        if any(needle in line for line in folded):
            found.append(f"term {term!r}")
    for line in lines:
        for match in IP_PATTERN.findall(line):
            found.append(f"IP address {match!r}")
    return found


# --------------------------------------------------------------------------- helpers


def build_helper(work: Path) -> Path:
    binary = work / "capture_helper"
    run(["swiftc", "-O", str(HERE / "capture_helper.swift"), "-o", str(binary)], capture_output=True)
    return binary


def export_head() -> Path:
    """A clean copy of the committed client, so other people's unfinished edits stay out."""
    source = CAPTURE_ROOT / "source"
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    archive = subprocess.run(["git", "archive", "HEAD"], cwd=APPLE, capture_output=True, check=True).stdout
    subprocess.run(["tar", "-x", "-C", str(source)], input=archive, check=True)
    run(["xcodegen", "generate", "--quiet"], cwd=source, capture_output=True)
    return source


def build_app(source: Path, platform: str) -> Path:
    """Build the Debug client for ``mac`` or ``iphone`` (simulator) from ``source``."""
    scheme, destination, products = {
        "mac": ("CorralMac", "platform=macOS", "Debug"),
        "iphone": ("Corral", "generic/platform=iOS Simulator", "Debug-iphonesimulator"),
    }[platform]
    derived = (DERIVED_DATA if source == APPLE else CAPTURE_ROOT / "derived") / platform
    derived.mkdir(parents=True, exist_ok=True)
    log_path = derived / "build.log"
    log(f"building the Debug {platform} client")
    with open(log_path, "w") as output:
        result = subprocess.run(
            ["xcodebuild", "-project", "Corral.xcodeproj", "-scheme", scheme, "-configuration", "Debug",
             "-destination", destination, "-derivedDataPath", str(derived),
             "-skipPackagePluginValidation", "build"],
            cwd=source, stdout=output, stderr=subprocess.STDOUT, text=True,
        )
    if result.returncode != 0:
        sys.exit(f"build failed; see {log_path}")
    app = derived / "Build" / "Products" / products / "Corral.app"
    if not app.is_dir():
        sys.exit(f"no Debug build at {app}")
    return app


def corral_app_pids() -> list[int]:
    out = _command_output(["pgrep", "-f", APP_EXECUTABLE_SUFFIX])
    return [int(pid) for pid in out.split()] if out else []


def pid_executable(pid: int) -> str:
    return _command_output(["ps", "-o", "comm=", "-p", str(pid)])


def stop_client_apps() -> bool:
    """Quit every Corral GUI app (never the CLI host); return whether the installed one ran."""
    pids = corral_app_pids()
    installed_running = any(pid_executable(pid).startswith(str(INSTALLED_APP)) for pid in pids)
    for pid in pids:
        log(f"quitting Corral client pid {pid}")
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while corral_app_pids() and time.monotonic() < deadline:
        time.sleep(0.3)
    if corral_app_pids():
        sys.exit("Corral client processes did not exit; close them and retry")
    return installed_running


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_port(port: int, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as sock:
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return
        time.sleep(0.3)
    sys.exit(f"demo host did not listen on {port}")


def cli_python() -> str:
    venv = CLI / ".venv" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


def start_demo_host(run_dir: Path, port: int) -> tuple[subprocess.Popen, dict]:
    home = run_dir / "home"
    # A run may host one client at a time; drop the previous phase's fixtures
    # so stale session files (new UUIDs each phase) never mix into the new host.
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(run_dir / "tmux", ignore_errors=True)
    home.mkdir(parents=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CORRAL_", "PICKUP_", "XDG_")) and key not in
           ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "OPENCODE_DATA_DIR", "PI_CODING_AGENT_DIR", "TMUX", "PYTHONPATH")}
    env.update({
        "HOME": str(home),
        "XDG_CONFIG_HOME": str(run_dir / "config"),
        "XDG_DATA_HOME": str(run_dir / "data"),
        "XDG_CACHE_HOME": str(run_dir / "cache"),
        "XDG_STATE_HOME": str(run_dir / "xdg-state"),
        "CORRAL_CACHE_DIR": str(run_dir / "corral-cache"),
        # The host identity persists so repeated runs reuse one paired machine.
        "CORRAL_STATE_DIR": str(CAPTURE_ROOT / "host-state"),
        "CORRAL_README_CAPTURE_ROOT": str(CAPTURE_ROOT),
        "CORRAL_ISOLATE_MANAGED_HOSTS": "1",
        "CORRAL_LANG": "en",
        "TMUX_TMPDIR": str(run_dir / "tmux"),
        "PYTHONPATH": str(CLI / "src"),
    })
    (run_dir / "tmux").mkdir()
    log_file = open(run_dir / "demo-host.log", "w")
    process = subprocess.Popen(
        [cli_python(), str(HERE / "demo_host.py"), "--port", str(port)],
        cwd=home, env=env, stdout=subprocess.PIPE, stderr=log_file, text=True,
        start_new_session=True,
    )
    line = process.stdout.readline() if process.stdout else ""
    if not line:
        process.wait(timeout=5)
        sys.exit(f"demo host failed; see {run_dir / 'demo-host.log'}")
    info = json.loads(line)
    wait_for_port(port, 30)
    return process, info


def launch_client(app: Path, run_dir: Path, info: dict, keys: list[str], appearance: str, size: str) -> int:
    mac_config = run_dir / "mac-config"
    mac_config.mkdir(exist_ok=True)
    env = {
        "XDG_CONFIG_HOME": str(mac_config),
        "CORRAL_INSPECTION_PAIR_URL": info["pair_url"],
        "CORRAL_INSPECTION_SESSION_KEY": ",".join(keys),
        "CORRAL_INSPECTION_WINDOW_SIZE": size,
    }
    args = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-CorralInspectConversation", "-CorralInspectKeyWindow",
            "-CorralInspectDark" if appearance == "dark" else "-CorralInspectLight"]
    cmd = ["open", "-n", "-g", "-F"]
    for key, value in env.items():
        cmd += ["--env", f"{key}={value}"]
    run(cmd + [str(app), "--args", *args])
    executable = str(app / "Contents" / "MacOS" / "Corral")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        for pid in corral_app_pids():
            if pid_executable(pid) == executable:
                return pid
        time.sleep(0.3)
    sys.exit("the Debug client did not start")


def find_window(helper: Path, pid: int, timeout: float = 20) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run([str(helper), "window-id", str(pid)], capture_output=True, text=True)
        if result.returncode == 0:
            return int(result.stdout.strip())
        time.sleep(0.5)
    sys.exit("the client window never appeared (is the display asleep or locked?)")


def size_problem(path: Path, size: str) -> str | None:
    """The window must have the requested point size (at 1x or 2x pixels)."""
    width, height = (int(v) for v in size.split("x"))
    out = _command_output(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)])
    pixels = dict(re.findall(r"(pixelWidth|pixelHeight): (\d+)", out))
    actual = (int(pixels.get("pixelWidth", 0)), int(pixels.get("pixelHeight", 0)))
    if actual in ((width, height), (width * 2, height * 2)):
        return None
    return f"window was {actual[0]}x{actual[1]} pixels, expected {size} points"


def newest_ios_runtime() -> str:
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "--json"], capture_output=True).stdout)["runtimes"]
    ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")
           and any(d["identifier"] == IPHONE_DEVICE_TYPE for d in r.get("supportedDeviceTypes", []))]
    if not ios:
        sys.exit(f"no installed iOS simulator runtime supports {IPHONE_DEVICE_TYPE}")
    return max(ios, key=lambda r: [int(x) for x in r["version"].split(".")])["identifier"]


class Simulator:
    """A throwaway simulator: created, booted headless, status bar fixed, then deleted."""

    def __init__(self) -> None:
        for device in self._existing():
            subprocess.run(["xcrun", "simctl", "delete", device], capture_output=True)
        self.udid = run(["xcrun", "simctl", "create", SIMULATOR_NAME, IPHONE_DEVICE_TYPE, newest_ios_runtime()],
                        capture_output=True).stdout.strip()
        run(["xcrun", "simctl", "boot", self.udid], capture_output=True)
        run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], capture_output=True)
        run(["xcrun", "simctl", "status_bar", self.udid, "override", "--time", "9:41", "--dataNetwork", "wifi",
             "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
             "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100"], capture_output=True)

    @staticmethod
    def _existing() -> list[str]:
        devices = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"], capture_output=True).stdout)
        return [d["udid"] for group in devices["devices"].values() for d in group if d["name"] == SIMULATOR_NAME]

    def launch(self, args: list[str], env: dict[str, str]) -> None:
        child_env = {**os.environ, **{f"SIMCTL_CHILD_{k}": v for k, v in env.items()}}
        # One atomic step: a plain terminate+launch can attach to the dying
        # process and silently ignore the new arguments.
        run(["xcrun", "simctl", "launch", "--terminate-running-process", self.udid, BUNDLE_ID, *args],
            capture_output=True, env=child_env)

    def delete(self) -> None:
        subprocess.run(["xcrun", "simctl", "shutdown", self.udid], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", self.udid], capture_output=True)


def sim_screenshot(sim: Simulator, path: Path) -> None:
    run(["xcrun", "simctl", "io", sim.udid, "screenshot", str(path)], capture_output=True)


def ocr_lines(helper: Path, path: Path) -> list[str]:
    out = run([str(helper), "ocr", str(path)], capture_output=True).stdout
    return json.loads(out)[str(path)]


def wait_for_markers(sim: Simulator, helper: Path, probe: Path, markers: list[str],
                     timeout: float, what: str) -> bool:
    """Screenshot-poll until every marker is OCR-visible; False on timeout."""
    deadline = time.monotonic() + timeout
    last: list[str] = []
    missing = list(markers)
    while time.monotonic() < deadline:
        time.sleep(IPHONE_POLL_INTERVAL)
        try:
            sim_screenshot(sim, probe)
            last = ocr_lines(helper, probe)
        except (OSError, subprocess.SubprocessError):
            continue
        missing = [m for m in markers
                   if not any(m.casefold() in line.casefold() for line in last)]
        if not missing:
            return True
    log(f"iphone {what}: still missing {missing} after {timeout:g}s; saw {len(last)} lines")
    for line in last[:40]:
        log(f"iphone {what} saw: {line[:120]}")
    return False


def stop_demo_host(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass


def capture_iphone(app: Path, info: dict, appearances: list[str], helper: Path,
                   run_dir: Path, stage, failures: list) -> None:
    sim = Simulator()
    try:
        run(["xcrun", "simctl", "install", sim.udid, str(app)], capture_output=True)
        common = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        # Pair on a cold start first; later launches reuse the stored machine
        # (the pairing code is one-time, and relaunching mid-pairing wedges).
        sim.launch(common, {"CORRAL_INSPECTION_PAIR_URL": info["pair_url"]})
        probe = run_dir / "probe.png"
        if not wait_for_markers(sim, helper, probe, ["Studio Mac"], IPHONE_PAIR_TIMEOUT, "pairing"):
            failures.append("iphone pairing: 'Studio Mac' never appeared in the host list")
            return
        for shot, spec in IPHONE_SHOTS.items():
            for appearance in appearances:
                name = f"iphone-{shot}-{appearance}.png"
                if spec["indexes"]:
                    key = info["session_keys"][spec["indexes"][0]]
                    args = [*common,
                            "-CorralInspectDark" if appearance == "dark" else "-CorralInspectLight",
                            "-CorralInspectConversation"]
                    env = {"CORRAL_INSPECTION_SESSION_KEY": key}
                else:
                    args = [*common,
                            "-CorralInspectDark" if appearance == "dark" else "-CorralInspectLight",
                            "-CorralInspectSessions"]
                    env = {}
                # A cold first relaunch can miss navigation and sit on a spinner
                # that never retries; relaunching heals it, so try again.
                settled = False
                for attempt in range(1, IPHONE_CONTENT_ATTEMPTS + 1):
                    run(["xcrun", "simctl", "ui", sim.udid, "appearance", appearance], capture_output=True)
                    sim.launch(args, env)
                    if wait_for_markers(sim, helper, probe, spec["markers"], IPHONE_CONTENT_TIMEOUT, name):
                        settled = True
                        break
                    log(f"iphone {name}: attempt {attempt} timed out, relaunching")
                if not settled:
                    failures.append(f"{name}: missing content ({', '.join(spec['markers'])})")
                    continue
                time.sleep(IPHONE_STABILIZE)
                staged_path = stage(name)
                sim_screenshot(sim, staged_path)
                stage(name, done=True)
    finally:
        sim.delete()


def compress(path: Path) -> None:
    if shutil.which("pngquant"):
        subprocess.run(["pngquant", "--force", "--skip-if-larger", "--quality", "80-98", "--strip",
                        "--output", str(path), str(path)], check=False)
    if shutil.which("oxipng"):
        subprocess.run(["oxipng", "-q", "-o", "3", "--strip", "safe", str(path)], check=False)


# --------------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description="Capture privacy-safe README screenshots of the Corral clients.")
    parser.add_argument("--clients", default="mac,iphone", help="comma-separated: mac, iphone")
    parser.add_argument("--appearance", choices=["light", "dark", "both"], default="both")
    parser.add_argument("--size", default="1440x900", help="Mac window size in points, WIDTHxHEIGHT")
    parser.add_argument("--out", type=Path, default=APPLE / "docs" / "screenshots")
    parser.add_argument("--copy-to", type=Path, action="append", default=[],
                        help="also copy accepted images here, e.g. ../cli/docs/screenshots")
    parser.add_argument("--source", choices=["head", "worktree"], default="head",
                        help="build the committed client (default) or the working tree")
    parser.add_argument("--settle", type=float, default=12, help="seconds to let each Mac screen settle (iPhone shots poll for content instead)")
    parser.add_argument("--deny", action="append", default=[], help="extra private term for the OCR gate")
    parser.add_argument("--keep", action="store_true", help="keep the run directory for debugging")
    args = parser.parse_args()
    if sys.platform != "darwin":
        sys.exit("macOS only")
    clients = [c.strip() for c in args.clients.split(",") if c.strip()]
    if not clients or set(clients) - {"mac", "iphone"}:
        parser.error("--clients takes mac and/or iphone")

    if args.source == "worktree":
        source = APPLE
        log("building from the working tree")
    else:
        log(f"building from commit {_command_output(['git', '-C', str(APPLE), 'rev-parse', '--short', 'HEAD'])}")
        source = export_head()
    apps = {client: build_app(source, client) for client in clients}
    appearances = ["light", "dark"] if args.appearance == "both" else [args.appearance]
    terms = private_terms(args.deny)
    args.out.mkdir(parents=True, exist_ok=True)

    CAPTURE_ROOT.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix="run-", dir=CAPTURE_ROOT))
    helper = build_helper(run_dir)
    written: list[Path] = []
    failures: list[str] = []

    def accept(name: str, expected_size: str | None) -> None:
        staged, target = run_dir / name, args.out / name
        lines = json.loads(run([str(helper), "ocr", str(staged)], capture_output=True).stdout)[str(staged)]
        problems = privacy_violations(lines, terms)
        if expected_size and (wrong := size_problem(staged, expected_size)):
            problems.append(wrong)
        if problems:
            staged.unlink()
            failures.append(f"{name}: {', '.join(problems)}")
            return
        compress(staged)
        shutil.move(staged, target)
        written.append(target)
        for extra in args.copy_to:
            extra.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, extra / name)
            written.append(extra / name)
        log(f"wrote {target} ({target.stat().st_size // 1024} KB, {len(lines)} text lines checked)")

    def stage_iphone(name: str, done: bool = False) -> Path:
        if done:
            accept(name, None)
        return run_dir / name

    host = None
    mac_state = None
    try:
        # Each client gets its own demo host: pairing codes are one-time, so
        # the iPhone pairing would otherwise expire the Mac's code.
        if "iphone" in apps:
            host, info = start_demo_host(run_dir, free_port())
            log(f"demo host ready with {len(info['session_keys'])} fictional sessions")
            try:
                capture_iphone(apps["iphone"], info, appearances, helper, run_dir, stage_iphone, failures)
            finally:
                stop_demo_host(host)
                host = None
        if "mac" in apps:
            host, info = start_demo_host(run_dir, free_port())
            log(f"demo host ready with {len(info['session_keys'])} fictional sessions")
            mac_state = MacState.save(run_dir)
            for shot, indexes in MAC_SHOTS.items():
                keys = [info["session_keys"][i] for i in indexes]
                for appearance in appearances:
                    pid = launch_client(apps["mac"], run_dir, info, keys, appearance, args.size)
                    find_window(helper, pid)
                    time.sleep(args.settle)
                    window = find_window(helper, pid)
                    name = f"mac-{shot}-{appearance}.png"
                    run(["screencapture", "-x", "-o", "-l", str(window), str(run_dir / name)])
                    os.kill(pid, signal.SIGTERM)
                    while pid in corral_app_pids():
                        time.sleep(0.2)
                    accept(name, args.size)
    finally:
        if mac_state is not None:
            mac_state.restore(apps["mac"])
        if host is not None:
            stop_demo_host(host)
        if args.keep:
            log(f"kept {run_dir}")
        else:
            shutil.rmtree(run_dir, ignore_errors=True)

    print(json.dumps({"ok": not failures, "written": [str(p) for p in written], "failures": failures}, indent=2))
    return 1 if failures else 0


class MacState:
    """The user's Mac client state around a capture: preferences and the running installed app."""

    def __init__(self, backup: Path, had_defaults: bool, relaunch_installed: bool) -> None:
        self.backup, self.had_defaults, self.relaunch_installed = backup, had_defaults, relaunch_installed

    @classmethod
    def save(cls, run_dir: Path) -> "MacState":
        backup = run_dir / "defaults.plist"
        had = subprocess.run(["defaults", "export", BUNDLE_ID, str(backup)], capture_output=True).returncode == 0
        return cls(backup, had, stop_client_apps())

    def restore(self, app: Path) -> None:
        for pid in corral_app_pids():
            if pid_executable(pid).startswith(str(app)):
                os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 10
        while any(pid_executable(p).startswith(str(app)) for p in corral_app_pids()) and time.monotonic() < deadline:
            time.sleep(0.2)
        if self.had_defaults:
            subprocess.run(["defaults", "import", BUNDLE_ID, str(self.backup)], check=False)
        else:
            subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True, check=False)
        if self.relaunch_installed:
            subprocess.run(["open", "-g", str(INSTALLED_APP)], check=False)


if __name__ == "__main__":
    sys.exit(main())
