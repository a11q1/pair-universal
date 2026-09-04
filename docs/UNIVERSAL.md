<!--
SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
SPDX-License-Identifier: Apache-2.0
-->

# PAIR Universal — BÊTA — Notes de fork

> ⚠️ BÊTA — upstream NVIDIA PAIR est en bêta (03/09/2026). Ce fork hérite du statut bêta : APIs/scheduler non stabilisés.

Ce document décrit les modifications du fork **PAIR Universal BÊTA** par rapport à [NVIDIA/Personal-AI-Router](https://github.com/NVIDIA/Personal-AI-Router) `0.91.7` (bêta).

## Objectif

Rendre PAIR utilisable sur **tout GPU** et **tout Linux**, sans allowlist RTX.

## Modifications

### 1. GPU universel — `services/nvpair-node-info/`

**`gpu_linux.go:36`** — `detectGPUs()` réécrit:

```
nvidia-smi (tous: GTX/Tesla/RTX/Quadro) → AMD (amd-smi/rocm-smi + DRM sysfs) → DRM sysfs (/sys/class/drm/card*) → ghw fallback
```

- Supporte GTX 6xx+, Tesla K/P/V/A/H (Kepler à Hopper), Quadro, RTX, **AMD Radeon/Instinct/RDNA/CDNA**, **Intel Arc/iGPU**, CPU-only.
- VRAM via `mem_info_vram_total`, `lmem_total_bytes` etc., sinon `0` (Ollama décide quand même si le modèle tient).
- Aucune vérification de génération — si le driver expose la carte, PAIR la liste.

**`stats_linux.go:153`** — `decodeGPU()` réécrit:

- Ne bloque plus après échec `nvidia-smi` (retire latch `nvidiaUnavailable`).
- Fallback sysfs DRM: lit `mem_info_vram_used` / `gpu_busy_percent` pour AMD/Intel.
- Permet clusters hétérogènes NVIDIA+AMD+Intel.

**Version bump:** `services/versions.json:8` `nvpair-node-info` `0.13.3` → `0.14.0`, `product` `0.91.7` → `0.91.8-universal`.

### 2. Linux universel

- **`scripts/install-universal.sh`** — installateur auto-détecte `apt`/`dnf`/`yum`/`zypper`/`pacman`/`apk`, sinon tarball portable dans `/opt/pair`. Supporte `--uninstall`.
- **`scripts/build-universal.sh`** — produit en une commande `dist/pair-universal-*.tar.gz` + `*.deb` + `*.rpm` (si `fpm`/`rpmbuild`).
- **`Makefile`** — target `make build-universal`.
- **README** — tableau comparatif + instructions multi-distro.

### 3. Non modifié

- Scheduler/routing: identique upstream (1 requête = 1 node, pas de pooling VRAM).
- Proxies Ollama/LM Studio, cluster mTLS, discovery mDNS: identiques.
- Desktop Electron: inchangé (lance les mêmes Go binaries).
- Licence: Apache-2.0 conservée, headers SPDX ajoutés sur nouveaux fichiers.

## Compatibilité

| GPU | Statut |
|---|---|
| NVIDIA GTX 10xx Pascal (sm_61) | ✅ Testé via nvidia-smi, VRAM OK, Ollama Q4 7B |
| Tesla T4/P100/V100 | ✅ Turing/Pascal/Volta, driver 535+ |
| Tesla K80 Kepler (sm_37) | ⚠️ CUDA 12 drop Kepler — CPU fallback seulement |
| RTX 20xx+ | ✅ Natif |
| AMD RX 6xxx/7xxx, Instinct MIxxx | ✅ Via DRM sysfs + rocm-smi si installé |
| Intel Arc A770, iGPU | ✅ Via DRM sysfs |
| Sans GPU | ✅ Node liste CPU/RAM, routage si Ollama CPU |

| Distro | Install |
|---|---|
| Debian/Ubuntu/Mint | `apt install *.deb` ou `install-universal.sh` |
| Fedora/RHEL/Alma/Rocky | `dnf install *.rpm` ou tarball |
| openSUSE | `zypper install *.rpm` |
| Arch/Manjaro | `pacman` non natif → tarball + `install-universal.sh` |
| NixOS/Alpine/Autre | tarball portable `/opt/pair` |

## Build

```bash
# Prérequis: Go 1.25+, jq, Node 25.5+ (desktop seulement)
make build-universal        # tout
./services/build.sh         # binaires seuls dans services/build/bin
./scripts/install-universal.sh   # install local auto-détect
./services/build/bin/nvpair-tui  # TUI headless (Tesla/serveurs)
```

## Upstream sync

Pour rebase sur nouveau tag NVIDIA:

```bash
git remote add upstream https://github.com/NVIDIA/Personal-AI-Router.git
git fetch upstream
git merge upstream/main  # résoudre conflits gpu_linux.go / stats_linux.go / versions.json
```

## Limites connues (identiques upstream)

- Pas de pooling VRAM — un modèle doit tenir sur 1 GPU.
- Scheduler naïf (utilization lissée seulement).
- Ollama/LM Studio seuls (vLLM à venir).

