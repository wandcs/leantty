"""Replay all extracted HostBytes cases in a disposable mosh-client source copy."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import os


RUST_TEST = r'''
#[cfg(test)]
mod leantty_disconnect_cases {
    use super::*;

    #[test]
    fn replay_all() {
        let input = std::fs::read_to_string(std::env::var("MOSH_CASE_INPUT").unwrap()).unwrap();
        for line in input.lines() {
            let (id, parts) = line.split_once('\t').unwrap();
            let mut state = TerminalState::new(147, 43).unwrap();
            let mut result = Ok(());
            let mut failed_step = 0;
            for (index, part) in parts.split(',').enumerate() {
                let bytes: Vec<u8> = part.as_bytes().chunks(2)
                    .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
                    .collect();
                result = state.apply_host_bytes(&bytes);
                if result.is_err() {
                    failed_step = index;
                    break;
                }
            }
            eprintln!("CASE_RESULT\t{id}\t{failed_step}\t{result:?}");
        }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path, help="New, disposable directory")
    parser.add_argument("--scan", action="store_true", help="Replay all 277 exploratory inputs")
    args = parser.parse_args()
    source, work = args.source.resolve(), args.work.resolve()
    state_path = Path("src/terminal/state.rs")
    if not (source / state_path).is_file():
        parser.error("source must contain src/terminal/state.rs")
    if work.exists() or work.is_relative_to(source):
        parser.error("work must not exist and must be outside source")

    pack = json.loads(Path(__file__).with_name("cases.json").read_text(encoding="utf-8"))
    cases = [case for group in pack["groups"] for case in group["cases"]]
    if args.scan:
        cases = [json.loads(line) for line in Path(__file__).with_name("scan-cases.jsonl")
                 .read_text(encoding="utf-8").splitlines() if line.strip()]
    work.mkdir(parents=True)
    copied = work / "client"
    shutil.copytree(source, copied, ignore=shutil.ignore_patterns(".git", "target"))
    original = (copied / state_path).read_text(encoding="utf-8")
    with (copied / state_path).open("a", encoding="utf-8") as output:
        output.write("\n" + RUST_TEST)
    assert (source / state_path).read_text(encoding="utf-8") == original
    input_path = work / "cases.tsv"
    input_path.write_text("".join(
        case["id"] + "\t" + ",".join(case["host_bytes_hex"]) + "\n" for case in cases
    ), encoding="utf-8")
    env = os.environ.copy()
    env["MOSH_CASE_INPUT"] = str(input_path)
    env.setdefault("CARGO_TARGET_DIR", str(work / "target"))
    result = subprocess.run(
        ["cargo", "test", "--locked", "--offline", "--lib",
         "leantty_disconnect_cases::replay_all", "--", "--nocapture", "--test-threads=1"],
        cwd=copied, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240,
    )
    (work / "cargo.log").write_bytes(result.stdout)
    observations = {name: {"step": int(step), "result": outcome}
                    for name, step, outcome in re.findall(
                        r"CASE_RESULT\t([^\t]+)\t(\d+)\t([^\r\n]+)",
                        result.stdout.decode(errors="replace"))}
    report = {"executionExit": result.returncode, "source": str(source),
              "baselineCommit": pack["commit"], "cases": []}
    for case in cases:
        actual = observations.get(case["id"])
        report["cases"].append({"id": case["id"], "actual": actual,
                                "baseline": case["raw_baseline"],
                                "changed": actual != case["raw_baseline"]})
    (work / "results.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if result.returncode or len(observations) != len(cases):
        raise SystemExit(f"Incomplete execution; inspect {work / 'cargo.log'}")
    changed = sum(case["changed"] for case in report["cases"])
    print(f"Executed {len(cases)} cases; {changed} differ from baseline. Results: {work / 'results.json'}")
    print("Execution completion is not a repair or release verdict; review each case category.")


if __name__ == "__main__":
    main()
