#!/usr/bin/env bash
# Pasang SUSFS (gki-android16-6.12) ke source kernel.
# Usage: apply-susfs.sh <kernel_dir> [ksu_dir]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K="${1:?kernel dir wajib}"; KSU="${2:-}"
[ -d "$K" ] || { echo "[susfs] kernel dir tidak ada: $K" >&2; exit 1; }

if [ -f "$K/fs/susfs.c" ]; then
  echo "[susfs] sudah terpasang, dilewati"; exit 0
fi

P="$HERE/50_add_susfs_in_gki-android16-6.12.patch"
echo "[susfs] apply patch kernel (fuzz 3)..."
if ! patch -p1 -d "$K" -F3 -l --no-backup-if-mismatch < "$P"; then
  echo "[susfs] hunk gagal, isi .rej:" >&2
  find "$K" -name '*.rej' -print -exec cat {} \; >&2
  echo "[susfs] FATAL: patch kernel tidak cocok" >&2
  exit 1
fi
cp "$HERE/susfs.c" "$K/fs/susfs.c"
cp "$HERE/susfs.h" "$HERE/susfs_def.h" "$K/include/linux/"
echo "[susfs] patch kernel terpasang"

# README susfs langkah 11: wajib dihapus, kalau tidak WiFi/modul rusak
rm -f "$K/android/abi_gki_protected_exports_aarch64" \
      "$K/android/abi_gki_protected_exports_x86_64"

if [ -n "$KSU" ] && [ -d "$KSU" ]; then
  if patch -p1 -d "$KSU" --dry-run -s < "$HERE/10_enable_susfs_for_ksu.patch" 2>/dev/null; then
    patch -p1 -d "$KSU" < "$HERE/10_enable_susfs_for_ksu.patch"
    echo "[susfs] patch KernelSU terpasang"
  else
    echo "[susfs] WARN: patch KernelSU dilewati (fork sudah punya SUSFS)"
  fi
fi
