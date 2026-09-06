#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 PAIR Universal Contributors
# SPDX-License-Identifier: Apache-2.0
# build-universal.sh — build PAIR Universal Linux packages and macOS bundles
# Produces: Linux tar.gz + .deb + .rpm (if rpmbuild/fpm is present), plus macOS tar.gz
# Usage: ./scripts/build-universal.sh [version]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVICES="$ROOT/services"
VERSION="${1:-$(jq -r '.product' "$SERVICES/versions.json")}"
ARCH="$(uname -m)"; case "$ARCH" in x86_64|amd64) ARCH="amd64";; aarch64|arm64) ARCH="arm64";; *) ARCH="amd64";; esac
DIST="$ROOT/dist"; mkdir -p "$DIST"
PORTABLE_SOURCE="$SERVICES/dist/NVIDIA-Personal-AI-Router-$VERSION-linux-$ARCH.tar.gz"
PORTABLE_TARGET="$DIST/pair-universal-$VERSION-linux-$ARCH.tar.gz"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

echo "=== PAIR Universal BETA build $VERSION ($ARCH) ==="

# 1. Build Go services
echo "[1/5] Build Go services..."
(cd "$SERVICES" && ./build.sh)

# 2. Portable universal tarball (reuses installer_build.sh but renamed)
echo "[2/5] Portable tarball..."
(cd "$SERVICES" && NVPAIR_SKIP_BUILD=1 ./installer_build.sh "$VERSION")
test -f "$PORTABLE_SOURCE" || {
  echo "ERROR: installer did not produce $PORTABLE_SOURCE" >&2
  exit 1
}
cp "$PORTABLE_SOURCE" "$PORTABLE_TARGET"
echo "  -> $PORTABLE_TARGET"

# 3. .deb (Debian/Ubuntu)
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "[3/5] .deb ..."
  DEB_DIR="$TMP_ROOT/deb"
  mkdir -p "$DEB_DIR/DEBIAN" "$DEB_DIR/opt/pair/bin" "$DEB_DIR/usr/local/bin" "$DEB_DIR/usr/share/man/man1"
  cp "$SERVICES/build/bin/"* "$DEB_DIR/opt/pair/bin/"
  gzip -n -9 -c "$ROOT/docs/nvpair-tui.1" > "$DEB_DIR/usr/share/man/man1/nvpair-tui.1.gz"
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
  echo "[3/5] .deb skip (dpkg-deb not found)"
fi

# 4. .rpm (Fedora/RHEL/openSUSE)
RPM_VERSION="${VERSION%%-*}"
RPM_RELEASE="${VERSION#*-}"
if [[ "$RPM_RELEASE" == "$VERSION" ]]; then RPM_RELEASE="1"; fi
case "$ARCH" in amd64) RPM_ARCH="x86_64";; arm64) RPM_ARCH="aarch64";; esac
RPM_TARGET="$DIST/pair-universal-${RPM_VERSION}-${RPM_RELEASE}.${RPM_ARCH}.rpm"
if command -v rpmbuild >/dev/null 2>&1; then
  echo "[4/5] .rpm ..."
  RPM_TOP="$TMP_ROOT/rpmbuild"
  RPM_TMP="$TMP_ROOT/rpmtmp"
  mkdir -p "$RPM_TOP"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS} "$RPM_TMP"
  cat > "$RPM_TOP/SPECS/pair-universal.spec" <<EOF
Name: pair-universal
Version: $RPM_VERSION
Release: $RPM_RELEASE
Summary: PAIR Universal headless services and terminal interface
License: Apache-2.0
BuildArch: $RPM_ARCH
Requires: jq

%description
Universal community fork of NVIDIA Personal AI Router, including headless
services and the nvpair-tui terminal interface.

%install
mkdir -p %{buildroot}/opt/pair/bin %{buildroot}/usr/local/bin %{buildroot}%{_mandir}/man1
cp $SERVICES/build/bin/* %{buildroot}/opt/pair/bin/
ln -s /opt/pair/bin/nvpair-tui %{buildroot}/usr/local/bin/nvpair
ln -s /opt/pair/bin/nvpair-ui-broker %{buildroot}/usr/local/bin/nvpair-broker
gzip -n -9 -c $ROOT/docs/nvpair-tui.1 > %{buildroot}%{_mandir}/man1/nvpair-tui.1.gz

%files
/opt/pair/bin/*
/usr/local/bin/nvpair
/usr/local/bin/nvpair-broker
%{_mandir}/man1/nvpair-tui.1.gz
EOF
  rpmbuild --define "_topdir $RPM_TOP" --define "_tmppath $RPM_TMP" \
    -bb "$RPM_TOP/SPECS/pair-universal.spec" >/dev/null
  RPM_BUILT="$(find "$RPM_TOP/RPMS" -type f -name '*.rpm' -print -quit)"
  test -n "$RPM_BUILT" || { echo "ERROR: rpmbuild did not produce an RPM" >&2; exit 1; }
  cp "$RPM_BUILT" "$RPM_TARGET"
  echo "  -> $RPM_TARGET"
elif command -v fpm >/dev/null 2>&1; then
  echo "[4/5] .rpm ..."
  RPM_DIR="$TMP_ROOT/rpm"
  mkdir -p "$RPM_DIR/opt/pair/bin" "$RPM_DIR/usr/local/bin" "$RPM_DIR/usr/share/man/man1"
  cp "$SERVICES/build/bin/"* "$RPM_DIR/opt/pair/bin/"
  ln -s /opt/pair/bin/nvpair-tui "$RPM_DIR/usr/local/bin/nvpair"
  ln -s /opt/pair/bin/nvpair-ui-broker "$RPM_DIR/usr/local/bin/nvpair-broker"
  gzip -n -9 -c "$ROOT/docs/nvpair-tui.1" > "$RPM_DIR/usr/share/man/man1/nvpair-tui.1.gz"
  fpm -s dir -t rpm -n pair-universal -v "$RPM_VERSION" --iteration "$RPM_RELEASE" -a "$RPM_ARCH" -C "$RPM_DIR" -p "$RPM_TARGET" --rpm-summary "PAIR Universal headless services" . >/dev/null
  echo "  -> $RPM_TARGET"
else
  echo "[4/5] .rpm skip (rpmbuild/fpm not found) — tar.gz works on any Linux distro"
fi

# 5. Portable macOS service bundles (cross-compiled from Linux)
echo "[5/5] macOS service bundles..."
for DARWIN_ARCH in arm64 amd64; do
  DARWIN_ROOT="$TMP_ROOT/darwin-$DARWIN_ARCH/pair-universal-$VERSION"
  mkdir -p "$DARWIN_ROOT/bin" "$DARWIN_ROOT/share/man/man1"
  while IFS=$'\t' read -r component component_version; do
    (cd "$SERVICES/$component" && CGO_ENABLED=0 GOOS=darwin GOARCH="$DARWIN_ARCH" \
      go build -ldflags "-X main.Version=$component_version" -o "$DARWIN_ROOT/bin/$component" .)
  done < <(jq -r '.components | to_entries[] | [.key, .value] | @tsv' "$SERVICES/versions.json")
  cp "$ROOT/docs/nvpair-tui.1" "$DARWIN_ROOT/share/man/man1/"
  cat > "$DARWIN_ROOT/README.md" <<EOF
# PAIR Universal $VERSION — macOS $DARWIN_ARCH service bundle

This archive contains the headless Go services and nvpair-tui. It does not
contain the Electron desktop application. Run ./bin/nvpair-tui from a terminal.
EOF
  DARWIN_TARGET="$DIST/pair-universal-$VERSION-darwin-$DARWIN_ARCH.tar.gz"
  tar -czf "$DARWIN_TARGET" -C "$TMP_ROOT/darwin-$DARWIN_ARCH" "pair-universal-$VERSION"
  echo "  -> $DARWIN_TARGET"
done

echo ""
echo "=== Build complete (BETA) ==="
ls -lh "$PORTABLE_TARGET" "$DIST/pair-universal_${VERSION}_${ARCH}.deb" "$RPM_TARGET" \
  "$DIST/pair-universal-$VERSION-darwin-arm64.tar.gz" \
  "$DIST/pair-universal-$VERSION-darwin-amd64.tar.gz" 2>/dev/null || true
echo ""
echo "Install:"
echo "  Debian/Ubuntu: sudo apt install ./dist/pair-universal_${VERSION}_${ARCH}.deb"
if [[ -f "$RPM_TARGET" ]]; then
  echo "  Fedora:        sudo dnf install $RPM_TARGET"
else
  echo "  Fedora:        use the portable tarball above (install rpmbuild to create an RPM)"
fi
echo "  Arch/Other:    sudo ./scripts/install-universal.sh --tarball $PORTABLE_TARGET"
