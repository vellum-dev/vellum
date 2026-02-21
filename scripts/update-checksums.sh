#!/bin/sh
# Update checksums in VELBUILD files using vbuild
# Usage: ./update-checksums.sh <package> [package2] ...

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <package> [package2] ..."
    echo "Updates sha512sums in APKBUILD files"
    exit 1
fi

if ! command -v vbuild >/dev/null 2>&1; then
    echo "Error: vbuild not found"
    exit 1
fi

for PACKAGE in "$@"; do
    PACKAGE_DIR="$REPO_ROOT/packages/$PACKAGE"

    if [ ! -d "$PACKAGE_DIR" ]; then
        echo "Error: Package '$PACKAGE' not found in packages/"
        continue
    fi

    echo "Updating checksums for $PACKAGE..."
    vbuild -C "$PACKAGE_DIR" checksum
    echo "Done: $PACKAGE"
done
