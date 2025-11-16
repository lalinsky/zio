#!/usr/bin/env python3
"""
Generic test runner for standalone test executables.
"""

import subprocess
import sys
import re
from dataclasses import dataclass
from typing import List, Optional

# Ensure UTF-8 output on Windows
if sys.platform == 'win32':
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8')


@dataclass
class TestCase:
    """Configuration for a single test executable."""
    name: str
    executable: str
    should_succeed: bool = True  # False if test should exit with error
    must_contain: List[str] = None
    must_match: List[str] = None  # Regex patterns
    must_not_contain: List[str] = None
    timeout: int = 5

    def __post_init__(self):
        if self.must_contain is None:
            self.must_contain = []
        if self.must_match is None:
            self.must_match = []
        if self.must_not_contain is None:
            self.must_not_contain = []


# Define test cases
EXE_EXT = ".exe" if sys.platform == "win32" else ""
TEST_CASES = [
    TestCase(
        name="Stack Overflow",
        executable=f"./zig-out/bin/test_stack_overflow{EXE_EXT}",
        should_succeed=False,  # Should crash
        must_contain=[
            "Stack Overflow Test",
            "Stack configuration:",
            "Running coroutine",
        ],
        must_match=[
            # Must detect stack overflow - either Linux diagnostics or Windows panic
            r"(Coroutine stack overflow!|Stack Overflow)",
        ],
        must_not_contain=[
            "Completed successfully",
            "ERROR: Coroutine completed without stack overflow",
        ],
    ),
    TestCase(
        name="Segmentation Fault",
        executable=f"./zig-out/bin/test_segfault{EXE_EXT}",
        should_succeed=False,  # Should crash with segfault
        must_contain=[
            "Segmentation Fault Test",
            "Running coroutine that will segfault",
            "Inside coroutine, causing segfault",
        ],
        must_not_contain=[
            "ERROR: Survived null pointer dereference",
            "ERROR: Coroutine completed",
            "ERROR: Test completed without segfault",
        ],
    ),
]


def run_test(test: TestCase) -> bool:
    """Run a single test case and validate output."""
    print(f"\n{'=' * 70}")
    print(f"Running: {test.name}")
    print(f"Executable: {test.executable}")
    print('=' * 70)

    try:
        result = subprocess.run(
            [test.executable],
            capture_output=True,
            text=True,
            timeout=test.timeout
        )
    except subprocess.TimeoutExpired:
        print(f"✗ FAIL: Test timed out after {test.timeout}s")
        return False
    except FileNotFoundError:
        print(f"✗ FAIL: Executable not found: {test.executable}")
        return False

    # Combine stdout and stderr
    output = result.stdout + result.stderr

    print("\nOutput:")
    print("-" * 70)
    print(output)
    print("-" * 70)

    passed = True

    # Check exit code
    print(f"\nExit code: {result.returncode}")
    if test.should_succeed:
        if result.returncode == 0:
            print("✓ Exit code is 0 (success)")
        else:
            print(f"✗ Exit code {result.returncode} != 0 (expected success)")
            passed = False
    else:
        if result.returncode != 0:
            print(f"✓ Exit code is non-zero: {result.returncode} (failure expected)")
        else:
            print("✗ Exit code is 0 (expected failure)")
            passed = False

    # Check must_contain
    print("\nChecking required strings:")
    for text in test.must_contain:
        if text in output:
            print(f"  ✓ Found: '{text}'")
        else:
            print(f"  ✗ Missing: '{text}'")
            passed = False

    # Check must_match (regex patterns)
    print("\nChecking required patterns:")
    for pattern in test.must_match:
        if re.search(pattern, output):
            print(f"  ✓ Matched: {pattern}")
        else:
            print(f"  ✗ Not matched: {pattern}")
            passed = False

    # Check must_not_contain
    print("\nChecking forbidden strings:")
    for text in test.must_not_contain:
        if text not in output:
            print(f"  ✓ Not found: '{text}'")
        else:
            print(f"  ✗ Found (should not be present): '{text}'")
            passed = False

    print("\n" + "-" * 70)
    if passed:
        print(f"✓ PASS: {test.name}")
    else:
        print(f"✗ FAIL: {test.name}")
    print("-" * 70)

    return passed


def main():
    """Run all test cases."""
    print("Standalone Test Runner")
    print("=" * 70)
    print(f"Running {len(TEST_CASES)} test(s)")

    results = []
    for test in TEST_CASES:
        passed = run_test(test)
        results.append((test.name, passed))

    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    for name, passed in results:
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"{status}: {name}")

    total = len(results)
    passed_count = sum(1 for _, p in results if p)
    failed_count = total - passed_count

    print("-" * 70)
    print(f"Total: {total}, Passed: {passed_count}, Failed: {failed_count}")
    print("=" * 70)

    return 0 if failed_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
