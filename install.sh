#!/bin/sh
# takeit installer. Downloads the prebuilt binary for this platform from the GitHub
# Release and installs it into a directory on your PATH.
#
#   curl -sSfL https://raw.githubusercontent.com/ray-language/takeit/main/install.sh | sh
#
# Environment variables (all optional):
#   TAKEIT_VERSION   tag to install (e.g. v0.1.0). Default: the latest release.
#   TAKEIT_BIN_DIR   install directory. Default: $HOME/.local/bin
#   TAKEIT_REPO      owner/repo. Default: ray-language/takeit
#   TAKEIT_DRY_RUN   if set, print the plan and download nothing (to test detection).
set -eu

REPO="${TAKEIT_REPO:-ray-language/takeit}"
BIN_DIR="${TAKEIT_BIN_DIR:-$HOME/.local/bin}"

info() { printf '\033[1;34m→\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mnote:\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Detect the platform → Rust target triple ---------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)  suffix="unknown-linux-gnu" ;;
  Darwin) suffix="apple-darwin" ;;
  MINGW*|MSYS*|CYGWIN*)
    err "takeit ships Linux and macOS binaries. On Windows, use WSL." ;;
  *) err "unsupported operating system: $os" ;;
esac
case "$arch" in
  x86_64|amd64)  cpu="x86_64" ;;
  arm64|aarch64) cpu="aarch64" ;;
  *) err "unsupported architecture: $arch" ;;
esac
target="${cpu}-${suffix}"
asset="takeit-${target}.tar.gz"

# --- Resolve the download URL -------------------------------------------------
if [ -n "${TAKEIT_VERSION:-}" ]; then
  base="https://github.com/$REPO/releases/download/$TAKEIT_VERSION"
  version="$TAKEIT_VERSION"
else
  base="https://github.com/$REPO/releases/latest/download"
  version="latest"
fi
url="$base/$asset"

info "takeit · $target · $version"
info "asset:   $asset"
info "target:  $BIN_DIR"

if [ -n "${TAKEIT_DRY_RUN:-}" ]; then
  info "DRY RUN — url: $url"
  exit 0
fi

# --- Download -----------------------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -sSfL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "'curl' or 'wget' is required"
fi
command -v tar >/dev/null 2>&1 || err "'tar' is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "downloading…"
dl "$url" "$tmp/$asset" || err "could not download $url
       is there a Release with that asset? See https://github.com/$REPO/releases"

# --- Verify the checksum, when both the asset and a hashing tool are there ----
if dl "$url.sha256" "$tmp/$asset.sha256" 2>/dev/null; then
  expected="$(cut -d' ' -f1 <"$tmp/$asset.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$tmp/$asset" | cut -d' ' -f1)"
  else
    actual=""
    warn "no 'sha256sum' nor 'shasum': checksum not verified"
  fi
  if [ -n "$actual" ]; then
    [ "$actual" = "$expected" ] || err "checksum mismatch for $asset
       expected: $expected
       actual:   $actual"
    info "checksum ok"
  fi
else
  warn "the release publishes no .sha256 for this asset: checksum not verified"
fi

info "extracting…"
tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/takeit" ] || err "the package does not contain 'takeit'"

# --- Install ------------------------------------------------------------------
mkdir -p "$BIN_DIR"
install -m 0755 "$tmp/takeit" "$BIN_DIR/takeit" 2>/dev/null || {
  cp "$tmp/takeit" "$BIN_DIR/takeit"; chmod 0755 "$BIN_DIR/takeit";
}

# macOS quarantines anything downloaded by curl; strip it so Gatekeeper does not
# refuse the first run of an unsigned binary.
if [ "$os" = "Darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -d com.apple.quarantine "$BIN_DIR/takeit" 2>/dev/null || true
fi

info "installed: $BIN_DIR/takeit"

# --- PATH guidance ------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*) info "run 'takeit' from any directory" ;;
  *) printf '\n\033[1;33mnote:\033[0m %s is not on your PATH. Add it to your shell:\n  export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac
