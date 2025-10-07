- read README.md for overview of the project
- use `./check.sh` to format code, run unit tests
- use `./check.sh --test-filter "test name" ` to run specific tests
- use `./check.sh --test-fail-first true` to stop on first test failure
- prefer only running specific tests and stopping on the first failure, while working on the feature
- run full check after you are done

Extra notes:
- use `zig env` to get the path to the Zig standard library, if you need to check something
- to test Windows builds on Linux: `zig build build-tests -Dtarget=x86_64-windows && wine zig-out/bin/test.exe`
