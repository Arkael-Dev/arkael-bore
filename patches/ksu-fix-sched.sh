#!/usr/bin/env bash
F="$(find "${GITHUB_WORKSPACE:-$PWD}/kernel" -name samsung_kdp.c -type f 2>/dev/null | head -1)"
[ -z "$F" ] && { echo "[ksu-fix] samsung_kdp.c tidak ada, skip"; exit 0; }
grep -q 'linux/sched.h' "$F" && { echo "[ksu-fix] sched.h sudah ada"; exit 0; }
sed -i '0,/^#include/s//#include <linux\/sched.h>\n#include/' "$F"
echo "[ksu-fix] sched.h ditambahkan ke $F"
