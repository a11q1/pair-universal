// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

//go:build linux

package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/jaypipes/ghw"
)

// nvidiaSmiTimeout caps how long we wait for a single nvidia-smi invocation.
// The tool is normally well under 100 ms, but on a wedged driver it can hang;
// a hard ceiling keeps both the one-shot startup detect and the per-tick stats
// collector from blocking indefinitely.
const nvidiaSmiTimeout = 3 * time.Second

// detectGPUs enumerates GPUs on Linux — UNIVERSAL EDITION (fork PAIR-Universal).
// Tries in order: nvidia-smi (NVIDIA: GTX/RTX/Tesla/Quadro, all generations) →
// AMD (rocm-smi/amd-smi + sysfs DRM) → Intel (sysfs DRM) → generic ghw fallback.
// This makes PAIR work on GTX, Tesla, AMD Radeon/Instinct, Intel Arc/iGPU,
// and any future accelerator that exposes a DRM card. No RTX allowlist.
// On unified-memory architectures (UMA, e.g. Grace-Blackwell / DGX Spark)
// nvidia-smi reports [N/A] for memory.total because the GPU shares system
// DRAM; in that case VramBytes is filled from detectMemoryTotal() instead.
func detectGPUs() []GPUInfo {
	if out, err := nvidiaSmiCSV("uuid,name,memory.total"); err == nil {
		if gpus, uma := parseNvidiaStatic(out); len(gpus) > 0 {
			if uma {
				if total := detectMemoryTotal(); total > 0 {
					for i := range gpus {
						if gpus[i].usesSystemMemoryUsage {
							gpus[i].VramBytes = total
						}
					}
				}
			}
			return gpus
		}
	}
	// AMD GPUs: try rocm-smi / amd-smi, then sysfs DRM
	if gpus := detectGPUsAMD(); len(gpus) > 0 {
		return gpus
	}
	// Intel + generic DRM: sysfs enumeration gives VRAM for all vendors
	if gpus := detectGPUsDRM(); len(gpus) > 0 {
		return gpus
	}
	return detectGPUsGHW()
}

// detectGPUsGHW is the ghw-based fallback, identical in spirit to the
// non-Windows/non-Linux path in gpu_other.go: enumerate display adapters and
// return names only (VramBytes stays 0, statsKey stays empty).
func detectGPUsGHW() []GPUInfo {
	gpu, err := ghw.GPU()
	if err != nil {
		log.Printf("GPU detection error: %v", err)
		return nil
	}
	var gpus []GPUInfo
	for _, card := range gpu.GraphicsCards {
		name := "Unknown"
		if card.DeviceInfo != nil && card.DeviceInfo.Product != nil {
			name = card.DeviceInfo.Product.Name
		}
		gpus = append(gpus, GPUInfo{Name: name})
	}
	return gpus
}

// detectGPUsAMD tries AMD-specific tools then falls back to DRM sysfs for AMD cards.
// Handles both `rocm-smi` (ROCm 5) and `amd-smi` (ROCm 6+), then sysfs.
func detectGPUsAMD() []GPUInfo {
	for _, bin := range []string{"amd-smi", "rocm-smi"} {
		if out, err := runCSV(bin, "--showproductname", "--csv"); err == nil && strings.TrimSpace(out) != "" {
			if gpus := parseAmdSmi(out, bin); len(gpus) > 0 {
				return gpus
			}
		}
		if out, err := exec.Command(bin, "--showmeminfo", "vram", "--csv").Output(); err == nil {
			_ = out // probed availability, actual VRAM comes from DRM sysfs
		}
	}
	// If no amd-smi, try to find AMD cards via DRM sysfs vendor check
	if gpus := detectGPUsDRMFiltered("0x1002"); len(gpus) > 0 {
		return gpus
	}
	return nil
}

func parseAmdSmi(out string, bin string) []GPUInfo {
	var gpus []GPUInfo
	lines := strings.Split(out, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(strings.ToLower(line), "gpu") || strings.HasPrefix(line, "card") {
			continue
		}
		// amd-smi csv: GPU, Card series, etc. — take raw line as name if not empty
		if line != "" {
			name := strings.Trim(line, ", ")
			if name != "" && name != "N/A" {
				vram := vramFromDRMByName(name)
				gpus = append(gpus, GPUInfo{Name: "AMD " + name, VramBytes: vram, statsKey: bin + ":" + name})
			}
		}
	}
	return gpus
}

// detectGPUsDRM enumerates /sys/class/drm/card* and extracts name+VRAM for any vendor.
func detectGPUsDRM() []GPUInfo {
	cards, _ := filepath.Glob("/sys/class/drm/card[0-9]*/device/vendor")
	if len(cards) == 0 {
		return nil
	}
	var gpus []GPUInfo
	for _, vendorPath := range cards {
		dir := filepath.Dir(vendorPath)
		name := drmCardName(dir)
		vram := drmCardVram(dir)
		if name == "" {
			name = "GPU " + filepath.Base(filepath.Dir(dir))
		}
		gpus = append(gpus, GPUInfo{Name: name, VramBytes: vram, statsKey: dir})
	}
	if len(gpus) > 0 {
		return gpus
	}
	return nil
}

// detectGPUsDRMFiltered returns only cards matching given PCI vendor ID (e.g. 0x1002 for AMD, 0x8086 Intel)
func detectGPUsDRMFiltered(vendorID string) []GPUInfo {
	cards, _ := filepath.Glob("/sys/class/drm/card[0-9]*/device/vendor")
	var gpus []GPUInfo
	for _, vendorPath := range cards {
		b, err := os.ReadFile(vendorPath)
		if err != nil {
			continue
		}
		if strings.TrimSpace(string(b)) != vendorID && strings.TrimSpace(strings.ToLower(string(b))) != strings.ToLower(vendorID) {
			continue
		}
		dir := filepath.Dir(vendorPath)
		name := drmCardName(dir)
		vram := drmCardVram(dir)
		gpus = append(gpus, GPUInfo{Name: name, VramBytes: vram, statsKey: dir})
	}
	return gpus
}

func drmCardName(dir string) string {
	// Try uevent product name, then ghw as fallback
	if b, err := os.ReadFile(filepath.Join(dir, "uevent")); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "PCI_SLOT_NAME=") {
				continue
			}
			// Some drivers expose PRODUCT
		}
	}
	// Try device name via lspci-style: read `device` symlink product
	if b, err := os.ReadFile(filepath.Join(dir, "product")); err == nil {
		if n := strings.TrimSpace(string(b)); n != "" {
			return n
		}
	}
	// Fallback: use ghw name for this card index
	if gpu, err := ghw.GPU(); err == nil {
		idx := drmCardIndex(dir)
		if idx >= 0 && idx < len(gpu.GraphicsCards) {
			if gpu.GraphicsCards[idx].DeviceInfo != nil && gpu.GraphicsCards[idx].DeviceInfo.Product != nil {
				return gpu.GraphicsCards[idx].DeviceInfo.Product.Name
			}
		}
	}
	return "GPU"
}

func drmCardIndex(dir string) int {
	base := filepath.Base(filepath.Dir(dir)) // card0, card1
	var idx int
	if _, err := fmt.Sscanf(base, "card%d", &idx); err == nil {
		return idx
	}
	return -1
}

func drmCardVram(dir string) uint64 {
	// AMD: /sys/class/drm/card*/device/mem_info_vram_total (bytes)
	if b, err := os.ReadFile(filepath.Join(dir, "mem_info_vram_total")); err == nil {
		if v, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil && v > 0 {
			return v
		}
	}
	// Intel discrete (Arc): mem_info_vram_total or lmem_total etc.
	if b, err := os.ReadFile(filepath.Join(dir, "lmem_total_bytes")); err == nil {
		if v, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil && v > 0 {
			return v
		}
	}
	// Generic: try `mem_info_*` or `local_memory`
	for _, f := range []string{"mem_info_vis_vram_total", "local_memory_total", "vram_total"} {
		if b, err := os.ReadFile(filepath.Join(dir, f)); err == nil {
			if v, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil && v > 0 {
				return v
			}
		}
	}
	return 0
}

func vramFromDRMByName(name string) uint64 {
	cards, _ := filepath.Glob("/sys/class/drm/card[0-9]*/device/vendor")
	for _, vp := range cards {
		dir := filepath.Dir(vp)
		if drmCardName(dir) == name || strings.Contains(name, drmCardName(dir)) {
			if v := drmCardVram(dir); v > 0 {
				return v
			}
		}
	}
	return 0
}

func runCSV(bin string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, args...).Output()
	return string(out), err
}

// nvidiaSmiCSV runs `nvidia-smi --query-gpu=<fields> --format=csv,noheader,nounits`
// and returns raw stdout. The caller parses the comma-separated rows. A missing
// binary (not on PATH) surfaces as an exec error, which callers treat as "no
// NVIDIA GPU data available" and degrade silently.
func nvidiaSmiCSV(fields string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), nvidiaSmiTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "nvidia-smi",
		"--query-gpu="+fields,
		"--format=csv,noheader,nounits").Output()
	return string(out), err
}

// isNvidiaSmiNA reports whether an nvidia-smi CSV field is a "not
// applicable" sentinel rather than a numeric value. UMA platforms such as
// DGX Spark return [N/A] or [Not Supported] for GPU memory queries.
func isNvidiaSmiNA(s string) bool {
	s = strings.TrimSpace(s)
	s = strings.Trim(s, "[]")
	switch strings.ToLower(s) {
	case "n/a", "not supported":
		return true
	default:
		return false
	}
}

// parseNvidiaStatic decodes the static query (uuid,name,memory.total) into
// GPUInfo records. memory.total is reported in MiB (because of -nounits); we
// convert to bytes. Rows missing a uuid or name, or with an unparseable VRAM
// figure, are skipped rather than emitted with placeholder values. Each
// unified-memory row is marked so response assembly can source its used bytes
// from system memory without depending on dynamic nvidia-smi collection. The
// second return value reports whether any row was unified, allowing the caller
// to fetch the shared system-memory total only when needed.
func parseNvidiaStatic(out string) ([]GPUInfo, bool) {
	var gpus []GPUInfo
	var unifiedMemory bool
	for _, line := range strings.Split(out, "\n") {
		fields := splitCSVRow(line)
		if len(fields) < 3 {
			continue
		}
		uuid, name := fields[0], fields[1]
		if uuid == "" || name == "" {
			continue
		}
		var vramBytes uint64
		usesUnifiedMemory := isNvidiaSmiNA(fields[2])
		if usesUnifiedMemory {
			unifiedMemory = true
		} else if mib, err := strconv.ParseUint(fields[2], 10, 64); err == nil {
			vramBytes = mib * 1024 * 1024
		}
		gpus = append(gpus, GPUInfo{
			Name:                  name,
			VramBytes:             vramBytes,
			statsKey:              uuid,
			usesSystemMemoryUsage: usesUnifiedMemory,
		})
	}
	return gpus, unifiedMemory
}

// splitCSVRow splits one nvidia-smi CSV row on commas and trims surrounding
// whitespace from each field (the tool emits ", " separators). Returns nil for
// a blank line so callers can skip it.
func splitCSVRow(line string) []string {
	line = strings.TrimSpace(line)
	if line == "" {
		return nil
	}
	parts := strings.Split(line, ",")
	for i := range parts {
		parts[i] = strings.TrimSpace(parts[i])
	}
	return parts
}
