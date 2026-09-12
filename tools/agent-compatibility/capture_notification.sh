#!/usr/bin/env bash
# Agent-only outer capture; the shared WSL fixture and Mosh stay unchanged.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fixture="$script_dir/../agent-compatibility-wsl.sh"

if [[ "${1:-}" != "capture" ]]; then
  [[ $# -eq 4 ]] || exit 2
  run_root="$1"; agent="$2"; mode="$3"; scenario="$4"
  [[ "$agent" =~ ^(codex|opencode|pi|qwen)$ && "$mode" =~ ^(direct|tmux)$ &&
     "$scenario" =~ ^(notification|input|interaction|protocol)$ ]] || exit 2
  capture_name="$agent-$mode-$scenario"
  # A second attachment must retain the first attachment's notification evidence.
  if [[ "$scenario" != notification || -f "$run_root/results/$capture_name-outer-final.json" ]]; then
    exec bash "$fixture" launch "$run_root" "$agent" "$mode" "$scenario"
  fi
  export LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE=1
  # OpenCode needs a visible prompt; Qwen must enable focus reporting before
  # minimizing. Only focus-independent producers wait at the pre-exec barrier.
  if [[ "$agent" == codex || "$agent" == pi ]]; then
    exec bash "$0" capture "$run_root" "$capture_name" -- \
      python3 "$script_dir/start_gate.py" "$run_root" "$capture_name" hold -- \
      bash "$fixture" launch "$run_root" "$agent" "$mode" "$scenario"
  fi
  exec bash "$0" capture "$run_root" "$capture_name" -- \
    bash "$fixture" launch "$run_root" "$agent" "$mode" "$scenario"
fi

[[ $# -ge 5 && "$4" == "--" ]] || exit 2
run_root="$2"; capture_name="$3"
shift 4
[[ "$run_root" == /* && "$(basename -- "$run_root")" =~ ^leantty-agent-compat-[a-zA-Z0-9_-]+$ &&
   "$capture_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ &&
   "${LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE:-}" == "1" ]] || exit 2
[[ -f "$run_root/.leantty-agent-compat" &&
   "$(cat -- "$run_root/.leantty-agent-compat")" == "controlled-pty-capture" ]] || exit 2
umask 077
output_path="$run_root/captures/$capture_name.outer-output"
[[ ! -e "$output_path" && ! -e "$run_root/results/$capture_name-outer-final.json" ]] || exit 2
printf -v command_line '%q ' "$@"
set +e
script --quiet --flush --return --log-out "$output_path" \
  --echo never --output-limit 16MiB --command "$command_line"
child_exit_code=$?
set -e
python3 "$script_dir/observe_attention.py" \
  "$run_root" "$capture_name" finish --exit-code "$child_exit_code"
exit "$child_exit_code"
