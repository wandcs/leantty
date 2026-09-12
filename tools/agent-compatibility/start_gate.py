#!/usr/bin/env python3
"""Single-use Agent launch barrier inside the existing outer PTY (no byte relay)."""
import argparse
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import time

from observe_attention import assert_run_owned, write_json


class Gate:
    def __init__(self, root, name):
        root = root.resolve()
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", name):
            raise ValueError("invalid gate name")
        self.state = root / "results" / f"{name}-start-gate.json"
        self.lock = root / "captures" / f"{name}.start-lock"
        self.checkpoints = root / "captures" / f"{name}.outer-checkpoints"
        self.output = root / "captures" / f"{name}.outer-output"
        for path in (self.state, self.lock, self.checkpoints, self.output):
            assert_run_owned(path, root)
        if (root / ".leantty-agent-compat").read_text() != "controlled-pty-capture\n":
            raise ValueError("invalid fixture sentinel")

    @contextmanager
    def locked(self):
        with self.lock.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = json.loads(self.state.read_text()) if self.state.exists() else {}
            original = dict(state)
            try:
                yield state
            finally:
                if state != original:
                    write_json(self.state, state)

    def control(self, action):
        with self.locked() as state:
            if action == "cancel" and state.get("status") in (None, "waiting", "released"):
                state["status"] = "cancelled"  # Also prevents a late-arriving launch.
            elif action in ("ready", "release"):
                if state.get("status") == "waiting" and time.monotonic() >= state["deadline"]:
                    state["status"] = "expired"
                if state.get("status") != "waiting":
                    raise ValueError("gate is not waiting")
                os.kill(state["pid"], 0)
                if action == "release":
                    marks = json.loads(self.checkpoints.read_text())
                    before, hidden = marks.get("before-minimize"), marks.get("after-hidden")
                    if not (type(before) is int and type(hidden) is int and
                            0 <= before <= hidden <= self.output.stat().st_size):
                        raise ValueError("hidden-window checkpoint missing or invalid")
                    state.update(status="released", hiddenOffset=hidden)
            elif action != "cancel" or state.get("status") != "cancelled":
                raise ValueError("gate cannot be cancelled after startup")
            return dict(state)

    def hold(self, command, timeout=60):
        if not command or not 0 < timeout <= 60 or not all(os.isatty(fd) for fd in (0, 1, 2)):
            raise ValueError("gate requires a bounded command in the outer PTY")
        with self.locked() as state:
            if state or self.checkpoints.exists() or not self.output.exists():
                raise ValueError("gate or observation already used")
            state.update(status="waiting", pid=os.getpid(), deadline=time.monotonic() + timeout)
        def interrupted(signum, _frame):
            raise SystemExit(128 + signum)
        for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, interrupted)
        try:
            while True:
                with self.locked() as state:
                    if time.monotonic() >= state["deadline"] and state["status"] in ("waiting", "released"):
                        state["status"] = "expired"
                    if state["status"] == "released":
                        # This is the cancellation boundary, not proof of child output.
                        state["status"] = "started"
                        break
                    if state["status"] != "waiting":
                        return 124 if state["status"] == "expired" else 125
                time.sleep(.02)
            # exec inherits the original PTY, environment and argv. No input or
            # output is consumed, transformed, injected or replayed by this gate.
            os.execvp(command[0], command)
        except BaseException:
            with self.locked() as state:
                if state.get("status") in ("waiting", "released"):
                    state["status"] = "cancelled"
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("name")
    parser.add_argument("action", choices=("hold", "ready", "release", "cancel"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    os.umask(0o077)
    gate = Gate(args.root, args.name)
    if args.action == "hold":
        command = args.command[1:] if args.command[:1] == ["--"] else args.command
        raise SystemExit(gate.hold(command))
    if args.command:
        parser.error("control actions take no command")
    gate.control(args.action)
