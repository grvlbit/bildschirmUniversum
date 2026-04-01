#!/usr/bin/env bash
# install.sh — download the latest release from GitHub and install to ~/.local/bin/
set -euo pipefail

REPO="grvlbit/bildschirmUniversum"
BINARY="bildschirmuniversum"
INSTALL_DIR="$HOME/.local/bin"
TARGET="$INSTALL_DIR/$BINARY"
ASSET="${BINARY}-macos.zip"

# Resolve the latest release download URL via the GitHub API (no auth required).
echo "Fetching latest release info for ${REPO} …"
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o "\"browser_download_url\": *\"[^\"]*${ASSET}\"" \
  | grep -o 'https://[^"]*')

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "error: could not find asset '${ASSET}' in the latest release." >&2
  echo "       Make sure a release has been published at:" >&2
  echo "       https://github.com/${REPO}/releases" >&2
  exit 1
fi

echo "Downloading ${DOWNLOAD_URL} …"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/$ASSET"
unzip -q "$TMP_DIR/$ASSET" -d "$TMP_DIR"

mkdir -p "$INSTALL_DIR"
install -m 755 "$TMP_DIR/$BINARY" "$TARGET"
echo "✓ Installed $(sw_vers -productVersion)-compatible binary to $TARGET"

# Check whether ~/.local/bin is already on PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo
    echo "⚠ Add the following line to your shell profile (~/.zshrc or ~/.bash_profile):"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "  Then run: source ~/.zshrc   (or restart your terminal)"
fi

