#!/bin/sh
set -e
usage() {
    echo "Usage: $0 [-h|--help] <apkbuild>"
    echo ""
    echo "Run apkbuild-lint on an apkbuild."
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
}
APKBUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    *)
        APKBUILD="$(realpath "$1")"
        shift
        break
        ;;
    esac
done
if [ -z "$APKBUILD" ] || [ $# -gt 0 ]; then
    usage
    exit 1
fi
if [ ! -f "$APKBUILD" ];then
    echo "$APKBUILD does not exist" >&2
    exit 1
fi
pkg_path=$(dirname "$APKBUILD")
if command -v apkbuild-lint >/dev/null 2>&1; then
    SKIP_AL8=1 SKIP_AL7=1 SKIP_AL28=1 apkbuild-lint "$pkg_path/APKBUILD" 2>&1
elif command -v podman >/dev/null 2>&1; then
    podman run --rm \
        -v "$pkg_path:/src:ro" \
        -w "/src" \
        ghcr.io/eeems/vbuild-builder:main \
        sh -c "SKIP_AL8=1 SKIP_AL7=1 SKIP_AL28=1 apkbuild-lint APKBUILD" 2>&1
elif command -v docker >/dev/null 2>&1; then
    docker run --rm \
        -v "$pkg_path:/src:ro" \
        -w "/src" \
        ghcr.io/eeems/vbuild-builder:main \
        sh -c "SKIP_AL8=1 SKIP_AL7=1 SKIP_AL28=1 apkbuild-lint APKBUILD" 2>&1
else
    echo "  (apkbuild-lint skipped - install atools, podman, or docker)"
    return 0
fi
