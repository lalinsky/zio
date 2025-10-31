- read README.md for overview of the project
- use `./check.sh` to format code, run unit tests
- use `./check.sh --test-filter "test name" ` to run specific tests
- use `./check.sh --test-fail-first true` to stop on first test failure
- prefer only running specific tests and stopping on the first failure, while working on the feature
- run full check after you are done

Extra notes:
- use `zig env` to get the path to the Zig standard library, if you need to check something
- to test Windows builds on Linux: `zig build build-tests -Dtarget=x86_64-windows && wine zig-out/bin/test.exe`

Release process:
1. Update docs/changelog.md - change [Unreleased] to [X.Y.Z] with current date
2. Update version in build.zig.zon
3. Commit files with message "Release vX.Y.Z"
4. Tag the commit with vX.Y.Z
5. Push commit and tags: `git push && git push --tags`
6. Create GitHub release: `gh release create vX.Y.Z --title "vX.Y.Z" --notes "<changelog content>"`
