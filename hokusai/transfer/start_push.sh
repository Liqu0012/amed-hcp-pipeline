#!/usr/bin/env bash
# 后台启动上传（断开 SSH 也会继续）。用法：bash start_push.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if pgrep -u "$(id -u)" -f '[p]ush_harp_list.sh' >/dev/null; then echo 'ALREADY_RUNNING'; exit 0; fi
logf="$HERE/push_$(date +%Y%m%d_%H%M%S).log"
nohup "$HERE/push_harp_list.sh" > "$logf" 2>&1 < /dev/null &
echo "PID=$! LOG=$logf"
