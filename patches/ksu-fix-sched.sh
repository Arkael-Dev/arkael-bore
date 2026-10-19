#!/usr/bin/env bash
set -e
ROOT="${1:-${GITHUB_WORKSPACE:-$PWD}/kernel}"
N=0
while IFS= read -r F; do
  grep -q '<linux/sched.h>' "$F" || \
    sed -i --follow-symlinks '0,/^#include/s//#include <linux\/sched.h>\n#include/' "$F"
  sed -i --follow-symlinks 's/task_pid_nr(target)/(target)->pid/' "$F"
  grep -q 'task_pid_nr(target)' "$F" && { echo "[ksu-fix] GAGAL: $F"; exit 1; }
  echo "[ksu-fix] OK: $F"
  N=$((N+1))
done < <(find -L "$ROOT" -name samsung_kdp.c -type f 2>/dev/null)
[ "$N" -gt 0 ] || echo "[ksu-fix] samsung_kdp.c tidak ada, skip"
