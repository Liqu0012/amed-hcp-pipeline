#!/usr/bin/env bash
set -Eeuo pipefail

load_site() {
  local cfg="${1:?site config required}"
  [[ -s "$cfg" ]] || { echo "Missing site config: $cfg" >&2; exit 2; }
  set -a
  # shellcheck disable=SC1090
  source "$cfg"
  set +a
  : "${HCP_STUDY:?HCP_STUDY is required}"
  : "${HCP_WORKFLOW_LOG_DIR:?HCP_WORKFLOW_LOG_DIR is required}"
}

validate_session() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "Unsafe session ID: ${1:-<empty>}" >&2; exit 2;
  }
}

manifest_row() {
  local manifest="$1" index="$2" row
  row=$(sed -n "${index}p" "$manifest")
  [[ -n "$row" ]] || { echo "No manifest row $index" >&2; exit 2; }
  SESSION=$(printf '%s' "$row" | cut -f1)
  ARCHIVE=$(printf '%s' "$row" | cut -f2)
  validate_session "$SESSION"
}

ensure_white_deformed() {
  local session="$1" surf="$HCP_STUDY/$session/T1w/$session/surf" hemi target link
  for hemi in lh rh; do
    target="$surf/$hemi.white"
    link="$surf/$hemi.white.deformed"
    [[ -s "$target" ]] || { echo "Missing or empty surface: $target" >&2; exit 4; }
    if [[ -L "$link" ]]; then
      [[ -e "$link" ]] || { echo "Broken symlink: $link" >&2; exit 4; }
    elif [[ -e "$link" ]]; then
      [[ -s "$link" ]] || { echo "Invalid surface: $link" >&2; exit 4; }
    else
      ln -s "$hemi.white" "$link"
      echo "Created compatibility link: $link -> $hemi.white"
    fi
  done
}

run_words() {
  local command="$1"; shift
  local -a words
  read -r -a words <<< "$command"
  "${words[@]}" "$@"
}
