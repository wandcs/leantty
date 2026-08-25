#!/usr/bin/env python3
"""Probe LeanTTY's bounded OSC 99 capability response over the active PTY."""

from __future__ import annotations

import json
import os
import select
import sys
import termios
import time
import tty


TIMEOUT_SECONDS = 5
QUERY = b"\x1b]99;i=opentui-notifications:p=?;\x1b\\"
EXPECTED = b"\x1b]99;i=opentui-notifications:p=?;p=title,body\x1b\\"


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: osc99_capability_probe.py RESULT_PATH")
    result_path = sys.argv[1]
    input_fd = sys.stdin.fileno()
    output_fd = sys.stdout.fileno()
    received = bytearray()
    response_count = 0
    error_kind = None
    error_code = None
    original = None

    try:
        original = termios.tcgetattr(input_fd)
        tty.setraw(input_fd)
        os.write(output_fd, QUERY)
        deadline = time.monotonic() + TIMEOUT_SECONDS
        while time.monotonic() < deadline and len(received) < 4096:
            remaining = deadline - time.monotonic()
            ready, _, _ = select.select([input_fd], [], [], max(0, remaining))
            if not ready:
                break
            chunk = os.read(input_fd, min(1024, 4096 - len(received)))
            if not chunk:
                break
            received.extend(chunk)
            if EXPECTED in received:
                break
        response_count = bytes(received).count(EXPECTED)
    except BaseException as error:
        error_kind = type(error).__name__
        if error.args and isinstance(error.args[0], int):
            error_code = error.args[0]
    finally:
        if original is not None:
            termios.tcsetattr(input_fd, termios.TCSADRAIN, original)

    result = {
        "schemaVersion": 1,
        "probe": "osc99-capability-response",
        "plannedModelRequests": 0,
        "responseObserved": response_count == 1,
        "responseCount": response_count,
        "receivedBytes": len(received),
        "timeoutSeconds": TIMEOUT_SECONDS,
        "inputIsTty": os.isatty(input_fd),
        "errorKind": error_kind,
        "errorCode": error_code,
        "privacy": {
            "rawResponseRetained": False,
            "queryIdentifierIncluded": False,
            "contentIncluded": False,
        },
    }
    with open(result_path, "w", encoding="utf-8") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    os.chmod(result_path, 0o600)
    print(
        "OSC99_CAPABILITY_RESPONSE_OK"
        if result["responseObserved"]
        else "OSC99_CAPABILITY_RESPONSE_MISSING"
    )
    return 0 if result["responseObserved"] else 5


if __name__ == "__main__":
    raise SystemExit(main())
