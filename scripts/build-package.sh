#!/bin/sh
# Build a single package using vbuild
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

if ! command -v vbuild >/dev/null 2>&1; then
    echo "Error: vbuild not found"
    exit 1
fi

if [ -z "$ARCH" ]; then
    if grep -q '^arch="noarch"' "$PACKAGE_DIR/VELBUILD"; then
        ARCH="noarch"
    else
        ARCH="aarch64"
    fi
fi

# Skip if the requested arch isn't supported by this package
PKG_ARCH=$(grep '^arch=' "$PACKAGE_DIR/VELBUILD" | sed 's/arch="\(.*\)"/\1/')
if [ "$PKG_ARCH" != "noarch" ] && ! echo "$PKG_ARCH" | grep -qw "$ARCH"; then
    echo "Skipping $PACKAGE: arch $ARCH not in supported architectures ($PKG_ARCH)"
    exit 0
fi

echo "Building $PACKAGE for $ARCH..."

mkdir -p "$REPO_ROOT/dist/$ARCH"

# Use production key if available, otherwise generate dev key
if [ -f "$REPO_ROOT/keys/packages.rsa" ]; then
    KEY_NAME=packages
    KEY_PATH="$REPO_ROOT/keys/packages.rsa"
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
mkdir -p ~/.config/vbuild
cp "$KEY_PATH" ~/.config/vbuild/"$KEY_NAME".rsa
cp "$KEY_PATH.pub" ~/.config/vbuild/"$KEY_NAME".rsa.pub

# Get reproducible timestamp from git (last commit to this package)
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct -- "$PACKAGE_DIR")
if [ -z "$SOURCE_DATE_EPOCH" ]; then
    SOURCE_DATE_EPOCH=$(stat -c %Y "$PACKAGE_DIR/VELBUILD" 2>/dev/null || stat -f %m "$PACKAGE_DIR/VELBUILD")
fi
echo "Using SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH for reproducible build"
set +e
WORK_DIR=$(mktemp -d)
ret=$?
if [ $ret -ne 0 ]; then
    echo "Failed to create working directory"
    exit $ret
fi
set -e
echo "Working directory $WORK_DIR"
cp -r "$REPO_ROOT/packages/$PACKAGE/." "$WORK_DIR"
VBUILD_KEY_NAME=$KEY_NAME CARCH=$ARCH vbuild -C "$WORK_DIR" all
cp -r "$WORK_DIR/dist/." "$REPO_ROOT/dist/"
vbuild -C "$WORK_DIR" clean
rm -rf "$WORK_DIR"

echo "Build complete."
ls -la "$REPO_ROOT/dist/"*/*.apk 2>/dev/null || echo "No .apk files found"
