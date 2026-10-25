#!/usr/bin/env bash
#
# Kernel build script
# Builds a GKI 6.12 kernel (android16) with KernelSU-Next (pershoot dev-susfs
# fork + extra manager signatures), Baseband Guard, DroidSpaces, NTSync and
# assorted config patches, then packages AnyKernel3.
#
# Usage: ./build.sh --target <6.12|cass> [options]

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly CUSTOM_REPO="https://github.com/Arkael-Dev/arkael-kernel-a12-5.10"
readonly ANDROID_VERSION="android16"
readonly KERNEL_VERSION="6.12"
readonly MANIFEST_SUBLEVEL="38"
readonly OS_PATCH_LEVEL="2025-09"
readonly VERSION="${ANDROID_VERSION}-${KERNEL_VERSION}"

readonly WORKSPACE="$(pwd)"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PATCH_DIR="${SCRIPT_DIR}/patches"
readonly KERNEL_DIR="${WORKSPACE}/kernel"
readonly OUT_DIR="/home/runner/out"
readonly AK3_DIR="${WORKSPACE}/AnyKernel"

# KernelSU-Next source: pershoot's fork, dev-susfs branch.
readonly KSU_REPO_URL="https://github.com/pershoot/KernelSU-Next.git"
readonly KSU_DEFAULT_REF="dev-susfs"
readonly KSU_SETUP_URL="https://raw.githubusercontent.com/pershoot/KernelSU-Next/${KSU_DEFAULT_REF}/kernel/setup.sh"

readonly BOT_NAME="arkael-bot"
readonly BOT_EMAIL="arkael-bot@users.noreply.github.com"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------

TARGET=""
KSU_BRANCH=""
KERNEL_NAME_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $0 --target <6.12|cass> [options]

Options:
  --target <6.12|cass>     Which kernel source branch to build (required)
  --ksu-branch <ref>       pershoot/KernelSU-Next branch/tag/commit (default: ${KSU_DEFAULT_REF})
  --kernel-name <tag>      Override branding tag (default: Arkael-Project or Arkael-Fork)
  -h, --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)       TARGET="$2"; shift 2 ;;
      --ksu-branch)   KSU_BRANCH="$2"; shift 2 ;;
      --kernel-name)  KERNEL_NAME_OVERRIDE="$2"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$TARGET" != "6.12" && "$TARGET" != "cass" ]]; then
    echo "ERROR: --target must be '6.12' or 'cass' (got: '${TARGET:-<empty>}')" >&2
    usage
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
warn() { echo -e "\033[1;33m[warn] $*\033[0m"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line_no=$1
  echo -e "\033[1;31m[fail] build.sh exited ${exit_code} at line ${line_no}\033[0m" >&2
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Derived / runtime globals (populated as the build progresses)
# ---------------------------------------------------------------------------

CUSTOM_BRANCH=""
BUILD_EPOCH=""
KERNEL_NAME_TAG=""
SUBLEVEL=""
FILE_NAME=""
KSU_VERSION=""
KSU_GIT_TAG=""

resolve_custom_branch() {
  if [[ "$TARGET" == "6.12" ]]; then
    CUSTOM_BRANCH="6.12-linux"
  else
    CUSTOM_BRANCH="cass"
  fi
}

# ---------------------------------------------------------------------------
# kconfig helper — merges "KEY=value" / "KEY" lines into gki_defconfig
# ---------------------------------------------------------------------------

apply_kconfig() {
  local defconfig="${KERNEL_DIR}/common/arch/arm64/configs/gki_defconfig"
  [[ -f "$defconfig" ]] || die "gki_defconfig not found at ${defconfig}"

  local line key value
  while IFS= read -r line; do
    line="$(echo "$line" | xargs)"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
    else
      key="$line"
      value="y"
    fi

    # "KEY=n" is written the way kconfig expects it: "# KEY is not set".
    if [[ "$value" == "n" ]]; then
      if grep -q "^${key}=" "$defconfig"; then
        sed -i "s|^${key}=.*|# ${key} is not set|g" "$defconfig"
      elif ! grep -q "^# ${key} is not set" "$defconfig"; then
        echo "# ${key} is not set" >> "$defconfig"
      fi
      continue
    fi

    if grep -q "^${key}=" "$defconfig"; then
      sed -i "s|^${key}=.*|${key}=${value}|g" "$defconfig"
    elif grep -q "^# ${key} is not set" "$defconfig"; then
      sed -i "s|^# ${key} is not set|${key}=${value}|g" "$defconfig"
    else
      echo "${key}=${value}" >> "$defconfig"
    fi
  done <<< "$1"
}

# ---------------------------------------------------------------------------
# Stage: environment setup
# ---------------------------------------------------------------------------

setup_build_environment() {
  log "Setting up build environment"

  git config --global user.name "$BOT_NAME"
  git config --global user.email "$BOT_EMAIL"

  mkdir -p "$KERNEL_DIR"

  if ! command -v repo >/dev/null 2>&1; then
    mkdir -p "${WORKSPACE}/git-repo"
    curl -L https://storage.googleapis.com/git-repo-downloads/repo -o "${WORKSPACE}/git-repo/repo"
    chmod +x "${WORKSPACE}/git-repo/repo"
    export PATH="${WORKSPACE}/git-repo:${PATH}"
  fi

  rm -rf "${WORKSPACE}/kernel_patches"
  git clone --depth=1 https://github.com/WildKernels/kernel_patches.git "${WORKSPACE}/kernel_patches"

  rm -rf "$AK3_DIR"
  git clone --depth=1 https://github.com/Arkael-Dev/AnyKernel.git -b gki-2.0 "$AK3_DIR"

  sudo apt-get update -qq
  sudo apt-get install -y -qq dwarves libelf-dev
}

# ---------------------------------------------------------------------------
# Stage: kernel source
# ---------------------------------------------------------------------------

_repo_init() {
  local formatted_branch="$1"
  repo init -u https://android.googlesource.com/kernel/manifest \
    -b "common-${formatted_branch}" --depth=1

  local remote_branch
  remote_branch=$(git ls-remote https://android.googlesource.com/kernel/common "${formatted_branch}")
  if grep -q deprecated <<<"$remote_branch"; then
    sed -i "s/\"${formatted_branch}\"/\"deprecated\/${formatted_branch}\"/g" .repo/manifests/default.xml
    warn "Branch ${formatted_branch} is deprecated upstream."
  fi
}

_repo_sync_with_retries() {
  local max_retries=3 attempt=1
  while (( attempt <= max_retries )); do
    echo "repo sync attempt ${attempt}/${max_retries}..."
    if timeout 15m repo sync -c --current-branch --no-clone-bundle --no-tags --jobs-checkout=4 -j4; then
      return 0
    fi
    if (( attempt < max_retries )); then
      rm -rf .repo
      sleep 15
      _repo_init "$1"
    else
      die "repo sync failed after ${max_retries} attempts"
    fi
    attempt=$((attempt + 1))
  done
}

_clone_custom_common() {
  log "Overriding kernel/common with ${CUSTOM_REPO} (branch: ${CUSTOM_BRANCH})"
  rm -rf common

  local attempt=1
  while (( attempt <= 3 )); do
    if git clone --branch "$CUSTOM_BRANCH" --depth=1 "$CUSTOM_REPO" common; then
      echo "kernel/common HEAD: $(git -C common rev-parse HEAD)"
      return 0
    fi
    rm -rf common
    if (( attempt == 3 )); then
      die "failed to clone ${CUSTOM_REPO} (${CUSTOM_BRANCH})"
    fi
    attempt=$((attempt + 1))
    sleep 10
  done
}

download_kernel() {
  log "Downloading AOSP GKI manifest ($VERSION, os_patch_level=$OS_PATCH_LEVEL)"

  local formatted_branch="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
  cd "$KERNEL_DIR"

  _repo_init "$formatted_branch"
  _repo_sync_with_retries "$formatted_branch"
  _clone_custom_common
}

# ---------------------------------------------------------------------------
# Stage: build metadata (timestamp, branding tag, output file name)
# ---------------------------------------------------------------------------

set_build_timestamp() {
  log "Setting build timestamp / branding tag"

  BUILD_EPOCH=$(date -u +%s)
  export SOURCE_DATE_EPOCH="$BUILD_EPOCH"

  export KBUILD_BUILD_TIMESTAMP
  KBUILD_BUILD_TIMESTAMP=$(date -u -d "@${BUILD_EPOCH}" '+%a %b %d %H:%M:%S UTC %Y')

  export GIT_COMMITTER_DATE GIT_AUTHOR_DATE
  GIT_COMMITTER_DATE=$(date -u -d "@${BUILD_EPOCH}" '+%Y-%m-%dT%H:%M:%SZ')
  GIT_AUTHOR_DATE="$GIT_COMMITTER_DATE"

  if [[ -n "$KERNEL_NAME_OVERRIDE" ]]; then
    KERNEL_NAME_TAG=$(echo "$KERNEL_NAME_OVERRIDE" | sed 's/[^A-Za-z0-9._-]/-/g')
  elif [[ "$TARGET" == "6.12" ]]; then
    KERNEL_NAME_TAG="Arkael-X"
  else
    KERNEL_NAME_TAG="Arkael-Dev"
  fi

  echo "Kernel branding tag: $KERNEL_NAME_TAG"
}

extract_sublevel_and_name() {
  log "Extracting sublevel / composing file name"

  SUBLEVEL="$MANIFEST_SUBLEVEL"
  if [[ -f "${KERNEL_DIR}/common/Makefile" ]]; then
    local extracted
    extracted=$(grep '^SUBLEVEL = ' "${KERNEL_DIR}/common/Makefile" | awk '{print $3}')
    [[ -n "$extracted" ]] && SUBLEVEL="$extracted"
  fi

  local stamp label
  stamp=$(date -u -d "@${BUILD_EPOCH}" '+%Y%m%d-%H%M')
  label="${KERNEL_VERSION}.${SUBLEVEL}"

  FILE_NAME="AK3-${label}-${KERNEL_NAME_TAG}-${stamp}"
  echo "File name: $FILE_NAME"
}

# ---------------------------------------------------------------------------
# Stage: toolchain / Makefile fixes
# ---------------------------------------------------------------------------

apply_kernel_fixes() {
  log "Applying kernel fixes"
  cd "${KERNEL_DIR}/common"

  local glibc_version
  glibc_version="$(ldd --version 2>/dev/null | head -n1 | awk '{print $NF}')"

  if [[ "$(printf '%s\n' "2.38" "$glibc_version" | sort -V | head -n1)" != "2.38" ]]; then
    echo "GLIBC ${glibc_version} < 2.38, skipping resolve_btfids Makefile fix"
    return
  fi

  echo "GLIBC ${glibc_version} >= 2.38, checking resolve_btfids Makefile..."
  local target="tools/bpf/resolve_btfids/Makefile"

  if grep -q '$(Q)$(MAKE) -C $(SUBCMD_SRC) OUTPUT=$(abspath $(dir $@))/ $(abspath $@)' "$target"; then
    sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' "$target"
    echo "  -> Makefile EXTRA_CFLAGS fix applied"
  else
    echo "  -> pattern not found / already fixed, skipping"
  fi
}

# ---------------------------------------------------------------------------
# Stage: KernelSU-Next
# ---------------------------------------------------------------------------

# Resolved ref actually used for KernelSU-Next (flag value or default).
_ksu_ref() { echo "${KSU_BRANCH:-$KSU_DEFAULT_REF}"; }

# pershoot's setup.sh ends with `git checkout "$1" && ... || echo "Checkout
# default branch"`, i.e. a bad ref is NOT an error — it silently leaves the
# clone on the repo's default branch ("dev", which has no SUSFS work). Verify
# that HEAD really is the requested ref so a typo can't produce a wrong build.
_ksu_verify_checkout() {
  local ref="$1"
  local ksu_dir="${KERNEL_DIR}/KernelSU-Next"
  local head want

  head="$(git -C "$ksu_dir" rev-parse HEAD)"
  want="$(git -C "$ksu_dir" rev-parse --verify -q "refs/remotes/origin/${ref}^{commit}" \
          || git -C "$ksu_dir" rev-parse --verify -q "${ref}^{commit}" \
          || true)"

  [[ -n "$want" ]] || die "KernelSU-Next ref '${ref}' not found in ${KSU_REPO_URL}"
  [[ "$head" == "$want" ]] \
    || die "KernelSU-Next is at ${head:0:12}, expected '${ref}' (${want:0:12}) — setup.sh fell back to its default branch"

  echo "KernelSU-Next: ${ref} @ ${head:0:12}"
}

_ksu_stamp_version() {
  local commits_count base_version=30000
  commits_count=$(git rev-list --count HEAD)
  KSU_VERSION=$((commits_count + base_version))
  sed -i "s/^KSU_VERSION_FALLBACK := 1$/KSU_VERSION_FALLBACK := ${KSU_VERSION}/" Kbuild

  KSU_GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)"
  sed -i "s/^KSU_VERSION_TAG_FALLBACK := v0.0.1$/KSU_VERSION_TAG_FALLBACK := ${KSU_GIT_TAG}/" Kbuild
}

# Extends KSU_NEXT_MANAGER_LIST in kernel/Kbuild so more manager apps
# (KSUN, pershoot, KOWSU, MamboSU, RKSU, WildKSU, VorteXSU) are accepted.
# pershoot's dev-susfs only reads that one list (kernel/manager/apk_sign.c),
# so this single patch is all that is needed.
#
# The patch is applied to the KernelSU-Next checkout (KernelSU-Next/kernel/Kbuild);
# drivers/kernelsu is a symlink to that directory, so it is the file the
# compiler actually reads. Idempotent: a tree that already carries the extended
# list is skipped; a genuine mismatch fails loudly instead of building a
# kernel with the wrong manager list.
_ksu_apply_manager_patch() {
  local patch_file="${PATCH_DIR}/ksun-add-more-managers-support.patch"
  local ksu_dir="${KERNEL_DIR}/KernelSU-Next"
  local kbuild="${ksu_dir}/kernel/Kbuild"
  local marker="# KSUN, pershoot, KOWSU, MamboSU, RKSU, WildKSU, VorteXSU"

  [[ -f "$patch_file" ]] || die "${patch_file} not found"
  [[ -f "$kbuild" ]]     || die "${kbuild} not found"

  if grep -qF "$marker" "$kbuild"; then
    echo "Kbuild already carries the extended manager list — skipping patch"
    return 0
  fi

  log "Applying ksun-add-more-managers-support.patch"
  (cd "$ksu_dir" && patch -p1 --forward --dry-run < "$patch_file" >/dev/null) \
    || die "ksun-add-more-managers-support.patch does not apply to ${KSU_REPO_URL} @ $(_ksu_ref)"
  (cd "$ksu_dir" && patch -p1 --forward < "$patch_file")

  grep -qF "$marker" "$kbuild" || die "manager list not updated in ${kbuild} after patching"

  local count
  count=$(grep '^KSU_NEXT_MANAGER_LIST :=' "$kbuild" | grep -o '0x[0-9a-fA-F]*:' | wc -l)
  echo "KSU_NEXT_MANAGER_LIST now has ${count} manager signature(s)"
}

# dev-susfs enables CONFIG_KSU_SUSFS by default, and with it the KernelSU code
# #includes <linux/susfs.h> / <linux/susfs_def.h> from the kernel tree. Those
# only exist if SUSFS has been patched into kernel/common. If they are missing
# the build would break, so turn the option off (KernelSU then uses its
# kprobe-based hooks, which gki_defconfig supports).
_ksu_configure_susfs() {
  local common="${KERNEL_DIR}/common"

  if [[ -f "${common}/include/linux/susfs.h" && -f "${common}/include/linux/susfs_def.h" ]]; then
    echo "SUSFS sources found in kernel/common — leaving CONFIG_KSU_SUSFS at its default (y)"
  else
    warn "SUSFS sources not found in kernel/common — building with CONFIG_KSU_SUSFS disabled"
    apply_kconfig "CONFIG_KSU_SUSFS=n"
  fi
}

# SUSFS kernel-side patch (simonpunk/susfs4ksu gki-android16-6.12 @ 3ff9fd3).
# KernelSU-side patch is NOT needed: pershoot dev-susfs already integrates it.
_susfs_apply_kernel_patch() {
  local src="${PATCH_DIR}/susfs-gki-6.12"
  local common="${KERNEL_DIR}/common"
  local patch_file="${src}/50_add_susfs_in_gki-android16-6.12.patch"

  [[ -f "$patch_file" ]] || die "${patch_file} not found"
  if grep -q 'susfs' "${common}/fs/Makefile" 2>/dev/null; then
    echo "SUSFS already patched into kernel/common — skipping"
    return 0
  fi

  log "Applying SUSFS kernel patch (gki-android16-6.12)"
  (cd "$common" && patch -p1 --forward --dry-run < "$patch_file" >/dev/null) \
    || die "SUSFS patch does not apply to ${common}"
  cp "${src}/fs/susfs.c" "${common}/fs/"
  cp "${src}/include/linux/susfs.h" "${src}/include/linux/susfs_def.h" "${common}/include/linux/"
  (cd "$common" && patch -p1 --forward < "$patch_file")
  [[ -f "${common}/fs/susfs.c" && -f "${common}/include/linux/susfs_def.h" ]] \
    || die "SUSFS files missing after patching"
}

setup_kernelsu() {
  local ksu_ref
  ksu_ref="$(_ksu_ref)"

  log "Setting up KernelSU-Next (pershoot, ${ksu_ref})"
  cd "$KERNEL_DIR"

  curl -LSs "$KSU_SETUP_URL" | bash -s "$ksu_ref"
  _ksu_verify_checkout "$ksu_ref"

  # No subshell here: KSU_VERSION / KSU_GIT_TAG are globals reported at the end.
  cd "${KERNEL_DIR}/KernelSU-Next/kernel"
  _ksu_stamp_version
  cd "$KERNEL_DIR"
  _ksu_apply_manager_patch

  apply_kconfig "CONFIG_KSU=y"
  _susfs_apply_kernel_patch
  _ksu_configure_susfs
  echo "KSU version: $KSU_VERSION (tag: $KSU_GIT_TAG)"
}

# ---------------------------------------------------------------------------
# Stage: Baseband Guard
# ---------------------------------------------------------------------------

setup_bbg() {
  log "Setting up Baseband Guard"
  cd "$KERNEL_DIR"

  wget -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash

  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' \
    common/security/Kconfig

  grep -q "baseband_guard" common/security/Kconfig \
    || die "baseband_guard not found in common/security/Kconfig"

  apply_kconfig "CONFIG_BBG=y"
}

# ---------------------------------------------------------------------------
# Stage: networking configs
# ---------------------------------------------------------------------------

setup_networking() {
  log "Setting up networking configs"

  apply_kconfig "$(cat <<'EOF'
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_BIC=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_ACT_CONNMARK=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_WIREGUARD=y
CONFIG_CIFS=y
CONFIG_NETWORK_FILESYSTEMS=y
CONFIG_NETFS_SUPPORT=y
CONFIG_KEYS=y
CONFIG_CIFS_XATTR=y
CONFIG_CIFS_POSIX=y
EOF
)"

  cd "${KERNEL_DIR}/common"
  sed -i '/"fs\/netfs\/netfs\.ko",/d' modules.bzl
}

# ---------------------------------------------------------------------------
# Stage: DroidSpaces-OSS
# ---------------------------------------------------------------------------

setup_droidspaces() {
  log "Setting up DroidSpaces-OSS"
  cd "$WORKSPACE"
  rm -rf Droidspaces-OSS
  git clone --depth=1 https://github.com/ravindu644/Droidspaces-OSS.git

  cd "${KERNEL_DIR}/common"
  cp "${WORKSPACE}/Droidspaces-OSS/Documentation/resources/kernel-patches/GKI/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch" ./
  patch -p1 < 001.GKI-6.12-or-above-fix_sysvipc_kabi.patch

  {
    echo
    echo 'EXPORT_SYMBOL_GPL(put_ipc_ns);'
  } >> "${KERNEL_DIR}/common/ipc/namespace.c"

  {
    echo
    echo 'EXPORT_SYMBOL_GPL(init_ipc_ns);'
  } >> "${KERNEL_DIR}/common/ipc/msgutil.c"

  apply_kconfig "$(cat <<'EOF'
CONFIG_PID_NS=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_DEVTMPFS=y
CONFIG_BINFMT_MISC=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_BINFMT_ELF=y
CONFIG_USER_NS=y
EOF
)"
}

# ---------------------------------------------------------------------------
# Stage: NTSync
# ---------------------------------------------------------------------------

setup_ntsync() {
  log "Applying NTSync patches"
  cd "${KERNEL_DIR}/common"

  echo "Removing pre-existing ntsync files for android16-6.12"
  rm -f include/uapi/linux/ntsync.h
  rm -f drivers/misc/ntsync.c

  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_compat_${VERSION}.patch"
  patch -p1 < "${WORKSPACE}/kernel_patches/common/ntsync/ntsync_base.patch"

  apply_kconfig "CONFIG_NTSYNC=y"
}

# ---------------------------------------------------------------------------
# Stage: misc patches (ptrace, unicode, extra kconfig)
# ---------------------------------------------------------------------------

_kernel_version_le() {
  # Returns success if $KERNEL_VERSION <= $1 (per `sort -V`).
  # NOTE: named _le (less-or-equal), not _at_least — the gki_ptrace patch
  # and the unicode-fix variant selection both key off "is this kernel
  # <= 5.16", not ">= 5.16". Getting this backwards means gki_ptrace.patch
  # (which touches tracehook.h, removed from the kernel well before 6.12)
  # gets applied to kernels it was never meant for.
  [[ "$(printf '%s\n' "$KERNEL_VERSION" "$1" | sort -V | head -n1)" == "$KERNEL_VERSION" ]]
}

apply_ptrace_patch() {
  log "Checking ptrace patch (kernel ${KERNEL_VERSION})"
  if _kernel_version_le "5.16"; then
    cd "${KERNEL_DIR}/common"
    patch -p1 -F3 < "${WORKSPACE}/kernel_patches/gki_ptrace.patch"
  else
    echo "Kernel >= 5.16, skipping ptrace patch"
  fi
}

apply_unicode_fix() {
  log "Applying unicode fix patch"
  cd "${KERNEL_DIR}/common"
  if _kernel_version_le "5.16"; then
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1-.patch"
  else
    patch -p1 --forward < "${WORKSPACE}/kernel_patches/common/unicode_bypass_fix_6.1+.patch"
  fi
}

setup_misc_and_btf() {
  log "Setting up misc kernel configs"
  # CONFIG_ADIOS=y dihapus karena tidak ada driver/patch di repo upstream
  apply_kconfig "$(cat <<'EOF'
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_BPF_EVENTS=y
CONFIG_KPROBE_EVENTS=y
CONFIG_UPROBES=y
CONFIG_UPROBE_EVENTS=y
CONFIG_FUSE_BPF=y
CONFIG_DEBUG_INFO_BTF=y
EOF
)"
}

# ---------------------------------------------------------------------------
# Stage: branding, protected exports, dirty flag
# ---------------------------------------------------------------------------

apply_kernel_branding() {
  log "Applying kernel branding: $KERNEL_NAME_TAG"
  cd "${KERNEL_DIR}/common"

  local kernel_string="${KERNEL_VERSION}.${SUBLEVEL}-${ANDROID_VERSION}"
  sed -i '$d' scripts/setlocalversion
  echo "echo \"${kernel_string}-${KERNEL_NAME_TAG}\"" >> scripts/setlocalversion
  chmod +x scripts/setlocalversion
}

remove_protected_exports() {
  cd "$KERNEL_DIR"

  if [[ -f "build/build.sh" ]]; then
    echo "Legacy build system detected, skipping protected-exports removal"
    return
  fi

  log "Removing protected exports (Bazel)"
  rm -rf common/android/abi_gki_protected_exports_*

  if grep -q '"protected_exports_list"[[:space:]]*:[[:space:]]*"android/abi_gki_protected_exports_aarch64"' common/BUILD.bazel; then
    perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' common/BUILD.bazel
  fi

  if grep -q '^protected_modules = ' common/modules.bzl; then
    sed -i 's/protected_modules = \[.*\]/protected_modules = []/' common/modules.bzl
  fi

  if grep -q 'protected_module_names_list' common/BUILD.bazel; then
    perl -pi -e 's/^\s*protected_module_names_list\s*=\s*":gki_(?:aarch64|x86_64)_protected_module_names",\s*$//;' common/BUILD.bazel
  fi
}

clean_kernel_flags() {
  log "Cleaning dirty flags"
  cd "$KERNEL_DIR"

  if [[ -f "build/build.sh" ]]; then
    sed -i 's/-dirty//' common/scripts/setlocalversion
  else
    sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl
    sed -i 's/-dirty//' common/scripts/setlocalversion
  fi

  cd "${KERNEL_DIR}/common"
  git add -A
  git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
    commit -m "arkael: clean dirty flag" --quiet || true
}

# ---------------------------------------------------------------------------
# Stage: build
# ---------------------------------------------------------------------------

_apply_bypass_patch() {
  local target_file="common/kernel/module/version.c"
  sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$target_file"
  grep -A5 "bad_version:" "$target_file" | grep -q "return 1;" \
    || die "bypass patch failed on $target_file"
}

_disable_defconfig_check() {
  [[ -f "./common/build.config.gki" ]] && sed -i 's/check_defconfig//' ./common/build.config.gki

  # Nonaktifkan check_defconfig Bazel secara permanen agar tidak fail saat
  # ada config tambahan.
  if grep -q 'name = "kernel_aarch64"' common/BUILD.bazel; then
    sed -i '/check_defconfig =/d' common/BUILD.bazel
    sed -i '/name = "kernel_aarch64",/a\    check_defconfig = "disabled",' common/BUILD.bazel
  fi
}

_run_legacy_build() {
  BUILD_GKI_ARTIFACTS="" \
  BUILD_GKI_CERTIFICATION_TOOLS=0 \
  BUILD_SYSTEM_DLKM=0 \
  SKIP_VENDOR_BOOT=1 \
  SKIP_EXT_MODULES=1 \
  SKIP_CP_KERNEL_HDR=1 \
  OUT_DIR="$OUT_DIR" \
  LTO=thin \
  BUILD_CONFIG=common/build.config.gki.aarch64 \
  build/build.sh -j"$(nproc)" \
  CC="ccache clang" CXX="ccache clang++" HOSTCC="ccache clang" HOSTCXX="ccache clang++"
}

_run_bazel_build() {
  tools/bazel build \
    --config=fast \
    --config=stamp \
    --kconfig_check=none \
    --disk_cache="${HOME}/.cache/bazel" \
    //common:kernel_aarch64/Image \
  || tools/bazel build \
    --config=fast \
    --config=stamp \
    --disk_cache="${HOME}/.cache/bazel" \
    //common:kernel_aarch64/Image
}

_locate_built_image() {
  if [[ -f "bazel-bin/common/kernel_aarch64/Image" ]]; then
    echo "bazel-bin/common/kernel_aarch64/Image"
  elif [[ -f "${OUT_DIR}/dist/Image" ]]; then
    echo "${OUT_DIR}/dist/Image"
  else
    die "could not find built Image"
  fi
}

build_variant() {
  local bypass="$1"
  log "Building kernel (bypass=${bypass})"
  cd "$KERNEL_DIR"

  [[ "$bypass" == "true" ]] && _apply_bypass_patch
  _disable_defconfig_check

  if [[ -f "build/build.sh" ]]; then
    _run_legacy_build
  else
    _run_bazel_build
  fi

  local image_out
  image_out="$(_locate_built_image)"

  if [[ "$bypass" == "true" ]]; then
    cp "$image_out" "${AK3_DIR}/Bypass-Image"
    cp "${PATCH_DIR}/anykernel3-bypass.patch" "${AK3_DIR}/bypass.patch"
    (cd "$AK3_DIR" && patch -p1 < bypass.patch)
  else
    cp "$image_out" "${AK3_DIR}/Image"
  fi
}

build_kernel() {
  touch "${WORKSPACE}/wild_gki.fragment"
  build_variant "false"
  build_variant "true"
}

# ---------------------------------------------------------------------------
# Stage: post-build (patch rejects, packaging)
# ---------------------------------------------------------------------------

scan_patch_rejects() {
  log "Scanning for .rej files"
  local rejects_dir="${WORKSPACE}/patch-rejects"
  mkdir -p "$rejects_dir"

  local rej_count=0 rej rel
  while IFS= read -r rej; do
    rel="${rej#"$KERNEL_DIR"/}"
    [[ "$(basename "$rel")" == "i2c-nomadik.c.rej" ]] && continue

    mkdir -p "$(dirname "${rejects_dir}/${rel}")"
    cp "$rej" "${rejects_dir}/${rel}"
    rej_count=$((rej_count + 1))
  done < <(find "$KERNEL_DIR" -type f -name '*.rej' 2>/dev/null || true)

  if (( rej_count > 0 )); then
    warn "${rej_count} patch reject(s) found — see ${rejects_dir}"
  else
    echo "No patch rejects."
    rmdir "$rejects_dir" 2>/dev/null || true
  fi
}

package_output() {
  log "Packaging AnyKernel3 as ${FILE_NAME}.zip"
  mkdir -p "${WORKSPACE}/out"

  local zip_path="${WORKSPACE}/out/${FILE_NAME}.zip"
  rm -f "$zip_path"
  ( cd "$AK3_DIR" && zip -r -q -9 "$zip_path" . -x '.git/*' )
  echo "Built: $zip_path"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  resolve_custom_branch

  echo "============================================================"
  echo " arkael Kernel build — target: ${TARGET} (${VERSION}, branch ${CUSTOM_BRANCH})"
  echo "============================================================"

  setup_build_environment
  download_kernel
  set_build_timestamp
  extract_sublevel_and_name
  apply_kernel_fixes
  setup_kernelsu
  setup_bbg
  setup_networking
  setup_droidspaces
  setup_ntsync
  apply_ptrace_patch
  apply_unicode_fix
  setup_misc_and_btf
  apply_kernel_branding
  remove_protected_exports
  clean_kernel_flags
  scan_patch_rejects
  build_kernel
  package_output

  echo
  echo "============================================================"
  echo " Done. KSU=${KSU_VERSION:-N/A} (${KSU_GIT_TAG:-N/A})"
  echo " Output: ${WORKSPACE}/out/${FILE_NAME}.zip"
  echo "============================================================"
}

main "$@"
