#!/bin/bash
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
    echo "Lint VELBUILD files for vellum packages."
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
        PACKAGES="$PACKAGES $1"
        shift
        ;;
    esac
done

if [ -z "$PACKAGES" ]; then
    if [ -n "$CHANGED_REF" ]; then
        PACKAGES=$(git diff --name-only "$CHANGED_REF" -- packages/ 2>/dev/null |
            grep "^packages/" |
            cut -d/ -f2 |
            sort -u)
        if [ -z "$PACKAGES" ]; then
            echo "No packages changed since $CHANGED_REF"
            exit 0
        fi
    else
        PACKAGES=$(ls -d "$REPO_ROOT"/packages/*/VELBUILD 2>/dev/null | xargs -I{} dirname {} | xargs -I{} basename {})
    fi
fi

PACKAGES="$(echo "$PACKAGES" | xargs -n1)"

if [ "$RUN_APKBUILD_LINT" = "true" ]; then
    echo "Generating APKBUILD..."
    echo ""
    if ! command -v vbuild >/dev/null 2>&1; then
        echo "Error: vbuild not found"
        exit 1
    fi
    set +e
    work_dir=$(mktemp -d)
    ret=$?
    trap 'rm -rf $work_dir' EXIT
    if [ $ret -ne 0 ]; then
        echo "Fatal Error: Failed to create working directory" 2>&1
        exit $ret
    fi
    set -e
    cpus=$(nproc)
    echo "$PACKAGES" |
        xargs -P "$((cpus * 2))" -I {} \
            bash -c "cp -r '$REPO_ROOT/packages/{}' '$work_dir' && vbuild -C '$work_dir/{}' gen"
fi

echo "Linting packages..."
echo ""

if [ "$RUN_APKBUILD_LINT" = "true" ]; then
    set +e
    lint_tmp=$(mktemp -d)
    ret=$?
    trap 'rm -rf $lint_tmp' EXIT
    if [ $ret -ne 0 ]; then
        echo "Fatal Error: Failed to create lint output directory" 2>&1
        exit $ret
    fi
    set -e
    cpus=$(nproc)
    echo "$PACKAGES" | \
        xargs -P "$((cpus * 2))" -I {} \
            sh -c '
                pkg=$1
                tmp=$2
                script_dir=$3
                work_dir=$4
                "$script_dir/apkbuild-lint.sh" "$work_dir/$pkg/APKBUILD" >"$tmp/$pkg.out" 2>&1
                printf "%s\n" "$?" >"$tmp/$pkg.status"
            ' _ {} "$lint_tmp" "$SCRIPT_DIR" "$work_dir"
    declare -A lint_status
    declare -A lint_output
    for pkg in $PACKAGES; do
        if [ -f "$lint_tmp/$pkg.status" ]; then
            lint_status[$pkg]=$(cat "$lint_tmp/$pkg.status")
        else
            lint_status[$pkg]=0
        fi
        if [ -f "$lint_tmp/$pkg.out" ]; then
            lint_output[$pkg]=$(cat "$lint_tmp/$pkg.out")
        else
            lint_output[$pkg]=""
        fi
    done
fi

for pkg in $PACKAGES; do
    VELBUILD_PATH="$REPO_ROOT/packages/$pkg/VELBUILD"

    if [ ! -f "$VELBUILD_PATH" ]; then
        printf "${RED}SKIP${NC}: %s (VELBUILD not found)\n" "$pkg"
        continue
    fi

    pkg_status="pass"
    pkg_warned=false
    validate_output=""
    lint_result=""

    status=0
    result=$("$SCRIPT_DIR/validate-velbuild.sh" "$VELBUILD_PATH" 2>&1) || status=$?

    if [ $status -ne 0 ]; then
        validate_output=$(echo "$result" | grep -v "^FAIL:" | sed 's/^/  /')
        pkg_status="fail"
    elif echo "$result" | grep -q "with warnings"; then
        validate_output=$(echo "$result" | grep -v "^PASS:" | sed 's/^/  /')
        pkg_warned=true
    fi

    if [ "$RUN_APKBUILD_LINT" = "true" ]; then
        lint_rc="${lint_status[$pkg]:-0}"
        lint_result="${lint_output[$pkg]:-}"
        if [ "$lint_rc" -ne 0 ]; then
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
    if [ -n "$lint_result" ]; then
        echo "  apkbuild-lint:"
        echo "$lint_result" | sed 's/^/    /'
    fi
done

echo ""
echo "Summary: $PASSED passed, $WARNED warnings, $FAILED failed"

if [ "$RUN_APKBUILD_LINT" = "true" ]; then
    rm -r "$work_dir"
fi

if [ $FAILED -gt 0 ]; then
    exit 1
fi

exit 0
