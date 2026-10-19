#!/usr/bin/env bash
set -e
ROOT="${GITHUB_WORKSPACE:-$PWD}"
F="$(find -L "$ROOT/kernel" -name samsung_kdp.c -type f 2>/dev/null | head -1)"
[ -n "$F" ] || { echo "[ksu-fix] samsung_kdp.c tidak ketemu"; exit 1; }
grep -q '<linux/sched.h>' "$F" || \
  sed -i '0,/^#include/s//#include <linux\/sched.h>\n#include/' "$F"
sed -i 's/task_pid_nr(target)/(target)->pid/' "$F"
grep -q 'task_pid_nr(target)' "$F" && { echo "[ksu-fix] GAGAL"; exit 1; }
echo "[ksu-fix] OK: $F"
