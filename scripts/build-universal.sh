#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
# SPDX-License-Identifier: Apache-2.0
# build-universal.sh — build PAIR Universal for any Linux (and cross darwin)
# Produces: portable tar.gz + .deb + .rpm (if tools present)
# Usage: ./scripts/build-universal.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES="$ROOT/services"
VERSION="${1:-$(jq -r '.product' "$SERVICES/versions.json")}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; *) ARCH="amd64";; esac
DIST="$ROOT/dist"; mkdir -p "$DIST"

echo "=== PAIR Universal BETA build $VERSION ($ARCH) ==="

# 1. Build Go services
echo "[1/4] Build Go services..."
(cd "$SERVICES" && ./build.sh)

# 2. Portable universal tarball (reuses installer_build.sh but renamed)
echo "[2/4] Portable tarball..."
(cd "$SERVICES" && NVPAIR_SKIP_BUILD=1 ./installer_build.sh "$VERSION" || true)
# Rename to universal
if ls "$SERVICES"/dist/*.tar.gz >/dev/null 2>&1; then
  for f in "$SERVICES"/dist/*.tar.gz; do
    base=$(basename "$f" | sed "s/NVIDIA-Personal-AI-Router/pair-universal/")
    cp "$f" "$DIST/$base"
    echo "  -> $DIST/$base"
  done
fi
# Fallback if installer_build didn't run
STAGE_TMP=$(mktemp -d)
trap 'rm -rf "$STAGE_TMP"' EXIT
STAGE="$STAGE_TMP/pair-universal-$VERSION"
mkdir -p "$STAGE/bin"
cp "$SERVICES/build/bin/"* "$STAGE/bin/"
chmod 0755 "$STAGE"/bin/*
cp "$SERVICES/installer/linux/INSTALL.md" "$STAGE/INSTALL-UNIVERSAL.md" 2>/dev/null || true
cat > "$STAGE/README-UNIVERSAL.md" <<EOF
# PAIR Universal BETA $VERSION
Universal fork — all GPUs (GTX/Tesla/AMD/Intel/Apple Silicon) + all Linux/macOS
Run: ./bin/nvpair-tui  or  ./bin/nvpair-ui-broker
Portable install: sudo mkdir -p /opt/pair && sudo cp -a bin /opt/pair/ && sudo ln -sf /opt/pair/bin/nvpair-tui /usr/local/bin/nvpair
EOF
tar -czf "$DIST/pair-universal-$VERSION-linux-$ARCH.tar.gz" -C "$STAGE_TMP" "pair-universal-$VERSION"
echo "  -> $DIST/pair-universal-$VERSION-linux-$ARCH.tar.gz"

# 3. .deb (Debian/Ubuntu)
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "[3/4] .deb ..."
  DEB_DIR=$(mktemp -d)
  trap 'rm -rf "$DEB_DIR" "$STAGE_TMP"' EXIT
  mkdir -p "$DEB_DIR/DEBIAN" "$DEB_DIR/opt/pair/bin" "$DEB_DIR/usr/local/bin"
  cp "$SERVICES/build/bin/"* "$DEB_DIR/opt/pair/bin/"
  cat > "$DEB_DIR/DEBIAN/control" <<EOF
Package: pair-universal
Version: $VERSION
Section: net
Priority: optional
Architecture: $ARCH
Maintainer: PAIR Universal <pair-universal@github>
Description: PAIR Universal BETA - Personal AI Router fork, all GPUs + all Linux/macOS
 Supports GTX/Tesla/RTX/AMD/Intel/Apple Silicon, all Linux (Debian/Fedora/Arch) + macOS
 Fork of NVIDIA Personal AI Router BETA (Apache-2.0)
Depends: jq
EOF
  cat > "$DEB_DIR/DEBIAN/postinst" <<'EOS'
#!/bin/sh
chmod 0755 /opt/pair/bin/* 2>/dev/null || true
ln -sf /opt/pair/bin/nvpair-tui /usr/local/bin/nvpair 2>/dev/null || true
ln -sf /opt/pair/bin/nvpair-ui-broker /usr/local/bin/nvpair-broker 2>/dev/null || true
echo "PAIR Universal BETA installed — run: nvpair  or  /opt/pair/bin/nvpair-tui"
exit 0
EOS
  chmod 0755 "$DEB_DIR/DEBIAN/postinst"
  dpkg-deb --build "$DEB_DIR" "$DIST/pair-universal_${VERSION}_${ARCH}.deb" >/dev/null
  echo "  -> $DIST/pair-universal_${VERSION}_${ARCH}.deb"
else
  echo "[3/4] .deb skip (dpkg-deb not found)"
fi

# 4. .rpm (Fedora/RHEL/openSUSE)
if command -v rpmbuild >/dev/null 2>&1 || command -v fpm >/dev/null 2>&1; then
  echo "[4/4] .rpm ..."
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t rpm -n pair-universal -v "$VERSION" -a "$ARCH" --prefix /opt/pair -C "$SERVICES/build/bin" --rpm-summary "PAIR Universal BETA all GPUs" . 2>/dev/null && mv *.rpm "$DIST/" 2>/dev/null || true
    echo "  -> $(ls "$DIST"/*.rpm 2>/dev/null | head -1)"
  else
    echo "  skip .rpm (fpm not installed — sudo gem install fpm  or  sudo dnf install rpm-build)"
  fi
else
  echo "[4/4] .rpm skip (rpmbuild/fpm not found) — tar.gz is enough for any distro"
fi

echo ""
echo "=== Build complete (BETA) ==="
ls -lh "$DIST"/pair-universal* 2>/dev/null || ls -lh "$SERVICES"/dist/* 2>/dev/null || true
echo ""
echo "Install:"
echo "  Debian/Ubuntu: sudo apt install ./dist/pair-universal_${VERSION}_${ARCH}.deb"
echo "  Fedora:        sudo dnf install ./dist/pair-universal-*.rpm"
echo "  Arch/Other:    tar xf dist/pair-universal-*-linux-*.tar.gz && sudo ./scripts/install-universal.sh --tarball dist/pair-universal-*-linux-*.tar.gz"
