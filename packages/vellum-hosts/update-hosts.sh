#!/bin/sh
set -e

HOSTS_FILE="/etc/hosts"
HOSTNAME="packages.vellum.delivery"
MARKER="# vellum-hosts"

IP1="172.67.203.137"
IP2="104.21.77.19"

remove_entries() {
    if grep -q "$MARKER" "$HOSTS_FILE" 2>/dev/null; then
        sed -i "/$MARKER/d" "$HOSTS_FILE"
    fi
}

add_entries() {
    remove_entries
    echo "$IP1 $HOSTNAME $MARKER" >> "$HOSTS_FILE"
    echo "$IP2 $HOSTNAME $MARKER" >> "$HOSTS_FILE"
}

case "$1" in
    add)
        add_entries
        echo "Added $HOSTNAME entries to $HOSTS_FILE"
        ;;
    remove)
        remove_entries
        echo "Removed $HOSTNAME entries from $HOSTS_FILE"
        ;;
    *)
        echo "Usage: $0 {add|remove}" >&2
        exit 1
        ;;
esac
