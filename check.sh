#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Default values
CI_MODE=false
FULL_MODE=false
VERBOSE=false
RELEASE_MODE=false
TEST_FILTER=""
TARGET=""
BACKEND=""
USE_WINE=false
USE_QEMU=false
NO_EXEC=false

# Parse arguments
usage() {
  echo "Usage: $0 [--filter \"test name\"] [--target <target>] [--backend <backend>] [--wine] [--qemu] [--no-exec] [--ci] [--full] [--release] [--verbose]"
}
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --filter)
            [[ $# -ge 2 ]] || { echo "--filter requires an argument"; usage; exit 1; }
            TEST_FILTER="$2"; shift 2
            ;;
        --target)
            [[ $# -ge 2 ]] || { echo "--target requires an argument"; usage; exit 1; }
            TARGET="$2"; shift 2
            ;;
        --backend)
            [[ $# -ge 2 ]] || { echo "--backend requires an argument"; usage; exit 1; }
            BACKEND="$2"; shift 2
            ;;
        --wine)
            USE_WINE=true
            shift
            ;;
        --qemu)
            USE_QEMU=true
            shift
            ;;
        --no-exec)
            NO_EXEC=true
            shift
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        --full)
            FULL_MODE=true
            shift
            ;;
        --release)
            RELEASE_MODE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
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
    echo "Checking formatting (CI mode)..."
    zig fmt --check .
else
    echo "Formatting code..."
    zig fmt .
fi

echo "=== Running unit tests ==="
BUILD_ARGS="test"
if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    BUILD_ARGS="$BUILD_ARGS -Dtest-filter=\"$TEST_FILTER\""
fi
if [ -n "$TARGET" ]; then
    echo "Target: $TARGET"
    BUILD_ARGS="$BUILD_ARGS -Dtarget=$TARGET"
fi
if [ -n "$BACKEND" ]; then
    echo "Backend: $BACKEND"
    BUILD_ARGS="$BUILD_ARGS -Dbackend=$BACKEND"
fi
if [ "$USE_WINE" = true ]; then
    BUILD_ARGS="$BUILD_ARGS -fwine"
fi
if [ "$USE_QEMU" = true ]; then
    BUILD_ARGS="$BUILD_ARGS -fqemu"
fi
if [ "$NO_EXEC" = true ]; then
    BUILD_ARGS="$BUILD_ARGS -Demit-test-bin"
fi
if [ "$RELEASE_MODE" = true ]; then
    echo "Build mode: ReleaseFast"
    BUILD_ARGS="$BUILD_ARGS -Doptimize=ReleaseFast"
fi
if [ "$VERBOSE" = true ]; then
    export TEST_VERBOSE=true
fi
eval zig build $BUILD_ARGS --summary all

if [ "$FULL_MODE" = true ]; then
    echo "=== Building examples ==="
    zig build examples

    echo "=== Building benchmarks ==="
    zig build benchmarks
fi

echo "=== All checks passed! ==="
