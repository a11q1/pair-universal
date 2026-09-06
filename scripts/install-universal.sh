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
MAN_DIR="${PAIR_MAN_DIR:-/usr/local/share/man/man1}"
BIN_LINK_DIR="${PAIR_BIN_LINK_DIR:-/usr/local/bin}"

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

run_privileged() {
  if [[ "${PAIR_NO_SUDO:-0}" == "1" || "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

install_command_links() {
  if [[ -d "$BIN_LINK_DIR" ]]; then
    run_privileged ln -sfn "$PREFIX/bin/nvpair-tui" "$BIN_LINK_DIR/nvpair"
    run_privileged ln -sfn "$PREFIX/bin/nvpair-ui-broker" "$BIN_LINK_DIR/nvpair-broker"
  fi
}

install_man_page() {
  local source_root="$1"
  local source=""
  if [[ -f "$source_root/share/man/man1/nvpair-tui.1.gz" ]]; then
    source="$source_root/share/man/man1/nvpair-tui.1.gz"
  elif [[ -f "$source_root/share/man/man1/nvpair-tui.1" ]]; then
    source="$source_root/share/man/man1/nvpair-tui.1"
  elif [[ -f "$source_root/docs/nvpair-tui.1" ]]; then
    source="$source_root/docs/nvpair-tui.1"
  else
    warn "This build does not contain the nvpair-tui manual page."
    return 0
  fi

  run_privileged install -d -m 0755 "$MAN_DIR"
  if [[ "$source" == *.gz ]]; then
    run_privileged install -m 0644 "$source" "$MAN_DIR/nvpair-tui.1.gz"
  else
    run_privileged install -m 0644 "$source" "$MAN_DIR/nvpair-tui.1"
    if command -v gzip >/dev/null 2>&1; then
      run_privileged gzip -n -f "$MAN_DIR/nvpair-tui.1"
    fi
  fi
  if command -v mandb >/dev/null 2>&1; then run_privileged mandb -q 2>/dev/null || true; fi
  log "Manual installed — run: man nvpair-tui"
}

remove_owned_link() {
  local path="$1"
  local target="$2"
  if [[ -L "$path" && "$(readlink "$path")" == "$target" ]]; then run_privileged rm -f "$path"; fi
}

install_tarball() {
  local archive="$1"
  local entries top_count
  entries="$(tar -tzf "$archive")" || { err "Cannot read tarball: $archive"; return 1; }
  if printf '%s\n' "$entries" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    err "Refusing unsafe tarball paths."
    return 1
  fi
  top_count="$(printf '%s\n' "$entries" | sed '/^$/d; s#/.*##' | sort -u | wc -l)"
  if [[ "$top_count" -ne 1 ]]; then
    err "Expected one top-level directory in $archive."
    return 1
  fi

  run_privileged install -d -m 0755 "$PREFIX"
  run_privileged tar -xzf "$archive" --strip-components=1 -C "$PREFIX"
  run_privileged chmod 0755 "$PREFIX"/bin/*
  install_command_links
  install_man_page "$PREFIX"
  log "Binaries installed to $PREFIX/bin — run: nvpair or $PREFIX/bin/nvpair-tui"
}

if [[ $UNINSTALL == 1 ]]; then
  log "Uninstalling..."
  if command -v apt >/dev/null 2>&1 && dpkg-query -W -f='${Status}' pair-universal 2>/dev/null | grep -q 'install ok installed'; then sudo apt remove -y pair-universal || true; fi
  if command -v dnf >/dev/null 2>&1 && rpm -q pair-universal >/dev/null 2>&1; then sudo dnf remove -y pair-universal || true; fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q pair-universal >/dev/null 2>&1; then sudo pacman -Rs --noconfirm pair-universal || true; fi
  if command -v zypper >/dev/null 2>&1 && rpm -q pair-universal >/dev/null 2>&1; then sudo zypper remove -y pair-universal || true; fi
  remove_owned_link "$BIN_LINK_DIR/nvpair" "$PREFIX/bin/nvpair-tui"
  remove_owned_link "$BIN_LINK_DIR/nvpair-broker" "$PREFIX/bin/nvpair-ui-broker"
  sudo rm -f "$MAN_DIR/nvpair-tui.1" "$MAN_DIR/nvpair-tui.1.gz"
  if command -v mandb >/dev/null 2>&1; then sudo mandb -q 2>/dev/null || true; fi
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
  install_tarball "$TARBALL"
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
  install_command_links
  install_man_page "$REPO_ROOT"
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

# Resolve VERSION="latest" → actual tag name via GitHub API
if [[ "$VERSION" == "latest" ]]; then
  log "Resolving latest release from GitHub API..."
  if LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases" | jq -r '.[0].tag_name' 2>/dev/null); then
    if [[ -n "$LATEST_TAG" && "$LATEST_TAG" != "null" ]]; then
      VERSION="$LATEST_TAG"
      log "Latest release: $VERSION"
    else
      warn "Could not resolve latest release, falling back to known tag v0.91.8-universal"
      VERSION="v0.91.8-universal"
    fi
  else
    warn "GitHub API unavailable, falling back to known tag v0.91.8-universal"
    VERSION="v0.91.8-universal"
  fi
fi

# Real assets are versioned: pair-universal-0.91.8-universal-linux-amd64.tar.gz
# Try versioned first, then generic for future compat
try_download() {
  local url="$1"
  log "Downloading $url ..."
  $DL "$TMPDIR/pair.tar.gz" "$url" 2>/dev/null
}

URLS=()
# Extract version without leading 'v' for asset name if present
ASSET_VER="${VERSION#v}"
URLS+=("https://github.com/$REPO/releases/download/$VERSION/pair-universal-$ASSET_VER-linux-$ARCH.tar.gz")
URLS+=("https://github.com/$REPO/releases/download/$VERSION/pair-universal-linux-$ARCH.tar.gz")
# Also try without 'v' prefix in tag
if [[ "$VERSION" == v* ]]; then
  URLS+=("https://github.com/$REPO/releases/download/${VERSION#v}/pair-universal-$ASSET_VER-linux-$ARCH.tar.gz")
fi

DL_OK=0
for URL in "${URLS[@]}"; do
  if try_download "$URL"; then DL_OK=1; break; fi
done
if [[ $DL_OK == 1 ]]; then
  install_tarball "$TMPDIR/pair.tar.gz"
else
  err "Download failed. Build from source:"
  err "  git clone https://github.com/$REPO && cd pair-universal && ./scripts/install-universal.sh"
  exit 1
fi
