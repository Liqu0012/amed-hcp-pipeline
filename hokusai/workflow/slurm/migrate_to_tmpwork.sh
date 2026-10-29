#!/usr/bin/env bash
# Move in-progress node-pipeline sessions from HCP_STUDY (home quota) to
# /lustre/tmp_work, leaving a symlink at the old path. A session is moved only
# while none of its stages runs (no state/<session>/*.running), so no process
# has files of it open; the next stage reaches it through the symlink (the
# container binds the tmp_work directory, see config/hokusai*.env).
#
# Lustre renames a directory only within one MDT and users cannot choose the
# MDT of a new directory, so:
#   - same MDT: rename (instant, same inodes);
#   - otherwise: copy with rsync while the session is idle, sync once more,
#     then swap (old dir renamed aside next to itself, symlink put in place)
#     and delete the old copy. If a stage starts at any point before the swap,
#     the copy is discarded and the session is tried again later.
# Files moved into tmp_work are counted there, not in the home quota.
#
# Usage: migrate_to_tmpwork.sh STUDY_DIR QUEUE_DIR TMP_STUDY_DIR [INTERVAL_SEC]
# Stop:  touch QUEUE_DIR/MIGRATE_STOP
set -u
study=$1 q=$2 tmp=$3 iv=${4:-60}
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
busy() { compgen -G "$q/state/$1/*.running" > /dev/null; }
mkdir -p "$tmp"

migrate() {
  local s=$1 d="$study/$1" t="$tmp/$1" lnk="$study/.$1.tmpwork-link" old="$study/.$1.moved-to-tmpwork"
  rm -f -- "$lnk"; ln -s "$t" "$lnk" || return 1
  busy "$s" && { rm -f -- "$lnk"; return 1; }
  # 1) same MDT: rename the directory itself.
  if python3 -c '
import os, sys
d, t, l = sys.argv[1:]
os.rename(d, t)
try:
    os.rename(l, d)
except OSError:
    os.rename(t, d)
    raise' "$d" "$t" "$lnk" 2>/dev/null; then
    log "renamed $s -> $t"; return 0
  fi
  # 2) other MDT: copy while idle, then swap.
  local t0=$SECONDS
  if ! rsync -aH --delete "$d/" "$t/" 2>>"$tmp/.rsync_errors.log"; then
    rm -rf -- "$t" "$lnk"; log "copy of $s failed; left in place"; return 1
  fi
  busy "$s" && { rm -rf -- "$t" "$lnk"; log "stage of $s started during copy; copy discarded"; return 1; }
  rsync -aH --delete "$d/" "$t/" 2>>"$tmp/.rsync_errors.log" || { rm -rf -- "$t" "$lnk"; return 1; }
  busy "$s" && { rm -rf -- "$t" "$lnk"; log "stage of $s started during copy; copy discarded"; return 1; }
  if python3 -c '
import os, sys
d, o, l = sys.argv[1:]
os.rename(d, o)
try:
    os.rename(l, d)
except OSError:
    os.rename(o, d)
    raise' "$d" "$old" "$lnk"; then
    rm -rf -- "$old"
    log "copied $s -> $t ($(( SECONDS - t0 )) s), home copy removed"
  else
    rm -rf -- "$t" "$lnk"; log "swap of $s failed; left in place"; return 1
  fi
}

while :; do
  [[ -e "$q/MIGRATE_STOP" ]] && { log "MIGRATE_STOP present; exiting"; break; }
  for c in "$q"/claims/*/; do
    [[ -e "$q/MIGRATE_STOP" ]] && break
    [[ -d "$c" ]] || continue
    s=$(basename "$c"); d="$study/$s"
    [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue
    [[ -d "$d" && ! -L "$d" ]] || continue
    busy "$s" && continue
    [[ -e "$tmp/$s" ]] && { log "skip $s: $tmp/$s already exists"; continue; }
    migrate "$s"
  done
  sleep "$iv"
done
