#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
analyzer="$script_dir/agent-compatibility/analyze_capture.py"

usage() {
  cat <<'EOF'
Usage:
  agent-compatibility-wsl.sh prepare RUN_ROOT
  agent-compatibility-wsl.sh configure RUN_ROOT
  agent-compatibility-wsl.sh environment RUN_ROOT
  agent-compatibility-wsl.sh inventory RUN_ROOT
  agent-compatibility-wsl.sh osc99-probe RUN_ROOT
  agent-compatibility-wsl.sh launch RUN_ROOT AGENT direct|tmux notification|input|interaction|protocol
  agent-compatibility-wsl.sh probe RUN_ROOT CAPTURE_NAME
  agent-compatibility-wsl.sh termios-probe RUN_ROOT CAPTURE_NAME SAMPLE_NAME
  agent-compatibility-wsl.sh cleanup RUN_ROOT
  agent-compatibility-wsl.sh capture RUN_ROOT CAPTURE_NAME -- COMMAND [ARG...]

capture is only for an already-authenticated Agent session with controlled test
input. It writes a content-free JSON summary and deletes the raw PTY logs.
EOF
}

validate_run_root() {
  local run_root="$1"
  local base
  if [[ "$run_root" != /* ]]; then
    echo "RUN_ROOT must be absolute" >&2
    exit 2
  fi
  base="$(basename -- "$run_root")"
  if [[ ! "$base" =~ ^leantty-agent-compat-[a-zA-Z0-9_-]+$ ]]; then
    echo "RUN_ROOT basename must start with leantty-agent-compat-" >&2
    exit 2
  fi
}

require_sentinel() {
  local run_root="$1"
  if [[ ! -f "$run_root/.leantty-agent-compat" ]] ||
     [[ "$(cat -- "$run_root/.leantty-agent-compat")" != "controlled-pty-capture" ]]; then
    echo "RUN_ROOT does not contain the exact LeanTTY capture sentinel" >&2
    exit 2
  fi
}

resolve_agent_bin_dir() {
  local prefix
  prefix="$(npm config get prefix)"
  if [[ ! -d "$prefix/bin" ]]; then
    echo "npm user binary directory is missing: $prefix/bin" >&2
    exit 3
  fi
  printf '%s\n' "$prefix/bin"
}

agent_auth_ready() {
  local agent="$1"
  local bin_dir="$2"
  case "$agent" in
    codex)
      "$bin_dir/codex" login status >/dev/null 2>&1
      ;;
    opencode)
      "$bin_dir/opencode" models opencode 2>/dev/null |
        grep -qx 'opencode/big-pickle'
      ;;
    pi)
      "$bin_dir/pi" auth check --provider deepseek --json --no-refresh >/dev/null 2>&1
      ;;
    qwen)
      [[ -n "${OPENAI_API_KEY:-}" || -n "${QWEN_TOKEN_PLAN_API_KEY:-}" ||
         -n "${QWEN_TOKEN_PLAN_CN_API_KEY:-}" || -f "$HOME/.qwen/settings.json" ]]
      ;;
    *) return 1 ;;
  esac
}

launch_agent_child() {
  local run_root="$1"
  local agent="$2"
  local mode="$3"
  local scenario="$4"
  local bin_dir
  local prompt='Reply exactly LEANTTY_AGENT_DONE and do not use tools.'
  local pi_notify_extension
  local -a command_arguments
  bin_dir="$(resolve_agent_bin_dir)"
  if [[ -f "$run_root/agent-network.env" ]]; then
    # This run-scoped file contains only the proxy variables already present in
    # the default WSL process environment. It is mode 0600 and never copied to evidence.
    source "$run_root/agent-network.env"
  fi
  agent_auth_ready "$agent" "$bin_dir" || {
    echo "Agent authentication is not ready: $agent" >&2
    return 4
  }
  cd -- "$run_root/workspace"
  export LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE=1
  case "$agent" in
    codex)
      command_arguments=(
        "$bin_dir/codex" --no-alt-screen -C "$run_root/workspace"
        --sandbox read-only --ask-for-approval never \
        -c 'tui.notifications=true'
        -c 'tui.notification_method="bel"'
        -c 'tui.notification_condition="always"'
        -c 'project_root_markers=[]'
        -c "projects={\"$run_root\"={trust_level=\"trusted\"},\"$run_root/workspace\"={trust_level=\"trusted\"}}"
      )
      ;;
    opencode)
      export OPENCODE_CONFIG_DIR="$run_root/opencode-config"
      unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT
      if [[ "${LEANTTY_OPENCODE_FORCE_OSC99_PROTOCOL:-}" == "1" ]]; then
        export OPENTUI_NOTIFICATION_PROTOCOL=osc99
      fi
      command_arguments=(
        "$bin_dir/opencode" --pure --model opencode/big-pickle
        "$run_root/workspace"
      )
      ;;
    pi)
      pi_notify_extension="$(npm root -g)/@earendil-works/pi-coding-agent/examples/extensions/notify.ts"
      [[ -f "$pi_notify_extension" ]] || {
        echo "Pi official notify extension is missing: $pi_notify_extension" >&2
        return 3
      }
      unset WT_SESSION KITTY_WINDOW_ID
      command_arguments=(
        "$bin_dir/pi" --provider deepseek --model deepseek-v4-flash
        --thinking minimal --no-tools --no-session --no-extensions --no-skills
        --no-prompt-templates --no-context-files --no-approve
        --extension "$pi_notify_extension"
      )
      ;;
    qwen)
      if [[ "$scenario" == "protocol" ]]; then
        export QWEN_CODE_SYSTEM_SETTINGS_PATH="$run_root/qwen-protocol-settings.json"
        export FORCE_HYPERLINK=1
      else
        export QWEN_CODE_SYSTEM_SETTINGS_PATH="$run_root/qwen-settings.json"
      fi
      prompt='Use the shell tool exactly once to run: touch .leantty-agent-done. Do not use any other tool. After it completes, reply exactly LEANTTY_AGENT_DONE.'
      command_arguments=(
        "$bin_dir/qwen" --safe-mode --model deepseek-v4-flash
        --approval-mode default --max-tool-calls 1 --max-wall-time 60s
      )
      if [[ "$scenario" == "protocol" ]]; then
        prompt='Do not use tools. Reply with exactly this Markdown link and no other text: [LeanTTY protocol](https://example.invalid/leantty-agent-protocol)'
      fi
      ;;
  esac
  if [[ "$scenario" == "notification" ]]; then
    if [[ "$agent" == "opencode" ]]; then
      prompt='Use the bash tool exactly once to run: sleep 12. Do not use any other tool. After it completes, reply exactly LEANTTY_AGENT_DONE.'
      # The physical harness submits this prompt only after the interactive TUI
      # is ready so the built-in notification plugin observes busy -> idle.
    elif [[ "$agent" == "qwen" ]]; then
      command_arguments+=(--prompt-interactive "$prompt")
    else
      command_arguments+=("$prompt")
    fi
  elif [[ "$scenario" == "protocol" ]]; then
    command_arguments+=(--prompt-interactive "$prompt")
  fi
  exec "$0" capture "$run_root" "$agent-$mode-$scenario" -- "${command_arguments[@]}"
}

command_name="${1:-}"
case "$command_name" in
  prepare)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    umask 077
    mkdir -p -- "$run_root/captures" "$run_root/results" "$run_root/workspace"
    printf 'controlled-pty-capture\n' > "$run_root/.leantty-agent-compat"
    ;;
  configure)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    umask 077
    cat > "$run_root/qwen-settings.json" <<'JSON'
{
  "general": {
    "terminalBell": true,
    "notificationMode": "all",
    "chatRecording": false,
    "enableAutoUpdate": false,
    "preventSystemSleep": false
  }
}
JSON
    cat > "$run_root/qwen-protocol-settings.json" <<'JSON'
{
  "general": {
    "terminalBell": false,
    "chatRecording": false,
    "enableAutoUpdate": false,
    "preventSystemSleep": false
  },
  "ui": {
    "useTerminalBuffer": true,
    "mouseTracking": false,
    "shellOutputMaxLines": 0
  }
}
JSON
    mkdir -p "$run_root/opencode-config"
    chmod 700 "$run_root/opencode-config"
    cat > "$run_root/opencode-config/tui.json" <<'JSON'
{
  "$schema": "https://opencode.ai/tui.json",
  "attention": {
    "enabled": true,
    "notifications": true,
    "sound": false
  }
}
JSON
    cat > "$run_root/tmux.conf" <<'EOF'
set -g allow-passthrough on
set -g focus-events on
set -g bell-action any
set -g monitor-bell on
set -g remain-on-exit off
EOF
    ;;
  environment)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    umask 077
    python3 - "$run_root/agent-network.env" "$run_root/results/network-environment.json" <<'PY'
import json
import os
import shlex
import sys

names = (
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
)
present = [name for name in names if os.environ.get(name)]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    for name in present:
        output.write(f"export {name}={shlex.quote(os.environ[name])}\n")
os.chmod(sys.argv[1], 0o600)
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(
        {
            "schemaVersion": 1,
            "variableNames": present,
            "valuesIncludedInEvidence": False,
            "scope": "run-only-default-wsl-agent-processes",
        },
        output,
        indent=2,
    )
    output.write("\n")
os.chmod(sys.argv[2], 0o600)
PY
    ;;
  inventory)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    bin_dir="$(resolve_agent_bin_dir)"
    export PATH="$bin_dir:$PATH"
    for agent in codex opencode pi qwen; do
      if agent_auth_ready "$agent" "$bin_dir"; then
        export "LEANTTY_AUTH_${agent^^}=1"
      else
        export "LEANTTY_AUTH_${agent^^}=0"
      fi
    done
    python3 - "$run_root/results/inventory.json" <<'PY'
import json
import os
import shutil
import subprocess
import sys

def version(command):
    path = shutil.which(command)
    if path is None:
        return {"installed": False, "path": None, "version": None}
    completed = subprocess.run(
        [command, "--version"], text=True, capture_output=True, timeout=20, check=False
    )
    text = (completed.stdout or completed.stderr).strip().splitlines()
    return {
        "installed": True,
        "path": path,
        "version": text[0] if text else None,
        "versionExitCode": completed.returncode,
    }

home = os.path.expanduser("~")
markers = {
    name: os.getenv(f"LEANTTY_AUTH_{name.upper()}") == "1"
    for name in ("codex", "opencode", "pi", "qwen")
}
result = {
    "schemaVersion": 1,
    "environment": {
        "distribution": os.getenv("WSL_DISTRO_NAME"),
        "term": os.getenv("TERM"),
        "colorterm": os.getenv("COLORTERM"),
        "locale": os.getenv("LANG"),
    },
    "tools": {name: version(name) for name in ("codex", "opencode", "pi", "qwen")},
    "authenticationReady": markers,
    "models": {
        "codex": "account-default",
        "opencode": "opencode/big-pickle",
        "pi": "deepseek/deepseek-v4-flash",
        "qwen": "deepseek-v4-flash",
    },
    "usageAccounting": {
        "plannedModelRequestsPerAgentMode": 1,
        "tokenUsage": "unavailable-unless-agent-exposes-run-scoped-usage",
    },
    "privacy": {"credentialContentRead": False, "environmentSecretValuesRead": False},
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(result, output, indent=2)
    output.write("\n")
os.chmod(sys.argv[1], 0o600)
PY
    ;;
  osc99-probe)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    command -v python3 >/dev/null
    umask 077
    python3 "$script_dir/agent-compatibility/osc99_capability_probe.py" \
      "$run_root/results/osc99-capability-probe.json"
    ;;
  launch)
    [[ $# -eq 5 ]] || { usage >&2; exit 2; }
    run_root="$2"
    agent="$3"
    mode="$4"
    scenario="$5"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    [[ "$agent" =~ ^(codex|opencode|pi|qwen)$ ]] || {
      echo "unsupported Agent: $agent" >&2
      exit 2
    }
    [[ "$mode" =~ ^(direct|tmux)$ ]] || {
      echo "unsupported mode: $mode" >&2
      exit 2
    }
    [[ "$scenario" =~ ^(notification|input|interaction|protocol)$ ]] || {
      echo "unsupported scenario: $scenario" >&2
      exit 2
    }
    if [[ "$mode" == "direct" ]]; then
      launch_agent_child "$run_root" "$agent" "$mode" "$scenario"
    else
      tmux_socket="leantty-agent-$(basename -- "$run_root")"
      quoted_command="$(printf '%q ' "$0" launch-child "$run_root" "$agent" "$mode" "$scenario")"
      exec tmux -L "$tmux_socket" -f "$run_root/tmux.conf" \
        new-session -A -s "$agent-$scenario" "$quoted_command"
    fi
    ;;
  launch-child)
    [[ $# -eq 5 ]] || { usage >&2; exit 2; }
    run_root="$2"
    agent="$3"
    mode="$4"
    scenario="$5"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    launch_agent_child "$run_root" "$agent" "$mode" "$scenario"
    ;;
  probe)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    run_root="$2"
    capture_name="$3"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    [[ "$capture_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || {
      echo "CAPTURE_NAME contains unsupported characters" >&2
      exit 2
    }
    input_path="$run_root/captures/$capture_name.input"
    output_path="$run_root/captures/$capture_name.output"
    result_path="$run_root/results/$capture_name-live.json"
    [[ -f "$input_path" && -f "$output_path" ]] || exit 5
    python3 "$analyzer" \
      --run-root "$run_root" \
      --name "$capture_name-live" \
      --input "$input_path" \
      --output "$output_path" \
      --result "$result_path" \
      --child-exit-code -1
    ;;
  termios-probe)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    run_root="$2"
    capture_name="$3"
    sample_name="$4"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    [[ "$capture_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || {
      echo "CAPTURE_NAME contains unsupported characters" >&2
      exit 2
    }
    [[ "$sample_name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
      echo "SAMPLE_NAME contains unsupported characters" >&2
      exit 2
    }
    pty_path_file="$run_root/captures/$capture_name.pty"
    [[ -f "$pty_path_file" ]] || exit 5
    pty_path="$(cat -- "$pty_path_file")"
    [[ "$pty_path" =~ ^/dev/pts/[0-9]+$ && -c "$pty_path" ]] || {
      echo "controlled PTY is unavailable" >&2
      exit 5
    }
    state_path="$run_root/captures/$capture_name-$sample_name.termios"
    result_path="$run_root/results/$capture_name-$sample_name-termios.json"
    umask 077
    stty -a < "$pty_path" > "$state_path"
    python3 - "$state_path" "$result_path" "$sample_name" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

state_path = Path(sys.argv[1])
result_path = Path(sys.argv[2])
sample_name = sys.argv[3]
state = state_path.read_text(encoding="utf-8")
tokens = set(re.findall(r"-?[a-z][a-z0-9]*", state))

def enabled(name: str) -> bool:
    return name in tokens and f"-{name}" not in tokens

rows_match = re.search(r"\brows\s+(\d+)\b", state)
columns_match = re.search(r"\bcolumns\s+(\d+)\b", state)
if not rows_match or not columns_match:
    raise SystemExit("controlled PTY dimensions are unavailable")

canonical = enabled("icanon")
echo = enabled("echo")
summary = {
    "schemaVersion": 1,
    "sample": sample_name,
    "ptyObserved": True,
    "rawMode": not canonical and not echo,
    "canonicalInput": canonical,
    "inputEcho": echo,
    "signalProcessing": enabled("isig"),
    "rows": int(rows_match.group(1)),
    "columns": int(columns_match.group(1)),
    "privacy": {"terminalContentIncluded": False, "rawTermiosRetained": False},
}
result_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
os.chmod(result_path, 0o600)
PY
    rm -f -- "$state_path"
    ;;
  cleanup)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    run_root="$2"
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    tmux_socket="leantty-agent-$(basename -- "$run_root")"
    tmux -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
    ;;
  capture)
    [[ $# -ge 5 ]] || { usage >&2; exit 2; }
    run_root="$2"
    capture_name="$3"
    shift 3
    [[ "${1:-}" == "--" ]] || { usage >&2; exit 2; }
    shift
    validate_run_root "$run_root"
    require_sentinel "$run_root"
    [[ "$capture_name" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] || {
      echo "CAPTURE_NAME contains unsupported characters" >&2
      exit 2
    }
    [[ "${LEANTTY_AGENT_COMPAT_CONTROLLED_CAPTURE:-}" == "1" ]] || {
      echo "controlled capture acknowledgement is required" >&2
      exit 2
    }
    command -v script >/dev/null
    command -v python3 >/dev/null
    umask 077
    input_path="$run_root/captures/$capture_name.input"
    output_path="$run_root/captures/$capture_name.output"
    pty_path="$run_root/captures/$capture_name.pty"
    result_path="$run_root/results/$capture_name.json"
    : > "$input_path"
    : > "$output_path"
    printf -v child_command_line '%q ' "$@"
    printf -v command_line 'printf "%%s\\n" "$(tty)" > %q; exec %s' \
      "$pty_path" "$child_command_line"
    set +e
    script --quiet --flush --return \
      --log-in "$input_path" --log-out "$output_path" \
      --echo never --output-limit 16MiB \
      --command "$command_line"
    child_exit_code=$?
    set -e
    python3 "$analyzer" \
      --run-root "$run_root" \
      --name "$capture_name" \
      --input "$input_path" \
      --output "$output_path" \
      --result "$result_path" \
      --child-exit-code "$child_exit_code" \
      --delete-raw
    rm -f -- "$pty_path"
    exit "$child_exit_code"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
