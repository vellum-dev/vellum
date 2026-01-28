#!/bin/sh
set -e

ENTWARE_DATA="/home/root/.entware"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
VELLUM_BIN="/home/root/.vellum/bin"

unset LD_LIBRARY_PATH LD_PRELOAD

cleanup() {
    echo "Error occurred. Cleaning up..."
    cd /home/root
    if mountpoint -q /opt 2>/dev/null; then
        umount /opt || true
    fi
    [ -d /opt ] && rmdir /opt 2>/dev/null || true
    [ -f /etc/systemd/system/opt.mount ] && rm -f /etc/systemd/system/opt.mount
    systemctl daemon-reload 2>/dev/null || true
    exit 1
}

linker_name() {
    case "$(uname -m)" in
        aarch64) echo "ld-linux-aarch64.so.1" ;;
        armv7l)  echo "ld-linux.so.3" ;;
        *)
            echo "Unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
}

install_entware() {
    trap cleanup ERR

    if ! [ -d "$ENTWARE_DATA" ]; then
        local available_mb
        available_mb=$(df -Pm /home/root | tail -1 | awk '{print $4}')
        if [ "$available_mb" -lt 50 ]; then
            echo "Error: Not enough free space on /home/root."
            echo "Available: ${available_mb}MB, Required: 50MB minimum."
            exit 1
        fi
    fi

    "$VELLUM_BIN/mount-rw"

    if [ -d "$ENTWARE_DATA" ] && [ "$(ls -A "$ENTWARE_DATA" 2>/dev/null)" ]; then
        echo "Reinstalling Entware (existing packages will be preserved)..."
    fi

    mkdir -p /opt
    mkdir -p "$ENTWARE_DATA"

    if ! mountpoint -q /opt 2>/dev/null; then
        mount --bind "$ENTWARE_DATA" /opt
    fi

    cat > /etc/systemd/system/opt.mount << 'EOF'
[Unit]
Description=Entware's bind mount over /opt
DefaultDependencies=no
Conflicts=umount.target
After=home.mount
Requires=home.mount
BindsTo=home.mount

[Mount]
What=/home/root/.entware
Where=/opt
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable opt.mount

    for folder in bin etc lib lib/opkg tmp var/lock; do
        mkdir -p "/opt/$folder"
    done

    echo "Installing bundled Entware components..."
    cp "$SCRIPT_DIR/bin/opkg" /opt/bin/opkg
    chmod 755 /opt/bin/opkg
    cp "$SCRIPT_DIR/opkg.conf" /opt/etc/opkg.conf
    cp "$SCRIPT_DIR/lib/ld-2.27.so" /opt/lib/
    cp "$SCRIPT_DIR/lib/libc-2.27.so" /opt/lib/
    cp "$SCRIPT_DIR/lib/libgcc_s.so.1" /opt/lib/
    cp "$SCRIPT_DIR/lib/libpthread-2.27.so" /opt/lib/

    cd /opt/lib
    chmod 755 ld-2.27.so
    ln -sf ld-2.27.so "$(linker_name)"
    ln -sf libc-2.27.so libc.so.6
    ln -sf libpthread-2.27.so libpthread.so.0

    echo "Installing base Entware packages..."
    /opt/bin/opkg update
    /opt/bin/opkg install entware-opt
    /opt/bin/opkg install wget wget-ssl ca-certificates

    if [ -f /opt/libexec/wget-ssl ]; then
        rm -f /opt/bin/wget
        ln -sf /opt/libexec/wget-ssl /opt/bin/wget
    elif [ -f /opt/bin/wget-ssl ]; then
        rm -f /opt/bin/wget
        ln -sf /opt/bin/wget-ssl /opt/bin/wget
    fi

    sed -i 's|http://|https://|g' /opt/etc/opkg.conf
    chmod 777 /opt/tmp

    for file in passwd group shells shadow gshadow localtime; do
        if [ -f "/etc/$file" ]; then
            ln -sf "/etc/$file" "/opt/etc/$file"
        fi
    done

    trap - ERR

    "$VELLUM_BIN/mount-restore"

    echo "Entware installation complete."
}

install_entware "$@"
