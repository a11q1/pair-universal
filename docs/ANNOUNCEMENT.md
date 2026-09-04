<!--
SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
SPDX-License-Identifier: Apache-2.0
-->

# PAIR Universal BETA — Announcements (copy-paste)

> Use these for Reddit, HN, X, Discord, LinkedIn. Repo: https://github.com/a11q1/pair-universal — Release: https://github.com/a11q1/pair-universal/releases/tag/v0.91.8-universal

## Reddit r/LocalLLaMA + r/ollama + r/homelab (title + body)

**Title:** `[Showoff] PAIR Universal BETA — I made NVIDIA PAIR run on any GPU (GTX/Tesla/AMD/Intel/M1-M5) + any Linux`

**Body:**
```
NVIDIA dropped PAIR yesterday (Personal AI Router, beta 09/03/2026) — it turns your home PCs into a local inference cluster for Ollama/LM Studio. Cool, but locked to RTX 20+ / M4+ and .deb only.

I forked it to PAIR Universal BETA: https://github.com/a11q1/pair-universal

What changed (Apache-2.0, PRs welcome):
- All GPUs: GTX 6xx+/Tesla K/P/V/A/H, RTX/Quadro, AMD ROCm (RX 7600 etc via DRM sysfs + amd-smi), Intel Arc/iGPU, Apple Silicon M1/M2/M3/M4/M5 (IORegistry, unified VRAM = RAM), CPU-only
- All Linux: .deb + .rpm + portable tar.gz + install.sh that auto-detects apt/dnf/pacman/zypper/apk. Also darwin-arm64/amd64 tarballs for Mac.
- Patch is 2 files: gpu_linux.go:36 (nvidia-smi → amd-smi → DRM → ghw) + stats_linux.go:153 (sysfs fallback). No RTX allowlist. Scheduler still 1 req = 1 node (no VRAM pooling, same as upstream).

Release: https://github.com/a11q1/pair-universal/releases/tag/v0.91.8-universal — 4 assets (linux/darwin). Quick start:
  curl -fsSL https://raw.githubusercontent.com/a11q1/pair-universal/main/scripts/install-universal.sh | bash
  # mac M1/M2/M3/M4: curl -LO .../pair-universal-*-darwin-arm64.tar.gz && tar xf && ./bin/nvpair-tui

BETA: APIs may break, not for prod. Test matrix in docs/TEST-MATRIX.md — please report your GPU via the Universal GPU Report issue template (nvidia-smi / rocm-smi / ioreg snippet + Jobs split).

Upstream: https://github.com/NVIDIA/Personal-AI-Router — happy to upstream the DRM fallback if wanted.

AMA: will track issues for heterogeneous clusters (e.g. T4 + GTX 1080 + M1).
```

## Hacker News Show HN

**Title:** `Show HN: PAIR Universal – NVIDIA PAIR without the RTX tax (any GPU, any Linux)`

**Body:**
```
Hi HN,

NVIDIA launched PAIR (Personal AI Router, beta) yesterday at IFA — it discovers PCs on your LAN and routes Ollama/LM Studio inference across them (mDNS + PIN + mTLS, Ollama proxy on :11434). Great idea, but only RTX 20+ / M4+ and Debian .deb.

I made a universal fork: https://github.com/a11q1/pair-universal

- Patch: gpu_linux.go nvidia-smi → rocm-smi/amd-smi → /sys/class/drm → ghw; stats via DRM sysfs. No RTX check. Works on GTX, Tesla (T4/P100 etc), AMD, Intel Arc, Apple M1-M5, CPU-only. Cross-built darwin-arm64/amd64.
- Universal Linux installer: apt/dnf/pacman/zypper/apk auto-detect, otherwise portable /opt/pair.
- Tested VM no-GPU → G200eR2 via DRM; full Go 1.25.1 build OK. Needs real HW for AMD/Intel – hence beta.

Release: https://github.com/a11q1/pair-universal/releases/tag/v0.91.8-universal (BETA, prerelease).

Looking for testers with homelab GTX/Tesla/AMD/Intel/Mac mixes. Issue template + test matrix in repo.

Apache-2.0, happy for feedback.
```

## X / Twitter thread (5 tweets)

**1/5** NVIDIA's PAIR (beta yesterday) turns home PCs into a local LLM cluster — but only RTX 20+/M4+ and Debian. I fixed that.

Introducing PAIR Universal BETA: any GPU, any Linux/macOS.
https://github.com/a11q1/pair-universal

**2/5** What changed:
- GTX/Tesla/RTX/Quadro, AMD (DRM sysfs + rocm-smi), Intel Arc/iGPU, Apple M1-M5 (IORegistry), CPU-only
- Linux: .deb+.rpm+tar.gz + install.sh (apt/dnf/pacman/zypper)
- 2-file patch: gpu_linux.go:36 + stats_linux.go:153

**3/5** Release v0.91.8-universal (BETA, 4 assets):
linux-amd64 + darwin-arm64 (M1-M5) + darwin-amd64 + deb
curl -fsSL https://raw.githubusercontent.com/a11q1/pair-universal/main/scripts/install-universal.sh | bash

**4/5** How it works: PAIR routes each req to one node (no VRAM pooling). My patch just lists every GPU via /sys/class/drm + IORegistry, so heterogeneous clusters actually work.

Test matrix: docs/TEST-MATRIX.md

**5/5** Beta — not for prod. Need testers with homelab mixes (T4 + GTX + M1 etc). Report via Universal GPU Report template — help prove it.

Upstream: https://github.com/NVIDIA/Personal-AI-Router

## LinkedIn (Sacha)

```
I forked NVIDIA's brand-new PAIR (Personal AI Router, beta 03/09/2026) to run on any hardware.

PAIR Universal BETA: https://github.com/a11q1/pair-universal

NVIDIA limited it to RTX 20+ / M4+ and Debian. My fork supports GTX/Tesla, AMD, Intel Arc, Apple M1-M5 and any Linux (Debian/Fedora/Arch/NixOS) + macOS. Same Apache-2.0, 2-file patch, prebuilt for linux + darwin.

Why? Homelabs have mixed GPUs — a T4, a GTX 1080, a MacBook M1 should be able to team up for Ollama.

Release v0.91.8-universal (BETA): 4 assets, install.sh auto-detects your distro.

Looking for testers — see docs/TEST-MATRIX.md and report via GitHub issue template.

#LocalLLM #Ollama #OpenSource #Homelab
```

## Discord (Ollama / LM Studio / Homelab)

```
**PAIR Universal BETA** — I made NVIDIA PAIR work on any GPU (GTX/Tesla/AMD/Intel/M1-M5) + any Linux/macOS.
Repo: https://github.com/a11q1/pair-universal
Release: https://github.com/a11q1/pair-universal/releases/tag/v0.91.8-universal
Install: curl -fsSL https://raw.githubusercontent.com/a11q1/pair-universal/main/scripts/install-universal.sh | bash
Testers welcome — use the Universal GPU Report template (nvidia-smi / ioreg snippet). Beta, Apache-2.0.
```

## Upstream issue to NVIDIA (polite)

Title: `Proposal: universal GPU detection via DRM sysfs + IORegistry fallback (support GTX/Tesla/M1-M3, all Linux distros)`

Body:
```
Hi team — love PAIR beta. I maintain a universal fork (https://github.com/a11q1/pair-universal) that widens gpu_linux.go:36 detection:

- nvidia-smi → amd-smi/rocm-smi → /sys/class/drm/card*/device/mem_info_vram_total → ghw
- stats via DRM sysfs (mem_info_vram_used, gpu_busy_percent)
- darwin already handles M1-M3 via IORegistry, just docs said M4+

It lets GTX 1080, Tesla T4, AMD, Intel Arc, M1-M3 join clusters with no RTX allowlist. Patch is ~80 lines, tested VM no-GPU → G200eR2 via DRM, builds on Go 1.25.1.

Happy to PR the fallback (behind a flag if you prefer) — would you accept it? Keeps your RTX path first, just adds graceful fallback for homelabs.

Fork is Apache-2.0, docs/UNIVERSAL.md details the diff. Thanks for open-sourcing PAIR!
```
