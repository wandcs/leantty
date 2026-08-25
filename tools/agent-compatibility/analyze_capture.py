#!/usr/bin/env python3
"""Summarize a controlled Agent TUI PTY capture without retaining its content."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path


OSC_PATTERN = re.compile(rb"\x1b\](\d+)(?:;([^\x07\x1b]*))?(?:\x07|\x1b\\)")
OSC99_METADATA_VALUE = re.compile(rb"^[A-Za-z0-9\-_\/+.,(){}\[\]*&^%$#@!`~]+$")
BASE64_PAYLOAD = re.compile(rb"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
MAX_ATTENTION_OSC_BYTES = 1024


def count(data: bytes, value: bytes) -> int:
    return data.count(value)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def contains_cjk(text: str) -> bool:
    return any(
        "\u3400" <= character <= "\u4dbf"
        or "\u4e00" <= character <= "\u9fff"
        for character in text
    )


def summarize_osc(output: bytes) -> dict[str, int]:
    counts: dict[str, int] = {}
    for match in OSC_PATTERN.finditer(output):
        code = match.group(1).decode("ascii")
        counts[code] = counts.get(code, 0) + 1
    return dict(sorted(counts.items(), key=lambda item: int(item[0])))


def summarize_osc8(output: bytes) -> tuple[int, int, int]:
    opened = 0
    reset = 0
    malformed = 0
    for match in OSC_PATTERN.finditer(output):
        if match.group(1) != b"8":
            continue
        payload = match.group(2)
        if payload is None:
            malformed += 1
            continue
        separator = payload.find(b";")
        if separator < 0:
            malformed += 1
        elif payload[separator + 1 :]:
            opened += 1
        else:
            reset += 1
    return opened, reset, malformed


def is_osc99_attention(payload: bytes | None) -> bool:
    if not payload or len(payload) > MAX_ATTENTION_OSC_BYTES:
        return False
    separator = payload.find(b";")
    if separator < 0:
        return False
    metadata = payload[:separator]
    content = payload[separator + 1 :]
    if not content:
        return False

    fields: dict[bytes, bytes] = {}
    if metadata:
        for entry in metadata.split(b":"):
            if len(entry) <= 2 or entry[1:2] != b"=":
                return False
            key = entry[:1]
            value = entry[2:]
            if key not in (b"i", b"p", b"e", b"d") or key in fields:
                return False
            if not OSC99_METADATA_VALUE.fullmatch(value):
                return False
            fields[key] = value

    if fields.get(b"p", b"title") not in (b"title", b"body"):
        return False
    if fields.get(b"d", b"1") != b"1":
        return False
    encoding = fields.get(b"e")
    if encoding is not None and encoding != b"1":
        return False
    if encoding == b"1":
        return len(content) % 4 != 1 and BASE64_PAYLOAD.fullmatch(content) is not None
    return not any(byte < 0x20 or byte == 0x7F for byte in content)


def summarize_osc99_attention(output: bytes) -> tuple[int, int]:
    accepted = 0
    ignored = 0
    for match in OSC_PATTERN.finditer(output):
        if match.group(1) != b"99":
            continue
        if is_osc99_attention(match.group(2)):
            accepted += 1
        else:
            ignored += 1
    return accepted, ignored


def is_osc99_capability_response(payload: bytes | None) -> bool:
    if not payload or len(payload) > MAX_ATTENTION_OSC_BYTES:
        return False
    separator = payload.find(b";")
    if separator < 0 or payload[separator + 1 :] != b"p=title,body":
        return False
    fields: dict[bytes, bytes] = {}
    for entry in payload[:separator].split(b":"):
        if len(entry) <= 2 or entry[1:2] != b"=":
            return False
        key = entry[:1]
        value = entry[2:]
        if key not in (b"i", b"p") or key in fields:
            return False
        if key == b"p" and value == b"?":
            fields[key] = value
            continue
        if not OSC99_METADATA_VALUE.fullmatch(value):
            return False
        fields[key] = value
    return len(fields) == 2 and fields.get(b"p") == b"?"


def count_osc99_capability_responses(input_bytes: bytes) -> int:
    return sum(
        1
        for match in OSC_PATTERN.finditer(input_bytes)
        if match.group(1) == b"99" and is_osc99_capability_response(match.group(2))
    )


def count_standalone_bel(output: bytes) -> tuple[int, int]:
    standalone = 0
    osc_terminators = 0
    cursor = 0
    for match in OSC_PATTERN.finditer(output):
        standalone += output[cursor : match.start()].count(b"\x07")
        if match.group(0).endswith(b"\x07"):
            osc_terminators += 1
        cursor = match.end()
    standalone += output[cursor:].count(b"\x07")
    return standalone, osc_terminators


def assert_run_owned(path: Path, run_root: Path) -> None:
    resolved = path.resolve()
    root = run_root.resolve()
    if root != resolved and root not in resolved.parents:
        raise ValueError(f"capture path is outside the run root: {resolved}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--child-exit-code", required=True, type=int)
    parser.add_argument("--delete-raw", action="store_true")
    arguments = parser.parse_args()

    run_root = Path(arguments.run_root)
    sentinel = run_root / ".leantty-agent-compat"
    if not sentinel.is_file() or sentinel.read_text(encoding="utf-8") != "controlled-pty-capture\n":
        raise ValueError("run root is missing the exact LeanTTY capture sentinel")

    input_path = Path(arguments.input)
    output_path = Path(arguments.output)
    result_path = Path(arguments.result)
    for path in (input_path, output_path, result_path):
        assert_run_owned(path, run_root)

    input_bytes = input_path.read_bytes()
    output_bytes = output_path.read_bytes()
    input_text = input_bytes.decode("utf-8", errors="ignore")
    osc99_capability_response_count = count_osc99_capability_responses(input_bytes)
    osc_counts = summarize_osc(output_bytes)
    osc8_hyperlink_count, osc8_reset_count, osc8_malformed_count = summarize_osc8(output_bytes)
    osc99_attention_count, osc99_ignored_count = summarize_osc99_attention(output_bytes)
    standalone_bel_count, osc_bel_terminator_count = count_standalone_bel(output_bytes)
    native_signal_kinds: list[str] = []
    if standalone_bel_count:
        native_signal_kinds.append("bel")
    for code in ("9", "777"):
        if osc_counts.get(code, 0):
            native_signal_kinds.append(f"osc-{code}")
    if osc99_attention_count:
        native_signal_kinds.append("osc-99")

    summary = {
        "schemaVersion": 1,
        "capture": arguments.name,
        "childExitCode": arguments.child_exit_code,
        "privacy": {
            "rawInputRetained": not arguments.delete_raw,
            "rawOutputRetained": not arguments.delete_raw,
            "contentIncludedInSummary": False,
        },
        "input": {
            "bytes": len(input_bytes),
            "sha256": sha256(input_bytes),
            "escapeCount": count(input_bytes, b"\x1b"),
            "carriageReturnCount": count(input_bytes, b"\r"),
            "lineFeedCount": count(input_bytes, b"\n"),
            "bracketedPasteStartCount": count(input_bytes, b"\x1b[200~"),
            "bracketedPasteEndCount": count(input_bytes, b"\x1b[201~"),
            "focusReporting": {
                "inCount": count(input_bytes, b"\x1b[I"),
                "outCount": count(input_bytes, b"\x1b[O"),
            },
            "osc99CapabilityResponseCount": osc99_capability_response_count,
            "containsControlledEnglishMarker": b"leanttyime" in input_bytes,
            "containsCjkUtf8": contains_cjk(input_text),
        },
        "output": {
            "bytes": len(output_bytes),
            "sha256": sha256(output_bytes),
            "belCount": standalone_bel_count,
            "oscBelTerminatorCount": osc_bel_terminator_count,
            "oscCounts": osc_counts,
            "osc99AttentionFrameCount": osc99_attention_count,
            "osc99IgnoredFrameCount": osc99_ignored_count,
            "alternateScreen": {
                "enterCount": sum(
                    count(output_bytes, sequence)
                    for sequence in (b"\x1b[?1049h", b"\x1b[?1047h", b"\x1b[?47h")
                ),
                "exitCount": sum(
                    count(output_bytes, sequence)
                    for sequence in (b"\x1b[?1049l", b"\x1b[?1047l", b"\x1b[?47l")
                ),
            },
            "bracketedPaste": {
                "enableCount": count(output_bytes, b"\x1b[?2004h"),
                "disableCount": count(output_bytes, b"\x1b[?2004l"),
            },
            "focusReporting": {
                "enableCount": count(output_bytes, b"\x1b[?1004h"),
                "disableCount": count(output_bytes, b"\x1b[?1004l"),
            },
            "nativeAttentionSignalKinds": native_signal_kinds,
            "nativeAttentionSignalObserved": bool(native_signal_kinds),
            "osc8HyperlinkCount": osc8_hyperlink_count,
            "osc8ResetCount": osc8_reset_count,
            "osc8MalformedCount": osc8_malformed_count,
            "osc52ClipboardCount": osc_counts.get("52", 0),
            "kittyKeyboardSequenceCount": len(
                re.findall(rb"\x1b(?:\[>|\[\?)[0-9;]*u", output_bytes)
            ),
        },
    }

    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    os.chmod(result_path, 0o600)

    if arguments.delete_raw:
        input_path.unlink(missing_ok=True)
        output_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
