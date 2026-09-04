#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
# SPDX-License-Identifier: Apache-2.0
# install-universal.sh — PAIR Universal: universal Linux installer
# Auto-detects apt/dnf/pacman/zypper/apk, otherwise portable tarball.
# Usage:
#   ./scripts/install-universal.sh [--uninstall] [--prefix /opt/pair] [--tarball path.tar.gz]
#   curl -fsSL https://raw.githubusercontent.com/a11q1/pair-universal/main/scripts/install-universal.sh | bash

set -euo pipefail

PREFIX="/opt/pair"
TARBALL=""
UNINSTALL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) UNINSTALL=1; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --help|-h) echo "Usage: $0 [--uninstall] [--prefix DIR] [--tarball FILE]"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { printf "\033[1;34m[pair-universal]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*"; }

if [[ $UNINSTALL == 1 ]]; then
  log "Uninstalling..."
  if command -v apt >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -q nvpair; then sudo apt remove -y nvpair || true; sudo apt purge -y nvpair || true; fi
  if command -v dnf >/dev/null 2>&1 && rpm -qa 2>/dev/null | grep -q nvpair; then sudo dnf remove -y nvpair || true; fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q nvpair 2>/dev/null | grep -q nvpair; then sudo pacman -Rs --noconfirm nvpair || true; fi
  if command -v zypper >/dev/null 2>&1 && rpm -qa 2>/dev/null | grep -q nvpair; then sudo zypper remove -y nvpair || true; fi
  if [[ -d "$PREFIX" ]]; then sudo rm -rf "$PREFIX"; log "Removed $PREFIX"; fi
  rm -rf ~/.config/"Nvidia Corporation"/"Personal AI Router" 2>/dev/null || true
  log "Uninstall complete. Ollama models kept in ~/.ollama"
  exit 0
fi

log "PAIR Universal — universal Linux installer"
log "Detecting distro..."

detect_pkg() {
  if command -v apt >/dev/null 2>&1; then echo "deb"; elif command -v dnf >/dev/null 2>&1; then echo "rpm-dnf"; elif command -v yum >/dev/null 2>&1; then echo "rpm-yum"; elif command -v zypper >/dev/null 2>&1; then echo "rpm-zypper"; elif command -v pacman >/dev/null 2>&1; then echo "arch"; elif command -v apk >/dev/null 2>&1; then echo "apk"; else echo "tarball"; fi
}

PKG=$(detect_pkg)
log "Package manager: $PKG"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; *) warn "Arch $ARCH not tested, trying amd64"; ARCH="amd64";; esac

# If tarball explicitly provided
if [[ -n "$TARBALL" && -f "$TARBALL" ]]; then
  log "Installing from tarball: $TARBALL"
  sudo mkdir -p "$PREFIX"
  sudo tar -xzf "$TARBALL" --strip-components=1 -C "$PREFIX" 2>/dev/null || sudo tar -xzf "$TARBALL" -C /tmp && sudo cp -a /tmp/NVIDIA-Personal-AI-Router-*/. "$PREFIX"/ 2>/dev/null || true
  sudo chmod +x "$PREFIX"/bin/* 2>/dev/null || true
  log "Binaries installed to $PREFIX/bin — run with $PREFIX/bin/nvpair-tui or $PREFIX/bin/nvpair-ui-broker"
  exit 0
fi

# Look for local artifact
find_artifact() {
  local pat="$1"; for p in "$REPO_ROOT"/services/dist/*.tar.gz "$REPO_ROOT"/dist/*.tar.gz ./pair-universal*.tar.gz /tmp/*.tar.gz; do [[ -f $p ]] && echo "$p" && return 0; done; return 1
}

# If inside cloned repo: build then install
if [[ -f "$REPO_ROOT/services/build.sh" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    err "Go not found. Install Go 1.25+ (https://go.dev/dl/) then retry."
    err "Or download a prebuilt release from GitHub Releases."
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if [[ "$PKG" == "deb" ]]; then sudo apt update && sudo apt install -y jq
    elif [[ "$PKG" == "rpm-dnf" ]]; then sudo dnf install -y jq
    elif [[ "$PKG" == "rpm-yum" ]]; then sudo yum install -y jq
    elif [[ "$PKG" == "rpm-zypper" ]]; then sudo zypper install -y jq
    elif [[ "$PKG" == "arch" ]]; then sudo pacman -Sy --noconfirm jq
    elif [[ "$PKG" == "apk" ]]; then sudo apk add jq
    fi
  fi
  log "Building from source (./services/build.sh)..."
  (cd "$REPO_ROOT/services" && ./build.sh)
  log "Build OK. Installing portable to $PREFIX..."
  sudo mkdir -p "$PREFIX/bin"
  sudo cp -a "$REPO_ROOT/services/build/bin/"* "$PREFIX/bin/"
  sudo chmod +x "$PREFIX/bin/"*
  # Add TUI to PATH if possible
  if [[ -d /usr/local/bin ]]; then sudo ln -sf "$PREFIX/bin/nvpair-tui" /usr/local/bin/nvpair 2>/dev/null || true; fi
  log "✅ Installed. Run: nvpair  or  $PREFIX/bin/nvpair-tui"
  log "   Desktop: cd $REPO_ROOT/desktop && npm install && npm start  (requires Node 25.5+)"
  exit 0
fi

# Otherwise: download release
REPO="${PAIR_UNIVERSAL_REPO:-a11q1/pair-universal}"
VERSION="${PAIR_VERSION:-latest}"
log "No local build — trying release download $REPO@$VERSION ..."
if command -v curl >/dev/null 2>&1; then DL="curl -fsSL -o"; elif command -v wget >/dev/null 2>&1; then DL="wget -qO"; else err "curl or wget required"; exit 1; fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Real assets are versioned: pair-universal-0.91.8-universal-linux-amd64.tar.gz
# Try versioned first, then generic for future compat
try_download() {
  local url="$1"
  log "Downloading $url ..."
  $DL "$TMPDIR/pair.tar.gz" "$url" 2>/dev/null
}

URLS=()
if [[ "$VERSION" == "latest" ]]; then
  URLS+=("https://github.com/$REPO/releases/latest/download/pair-universal-0.91.8-universal-linux-$ARCH.tar.gz")
  URLS+=("https://github.com/$REPO/releases/latest/download/pair-universal-linux-$ARCH.tar.gz")
else
  URLS+=("https://github.com/$REPO/releases/download/$VERSION/pair-universal-$VERSION-linux-$ARCH.tar.gz")
  URLS+=("https://github.com/$REPO/releases/download/$VERSION/pair-universal-linux-$ARCH.tar.gz")
fi

DL_OK=0
for URL in "${URLS[@]}"; do
  if try_download "$URL"; then DL_OK=1; break; fi
done
if [[ $DL_OK == 1 ]]; then
  sudo mkdir -p "$PREFIX"
  sudo tar -xzf "$TMPDIR/pair.tar.gz" --strip-components=1 -C "$PREFIX" 2>/dev/null || { sudo tar -xzf "$TMPDIR/pair.tar.gz" -C "$TMPDIR" && sudo mkdir -p "$PREFIX/bin" && sudo cp -a "$TMPDIR"/*/bin/* "$PREFIX/bin/" 2>/dev/null || sudo cp -a "$TMPDIR"/bin/* "$PREFIX/bin/" 2>/dev/null; }
  sudo chmod +x "$PREFIX/bin/"* 2>/dev/null || true
  log "✅ Installed to $PREFIX — run: $PREFIX/bin/nvpair-tui"
else
  err "Download failed. Build from source:"
  err "  git clone https://github.com/$REPO && cd pair-universal && ./scripts/install-universal.sh"
  exit 1
fi
