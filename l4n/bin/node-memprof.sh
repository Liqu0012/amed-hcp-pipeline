#!/usr/bin/env bash
# Sample the memory of every running (stage, session) on this node: the RSS of the
# whole process tree under each "run-stage.sh CONFIG STAGE SESSION ARCHIVE".
# Output lines: epoch  stage  session  rss_MiB  threads_running
# Usage (inside a running node-pipeline job): memprof.sh OUTFILE [INTERVAL_SEC]
out="$1"; iv="${2:-20}"
while :; do
  ps -eLo pid=,ppid=,rss=,stat=,args= | awk -v ts="$(date +%s)" '
    { pid=$1; pp[pid]=$2; if (!(pid in seen)) { rss[pid]=$3; seen[pid]=1 } if ($4 ~ /^R/) run[pid]++
      if (!(pid in key)) for (i=5; i<=NF; i++) if ($i ~ /run-stage\.sh$/) { key[pid]=$(i+2) "\t" $(i+3); break } }
    END { for (p in seen) { q=p; d=0; while ((q in pp) && !(q in key) && d<60) { q=pp[q]; d++ }
            if (q in key) { R[key[q]]+=rss[p]; T[key[q]]+=run[p] } }
          for (k in R) printf "%s\t%s\t%d\t%d\n", ts, k, R[k]/1024, T[k] }' >> "$out"
  sleep "$iv"
done
