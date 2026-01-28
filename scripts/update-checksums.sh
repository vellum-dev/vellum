#!/bin/sh
# Update checksums in APKBUILD files using Alpine's abuild
# Usage: ./update-checksums.sh <package> [package2] ...

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <package> [package2] ..."
    echo "Updates sha512sums in APKBUILD files"
    exit 1
fi

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
else
    CONTAINER_CMD="docker"
fi

for PACKAGE in "$@"; do
    PACKAGE_DIR="$REPO_ROOT/packages/$PACKAGE"

    if [ ! -d "$PACKAGE_DIR" ]; then
        echo "Error: Package '$PACKAGE' not found in packages/"
        continue
    fi

    echo "Updating checksums for $PACKAGE..."

    $CONTAINER_CMD run --rm \
        -v "$REPO_ROOT/packages:/work/packages:Z" \
        -w "/work/packages/$PACKAGE" \
        alpine:3 \
        sh -c 'apk add --no-cache abuild >/dev/null 2>&1 && abuild -F checksum'

    rm -rf "$PACKAGE_DIR/src"
    echo "Done: $PACKAGE"
done

# Docker: fix ownership so host user can access modified files
if [ "$CONTAINER_CMD" = "docker" ]; then
    $CONTAINER_CMD run --rm \
        -v "$REPO_ROOT/packages:/work/packages:Z" \
        alpine:3 \
        chown -R "$(id -u):$(id -g)" /work/packages
fi
