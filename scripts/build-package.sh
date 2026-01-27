#!/bin/sh
# Build a single package using Alpine's abuild in a container
# Usage: ./build-package.sh <package-name> [arch]
#
# Requires: docker or podman

set -e

PACKAGE="$1"
ARCH="${2:-}"

if [ -z "$PACKAGE" ]; then
    echo "Usage: $0 <package-name> [arch]"
    echo "  arch: aarch64, armv7, or omit for noarch"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="$REPO_ROOT/packages/$PACKAGE"

if [ ! -d "$PACKAGE_DIR" ]; then
    echo "Error: Package '$PACKAGE' not found in packages/"
    exit 1
fi

if command -v podman >/dev/null 2>&1; then
    CONTAINER_CMD="podman"
else
    CONTAINER_CMD="docker"
fi

if [ -z "$ARCH" ]; then
    if grep -q '^arch="noarch"' "$PACKAGE_DIR/APKBUILD"; then
        ARCH="noarch"
    else
        ARCH="aarch64"
    fi
fi

echo "Building $PACKAGE for $ARCH using $CONTAINER_CMD..."

mkdir -p "$REPO_ROOT/dist/$ARCH"

# Get reproducible timestamp from git (last commit to this package)
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct -- "$PACKAGE_DIR")
if [ -z "$SOURCE_DATE_EPOCH" ]; then
    # Fallback to APKBUILD modification time if no git history
    SOURCE_DATE_EPOCH=$(stat -c %Y "$PACKAGE_DIR/APKBUILD" 2>/dev/null || stat -f %m "$PACKAGE_DIR/APKBUILD")
fi
echo "Using SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH for reproducible build"

CARCH_ENV="-e CARCH=$ARCH -e SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

$CONTAINER_CMD run --rm \
    -v "$REPO_ROOT:/work:Z" \
    -v "$REPO_ROOT/packages:/work/packages:O" \
    -w "/work/packages/$PACKAGE" \
    $CARCH_ENV \
    alpine:edge \
    sh -c '
        set -e

        apk add --no-cache alpine-sdk sudo

        adduser -D builder
        addgroup builder abuild
        echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

        mkdir -p /work/dist/'$ARCH'
        chown -R builder:builder /work/dist

        # Set up signing key from repo
        mkdir -p /home/builder/.abuild
        cp /work/keys/packages.rsa /home/builder/.abuild/
        cp /work/keys/packages.rsa.pub /home/builder/.abuild/
        echo "PACKAGER_PRIVKEY=/home/builder/.abuild/packages.rsa" > /home/builder/.abuild/abuild.conf
        chown -R builder:builder /home/builder/.abuild

        # Install public key for index verification
        cp /work/keys/packages.rsa.pub /etc/apk/keys/

        # Build package (-d skips dependency checking for custom deps not in Alpine repos)
        chown -R builder:builder /work/packages
        su builder -c "REPODEST=/work/dist abuild -d -r"

        # Fix ownership for cleanup outside container
        chown -R $(stat -c %u /work) /work/dist
    '

# Move packages from nested structure to flat
if [ -d "$REPO_ROOT/dist/packages/noarch" ]; then
    mkdir -p "$REPO_ROOT/dist/noarch"
    mv "$REPO_ROOT/dist/packages/noarch"/*.apk "$REPO_ROOT/dist/noarch/" 2>/dev/null || true
fi
if [ -d "$REPO_ROOT/dist/packages/$ARCH" ]; then
    mv "$REPO_ROOT/dist/packages/$ARCH"/*.apk "$REPO_ROOT/dist/$ARCH/" 2>/dev/null || true
fi
rm -rf "$REPO_ROOT/dist/packages"

echo "Build complete."
ls -la "$REPO_ROOT/dist/"*/*.apk 2>/dev/null || echo "No .apk files found"
