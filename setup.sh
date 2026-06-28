#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG="$SCRIPT_DIR/Config/default-config.json"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/FinderBreadcrumbs"
TARGET_CONFIG="${APP_SUPPORT_DIR}/config.json"

usage() {
  cat <<'EOF'
Usage: ./setup.sh [--force]

Bootstraps FinderBreadcrumbs on a new Mac by installing the checked-in
default config into:

  ~/Library/Application Support/FinderBreadcrumbs/config.json

Options:
  --force    Overwrite an existing live config.
  --help     Show this help text.
EOF
}

force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$SOURCE_CONFIG" ]]; then
  echo "Missing source config: $SOURCE_CONFIG" >&2
  exit 1
fi

mkdir -p "$APP_SUPPORT_DIR"

if [[ -f "$TARGET_CONFIG" && "$force" -ne 1 ]]; then
  echo "Live config already exists at:"
  echo "  $TARGET_CONFIG"
  echo
  echo "Leaving it unchanged. Re-run with --force to overwrite it."
  exit 0
fi

cp "$SOURCE_CONFIG" "$TARGET_CONFIG"

echo "Installed FinderBreadcrumbs config:"
echo "  $TARGET_CONFIG"
echo
echo "Next steps:"
echo "  1. Open FinderBreadcrumbs.xcodeproj in Xcode."
echo "  2. Build and run the app."
echo "  3. Grant Accessibility and Finder automation permissions if prompted."
