#!/usr/bin/env bash
# 把 HOKUSAI（ziqing、haruka74）上已经全部算完（node pipeline 的 state/<session>/DONE）
# 的 session 结果拉回 wu，用 checksum 校验完全一致后，才删除 HOKUSAI 上的那一份 study 目录，
# 并在 HOKUSAI 写 state/<session>/PULLED（失败/阻塞而放在 tmp_work 的 session 拉回 _failed_or_blocked/ 后写 PULLED_FAILED）。
# 完成时 DONE 里记录的文件数与 wu 上的不一致时不删。
# 原始 zip 不删。
#
# 用法（在 wu 上）：
#   bash start_pull.sh                   后台循环运行（每 INTERVAL 秒一轮，全部算完拉完后自动结束）
#   ONCE=1 bash pull_hokusai_results.sh  只跑一轮
#   DRY_RUN=1 ONCE=1 bash pull_hokusai_results.sh   只列出要拉的 session，不拉不删
# 停止：touch $STATE/STOP（当前 session 拉完后退出）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${DEST:-/mnt/data/HCP/amed_hcp_v6_hokusai}"
STATE="${STATE:-$HERE/pull_state}"
INTERVAL="${INTERVAL:-300}"
RETRIES="${RETRIES:-5}"
# 每行：ssh 主机  study 目录  node pipeline 队列目录  manifest
TARGETS_FILE="${TARGETS_FILE:-}"
DEFAULT_TARGETS="HOKUSAI /home/ziqing/AMED_HCP/hcp_study /home/ziqing/AMED_HCP/hcp_workflow_logs/node_pipeline /home/ziqing/AMED_HCP/manifests/hokusai_chang_node_manifest.tsv
HOKUSAIwang /home/haruka74/AMED_HCP/hcp_study /home/haruka74/AMED_HCP/hcp_workflow_logs/node_pipeline /home/haruka74/AMED_HCP/manifests/hokusai_wang_node_manifest.tsv"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=5"

mkdir -p "$DEST" "$STATE/logs"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
targets() { if [[ -n "$TARGETS_FILE" ]]; then grep -v '^\s*#' "$TARGETS_FILE"; else printf '%s\n' "$DEFAULT_TARGETS"; fi; }

# HOKUSAI 登录时会打印横幅和 module 信息，所以远端输出都带 @@ 前缀，只取这些行。
scan() {
  local h=$1 q=$2 m=$3 study=$4
  $SSH "$h" "q='$q'; m='$m'; open=0; failed=0
    while IFS=\$'\t' read -r s _; do
      [ -n \"\$s\" ] || continue; d=\"\$q/state/\$s\"
      if [ -e \"\$d/DONE\" ]; then [ -e \"\$d/PULLED\" ] || echo \"@@DONE \$s\"
      elif [ -e \"\$d/FAILED\" ] || [ -e \"\$d/BLOCKED\" ]; then failed=\$((failed+1)); [ -L \"$study/\$s\" ] && [ ! -e \"\$d/PULLED_FAILED\" ] && echo \"@@FAILTMP \$s\"
      else open=\$((open+1)); fi
    done < \"\$m\"
    echo \"@@OPEN \$open\"; echo \"@@FAILED \$failed\"" 2>/dev/null | sed -n 's/^@@//p'
}

pull_one() {
  local h=$1 study=$2 q=$3 s=$4 dst="$DEST/${SUBDIR:-}$4" lf="$STATE/logs/$4.log" i out
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { log "跳过：session 名不合法 $s"; return 1; }
  mkdir -p "$dst"
  for ((i = 1; i <= RETRIES; i++)); do
    if rsync -a --partial -e "$SSH" "$h:$study/$s/" "$dst/" >> "$lf" 2>&1; then break; fi
    log "$s 第 $i/$RETRIES 次拉取失败，稍后续传"; sleep 30
  done
  (( i <= RETRIES )) || { log "失败：$s（拉取）"; echo "$h $s pull" >> "$STATE/failed.txt"; return 1; }
  # 运行日志和状态也带回来（小文件）。
  mkdir -p "$dst/hcp_node_pipeline/logs" "$dst/hcp_node_pipeline/state"
  rsync -a -e "$SSH" "$h:$q/logs/$s.*.log" "$dst/hcp_node_pipeline/logs/" >> "$lf" 2>&1
  rsync -a -e "$SSH" "$h:$q/state/$s/" "$dst/hcp_node_pipeline/state/" >> "$lf" 2>&1
  # 校验：按内容（checksum）再比一遍，任何差异都不删。
  if ! out=$(rsync -anc --delete --exclude=/hcp_node_pipeline/ --out-format='%i %n' -e "$SSH" "$h:$study/$s/" "$dst/" 2>>"$lf"); then
    log "失败：$s（校验时 rsync 出错，HOKUSAI 上保留）"; echo "$h $s verify-error" >> "$STATE/failed.txt"; return 1
  fi
  out=$(grep -v '^\.d\.\.t' <<< "$out" | grep -v '^$' || true)
  if [[ -n "$out" ]]; then
    log "失败：$s 校验不一致（HOKUSAI 上保留）：$(head -3 <<< "$out" | tr '\n' ' ')"
    echo "$h $s verify-mismatch" >> "$STATE/failed.txt"; return 1
  fi
  local bytes nfiles; bytes=$(du -sb "$dst" | cut -f1); nfiles=$(find "$dst" -type f | wc -l)
  # Completeness: DONE records the file count when the session finished. Fewer
  # files now (e.g. removed by the tmp_work purge on both sides) -> keep HOKUSAI.
  local expect have marker=PULLED
  [[ -n "${SUBDIR:-}" ]] && marker=PULLED_FAILED
  if [[ -z "${SUBDIR:-}" ]]; then
    expect=$($SSH "$h" "sed -n 's/^files=//p' '$q/state/$s/DONE'" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
    have=$(find "$dst" -type f ! -path "$dst/hcp_node_pipeline/*" | wc -l)
    if [[ -n "$expect" && "$have" != "$expect" ]]; then
      log "失败：$s 文件数 $have 与完成时记录的 $expect 不一致（HOKUSAI 上保留）"
      echo "$h $s incomplete $have/$expect" >> "$STATE/failed.txt"; return 1
    fi
  fi
  if [[ "${DRY_DELETE:-0}" == 1 ]]; then log "已校验（DRY_DELETE，不删）：$s"; return 0; fi
  if $SSH "$h" "d='$study/$s'; if [ -L \"\$d\" ]; then r=\$(readlink -f -- \"\$d\"); case \"\$r\" in /lustre/tmp_work/*_hcp/hcp_study/*) rm -rf -- \"\$r\" && rm -f -- \"\$d\";; *) false;; esac; else [ -d \"\$d\" ] && rm -rf -- \"\$d\"; fi && printf 'pulled_to=wu:%s\npulled_at=%s\nbytes=%s\nfiles=%s\n' '$dst' \"\$(date -Is)\" '$bytes' '$nfiles' > '$q/state/$s/$marker' && echo @@OK" 2>/dev/null | grep -q '^@@OK'; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$h" "$s" "$bytes" "$nfiles" >> "$STATE/pulled.tsv"
    log "完成：$s 已拉回并校验（$((bytes / 1024 / 1024)) MiB，$nfiles 个文件），HOKUSAI 上已删除"
  else
    log "注意：$s 已拉回并校验，但 HOKUSAI 上删除失败，下一轮再试"; return 1
  fi
}

# 两个账号同时拉，每个账号 JOBS 个 session 并行（同 parallel_rsync_transfer_hokusai.sh 的做法）。
JOBS="${JOBS:-4}"
pull_host() {
  local h=$1 study=$2 q=$3; shift 3; local s
  for s in "$@"; do
    [[ -e "$STATE/STOP" ]] && break
    while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n; done
    pull_one "$h" "$study" "$q" "$s" &
  done
  wait
}

while :; do
  all_finished=1
  pids=()
  while read -r h study q m <&3; do
    [[ -n "${h:-}" ]] || continue
    res=$(scan "$h" "$q" "$m" "$study")
    if [[ -z "$res" ]]; then log "$h：连接失败，下一轮再试"; all_finished=0; continue; fi
    open=$(sed -n 's/^OPEN //p' <<< "$res"); failed=$(sed -n 's/^FAILED //p' <<< "$res")
    mapfile -t todo < <(sed -n 's/^DONE //p' <<< "$res")
    # Failed/blocked sessions in tmp_work would be purged after 7 days: keep them on wu.
    mapfile -t ftodo < <(sed -n 's/^FAILTMP //p' <<< "$res")
    if (( ${#ftodo[@]} )) && [[ "${DRY_RUN:-0}" != 1 ]]; then
      log "$h：失败/阻塞且在 tmp_work 的 ${#ftodo[@]} 个，拉回 wu 的 _failed_or_blocked/"
      for s in "${ftodo[@]}"; do SUBDIR=_failed_or_blocked/ pull_one "$h" "$study" "$q" "$s"; done
    fi
    log "$h：待拉 ${#todo[@]}，还在算/没开始 $open，失败/阻塞 $failed"
    (( open == 0 && ${#todo[@]} == 0 )) || all_finished=0
    (( ${#todo[@]} )) || continue
    if [[ "${DRY_RUN:-0}" == 1 ]]; then printf '%s
' "${todo[@]}" | sed "s/^/DRY_RUN 要拉：$h /"; continue; fi
    pull_host "$h" "$study" "$q" "${todo[@]}" &
    pids+=($!)
  done 3< <(targets)   # fd 3：循环里的 ssh 会读标准输入
  (( ${#pids[@]} )) && wait "${pids[@]}"
  [[ -e "$STATE/STOP" ]] && { log "发现 STOP，退出"; break; }
  [[ "${ONCE:-0}" == 1 ]] && break
  (( all_finished )) && { log "两边都已算完并拉回，结束"; break; }
  sleep "$INTERVAL"
done
