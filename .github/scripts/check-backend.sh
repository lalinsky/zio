#!/bin/bash
# Builds and tests one backend of a CI matrix job, configured by the job's
# environment (BACKEND, MODE, TARGET, QEMU, VM).
#
# `check.sh --full` builds the examples for the host in debug mode, whatever
# the job's mode and target, so only the native debug jobs pass it.

set -euo pipefail

args=(--backend "$BACKEND")
if [ "$TARGET" != native ]; then args+=(--target "$TARGET"); fi
if [ "$QEMU" = true ]; then args+=(--qemu); fi
if [ -n "$VM" ]; then args+=(--no-exec); fi
if [ "$MODE" = release ]; then args+=(--release); fi
if [ "$MODE" = debug ] && [ "$TARGET" = native ]; then args+=(--full); fi

./check.sh "${args[@]}"

# The VM steps run every backend's binary after the builds.
if [ -n "$VM" ]; then cp zig-out/bin/test "zig-out/bin/test-$BACKEND"; fi
