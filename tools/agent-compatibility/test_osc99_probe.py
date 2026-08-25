#!/usr/bin/env python3
"""Exercise the zero-model OSC 99 probe through a local pseudo-terminal."""

from __future__ import annotations

import json
import os
import pty
import select
import sys
import time


QUERY = b"\x1b]99;i=opentui-notifications:p=?;\x1b\\"
RESPONSE = b"\x1b]99;i=opentui-notifications:p=?;p=title,body\x1b\\"


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: test_osc99_probe.py HARNESS RUN_ROOT")
    harness, run_root = sys.argv[1:]
    child_pid, master = pty.fork()
    if child_pid == 0:
        os.execv(harness, [harness, "osc99-probe", run_root])
    observed = bytearray()
    replied = False
    child_status = None
    deadline = time.monotonic() + 10
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.25)
            if not ready:
                waited_pid, status = os.waitpid(child_pid, os.WNOHANG)
                if waited_pid == child_pid:
                    child_status = status
                    break
                continue
            try:
                chunk = os.read(master, 1024)
            except OSError:
                break
            if not chunk:
                break
            observed.extend(chunk)
            if not replied and QUERY in observed:
                os.write(master, RESPONSE)
                replied = True
            if len(observed) > 4096:
                del observed[:-4096]
        if child_status is None:
            _, child_status = os.waitpid(child_pid, 0)
        exit_code = os.waitstatus_to_exitcode(child_status)
    finally:
        os.close(master)

    result_path = os.path.join(run_root, "results", "osc99-capability-probe.json")
    with open(result_path, encoding="utf-8") as source:
        result = json.load(source)
    assert replied, (
        "probe did not write the standard OSC 99 query; "
        f"errorKind={result['errorKind']!r}, errorCode={result['errorCode']!r}, "
        f"inputIsTty={result['inputIsTty']!r}, observedHex={bytes(observed).hex()}"
    )
    assert exit_code == 0, f"probe exited with {exit_code}"
    assert result["plannedModelRequests"] == 0
    assert result["responseObserved"] is True
    assert result["responseCount"] == 1
    assert result["inputIsTty"] is True
    assert result["errorKind"] is None
    assert result["privacy"] == {
        "rawResponseRetained": False,
        "queryIdentifierIncluded": False,
        "contentIncluded": False,
    }
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
