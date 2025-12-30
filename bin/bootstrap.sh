#!/bin/sh
set -e

VELLUM_ROOT="/home/root/.vellum"
VELLUM_REPO="https://raw.githubusercontent.com/rmitchellscott/vellum/main"
VELLUM_APK_RELEASES="https://github.com/rmitchellscott/vellum-apk/releases/latest/download"

echo "Installing vellum..."

ARCH=$(uname -m)
case "$ARCH" in
    aarch64) APK_ARCH="aarch64" ;;
    armv7l)  APK_ARCH="armv7" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p "$VELLUM_ROOT"/{bin,etc/apk/keys,lib/apk/db,share/bash-completion/completions,state,local-repo,cache}

echo "Downloading apk.vellum..."
wget -q "$VELLUM_APK_RELEASES/apk-$APK_ARCH" -O "$VELLUM_ROOT/bin/apk.vellum"
chmod +x "$VELLUM_ROOT/bin/apk.vellum"

echo "Downloading vellum..."
mv /tmp/vellum "$VELLUM_ROOT/bin/vellum"
# wget -q "$VELLUM_REPO/bin/vellum" -O "$VELLUM_ROOT/bin/vellum"
chmod +x "$VELLUM_ROOT/bin/vellum"

echo "Downloading signing key..."
mv /tmp/packages.rsa.pub "$VELLUM_ROOT/etc/apk/keys/packages.rsa.pub"
# wget -q "$VELLUM_REPO/keys/packages.rsa.pub" -O "$VELLUM_ROOT/etc/apk/keys/packages.rsa.pub"

echo "Generating local signing key..."
if [ ! -f "$VELLUM_ROOT/etc/apk/keys/local.rsa" ]; then
    openssl genrsa -out "$VELLUM_ROOT/etc/apk/keys/local.rsa" 2048 2>/dev/null
    openssl rsa -in "$VELLUM_ROOT/etc/apk/keys/local.rsa" -pubout -out "$VELLUM_ROOT/etc/apk/keys/local.rsa.pub" 2>/dev/null
fi

echo "Configuring repositories..."
cat > "$VELLUM_ROOT/etc/apk/repositories" <<EOF
/home/root/.vellum/local-repo
https://packages.vellum.delivery
EOF

echo "Initializing local repository..."
mkdir -p "$VELLUM_ROOT/local-repo/$APK_ARCH"
(cd "$VELLUM_ROOT/local-repo/$APK_ARCH" && touch APKINDEX && tar -czf APKINDEX.tar.gz APKINDEX && rm APKINDEX)

echo "Initializing apk database..."
"$VELLUM_ROOT/bin/apk.vellum" \
    --root "$VELLUM_ROOT" \
    --dest / \
    --no-logfile \
    add --initdb

echo "Updating package index..."
"$VELLUM_ROOT/bin/vellum" update

echo "Installing bash completion..."
"$VELLUM_ROOT/bin/vellum" add vellum-bash-completion

BASHRC="/home/root/.bashrc"
PATH_LINE="export PATH=\"$VELLUM_ROOT/bin:\$PATH\""
COMPLETION_LINE="[ -f \"$VELLUM_ROOT/share/bash-completion/completions/vellum\" ] && . \"$VELLUM_ROOT/share/bash-completion/completions/vellum\""

if [ -f "$BASHRC" ] && grep -qF ".vellum/bin" "$BASHRC"; then
    echo "PATH already configured in $BASHRC"
else
    echo "" >> "$BASHRC"
    echo "$PATH_LINE" >> "$BASHRC"
    echo "$COMPLETION_LINE" >> "$BASHRC"
    echo "Added vellum to PATH and completions in $BASHRC"
fi

echo ""
echo "Vellum installed successfully!"
echo "Run 'source ~/.bashrc' or start a new shell to use vellum."
