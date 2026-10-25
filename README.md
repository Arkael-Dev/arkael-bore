<div align="center">

<img src="assets/banner.svg" alt="Arkael Kernel" width="100%">

<br>

[![Build](https://github.com/Arkael-Dev/arkael-bore/actions/workflows/build.yml/badge.svg?branch=arkael-dev)](https://github.com/Arkael-Dev/arkael-bore/actions/workflows/build.yml)
![Android](https://img.shields.io/badge/Android-16-3DDC84?logo=android&logoColor=white)
![Kernel](https://img.shields.io/badge/GKI-6.12-0ea5e9?logo=linux&logoColor=white)
[![KernelSU-Next](https://img.shields.io/badge/KernelSU--Next-pershoot%20dev--susfs-22c55e)](https://github.com/pershoot/KernelSU-Next/tree/dev-susfs)
[![Releases](https://img.shields.io/badge/Download-Releases-a78bfa)](https://github.com/Arkael-Dev/arkael-bore/releases)

**A GKI 6.12 (android16) kernel with KernelSU-Next, multi-manager support, Baseband Guard, Droidspaces and NTSync.**

[Features](#-features) · [Managers](#-supported-managers) · [Flashing](#-flashing) · [Building](#-building) · [Credits](#-credits)

</div>

> [!WARNING]
> **Your warranty is no longer valid!** Flashing a custom kernel can brick your device. Back up your data and read the [disclaimer](#-disclaimer) before you continue.

---

## ✨ Features

| | Feature | Details |
|---|---|---|
| 🔑 | **KernelSU-Next** | Built from [pershoot's `dev-susfs` fork](https://github.com/pershoot/KernelSU-Next/tree/dev-susfs) |
| 🧩 | **Multi-manager support** | 9 manager signatures accepted, see [Supported managers](#-supported-managers) |
| 🛡️ | **Baseband Guard** | LSM that protects the modem / baseband partitions |
| 📦 | **Droidspaces** | Kernel options for running Linux containers |
| 🍷 | **NTSync** | NT synchronization primitives for Wine / Proton |
| 🌐 | **Networking** | BBR (default), CUBIC, BIC, Westwood, H-TCP · FQ / FQ_CODEL / CAKE · WireGuard · ipset · extra netfilter modules · CIFS client |
| 🔬 | **Debugging** | kprobe / uprobe events, BPF events, FUSE-BPF, BTF, `kallsyms` |
| 🗂️ | **Filesystems** | OverlayFS, tmpfs xattr + POSIX ACL |
| 📲 | **AnyKernel3 installer** | One zip, with a choice between *Normal* and *Bypass* image at flash time |

> [!NOTE]
> **SUSFS** is not forced on. KernelSU-Next is built from the `dev-susfs` branch, and the build turns SUSFS on only when the kernel source tree actually contains the SUSFS sources. Otherwise it is built with SUSFS disabled.

## 🧩 Supported managers

The kernel accepts these manager apps (signature list is applied by
[`patches/ksun-add-more-managers-support.patch`](patches/ksun-add-more-managers-support.patch)):

`KernelSU-Next` · `KernelSU-Next (pershoot)` · `KOWSU` · `MamboSU` · `RKSU` · `WildKSU` · `VorteXSU`

## 📲 Flashing

1. Download the `AK3-6.12.*-Arkael-*.zip` from the [Releases](https://github.com/Arkael-Dev/arkael-bore/releases) page, or from the artifacts of a [workflow run](https://github.com/Arkael-Dev/arkael-bore/actions).
2. Flash the zip with a kernel flasher app or from custom recovery.
3. When the installer asks for the **Kernel Image Mode**, press a volume key within 20 seconds:

| Key | Mode | When to use |
|---|---|---|
| **Vol −** | **Normal** *(recommended)* | Most devices |
| **Vol +** | **Bypass** *(advanced)* | Only if the device fails to boot because of kernel module compatibility |

> [!IMPORTANT]
> Bypass mode only relaxes the kernel module version check. It does **not** hide root and it does **not** bypass any detection.
> If no key is pressed before the timeout, the installer exits without flashing anything.

## 🛠️ Building

Builds run on GitHub Actions: **Actions → Build Arkael Kernel 6.12 → Run workflow**.

| Input | Meaning |
|---|---|
| **Release type** | `Action` (artifact only) · `Pre-Release` · `Release` (creates tag `r<N>` automatically) |
| **Branch** | `6.12`, `cass`, or both |
| **ksu_branch** | `pershoot/KernelSU-Next` branch, tag or commit. Empty = `dev-susfs` |
| **kernel_name** | Overrides the branding tag (default: `Arkael-X` for `6.12`, `Arkael-Dev` for `cass`) |

Locally (written for an Ubuntu runner, it uses `sudo apt-get` and `/home/runner/out`):

```bash
./build.sh --target 6.12 [--ksu-branch <ref>] [--kernel-name <tag>]
```

The script pulls the AOSP `android16-6.12` manifest, swaps `kernel/common` for
[`arkael-kernel-a12-5.10`](https://github.com/Arkael-Dev/arkael-kernel-a12-5.10) (branch `6.12` or `cass`),
applies the features above, builds both the Normal and the Bypass image, and packs them into an AnyKernel3 zip.

<details>
<summary><b>Repository layout</b></summary>

```
.
├── build.sh                       # whole build pipeline
├── assets/banner.svg              # animated README banner
├── patches/
│   ├── anykernel3-bypass.patch    # Normal / Bypass image menu for the installer
│   └── ksun-add-more-managers-support.patch   # extra manager signatures
└── .github/workflows/build.yml    # "Build Arkael Kernel 6.12" workflow
```

</details>

## 🙏 Credits

- **clone for GKI kernel**: [Kinosaki](https://github.com/usermahiro/GKI_KernelSU_SUSFS)
- **KernelSU**: developed by [tiann](https://github.com/tiann/KernelSU)
- **KernelSU-Next**: developed by [rifsxd](https://github.com/KernelSU-Next/KernelSU-Next)
- **KernelSU-Next (dev-susfs)**: maintained by [pershoot](https://github.com/pershoot/KernelSU-Next)
- **Magic-KSU**: developed by [5ec1cff](https://github.com/5ec1cff/KernelSU)
- **SUSFS**: developed by [simonpunk](https://gitlab.com/simonpunk/susfs4ksu.git)
- **SUSFS Module**: developed by [sidex15](https://github.com/sidex15)
- **Baseband-guard (BBG)**: developed by [vc-teahouse](https://github.com/vc-teahouse/Baseband-guard)
- **Droidspaces-OSS**: developed by [ravindu644](https://github.com/ravindu644/Droidspaces-OSS)
- **Kernel patches**: [WildKernels/kernel_patches](https://github.com/WildKernels/kernel_patches)
- **AnyKernel3**: [Arkael-Dev/AnyKernel](https://github.com/Arkael-Dev/AnyKernel)

Special thanks to the open-source community for their contributions!

## ⚠️ Disclaimer

I am **not responsible** for bricked devices, damaged hardware, or any issues that arise from using this kernel.

**Please** do thorough research and fully understand the features included in this kernel before flashing it!

By flashing this kernel, **YOU** are choosing to make these modifications. If something goes wrong, **do not blame me**!

Flashing this kernel will void your warranty, and there is always a risk of bricking your device. Please make sure to:

- Back up your data
- Understand the risks before proceeding

**Proceed at your own risk!**
