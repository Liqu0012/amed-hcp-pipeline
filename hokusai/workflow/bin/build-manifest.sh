#!/usr/bin/env bash
set -Eeuo pipefail
# Build SESSION<TAB>ARCHIVE manifest rows.
# Inputs are directories (their *.zip) and/or list files (one zip path per line).
# 2026-10-28: the session ID is the full archive name including _MRn, one
# archive per session. The old version stripped _MRn and joined MR1/MR2 zips
# into one session, which mixes separate scan visits and breaks the naming
# used for the 1083 accepted DB sessions. Duplicate names are an error.

output="${1:?Usage: build-manifest.sh OUTPUT.tsv DATA_DIR_OR_LIST [...]}"
shift
(($# > 0)) || { echo 'At least one data directory or list file is required' >&2; exit 2; }

mkdir -p "$(dirname "$output")"
tmp=$(mktemp "${output}.tmp.XXXXXX")
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT

list_archives() {
  local src
  for src in "$@"; do
    if [[ -d "$src" ]]; then
      find "$src" -maxdepth 1 -type f -name '*.zip' -size +0c -print
    elif [[ -f "$src" ]]; then
      grep -v '^[[:space:]]*$' "$src"
    else
      echo "Not a directory or list file: $src" >&2; return 2
    fi
  done
}

declare -A seen=()
count=0 bad=0
while IFS= read -r archive; do
  [[ "$archive" == /*.zip && -s "$archive" ]] || { echo "Missing or non-absolute archive: $archive" >&2; bad=1; continue; }
  session=$(basename "$archive" .zip)
  [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session ID: $archive" >&2; bad=1; continue; }
  if [[ -n "${seen[$session]:-}" ]]; then
    echo "Duplicate session $session: ${seen[$session]} and $archive" >&2; bad=1; continue
  fi
  seen[$session]="$archive"
  printf '%s\t%s\n' "$session" "$archive" >> "$tmp"
  count=$((count + 1))
done < <(list_archives "$@" | sort)

((bad == 0)) || { echo 'Manifest not written' >&2; exit 4; }
((count > 0)) || { echo 'No complete ZIP archives found' >&2; exit 4; }
mv -f -- "$tmp" "$output"
trap - EXIT
echo "Manifest written: $output ($count sessions)"
