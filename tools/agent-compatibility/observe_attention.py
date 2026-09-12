#!/usr/bin/env python3
"""Content-free outer PTY evidence. Byte barriers order observations, not delivery."""

import argparse
import json
import os
import re
from pathlib import Path

from analyze_capture import OSC_PATTERN, assert_run_owned, is_osc99_attention


def attention_events(data: bytes) -> list[dict]:
    events = []
    cursor = 0
    while cursor < len(data):
        start = cursor
        if data[cursor:cursor + 2] in (b"\x1b]", b"\x1bP", b"\x1bX", b"\x1b^", b"\x1b_"):
            osc = data[cursor + 1] == ord("]")
            end = re.search(rb"\x07|\x1b\\" if osc else rb"\x1b\\", data[cursor + 2:])
            if end is None:
                break  # Incomplete strings never turn their payload into standalone BEL.
            cursor += 2 + end.end()
            frame = data[start:cursor]
            match = OSC_PATTERN.fullmatch(frame) if osc else None
            if match and (match[1] in (b"9", b"777") or
                          (match[1] == b"99" and is_osc99_attention(match[2]))):
                events.append({"kind": "osc-" + match[1].decode("ascii"), "start": start, "end": cursor})
        else:
            cursor += 1
            if data[start] == 7:
                events.append({"kind": "bel", "start": start, "end": cursor})
        if len(events) > 4096:
            raise ValueError("outer attention event limit exceeded")
    return events


def summarize(capture: dict, marks: dict) -> dict:
    before = marks.get("before-minimize")
    hidden = marks.get("after-hidden")
    if before is not None and not 0 <= before <= capture["bytes"]:
        raise ValueError("outer capture shrank after checkpoint")
    if hidden is not None and (before is None or not before <= hidden <= capture["bytes"]):
        raise ValueError("outer hidden checkpoint is out of order")
    events = capture["events"]
    early = [event for event in events if before is not None and event["end"] <= before]
    late = [event for event in events if hidden is not None and event["start"] >= hidden]
    after_start = [event for event in events if before is not None and event["start"] >= before]
    return {
        "schemaVersion": 1,
        "boundary": "remote-outer-pty-not-client-receipt",
        "bytes": capture["bytes"],
        "complete": capture["complete"],
        "childExitCode": capture["childExitCode"],
        "checkpoints": marks,
        "attentionCount": len(events),
        "beforeMinimizeCount": len(early),
        "hideIntervalOrUnorderedCount": len(events) - len(early) - len(late),
        "afterHiddenCount": len(late),
        "afterMinimizeStartCount": len(after_start),
        "afterHiddenKinds": sorted({event["kind"] for event in late}),
        "privacy": {"contentIncludedInSummary": False},
    }


def write_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + f".{os.getpid()}.tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def observe(run_root: Path, name: str, action: str, exit_code: int = -1) -> dict:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", name):
        raise ValueError("invalid outer capture name")
    if (run_root / ".leantty-agent-compat").read_text() != "controlled-pty-capture\n":
        raise ValueError("missing controlled capture sentinel")
    raw = run_root / "captures" / f"{name}.outer-output"
    final = run_root / "results" / f"{name}-outer-final.json"
    checkpoint = run_root / "captures" / f"{name}.outer-checkpoints"
    result = run_root / "results" / f"{name}-outer-observation.json"
    for path in (raw, final, checkpoint, result):
        assert_run_owned(path, run_root)
    # The final summary is published before raw deletion. A concurrent finalizer
    # may remove raw after the existence check; only that known final is fallback.
    if final.exists():
        capture = json.loads(final.read_text())
    else:
        try:
            data = raw.read_bytes()
        except FileNotFoundError:
            capture = json.loads(final.read_text())
        else:
            capture = {"bytes": len(data), "events": attention_events(data),
                       "complete": action == "finish", "childExitCode": exit_code,
                       "privacy": {"contentIncludedInSummary": False}}
    marks = json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    if action in ("before-minimize", "after-hidden"):
        if action in marks:
            raise ValueError("outer checkpoint cannot be replaced")
        marks[action] = capture["bytes"]
        summarize(capture, marks)  # Validate ordering before persisting a barrier.
        write_json(checkpoint, marks)
    summary = summarize(capture, marks)
    if action == "finish":
        write_json(final, capture)
        raw.unlink(missing_ok=True)
    write_json(result, summary)
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_root", type=Path)
    parser.add_argument("name")
    parser.add_argument("action", choices=("before-minimize", "after-hidden", "probe", "finish"))
    parser.add_argument("--exit-code", type=int, default=-1)
    args = parser.parse_args()
    observe(args.run_root, args.name, args.action, args.exit_code)
