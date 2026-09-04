<!--
SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
SPDX-License-Identifier: Apache-2.0
-->

# PAIR Universal — Hardware Test Matrix (BETA)

Use this matrix to validate **all-GPU + all-Linux/macOS** claims. Each row is a node that joins the same PAIR cluster via PIN (`Settings → Cluster`). Report results via the `Universal GPU Report` issue template.

## Matrix

| # | Node | GPU | Arch / Compute | Driver | VRAM expected (`gpu_linux.go:36` / `ioreg_parse.go:81`) | Test model (fits VRAM) | Scenario | Success criteria | Log to attach |
|---|---|---|---|---|---|---|---:|---|
| 1 | Linux x64 | GTX 1080 8GB | Pascal sm_61 | CUDA 535+ / 550 | `nvidia-smi` → 8192 MiB | `qwen2.5:7b-instruct-q4_K_M` ~5GB | Solo: 10 sequential `curl :11434/v1/chat/completions` | `ollama ps` shows loaded, tok/s >10, no OOM | `nvidia-smi`, `nvpair-node-info` stdout |
| 2 | Linux x64 | Tesla T4 16GB | Turing sm_75 | CUDA 535+ | 15360 MiB | `qwen3:8b` / `qwen3:14b-q4` | Cluster with #1: 20 parallel req via PAIR proxy `:11434` | Jobs split across 2 nodes in `Jobs` UI, ~1.5x throughput vs solo, no fallback to CPU | `NVPAIR_LOG_LEVEL=debug` broker |
| 3 | Linux x64 | Tesla K80 12GB | Kepler sm_37 | 470 | CPU fallback (CUDA 12 drops Kepler) | `llama3.2:3b-instruct-q4` | Check listed but not eligible if driver missing | Graceful `engine not ready` in UI, no crash | `ollama` log |
| 4 | Linux x64 | AMD RX 7600 8GB | RDNA3 | ROCm 6.2 + `amd-smi` | DRM `mem_info_vram_total` 8192 MiB (`stats_linux.go:153`) | `mistral:7b-instruct-q4` via Ollama ROCm | `amd-smi` vs DRM fallback | `ghw` name + DRM VRAM matches, `gpu_busy_percent` >0 under load | `rocm-smi --showmeminfo vram`, `/sys/class/drm/card0/device/mem_info_*` |
| 5 | Linux x64 | Intel Arc A750 8GB | Xe-HPG | i915/xe + `intel_gpu_top` | DRM `lmem_total_bytes` 8192 MiB | `phi3:mini-q4` Vulkan | Intel `gpu_busy_percent` | Listed, VRAM >0, busy% appears when generating | `/sys/class/drm/card*/device/lmem_*`, `intel_gpu_top -o -` |
| 6 | macOS arm64 | Apple M1 8GB | M1 | Metal | IOReg `systemMemory` 8192 MiB (`ioreg_parse.go:81`) | `qwen2.5:3b-instruct` 2GB | Solo M1, no discrete GPU | `Apple M1` in node info, unified VRAM = RAM, tok/s via Metal | `ioreg -a -c IOAccelerator` plist snippet |
| 7 | macOS arm64 | Apple M4 16GB | M4 | Metal | 16384 MiB | `qwen2.5:7b-instruct-q4` 5GB | Reference upstream (should match NVIDIA M4) | Same as #6, faster tok/s, baseline for M1 comparison | Same |
| 8 | Any | No GPU | — | — | `ghw` fallback, Vram 0 | `tinyllama:1.1b` CPU | PAIR without GPU | CPU/RAM only in node info, routes if Ollama CPU, `gpus: []` not error | `lspci` or `system_profiler SPDisplaysDataType` |

## Procedure per node

```bash
# 1. Build/check (any Linux/macOS)
git clone https://github.com/a11q1/pair-universal && cd pair-universal
./services/build.sh && ./services/build/bin/nvpair-node-info --version  # expect 0.14.0
./services/build/bin/nvpair-node-info 2>&1 | head -20  # check GPU name/VRAM

# 2. Start PAIR
./services/build/bin/nvpair-tui  # or desktop: cd desktop && npm install && npm start
# or portable: tar xf pair-universal-*-*.tar.gz && ./pair-universal-*/bin/nvpair-tui

# 3. Engine
# In PAIR UI: Engine settings → Install Ollama (or use existing ollama)
ollama pull qwen2.5:7b-instruct-q4_K_M
ollama run qwen2.5:7b-instruct-q4_K_M "Hello"  # sanity: model fits VRAM

# 4. Solo test
curl http://127.0.0.1:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:7b-instruct-q4_K_M","messages":[{"role":"user","content":"In one sentence, what does a router do?"}]}'

# 5. Cluster (2+ nodes same LAN, UDP 5353 open)
# Node A: Settings → Cluster → Invite → show 6-digit PIN
# Node B: Settings → Cluster → Join → enter PIN
# Check Overview shows 2 nodes, each with GPU/RAM

# 6. Parallel routing test
for i in $(seq 1 20); do
  curl -s http://127.0.0.1:11434/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5:7b-instruct-q4_K_M","messages":[{"role":"user","content":"Write a haiku about GPUs"}]}' &
done; wait
# Check Jobs tab: jobs spread across nodes, no single GPU bottleneck

# 7. Collect logs
./scripts/collect-logs.sh  # or NVPAIR_LOG_LEVEL=debug ./services/build/bin/nvpair-ui-broker 2> broker.log
```

## Reporting

Open an issue → **Universal GPU Report** template. Attach:
- `nvidia-smi` / `amd-smi` / `rocm-smi --showmeminfo` / `ioreg -a -c IOAccelerator` snippet
- `/sys/class/drm/card*/device/mem_info_vram_total` or `lmem_total_bytes` if Linux
- `nvpair-node-info` detection line (e.g. `INFO detected 1 GPU(s): AMD Radeon ... 8192 MiB`)
- PAIR `Jobs` screenshot + `ollama ps` + tok/s
- Pass/fail per row

## CI (local simulation when no hardware)

```bash
make test  # desktop unit + go test in every services module
go test ./...  # in services/nvpair-node-info includes gpu_linux_test, gpu_darwin_test
# Simulate 2 nodes on one host (different config dirs, manual peer):
NVPAIR_CONFIG_DIR=/tmp/pair-a ./services/build/bin/nvpair-ui-broker --cluster-dir /tmp/pair-a &
NVPAIR_CONFIG_DIR=/tmp/pair-b ./services/build/bin/nvpair-ui-broker --cluster-dir /tmp/pair-b &
# then add manual node 127.0.0.1:<port> in Cluster settings
```

## Known beta limits

- No VRAM pooling — model must fit on one GPU (`README.md:29`).
- Scheduler is smoothed utilization only — heterogeneous VRAM (4GB vs 24GB) not weighted.
- Beta APIs may break — pin to tag `v0.91.8-universal`.
