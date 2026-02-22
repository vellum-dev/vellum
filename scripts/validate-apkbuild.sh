#!/bin/sh
set -e

APKBUILD_PATH="$1"
ERRORS=""
WARNINGS=""

if [ -z "$APKBUILD_PATH" ]; then
    echo "Usage: $0 <path/to/APKBUILD>"
    exit 1
fi

if [ ! -f "$APKBUILD_PATH" ]; then
    echo "Error: $APKBUILD_PATH not found"
    exit 1
fi

add_error() {
    ERRORS="${ERRORS}  - $1\n"
}

add_warning() {
    WARNINGS="${WARNINGS}  - $1\n"
}

pkgname=""
pkgdesc=""
_upstream_author=""
_category=""
license=""

eval "$(grep -E '^(pkgname|pkgdesc|_upstream_author|_category|license)=' "$APKBUILD_PATH")"

if [ -z "$_upstream_author" ]; then
    add_error "_upstream_author is not set"
fi

if [ -z "$_category" ]; then
    add_error "_category is not set"
else
    valid_categories="ui fixes utilities apps framework"
    for cat in $_category; do
        if ! echo "$valid_categories" | grep -qw "$cat"; then
            add_error "_category contains invalid value '$cat' (valid: $valid_categories)"
        fi
    done
fi

if [ -z "$license" ]; then
    add_error "license is not set"
fi

pkgdesc_len=${#pkgdesc}
if [ "$pkgdesc_len" -ge 128 ]; then
    add_error "pkgdesc is too long ($pkgdesc_len chars, must be <128)"
fi

if grep -q '^# Maintainer:' "$APKBUILD_PATH"; then
    add_error "uses '# Maintainer:' comment instead of 'maintainer=' variable"
fi

if ! grep -q '^maintainer=' "$APKBUILD_PATH"; then
    add_error "maintainer variable is not set"
fi

if [ -n "$ERRORS" ]; then
    echo "FAIL: $pkgname"
    printf "%b" "$ERRORS"
    if [ -n "$WARNINGS" ]; then
        echo "  Warnings:"
        printf "%b" "$WARNINGS"
    fi
    exit 1
fi

if [ -n "$WARNINGS" ]; then
    echo "PASS: $pkgname (with warnings)"
    printf "%b" "$WARNINGS"
    exit 0
fi

echo "PASS: $pkgname"
exit 0
