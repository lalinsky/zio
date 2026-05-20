Testing:
- Use `./check.sh` to format code, run unit tests
- Use `./check.sh --filter "test name"` to run specific tests
- Use `./check.sh --target x86_64-windows --wine` to cross-compile and test via Wine
- Use `./check.sh --target riscv64-linux --qemu` to cross-compile and test via QEMU
- Use `./check.sh --full` to build all tests, but also build examples and benchmarks (at least once before creating a PR)

Notes on Zig usage:
- We are using Zig 0.16+, so modules like `std.posix`, `std.Thread`, `std.fs`, `std.net` no longer exist or are mostly empty, look at src/os/ for replacements.
- Use `zig env` to get the path to the Zig standard library, if you need to check something.

Release process:
1. Update docs/changelog.md - change [Unreleased] to [X.Y.Z] with current date
2. Update version in build.zig.zon
3. Update README.md and docs/getting-started.md to reference vX.Y.Z in `zig fetch --save` command
4. Commit files with message "Release vX.Y.Z"
5. Tag the commit with vX.Y.Z
6. Push commit and tags: `git push && git push --tags`
7. Create GitHub release: `gh release create vX.Y.Z --title "vX.Y.Z" --notes "<changelog content>"`
