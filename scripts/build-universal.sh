#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
# SPDX-License-Identifier: Apache-2.0
# build-universal.sh — build PAIR Universal pour tout Linux
# Produit: tar.gz portable + .deb + .rpm (si outils présents)
# Usage: ./scripts/build-universal.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES="$ROOT/services"
VERSION="${1:-$(jq -r '.product' "$SERVICES/versions.json")}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; *) ARCH="amd64";; esac
DIST="$ROOT/dist"; mkdir -p "$DIST"

echo "=== PAIR Universal build $VERSION ($ARCH) ==="

# 1. Build binaires Go
echo "[1/4] Build Go services..."
(cd "$SERVICES" && ./build.sh)

# 2. Tarball portable universel (reprend installer_build.sh mais renommé)
echo "[2/4] Tarball portable..."
(cd "$SERVICES" && NVPAIR_SKIP_BUILD=1 ./installer_build.sh "$VERSION" || true)
# Renommer pour universal
if ls "$SERVICES"/dist/*.tar.gz >/dev/null 2>&1; then
  for f in "$SERVICES"/dist/*.tar.gz; do
    base=$(basename "$f" | sed "s/NVIDIA-Personal-AI-Router/pair-universal/")
    cp "$f" "$DIST/$base"
    echo "  -> $DIST/$base"
  done
fi
# Fallback si installer_build n'a pas tourné
STAGE_TMP=$(mktemp -d)
trap 'rm -rf "$STAGE_TMP"' EXIT
STAGE="$STAGE_TMP/pair-universal-$VERSION"
mkdir -p "$STAGE/bin"
cp "$SERVICES/build/bin/"* "$STAGE/bin/"
chmod 0755 "$STAGE"/bin/*
cp "$SERVICES/installer/linux/INSTALL.md" "$STAGE/INSTALL-UNIVERSAL.md" 2>/dev/null || true
cat > "$STAGE/README-UNIVERSAL.md" <<EOF
# PAIR Universal $VERSION
Fork universel — tout GPU (GTX/Tesla/AMD/Intel) + tout Linux
Lance: ./bin/nvpair-tui  ou  ./bin/nvpair-ui-broker
Install portable: sudo mkdir -p /opt/pair && sudo cp -a bin /opt/pair/ && sudo ln -sf /opt/pair/bin/nvpair-tui /usr/local/bin/nvpair
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
Description: PAIR Universal - Personal AI Router fork, tout GPU + tout Linux
 Compatible GTX/Tesla/RTX/AMD/Intel, tout Linux (Debian/Fedora/Arch)
 Fork de NVIDIA Personal AI Router (Apache-2.0)
Depends: jq
EOF
  cat > "$DEB_DIR/DEBIAN/postinst" <<'EOS'
#!/bin/sh
chmod 0755 /opt/pair/bin/* 2>/dev/null || true
ln -sf /opt/pair/bin/nvpair-tui /usr/local/bin/nvpair 2>/dev/null || true
ln -sf /opt/pair/bin/nvpair-ui-broker /usr/local/bin/nvpair-broker 2>/dev/null || true
echo "PAIR Universal installé — lance: nvpair  ou  /opt/pair/bin/nvpair-tui"
exit 0
EOS
  chmod 0755 "$DEB_DIR/DEBIAN/postinst"
  dpkg-deb --build "$DEB_DIR" "$DIST/pair-universal_${VERSION}_${ARCH}.deb" >/dev/null
  echo "  -> $DIST/pair-universal_${VERSION}_${ARCH}.deb"
else
  echo "[3/4] .deb skip (dpkg-deb absent)"
fi

# 4. .rpm (Fedora/RHEL/openSUSE)
if command -v rpmbuild >/dev/null 2>&1 || command -v fpm >/dev/null 2>&1; then
  echo "[4/4] .rpm ..."
  if command -v fpm >/dev/null 2>&1; then
    fpm -s dir -t rpm -n pair-universal -v "$VERSION" -a "$ARCH" --prefix /opt/pair -C "$SERVICES/build/bin" --rpm-summary "PAIR Universal tout GPU" . 2>/dev/null && mv *.rpm "$DIST/" 2>/dev/null || true
    echo "  -> $(ls "$DIST"/*.rpm 2>/dev/null | head -1)"
  else
    echo "  skip .rpm (fpm non installé — sudo gem install fpm  ou  sudo dnf install rpm-build)"
  fi
else
  echo "[4/4] .rpm skip (rpmbuild/fpm absent) — tar.gz suffit pour tout distro"
fi

echo ""
echo "=== Build terminé ==="
ls -lh "$DIST"/pair-universal* 2>/dev/null || ls -lh "$SERVICES"/dist/* 2>/dev/null || true
echo ""
echo "Install:"
echo "  Debian/Ubuntu: sudo apt install ./dist/pair-universal_${VERSION}_${ARCH}.deb"
echo "  Fedora:        sudo dnf install ./dist/pair-universal-*.rpm"
echo "  Arch/Autre:    tar xf dist/pair-universal-*-linux-*.tar.gz && sudo ./scripts/install-universal.sh --tarball dist/pair-universal-*-linux-*.tar.gz"
