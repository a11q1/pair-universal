#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
# SPDX-License-Identifier: Apache-2.0
# install-universal.sh — PAIR Universal: installateur Linux universel
# Détecte apt/dnf/pacman/zypper/apk, sinon tarball portable.
# Usage:
#   ./scripts/install-universal.sh [--uninstall] [--prefix /opt/pair] [--tarball path.tar.gz]
#   curl -fsSL https://raw.githubusercontent.com/<org>/pair-universal/main/scripts/install-universal.sh | bash

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
    *) echo "Arg inconnu: $1" >&2; exit 1 ;;
  esac
done

log() { printf "\033[1;34m[pair-universal]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[err]\033[0m %s\n" "$*"; }

if [[ $UNINSTALL == 1 ]]; then
  log "Désinstallation..."
  if command -v apt >/dev/null 2>&1 && dpkg -l 2>/dev/null | grep -q nvpair; then sudo apt remove -y nvpair || true; sudo apt purge -y nvpair || true; fi
  if command -v dnf >/dev/null 2>&1 && rpm -qa 2>/dev/null | grep -q nvpair; then sudo dnf remove -y nvpair || true; fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q nvpair 2>/dev/null | grep -q nvpair; then sudo pacman -Rs --noconfirm nvpair || true; fi
  if command -v zypper >/dev/null 2>&1 && rpm -qa 2>/dev/null | grep -q nvpair; then sudo zypper remove -y nvpair || true; fi
  if [[ -d "$PREFIX" ]]; then sudo rm -rf "$PREFIX"; log "Supprimé $PREFIX"; fi
  rm -rf ~/.config/"Nvidia Corporation"/"Personal AI Router" 2>/dev/null || true
  log "Désinstallation terminée. Modèles Ollama conservés dans ~/.ollama"
  exit 0
fi

log "PAIR Universal — installateur universel Linux"
log "Détection distro..."

detect_pkg() {
  if command -v apt >/dev/null 2>&1; then echo "deb"; elif command -v dnf >/dev/null 2>&1; then echo "rpm-dnf"; elif command -v yum >/dev/null 2>&1; then echo "rpm-yum"; elif command -v zypper >/dev/null 2>&1; then echo "rpm-zypper"; elif command -v pacman >/dev/null 2>&1; then echo "arch"; elif command -v apk >/dev/null 2>&1; then echo "apk"; else echo "tarball"; fi
}

PKG=$(detect_pkg)
log "Gestionnaire détecté: $PKG"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; *) warn "Arch $ARCH non testée, tentative amd64"; ARCH="amd64";; esac

# Si tarball fourni explicitement
if [[ -n "$TARBALL" && -f "$TARBALL" ]]; then
  log "Installation depuis tarball: $TARBALL"
  sudo mkdir -p "$PREFIX"
  sudo tar -xzf "$TARBALL" --strip-components=1 -C "$PREFIX" 2>/dev/null || sudo tar -xzf "$TARBALL" -C /tmp && sudo cp -a /tmp/NVIDIA-Personal-AI-Router-*/. "$PREFIX"/ 2>/dev/null || true
  sudo chmod +x "$PREFIX"/bin/* 2>/dev/null || true
  log "Binaires installés dans $PREFIX/bin — lance avec $PREFIX/bin/nvpair-tui ou $PREFIX/bin/nvpair-ui-broker"
  exit 0
fi

# Chercher un artefact local
find_artifact() {
  local pat="$1"; for p in "$REPO_ROOT"/services/dist/*.tar.gz "$REPO_ROOT"/dist/*.tar.gz ./pair-universal*.tar.gz /tmp/*.tar.gz; do [[ -f $p ]] && echo "$p" && return 0; done; return 1
}

# Si on est dans le repo cloné: build puis installer
if [[ -f "$REPO_ROOT/services/build.sh" ]]; then
  if ! command -v go >/dev/null 2>&1; then
    err "Go non trouvé. Installe Go 1.25+ (https://go.dev/dl/) puis relance."
    err "Ou télécharge un release pré-buildé depuis GitHub Releases."
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log "Installation de jq..."
    if [[ "$PKG" == "deb" ]]; then sudo apt update && sudo apt install -y jq
    elif [[ "$PKG" == "rpm-dnf" ]]; then sudo dnf install -y jq
    elif [[ "$PKG" == "rpm-yum" ]]; then sudo yum install -y jq
    elif [[ "$PKG" == "rpm-zypper" ]]; then sudo zypper install -y jq
    elif [[ "$PKG" == "arch" ]]; then sudo pacman -Sy --noconfirm jq
    elif [[ "$PKG" == "apk" ]]; then sudo apk add jq
    fi
  fi
  log "Build depuis les sources (./services/build.sh)..."
  (cd "$REPO_ROOT/services" && ./build.sh)
  log "Build OK. Installation portable dans $PREFIX..."
  sudo mkdir -p "$PREFIX/bin"
  sudo cp -a "$REPO_ROOT/services/build/bin/"* "$PREFIX/bin/"
  sudo chmod +x "$PREFIX/bin/"*
  # Installer le binaire TUI sur PATH si possible
  if [[ -d /usr/local/bin ]]; then sudo ln -sf "$PREFIX/bin/nvpair-tui" /usr/local/bin/nvpair 2>/dev/null || true; fi
  log "✅ Installé. Lance: nvpair  ou  $PREFIX/bin/nvpair-tui"
  log "   Desktop: cd $REPO_ROOT/desktop && npm install && npm start  (nécessite Node 25.5+)"
  exit 0
fi

# Sinon: téléchargement release
REPO="${PAIR_UNIVERSAL_REPO:-a11q1/pair-universal}"
VERSION="${PAIR_VERSION:-latest}"
log "Aucun build local — tentative téléchargement release $REPO@$VERSION ..."
if command -v curl >/dev/null 2>&1; then DL="curl -fsSL -o"; elif command -v wget >/dev/null 2>&1; then DL="wget -qO"; else err "curl ou wget requis"; exit 1; fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Assets réels sont versionnés: pair-universal-0.91.8-universal-linux-amd64.tar.gz
# On tente d'abord versionné, puis générique pour compat future
try_download() {
  local url="$1"
  log "Téléchargement $url ..."
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
  log "✅ Installé dans $PREFIX — lance: $PREFIX/bin/nvpair-tui"
else
  err "Échec téléchargement. Construis depuis les sources:"
  err "  git clone https://github.com/$REPO && cd pair-universal && ./scripts/install-universal.sh"
  exit 1
fi
