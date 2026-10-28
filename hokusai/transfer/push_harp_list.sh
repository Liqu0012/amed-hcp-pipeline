#!/usr/bin/env bash
set -Eeuo pipefail
# 按清单把 HARP 原始 zip 从 wu 并行上传到计算服务器（仿 ~/parallel_rsync_transfer_hokusai.sh）。
# 只上传、不删除源文件；断点续传；每个文件传完后做 checksum 比对，通过才记入 done.txt，
# 重新运行会自动跳过 done.txt 里已经校验过的文件。
#
# ======== 需要填写的远端信息（也可以用同名环境变量覆盖） ========
REMOTE_HOSTNAME="${REMOTE_HOSTNAME:-digitalbrain.brainminds.jp}"   # 富岳登录节点
REMOTE_USER="${REMOTE_USER:-j.mao.xv}"               # 远端用户名
REMOTE_PORT="${REMOTE_PORT:-22}"
SSH_KEY="${SSH_KEY:-~/.ssh/amed}"                   # wu 上的私钥路径，例如 ~/.ssh/id_ed25519_xxx
DEST_PATH="${DEST_PATH:-/data/juntendodb/amedhcp1028}"             # 远端保存目录（绝对路径）
# =================================================================
JOBS="${JOBS:-8}"
RETRIES="${RETRIES:-8}"
SRC_ROOT=/mnt/data/AMED
HERE="$(cd "$(dirname "$0")" && pwd)"
LIST="${LIST:-$HERE/harp_recompute_2762_zips.list}"
STATE_DIR="${STATE_DIR:-$HERE/push_state}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ printf '[错误] %s\n' "$*" >&2; exit 1; }

for v in REMOTE_HOSTNAME REMOTE_USER SSH_KEY DEST_PATH; do
    [[ "${!v}" != __FILL_* ]] || die "请先在脚本顶部或环境变量里填写 $v"
done
SSH_KEY="${SSH_KEY/#\~/$HOME}"
[[ -r "$SSH_KEY" ]] || die "私钥不可读：$SSH_KEY"
[[ "$DEST_PATH" == /* ]] || die "DEST_PATH 必须是绝对路径"
depth="$(awk -F/ '{n=0;for(i=1;i<=NF;i++)if($i!="")n++;print n}' <<< "$DEST_PATH")"
(( depth >= 2 )) || die "DEST_PATH 层级过浅：$DEST_PATH"
[[ "$JOBS" =~ ^[1-9][0-9]*$ && "$RETRIES" =~ ^[1-9][0-9]*$ ]] || die "JOBS/RETRIES 必须是正整数"
[[ -s "$LIST" ]] || die "清单为空或不存在：$LIST"
for cmd in ssh rsync xargs flock awk; do command -v "$cmd" >/dev/null || die "缺少命令：$cmd"; done

# 只用指定的用户和私钥，不读 ~/.ssh/config 里的 Host 设置，也不用 agent 里的其他密钥。
SSH_CMD="ssh -F /dev/null -i $SSH_KEY -p $REMOTE_PORT -o IdentitiesOnly=yes -o  BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=60 -o ServerAliveCountMax=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$HOME/.ssh/known_hosts"
REMOTE="${REMOTE_USER}@${REMOTE_HOSTNAME}"
$SSH_CMD "$REMOTE" "command -v rsync >/dev/null && mkdir -p -- '$DEST_PATH' && test -w '$DEST_PATH' && df -h '$DEST_PATH' | tail -1" \
    || die "无法以 $REMOTE 登录、远端缺少 rsync，或 $DEST_PATH 不可写"

# 源文件都必须在 /mnt/data/AMED 下且可读。
while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" == "$SRC_ROOT"/*.zip ]] || die "清单中的路径不在 $SRC_ROOT 下：$p"
    [[ -r "$p" ]] || die "源文件不可读：$p"
done < "$LIST"

mkdir -p "$STATE_DIR/logs"; touch "$STATE_DIR/done.txt" "$STATE_DIR/failed.txt"
TODO="$STATE_DIR/todo.$$"; trap 'rm -f -- "$TODO"' EXIT
grep -vxF -f "$STATE_DIR/done.txt" "$LIST" | grep -v '^$' > "$TODO" || true
total=$(grep -c . "$LIST"); left=$(grep -c . "$TODO" || true)
bytes=$(xargs -d '\n' -r stat -c %s < "$TODO" | awk '{s+=$1}END{printf "%.1f GiB", s/1073741824}')
log "远端=$REMOTE:$DEST_PATH 清单=$total 已校验=$((total-left)) 待传=$left（$bytes） 并行=$JOBS 重试=$RETRIES"
(( left > 0 )) || { log '全部已上传并校验，无需操作'; exit 0; }
[[ "${DRY_RUN:-0}" == 1 ]] && { log 'DRY_RUN=1：只检查，不传输'; head -5 "$TODO"; exit 0; }

export SSH_CMD REMOTE DEST_PATH SRC_ROOT STATE_DIR RETRIES
fail=0
xargs -d '\n' -r -n1 -P"$JOBS" bash -c '
 set -uo pipefail; p="$1"; name="$(basename "$p")"; job="$STATE_DIR/logs/${name%.zip}.log"
 rel="${p#$SRC_ROOT/}"; src="$SRC_ROOT/./$rel"       # --relative 保留 BMB_xxx 子目录结构
 for ((a=1; a<=RETRIES; a++)); do
   if rsync -a --relative --partial --append-verify --protect-args -e "$SSH_CMD" "$src" "$REMOTE:$DEST_PATH/" >>"$job" 2>&1; then
     diff="$(rsync -nc -a --relative --itemize-changes --protect-args -e "$SSH_CMD" "$src" "$REMOTE:$DEST_PATH/" 2>>"$job")" && [[ -z "$diff" ]] && {
       flock "$STATE_DIR/done.txt" -c "printf \"%s\n\" \"$p\" >> \"$STATE_DIR/done.txt\""
       echo "[$(date "+%F %T")] 完成并校验：$name"; exit 0; }
     echo "[$(date "+%F %T")] $name 校验不一致：$diff" >>"$job"
     # 内容不一致时去掉续传，重新完整传一次
     rsync -a --relative --checksum --protect-args -e "$SSH_CMD" "$src" "$REMOTE:$DEST_PATH/" >>"$job" 2>&1 || true
   fi
   echo "[$(date "+%F %T")] $name 第 $a/$RETRIES 次失败，稍后续传" >&2
   sleep $((a * 10))
 done
 flock "$STATE_DIR/failed.txt" -c "printf \"%s\n\" \"$p\" >> \"$STATE_DIR/failed.txt\""
 echo "[$(date "+%F %T")] 失败：$name" >&2; exit 1
' _ < "$TODO" || fail=1

done_n=$(sort -u "$STATE_DIR/done.txt" | grep -cxF -f "$LIST" || true)
log "结束：已校验 $done_n / $total；失败条目见 $STATE_DIR/failed.txt；源文件全部保留"
(( fail == 0 )) || die "有文件失败，直接重新运行本脚本即可续传"
