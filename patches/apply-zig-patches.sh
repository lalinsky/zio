#!/bin/bash
set -e

# Apply patches to Zig standard library for known issues

# Get absolute path to patch directory
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get Zig version and lib directory
ZIG_VERSION=$(zig version)
ZIG_LIB_DIR=$(zig env | grep 'lib_dir' | sed 's/.*"\([^"]*\)".*/\1/')

echo "Zig version: $ZIG_VERSION"
echo "Zig lib dir: $ZIG_LIB_DIR"

# Apply LoongArch64 frame pointer offset patch for Zig 0.15.x
# This fixes infinite loop in stack unwinding on loongarch64
# Fixed in Zig 0.16+, so only apply to 0.15.x
if [[ "$ZIG_VERSION" == 0.15.* ]]; then
    DEBUG_ZIG="$ZIG_LIB_DIR/std/debug.zig"

    # Check if patch is already applied
    if grep -q "native_arch.isRISCV() or native_arch.isLoongArch()" "$DEBUG_ZIG" 2>/dev/null; then
        echo "LoongArch64 fp_offset patch already applied, skipping"
    else
        echo "Applying LoongArch64 fp_offset patch to Zig 0.15.x stdlib..."

        # Apply the patch
        cd "$ZIG_LIB_DIR/.."
        patch -p1 < "$PATCH_DIR/zig-0.15-loongarch64-fp-offset.patch"

        echo "Patch applied successfully"
    fi
else
    echo "Zig version is not 0.15.x, patch not needed (fixed in 0.16+)"
fi
