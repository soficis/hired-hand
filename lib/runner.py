"""Run an OpenCode process under a watchdog.

The runner streams OpenCode's JSON events, stops the process tree on timeout,
idle silence, a repeated step loop, or consecutive provider errors, and exits
with a code that tells the caller what happened.
"""

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

SYNC = (
    "Work synchronously in this single turn. Do NOT dispatch background, parallel or sub-agents, "
    "and do not end your turn while waiting for anything: if you need several lookups, make them "
    "yourself one after another. Your last message must be the complete final answer (say plainly "
    "what you could not finish)."
)

UNFINISHED = (
    "background agent",
    "dispatched",
    "still running",
    "still checking",
    "will fold",
    "i'll fold",
    "waiting on",
    "once they report",
    "agents are still",
)

UP_STRONG = re.compile(
    r"(?i)(?:"
    r"\b(?:http(?:/\d(?:\.\d)?)?[\s:=-]*)?429\b"
    r"|\bhttp(?:/\d(?:\.\d)?)?[\s:=-]*5\d\d\b"
    r"|\b(?:status|code|error)[\s:=#-]*5\d\d\b"
    r"|rate[\s_-]*limit"
    r"|overloaded"
    r"|upstream"
    r"|econnreset\b"
    r"|internal server error"
    r"|bad gateway"
    r"|service unavailable"
    r"|gateway time-?out"
    r")"
)
UP_WEAK = re.compile(r"(?i)\b(?:timeout|timed out)\b")
UP_CONTEXT = re.compile(r"(?i)\b(?:error|failed|failure|abort(?:ed)?|provider|request)\b")
ERR_TYPES = ("error", "api_error", "provider_error")
TOOL_TYPES = ("tool", "tool_use", "tool_result", "tool_call")
PROSE_SKIP = ("type", "id", "sessionID", "tool", "callID")

MAX_STEPS = 80
LOOP_STEPS = 2
DONE_GRACE = 20
POLL_SECONDS = 2


def _safe_stdio():
    """Keep console encoding errors from killing the output reader thread."""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError, OSError):
            pass


def _prose(value, out, depth=0):
    """Collect human-readable strings from an event, skipping ids and tool names."""
    if depth > 5:
        return out
    if isinstance(value, str):
        if value.strip():
            out.append(value.strip())
    elif isinstance(value, dict):
        for key, item in value.items():
            if key in PROSE_SKIP:
                continue
            _prose(item, out, depth + 1)
    elif isinstance(value, list):
        for item in value:
            _prose(item, out, depth + 1)
    return out


def upstream_error(event):
    """Return the provider-failure text for an event, or None for normal output."""
    kind = str(event.get("type") or "").lower()
    text = " ".join(_prose(event, []))
    if kind in ERR_TYPES or kind.endswith(".error") or kind.endswith("_error"):
        return (text or kind or "error event")[:400]
    if kind in TOOL_TYPES or kind.startswith("tool."):
        return None
    if UP_STRONG.search(text):
        return text[:400]
    if UP_WEAK.search(text) and UP_CONTEXT.search(text):
        return text[:400]
    return None


class Upstream:
    """Count consecutive provider errors; tool work resets the streak."""

    QUIET = ("step_start", "text", "step_finish", "reasoning")

    def __init__(self, stop_after=2):
        self.stop_after = max(1, int(stop_after))
        self.n = 0
        self.last = ""

    @property
    def tripped(self):
        return self.n >= self.stop_after

    def feed(self, event):
        message = upstream_error(event)
        if message is not None:
            self.n += 1
            self.last = message[:200]
            return True
        if str(event.get("type") or "").lower() not in self.QUIET:
            self.n = 0
        return False


_PYTHON_BIN_RE = re.compile(r"python(\.exe)?|python3(\.\d+)?(\.exe)?", re.IGNORECASE)


def _is_python_binary(path):
    """Match python binaries across platforms: python, python3, python3.15, .exe variants."""
    name = path.replace("\\", "/").split("/")[-1]
    return _PYTHON_BIN_RE.fullmatch(name) is not None


def _resolve_executable():
    raw = os.environ.get("HH_OPENCODE", "")
    if raw:
        first, sep, rest = raw.partition(" ")
        if sep and _is_python_binary(first):
            return [first, rest]
        return [raw]
    found = shutil.which("opencode")
    if not found:
        return None
    if os.name == "nt" and found.lower().endswith((".cmd", ".bat")):
        return [os.environ.get("COMSPEC", "cmd.exe"), "/c", found]
    return [found]


def _kill_tree(process):
    """Stop the child and every process it started. Never raises."""
    try:
        if os.name == "nt":
            subprocess.run(
                ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            return
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    except Exception:
        pass


def _interrupt(signum, frame):
    raise KeyboardInterrupt()


def _watch(process, timeout, idle, unfinished_check):
    started = time.time()
    state = {
        "last": started,
        "tail": "",
        "steps": 0,
        "tools": 0,
        "empty": 0,
        "last_text": None,
        "since_text_events": 0,
    }
    upstream = Upstream()
    verdict = {"why": None, "rc": None}
    ok_note = {"text": None}

    def pump():
        for raw in iter(process.stdout.readline, b""):
            line = raw.decode("utf-8", "replace").strip()
            now = time.time()
            state["last"] = now
            try:
                event = json.loads(line)
            except ValueError:
                if line:
                    print(line, flush=True)
                continue
            kind = event.get("type")
            part = event.get("part") or {}
            if upstream.feed(event):
                if upstream.tripped and not verdict["why"]:
                    verdict.update(why="upstream errors", rc=6)
                if kind != "text":
                    print("  ! provider error: " + (upstream.last or "?"), flush=True)
                    continue
            if kind == "step_start":
                if state["steps"] > 0:
                    state["empty"] = state["empty"] + 1 if state["tools"] == 0 else 0
                state["steps"] += 1
                state["tools"] = 0
                if state["empty"] >= LOOP_STEPS and not verdict["why"]:
                    verdict.update(
                        why="looping: %d steps in a row did no tool work (answer repeated?)"
                        % state["empty"],
                        rc=4,
                    )
                if state["steps"] > MAX_STEPS and not verdict["why"]:
                    verdict.update(why="over %d steps" % MAX_STEPS, rc=4)
                state["since_text_events"] += 1
            elif kind == "text":
                text = part.get("text") or ""
                state["tail"] = (state["tail"] + text)[-1500:]
                state["last_text"] = now
                state["since_text_events"] = 0
                print(text, flush=True)
            elif kind == "step_finish":
                pass
            elif kind == "reasoning":
                pass
            else:
                state["tools"] += 1
                state["since_text_events"] += 1
                tool = part.get("tool")
                print("  . " + str(kind) + (" " + str(tool) if tool else ""), flush=True)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    rc = None
    why = None
    while rc is None:
        try:
            rc = process.wait(timeout=POLL_SECONDS)
        except subprocess.TimeoutExpired:
            now = time.time()
            if verdict["why"]:
                why, rc = verdict["why"], verdict["rc"]
            elif now - started > timeout:
                why, rc = "timeout %ds" % timeout, 124
            elif now - state["last"] > idle:
                why, rc = "no output for %ds (silent thinking or stalled)" % idle, 125
            elif (
                state["last_text"]
                and state["since_text_events"] == 0
                and now - state["last_text"] > DONE_GRACE
            ):
                ok_note["text"] = (
                    "answer delivered; process lingered %ds after it, stopped" % DONE_GRACE
                )
                rc = 0
            if why or ok_note["text"]:
                _kill_tree(process)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
    reader.join(3)
    if verdict["why"] and verdict["rc"] == 6:
        rc, why = 6, verdict["why"]
    if rc == 6:
        print("runner: last provider error: " + (upstream.last or "")[:200], file=sys.stderr)
    if (
        rc == 0
        and not ok_note["text"]
        and unfinished_check
        and any(key in state["tail"].lower() for key in UNFINISHED)
    ):
        why, rc = "answer ended while still waiting on something (unfinished)", 3
    note = why or ok_note["text"]
    if note:
        print("runner: " + note, file=sys.stderr)
    return rc


def main(argv):
    _safe_stdio()
    if "--" in argv:
        index = argv.index("--")
        own, child_args = argv[:index], argv[index + 1:]
    else:
        own, child_args = argv, []

    parser = argparse.ArgumentParser(prog="runner.py")
    parser.add_argument("--timeout", type=int, default=1500)
    parser.add_argument("--idle", type=int, default=240)
    parser.add_argument("--project", default=".")
    parser.add_argument("--sync", action="store_true")
    parser.add_argument("--no-standalone", action="store_true")
    parser.add_argument("--no-isolate", action="store_true")
    parser.add_argument("--unfinished-check", action="store_true")
    args = parser.parse_args(own)

    executable = _resolve_executable()
    if executable is None:
        print("runner: opencode not found (set HH_OPENCODE)", file=sys.stderr)
        return 2

    project = os.path.abspath(args.project)
    if not os.path.isdir(project):
        print("runner: project directory not found: " + project, file=sys.stderr)
        return 2

    command = list(child_args)
    if command and command[0] == "run":
        if args.sync and len(command) > 1:
            command[-1] = command[-1] + " " + SYNC
        if not args.no_standalone and "--standalone" not in command:
            command.insert(1, "--standalone")
        if not any(
            item == "--format" or item.startswith("--format=") for item in command
        ):
            command[1:1] = ["--format", "json"]

    env = dict(os.environ)
    env["PWD"] = project
    env["INIT_CWD"] = project
    if not args.no_isolate:
        repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        isolated = os.path.join(repo, "share", "opencode-isolated")
        if os.path.isdir(os.path.join(isolated, "opencode")):
            env["XDG_CONFIG_HOME"] = isolated

    kwargs = {}
    if os.name == "nt":
        kwargs["creationflags"] = 0x00000200
    else:
        kwargs["start_new_session"] = True

    old_handlers = {}
    for name in ("SIGINT", "SIGTERM"):
        sig = getattr(signal, name, None)
        if sig is not None:
            try:
                old_handlers[sig] = signal.signal(sig, _interrupt)
            except (OSError, ValueError):
                pass

    process = None
    try:
        process = subprocess.Popen(
            executable + command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=project,
            env=env,
            **kwargs
        )
        return _watch(process, args.timeout, args.idle, args.unfinished_check)
    except KeyboardInterrupt:
        print("runner: interrupted", file=sys.stderr)
        return 130
    except OSError as error:
        print("runner: could not start opencode: %s" % error, file=sys.stderr)
        return 2
    finally:
        if process is not None and process.poll() is None:
            _kill_tree(process)
        for sig, handler in old_handlers.items():
            try:
                signal.signal(sig, handler)
            except (OSError, ValueError):
                pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
