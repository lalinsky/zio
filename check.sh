#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

CI_MODE=false
FILTER=""
TARGET=""
USE_WINE=false
USE_QEMU=false

# Parse arguments
usage() {
  echo "Usage: $0 [--filter \"test name\"] [--target <target>] [--wine] [--qemu] [--ci]"
}
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --filter)
            [[ $# -ge 2 ]] || { echo "--filter requires an argument"; usage; exit 1; }
            FILTER="$2"; shift 2
            ;;
        --target)
            [[ $# -ge 2 ]] || { echo "--target requires an argument"; usage; exit 1; }
            TARGET="$2"; shift 2
            ;;
        --wine)
            USE_WINE=true
            shift
            ;;
        --qemu)
            USE_QEMU=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

echo "=== Formatting code ==="
if [ "$CI_MODE" = true ]; then
    zig fmt --check .
else
    zig fmt .
fi

echo "=== Running unit tests ==="
BUILD_ARGS="test"
if [ -n "$FILTER" ]; then
    echo "Filter: $FILTER"
    BUILD_ARGS="$BUILD_ARGS -Dtest-filter=\"$FILTER\""
fi
if [ -n "$TARGET" ]; then
    echo "Target: $TARGET"
    BUILD_ARGS="$BUILD_ARGS -Dtarget=$TARGET"
fi
if [ "$USE_WINE" = true ]; then
    BUILD_ARGS="$BUILD_ARGS -fwine"
fi
if [ "$USE_QEMU" = true ]; then
    BUILD_ARGS="$BUILD_ARGS -fqemu"
fi
eval timeout 60s zig build $BUILD_ARGS --summary all

echo "=== All checks passed! ==="
