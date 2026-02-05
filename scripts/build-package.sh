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

# Skip if the requested arch isn't supported by this package
PKG_ARCH=$(grep '^arch=' "$PACKAGE_DIR/APKBUILD" | sed 's/arch="\(.*\)"/\1/')
if [ "$PKG_ARCH" != "noarch" ] && ! echo "$PKG_ARCH" | grep -qw "$ARCH"; then
    echo "Skipping $PACKAGE: arch $ARCH not in supported architectures ($PKG_ARCH)"
    exit 0
fi

echo "Building $PACKAGE for $ARCH using $CONTAINER_CMD..."

mkdir -p "$REPO_ROOT/dist/$ARCH"

# Use production key if available, otherwise generate dev key
if [ -f "$REPO_ROOT/keys/packages.rsa" ]; then
    KEY_NAME="packages"
else
    KEY_NAME="vellum-dev"
    KEY_PATH="$REPO_ROOT/keys/$KEY_NAME.rsa"
    if [ ! -f "$KEY_PATH" ]; then
        echo "Generating $KEY_NAME signing keypair for build testing..."
        mkdir -p "$REPO_ROOT/keys"
        openssl genrsa -out "$KEY_PATH" 4096 2>/dev/null
        openssl rsa -in "$KEY_PATH" -pubout -out "$KEY_PATH.pub" 2>/dev/null
        chmod 600 "$KEY_PATH"
    fi
fi

# Get reproducible timestamp from git (last commit to this package)
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct -- "$PACKAGE_DIR")
if [ -z "$SOURCE_DATE_EPOCH" ]; then
    SOURCE_DATE_EPOCH=$(stat -c %Y "$PACKAGE_DIR/APKBUILD" 2>/dev/null || stat -f %m "$PACKAGE_DIR/APKBUILD")
fi
echo "Using SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH for reproducible build"

CARCH_ENV="-e CARCH=$ARCH -e SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"

if [ "$CONTAINER_CMD" = "podman" ]; then
    SRC_MOUNT="-v $REPO_ROOT:/work:O"
else
    SRC_MOUNT="-v $REPO_ROOT:/work-src:Z,ro"
fi

$CONTAINER_CMD run --rm \
    $SRC_MOUNT \
    -v "$REPO_ROOT/dist:/work/dist:Z" \
    $CARCH_ENV \
    alpine:3 \
    sh -c '
        set -e

        apk add --no-cache alpine-sdk

        # Docker: copy source to writable /work
        if [ -d /work-src ]; then
            cp -r /work-src/packages /work/
            cp -r /work-src/keys /work/
        fi

        mkdir -p /work/dist/'$ARCH'
        cd /work/packages/'$PACKAGE'

        # Set up signing key
        mkdir -p /root/.abuild
        cp /work/keys/'$KEY_NAME'.rsa /root/.abuild/
        cp /work/keys/'$KEY_NAME'.rsa.pub /root/.abuild/
        echo "PACKAGER_PRIVKEY=/root/.abuild/'$KEY_NAME'.rsa" > /root/.abuild/abuild.conf
        cp /work/keys/'$KEY_NAME'.rsa.pub /etc/apk/keys/

        REPODEST=/work/dist abuild -d -r -F
    '

# Docker: fix ownership so host user can access dist files
if [ "$CONTAINER_CMD" = "docker" ]; then
    $CONTAINER_CMD run --rm \
        -v "$REPO_ROOT/dist:/work/dist:Z" \
        alpine:3 \
        chown -R "$(id -u):$(id -g)" /work/dist
fi

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
