# stdx - std.Io Backport for Zig 0.15

This directory contains a backport of `std.Io` from Zig 0.16 (dev) to Zig 0.15, packaged as the `stdx` module.

## Purpose

The `std.Io` interface was introduced in Zig 0.16 as a new async I/O abstraction. This backport allows zio to implement the `std.Io` VTable on Zig 0.15, providing forward compatibility.

## Structure

- **`src/`** - Backported std.Io implementation files
  - `Io.zig` - Core std.Io interface (modified for 0.15 compatibility)
  - `Io/Dir.zig`, `Io/File.zig`, `Io/net.zig` - I/O abstractions (import fixes only)
  - Only includes minimal set of files needed for the VTable interface
- **`build.zig`** - Standalone build configuration for the stdx module
- **`build.zig.zon`** - Package metadata

## Modifications from Upstream

The following changes were made to adapt std.Io for Zig 0.15:

1. **Builtin compatibility**: Replaced Zig 0.16 builtins (`@Struct`, `@Union`) with Zig 0.15 `@Type()` API
2. **Standard library re-exports**: Use `std.Io.Reader`, `std.Io.Writer`, `std.Io.Limit`, `std.Io.tty` from Zig 0.15 stdlib instead of duplicating them
3. **Import fixes**: Changed imports to use local `Io.zig` instead of `std.Io`
4. **Removed files**: Deleted implementation files (IoUring, Kqueue, Threaded, Reader, Writer, test files) that aren't needed for the VTable interface

## Git Subtree Workflow

This backport uses a pseudo-subtree workflow to track upstream changes:

### Branch Structure

- **`std-io-upstream`**: Orphan branch containing pristine upstream files from `ziglang/zig`
  - Tracks files from `lib/std/Io.zig` and `lib/std/Io/` in the Zig repository
  - Each commit references the upstream Zig commit hash

### Updating from Upstream

To update when new Zig changes are available:

```bash
# 1. Update the Zig repository
cd /path/to/zig
git checkout master
git pull

# 2. Update std-io-upstream branch
cd /path/to/zio
git checkout std-io-upstream
rm -rf src/compat/std/src/
mkdir -p src/compat/std/src
cp /path/to/zig/lib/std/Io.zig src/compat/std/src/
cp -r /path/to/zig/lib/std/Io src/compat/std/src/
git add src/compat/std/src/
git commit -m "Update std.Io from upstream Zig

Source: ziglang/zig@<commit-hash>"

# 3. Merge into main and resolve conflicts
git checkout main
git merge std-io-upstream
# Resolve any conflicts (typically Threaded.zig deletion)
# Re-apply/verify modifications if needed
./check.sh  # Verify everything still works
```
