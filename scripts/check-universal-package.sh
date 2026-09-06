#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:-}"
VERSION="$(jq -r '.product' "$ROOT/services/versions.json")"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) printf 'ERROR: unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
esac

if [[ -z "$ARCHIVE" ]]; then
  ARCHIVE="$ROOT/dist/pair-universal-$VERSION-linux-$ARCH.tar.gz"
fi
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  printf 'ERROR: universal Linux tarball not found\n' >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d -t pair-package-check-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

tar -xzf "$ARCHIVE" -C "$TMP_ROOT"
PACKAGE_ROOT="$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d -print -quit)"
if [[ -z "$PACKAGE_ROOT" ]]; then
  printf 'ERROR: archive has no top-level package directory\n' >&2
  exit 1
fi

BINARIES=(
  ollama-proxy lmstudio-proxy vllm-proxy nvpair-node-info
  nvpair-node-scanner nvpair-manual-nodes nvpair-workload-manager
  nvpair-errors nvpair-engine-manager nvpair-node-settings
  nvpair-cluster-manager nvpair-job-scheduler nvpair-ui-broker nvpair-tui
)
for binary in "${BINARIES[@]}"; do
  test -x "$PACKAGE_ROOT/bin/$binary" || {
    printf 'ERROR: missing executable bin/%s\n' "$binary" >&2
    exit 1
  }
done

while IFS=$'\t' read -r binary expected; do
  actual="$("$PACKAGE_ROOT/bin/$binary" --version)"
  test "$actual" = "$expected" || {
    printf 'ERROR: bin/%s version is %s, expected %s\n' "$binary" "$actual" "$expected" >&2
    exit 1
  }
done < <(jq -r '.components | to_entries[] | [.key, .value] | @tsv' "$ROOT/services/versions.json")

test -s "$PACKAGE_ROOT/share/man/man1/nvpair-tui.1" || {
  printf 'ERROR: missing manual page share/man/man1/nvpair-tui.1\n' >&2
  exit 1
}
grep -q '^\.TH NVPAIR-TUI 1' "$PACKAGE_ROOT/share/man/man1/nvpair-tui.1"
"$PACKAGE_ROOT/bin/nvpair-tui" --version >/dev/null
"$PACKAGE_ROOT/bin/nvpair-ui-broker" --version >/dev/null

INSTALL_ROOT="$TMP_ROOT/install"
LINK_ROOT="$TMP_ROOT/links"
MAN_ROOT="$TMP_ROOT/man/man1"
mkdir -p "$LINK_ROOT"
PAIR_NO_SUDO=1 PAIR_BIN_LINK_DIR="$LINK_ROOT" PAIR_MAN_DIR="$MAN_ROOT" \
  "$ROOT/scripts/install-universal.sh" --prefix "$INSTALL_ROOT" --tarball "$ARCHIVE"
test -L "$LINK_ROOT/nvpair"
test -L "$LINK_ROOT/nvpair-broker"
test -x "$INSTALL_ROOT/bin/nvpair-tui"
test -s "$MAN_ROOT/nvpair-tui.1.gz"

DEB="$ROOT/dist/pair-universal_${VERSION}_${ARCH}.deb"
if [[ -f "$DEB" && -x "$(command -v dpkg-deb || true)" ]]; then
  dpkg-deb --contents "$DEB" > "$TMP_ROOT/deb-contents.txt"
  grep -q 'usr/share/man/man1/nvpair-tui.1.gz' "$TMP_ROOT/deb-contents.txt"
  grep -q 'opt/pair/bin/nvpair-tui' "$TMP_ROOT/deb-contents.txt"
fi

RPM_VERSION="${VERSION%%-*}"
RPM_RELEASE="${VERSION#*-}"
if [[ "$RPM_RELEASE" == "$VERSION" ]]; then RPM_RELEASE="1"; fi
case "$ARCH" in amd64) RPM_ARCH="x86_64";; arm64) RPM_ARCH="aarch64";; esac
RPM="$ROOT/dist/pair-universal-${RPM_VERSION}-${RPM_RELEASE}.${RPM_ARCH}.rpm"
if [[ -f "$RPM" && -x "$(command -v rpm || true)" ]]; then
  metadata="$(rpm -qp --qf '%{NAME}\t%{VERSION}\t%{RELEASE}\t%{ARCH}' "$RPM")"
  expected_metadata="pair-universal"$'\t'"$RPM_VERSION"$'\t'"$RPM_RELEASE"$'\t'"$RPM_ARCH"
  test "$metadata" = "$expected_metadata" || {
    printf 'ERROR: unexpected RPM metadata: %s\n' "$metadata" >&2
    exit 1
  }
  rpm -qpl "$RPM" > "$TMP_ROOT/rpm-contents.txt"
  grep -q '^/usr/share/man/man1/nvpair-tui.1.gz$' "$TMP_ROOT/rpm-contents.txt"
  grep -q '^/opt/pair/bin/nvpair-tui$' "$TMP_ROOT/rpm-contents.txt"
  rpm -qp --requires "$RPM" | grep -qx 'jq'
fi

for darwin_arch in arm64 amd64; do
  darwin_archive="$ROOT/dist/pair-universal-$VERSION-darwin-$darwin_arch.tar.gz"
  test -f "$darwin_archive" || {
    printf 'ERROR: missing macOS %s archive\n' "$darwin_arch" >&2
    exit 1
  }
  darwin_root="$TMP_ROOT/darwin-$darwin_arch"
  mkdir -p "$darwin_root"
  tar -xzf "$darwin_archive" -C "$darwin_root"
  for binary in "${BINARIES[@]}"; do
    test -x "$darwin_root/pair-universal-$VERSION/bin/$binary" || {
      printf 'ERROR: macOS %s archive is missing bin/%s\n' "$darwin_arch" "$binary" >&2
      exit 1
    }
  done
  case "$darwin_arch" in arm64) file_arch="arm64";; amd64) file_arch="x86_64";; esac
  file "$darwin_root/pair-universal-$VERSION/bin/nvpair-tui" | grep -q "Mach-O 64-bit $file_arch"
done

printf 'Package smoke check passed: %s\n' "$ARCHIVE"
