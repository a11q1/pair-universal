<!--
SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
SPDX-License-Identifier: Apache-2.0
-->

# PAIR Universal — BETA — Fork Notes

> ⚠️ BETA — upstream NVIDIA PAIR is in beta since 09/03/2026. This fork inherits the beta status: APIs/scheduler not yet stable.

This document describes the changes in the **PAIR Universal BETA** fork compared to [NVIDIA/Personal-AI-Router](https://github.com/NVIDIA/Personal-AI-Router) `0.91.7` (beta).

## Goal

Make PAIR usable on **all GPUs** and **all Linux distros**, without an RTX allowlist, and with full Apple Silicon support.

## Changes

### 1. Universal GPU — `services/nvpair-node-info/`

**`gpu_linux.go:36`** — `detectGPUs()` rewritten:

```
nvidia-smi (all: GTX/Tesla/RTX/Quadro) → AMD (amd-smi/rocm-smi + DRM sysfs) → DRM sysfs (/sys/class/drm/card*) → ghw fallback
```

- Supports GTX 6xx+, Tesla K/P/V/A/H (Kepler to Hopper), Quadro, RTX, **AMD Radeon/Instinct/RDNA/CDNA**, **Intel Arc/iGPU**, Apple Silicon via IORegistry, CPU-only.
- VRAM via `mem_info_vram_total`, `lmem_total_bytes` etc., otherwise `0` (Ollama still decides if the model fits).
- No generation check — if the driver exposes the card, PAIR lists it.

**`gpu_darwin.go:21` / `ioreg_parse.go:73`** — inherited: detects any Apple Silicon via `AGXAccelerator` / `Apple*` (M1/M2/M3/M4/M5), `VRAM = systemMemory`. Upstream test uses `Apple M3 Max`.

**`stats_linux.go:153`** — `decodeGPU()` rewritten:

- No longer latches after `nvidia-smi` failure (removes `nvidiaUnavailable` latch).
- DRM sysfs fallback: reads `mem_info_vram_used` / `gpu_busy_percent` for AMD/Intel.
- Enables heterogeneous NVIDIA+AMD+Intel clusters.

**Version bump:** `services/versions.json:8` `nvpair-node-info` `0.13.3` → `0.14.0`, `product` `0.91.7` → `0.91.8-universal`.

### 2. Universal Linux + macOS

- **`scripts/install-universal.sh`** — auto-detects `apt`/`dnf`/`yum`/`zypper`/`pacman`/`apk`, otherwise portable tarball to `/opt/pair`. Supports `--uninstall`.
- **`scripts/build-universal.sh`** — produces Linux `.tar.gz` and `.deb`, an
  `.rpm` when `rpmbuild` or `fpm` is installed, and cross-compiled
  `darwin-arm64`/`darwin-amd64` service bundles.
- **`Makefile`** — `make build-universal` target.
- **README** — comparison table + multi-distro and Apple Silicon instructions.

### 3. Unchanged

- Scheduler/routing: same as upstream (1 request = 1 node, no VRAM pooling).
- Ollama/LM Studio proxies, cluster mTLS, mDNS discovery: same.
- Desktop Electron: unchanged (launches same Go binaries).
- License: Apache-2.0 preserved, SPDX headers added on new files.
- Beta status: same as upstream (see `services/VERSIONING.md:28`).

## Compatibility

| GPU | Status |
|---|---|
| NVIDIA GTX 10xx Pascal (sm_61) | ✅ Tested via nvidia-smi, VRAM OK, Ollama Q4 7B |
| Tesla T4/P100/V100 | ✅ Turing/Pascal/Volta, driver 535+ |
| Tesla K80 Kepler (sm_37) | ⚠️ CUDA 12 drops Kepler — CPU fallback only |
| RTX 20xx+ | ✅ Native |
| AMD RX 6xxx/7xxx, Instinct MIxxx | ✅ Via DRM sysfs + rocm-smi if installed |
| Intel Arc A770, iGPU | ✅ Via DRM sysfs |
| Apple Silicon M1/M2/M3/M4/M5 | ✅ Via IORegistry, unified memory |
| No GPU | ✅ Lists CPU/RAM, routes if Ollama CPU |

| Distro / OS | Install |
|---|---|
| Debian/Ubuntu/Mint | `apt install *.deb` or `install-universal.sh` |
| Fedora/RHEL/Alma/Rocky | `dnf install *.rpm` or tarball |
| openSUSE | `zypper install *.rpm` |
| Arch/Manjaro | `pacman` not native → tarball + `install-universal.sh` |
| NixOS/Alpine/other | portable tarball `/opt/pair` |
| macOS Apple Silicon | `pair-universal-*-darwin-arm64.tar.gz` or build from source |
| macOS Intel | `pair-universal-*-darwin-amd64.tar.gz` |
| Windows 11 | `.exe` same as upstream |

## Build

```bash
# Prerequisites: Go 1.25+, jq, Node 25.5+ (desktop only)
make build-universal        # all (linux tar.gz + deb + rpm)
./services/build.sh         # binaries only in services/build/bin
./scripts/install-universal.sh   # auto-detect install
./services/build/bin/nvpair-tui  # headless TUI (Tesla/servers)
# cross darwin from Linux:
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -o nvpair-node-info ./...
```

## Upstream sync

To rebase on a new NVIDIA tag:

```bash
git remote add upstream https://github.com/NVIDIA/Personal-AI-Router.git
git fetch upstream
git merge upstream/main  # resolve conflicts in gpu_linux.go / stats_linux.go / versions.json
```

## Known limitations (same as upstream, beta)

- No VRAM pooling — a model must fit on one GPU.
- Naïve scheduler (smoothed utilization only).
- Ollama and LM Studio are stable. The Linux vLLM proxy is an experimental
  standalone component; it is not integrated with the desktop or scheduler.
- Beta APIs may change without notice.
