#!/bin/sh
set -e

VELLUM_ROOT="/home/root/.vellum"
VELLUM_REPO="https://raw.githubusercontent.com/rmitchellscott/vellum/main"
APK_VERSION="3.0.3-r1"

echo "Installing vellum..."

ARCH=$(uname -m)
case "$ARCH" in
    aarch64) APK_ARCH="aarch64" ;;
    armv7l)  APK_ARCH="armv7" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p "$VELLUM_ROOT"/{bin,etc/apk/keys,state,local-repo,cache,lib/apk/db}

echo "Downloading apk.static..."
APK_URL="https://dl-cdn.alpinelinux.org/alpine/edge/main/$APK_ARCH/apk-tools-static-$APK_VERSION.apk"
cd /tmp
wget -q "$APK_URL" -O apk-tools-static.apk
tar -xzf apk-tools-static.apk sbin/apk.static
mv sbin/apk.static "$VELLUM_ROOT/bin/"
chmod +x "$VELLUM_ROOT/bin/apk.static"
rm -rf apk-tools-static.apk sbin

echo "Downloading vellum..."
wget -q "$VELLUM_REPO/bin/vellum" -O "$VELLUM_ROOT/bin/vellum"
chmod +x "$VELLUM_ROOT/bin/vellum"

echo "Downloading signing key..."
wget -q "$VELLUM_REPO/keys/packages.rsa.pub" -O "$VELLUM_ROOT/etc/apk/keys/packages.rsa.pub"

echo "Configuring repositories..."
cat > "$VELLUM_ROOT/etc/apk/repositories" <<EOF
/home/root/.vellum/local-repo
https://packages.vellum.delivery
EOF

echo "Initializing apk database..."
"$VELLUM_ROOT/bin/apk.static" \
    --root "$VELLUM_ROOT" \
    --keys-dir "$VELLUM_ROOT/etc/apk/keys" \
    --repositories-file "$VELLUM_ROOT/etc/apk/repositories" \
    add --initdb

echo "Updating package index..."
"$VELLUM_ROOT/bin/vellum" update

BASHRC="/home/root/.bashrc"
PATH_LINE="export PATH=\"$VELLUM_ROOT/bin:\$PATH\""

if [ -f "$BASHRC" ] && grep -qF ".vellum/bin" "$BASHRC"; then
    echo "PATH already configured in $BASHRC"
else
    echo "" >> "$BASHRC"
    echo "$PATH_LINE" >> "$BASHRC"
    echo "Added vellum to PATH in $BASHRC"
fi

echo ""
echo "Vellum installed successfully!"
echo "Run 'source ~/.bashrc' or start a new shell to use vellum."
