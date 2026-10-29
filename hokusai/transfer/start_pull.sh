#!/usr/bin/env bash
# 后台运行 pull_hokusai_results.sh（断开 SSH 也会继续）。用法：bash start_pull.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export STATE="${STATE:-$HERE/pull_state}"
pidf="$STATE/pull.pid"
mkdir -p "$STATE"
if [[ -s "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then echo "ALREADY_RUNNING PID=$(cat "$pidf")"; exit 0; fi
logf="$STATE/pull_$(date +%Y%m%d_%H%M%S).log"
nohup "$HERE/pull_hokusai_results.sh" > "$logf" 2>&1 < /dev/null &
echo $! > "$pidf"
echo "PID=$! LOG=$logf"
