#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PACKAGES=""
RUN_APKBUILD_LINT="${RUN_APKBUILD_LINT:-false}"
CHANGED_REF=""
FAILED=0
PASSED=0
WARNED=0

usage() {
    echo "Usage: $0 [OPTIONS] [PACKAGE...]"
    echo ""
    echo "Lint APKBUILD files for vellum packages."
    echo ""
    echo "Options:"
    echo "  --apkbuild-lint    Also run apkbuild-lint (requires Docker or atools)"
    echo "  --changed [REF]    Only lint packages changed since REF (default: origin/main)"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "If no packages specified, lints all packages in packages/"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --apkbuild-lint)
            RUN_APKBUILD_LINT=true
            shift
            ;;
        --changed)
            shift
            if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
                CHANGED_REF="$1"
                shift
            else
                CHANGED_REF="origin/main"
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            PACKAGES="$PACKAGES $1"
            shift
            ;;
    esac
done

if [ -z "$PACKAGES" ]; then
    if [ -n "$CHANGED_REF" ]; then
        PACKAGES=$(git diff --name-only "$CHANGED_REF" -- packages/ 2>/dev/null | \
            grep "^packages/" | \
            cut -d/ -f2 | \
            sort -u)
        if [ -z "$PACKAGES" ]; then
            echo "No packages changed since $CHANGED_REF"
            exit 0
        fi
    else
        PACKAGES=$(ls -d "$REPO_ROOT"/packages/*/APKBUILD 2>/dev/null | xargs -I{} dirname {} | xargs -I{} basename {})
    fi
fi

run_apkbuild_lint() {
    local pkg_path="$1"
    local pkg_name="$2"

    if command -v apkbuild-lint >/dev/null 2>&1; then
        apkbuild-lint "$pkg_path" 2>&1
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm \
            -v "$REPO_ROOT:/repo:ro" \
            -w "/repo/packages/$pkg_name" \
            alpine:edge \
            sh -c "apk add --no-cache atools >/dev/null 2>&1 && apkbuild-lint APKBUILD" 2>&1
    else
        echo "  (apkbuild-lint skipped - install atools or Docker)"
        return 0
    fi
}

echo "Linting packages..."
echo ""

for pkg in $PACKAGES; do
    APKBUILD_PATH="$REPO_ROOT/packages/$pkg/APKBUILD"

    if [ ! -f "$APKBUILD_PATH" ]; then
        printf "${RED}SKIP${NC}: %s (APKBUILD not found)\n" "$pkg"
        continue
    fi

    pkg_status="pass"
    pkg_warned=false
    validate_output=""
    lint_output=""

    status=0
    result=$("$SCRIPT_DIR/validate-apkbuild.sh" "$APKBUILD_PATH" 2>&1) || status=$?

    if [ $status -ne 0 ]; then
        validate_output=$(echo "$result" | grep -v "^FAIL:" | sed 's/^/  /')
        pkg_status="fail"
    elif echo "$result" | grep -q "with warnings"; then
        validate_output=$(echo "$result" | grep -v "^PASS:" | sed 's/^/  /')
        pkg_warned=true
    fi

    if [ "$RUN_APKBUILD_LINT" = "true" ]; then
        lint_status=0
        lint_output=$(run_apkbuild_lint "$APKBUILD_PATH" "$pkg") || lint_status=$?
        if [ $lint_status -ne 0 ]; then
            pkg_status="fail"
        fi
    fi

    case "$pkg_status" in
        fail)
            printf "${RED}FAIL${NC}: %s\n" "$pkg"
            FAILED=$((FAILED + 1))
            ;;
        *)
            if [ "$pkg_warned" = true ]; then
                printf "${YELLOW}WARN${NC}: %s\n" "$pkg"
                WARNED=$((WARNED + 1))
            else
                printf "${GREEN}PASS${NC}: %s\n" "$pkg"
                PASSED=$((PASSED + 1))
            fi
            ;;
    esac

    [ -n "$validate_output" ] && echo "$validate_output"
    if [ -n "$lint_output" ]; then
        echo "  apkbuild-lint:"
        echo "$lint_output" | sed 's/^/    /'
    fi
done

echo ""
echo "Summary: $PASSED passed, $WARNED warnings, $FAILED failed"

if [ $FAILED -gt 0 ]; then
    exit 1
fi

exit 0
