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
SCHEDULING=""
USE_WINE=false
USE_QEMU=false
NO_EXEC=false
COVERAGE=false
TIMEOUT=""

# Parse arguments
usage() {
  echo "Usage: $0 [--filter \"test name\"] [--target <target>] [--backend <backend>] [--scheduling <mode>] [--wine] [--qemu] [--no-exec] [--coverage] [--ci] [--full] [--release] [--verbose] [--timeout <seconds>]"
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
        --scheduling)
            [[ $# -ge 2 ]] || { echo "--scheduling requires an argument"; usage; exit 1; }
            SCHEDULING="$2"; shift 2
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
        --coverage)
            COVERAGE=true
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
        --timeout)
            [[ $# -ge 2 ]] || { echo "--timeout requires an argument"; usage; exit 1; }
            TIMEOUT="$2"; shift 2
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
BUILD_ARGS=(test)
if [ -n "$TEST_FILTER" ]; then
    echo "Filter: $TEST_FILTER"
    BUILD_ARGS+=("-Dtest-filter=$TEST_FILTER")
fi
if [ -n "$TARGET" ]; then
    echo "Target: $TARGET"
    BUILD_ARGS+=("-Dtarget=$TARGET")
fi
if [ -n "$SCHEDULING" ]; then
    echo "Scheduling: $SCHEDULING"
    BUILD_ARGS+=("-Dscheduling=$SCHEDULING")
fi

if [ -n "$BACKEND" ]; then
    echo "Backend: $BACKEND"
    BUILD_ARGS+=("-Dbackend=$BACKEND")
fi
if [ "$USE_WINE" = true ]; then
    BUILD_ARGS+=(-Demit-test-bin)
fi
if [ "$USE_QEMU" = true ]; then
    BUILD_ARGS+=(-fqemu)
fi
if [ "$NO_EXEC" = true ] || [ "$COVERAGE" = true ]; then
    BUILD_ARGS+=(-Demit-test-bin)
fi
if [ "$RELEASE_MODE" = true ]; then
    echo "Build mode: ReleaseSafe"
    BUILD_ARGS+=(-Doptimize=ReleaseSafe)
fi
if [ "$VERBOSE" = true ]; then
    export TEST_VERBOSE=true
fi
if [ -n "$TIMEOUT" ]; then
    timeout "$TIMEOUT" zig build "${BUILD_ARGS[@]}" --summary all
else
    zig build "${BUILD_ARGS[@]}" --summary all
fi

if [ "$USE_WINE" = true ]; then
    echo "=== Running tests with Wine ==="
    wine zig-out/bin/test.exe
fi

if [ "$COVERAGE" = true ]; then
    echo "=== Running coverage ==="
    rm -rf zig-out/coverage
    kcov --include-pattern=src/ zig-out/coverage/ zig-out/bin/test
    echo "Coverage report: zig-out/coverage/index.html"
fi

if [ "$FULL_MODE" = true ]; then
    echo "=== Building examples ==="
    zig build examples

    # Run the stderr locking smoke test on native targets. It exercises the
    # debug_io lockStderr path, which the unit-test runner never installs:
    # logging from tasks, threads and pool workers, a task holding the lock
    # across a suspension, and a panic while a task holds it. Tag presence only
    # proves the call returned, so the ordering property is asserted in-process
    # and reported as "smoke: order ok" -- required below.
    if [ "$NO_EXEC" = false ] && [ "$USE_QEMU" = false ] && [ "$USE_WINE" = false ] && [ -z "$TARGET" ]; then
        echo "=== Running stderr smoke test ==="
        SMOKE=zig-out/bin/stderr-smoke
        [ -f "$SMOKE" ] || SMOKE=zig-out/bin/stderr-smoke.exe
        SMOKE_OUT=$("$SMOKE" 2>&1) || { echo "$SMOKE_OUT"; echo "stderr smoke test exited with an error"; exit 1; }
        for tag in "smoke: main task" "smoke: task 0" "smoke: task 1" "smoke: task 2" "smoke: task 3" \
                   "smoke: foreign thread" "smoke: pool worker" \
                   "smoke: holder before sleep" "smoke: holder after sleep" \
                   "smoke: waited for user lock" "smoke: order ok" "smoke: done"; do
            if ! grep -qF "$tag" <<< "$SMOKE_OUT"; then
                echo "$SMOKE_OUT"
                echo "stderr smoke test: missing output: $tag"
                exit 1
            fi
        done
        PANIC_OUT=$("$SMOKE" --panic 2>&1) && { echo "$PANIC_OUT"; echo "stderr smoke test: --panic did not abort"; exit 1; }
        for tag in "smoke: panicking while holding stderr" "stderr smoke panic"; do
            if ! grep -qF "$tag" <<< "$PANIC_OUT"; then
                echo "$PANIC_OUT"
                echo "stderr smoke test: missing panic output: $tag"
                exit 1
            fi
        done
    fi
fi

echo "=== All checks passed! ==="
