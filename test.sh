#!/usr/bin/env bash
# Run Ambrosia's test suite locally, the same way .github/workflows/swift.yml
# does in CI: SwiftLint first, then `xcodebuild test` against the AmbrosiaTests
# target. See docs/overview.md's "Repo-wide engineering rules" for the
# invariants this enforces (Invariant 12 force-unwrap ban, Invariant 21 build
# gate).
#
# Usage:
#   ./test.sh                     Run lint + full test suite
#   ./test.sh --no-lint           Skip SwiftLint, run tests only
#   ./test.sh --lint-only         Run SwiftLint only, skip tests
#   ./test.sh --filter PATTERN    Run only tests matching PATTERN
#                                  (xcodebuild -only-testing:PATTERN, e.g.
#                                  AmbrosiaTests/CollectionStoreTests or
#                                  AmbrosiaTests/CollectionStoreTests/testFoo)
#   ./test.sh -q | --quiet        Suppress xcodebuild's own output; only
#                                  print the final pass/fail summary
#   ./test.sh -h | --help         Show this message
#
# Requires Xcode (xcodebuild) and, unless --no-lint is passed, SwiftLint
# (`brew install swiftlint`). xcbeautify is used to format xcodebuild's
# output when present, and falls back to raw output otherwise.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PROJECT="Ambrosia.xcodeproj"
SCHEME="Ambrosia"
RESULT_BUNDLE="/tmp/Ambrosia-test-$(date +%s).xcresult"

RUN_LINT=1
RUN_TESTS=1
QUIET=0
FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-lint)
      RUN_LINT=0
      shift
      ;;
    --lint-only)
      RUN_TESTS=0
      shift
      ;;
    --filter)
      FILTER="${2:?--filter requires a PATTERN argument}"
      shift 2
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run './test.sh --help' for usage." >&2
      exit 1
      ;;
  esac
done

status=0

if [[ "$RUN_LINT" -eq 1 ]]; then
  if command -v swiftlint >/dev/null 2>&1; then
    echo "==> Running SwiftLint"
    if ! swiftlint lint --strict; then
      echo "==> SwiftLint failed" >&2
      status=1
    fi
  else
    echo "==> SwiftLint not installed, skipping (install with: brew install swiftlint)" >&2
    echo "    or re-run with --no-lint to silence this notice." >&2
  fi
fi

if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "==> Running tests (xcodebuild test)"

  xcodebuild_args=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -destination "platform=macOS,arch=arm64"
    -resultBundlePath "$RESULT_BUNDLE"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    test
  )

  if [[ -n "$FILTER" ]]; then
    xcodebuild_args=(-only-testing:"$FILTER" "${xcodebuild_args[@]}")
  fi

  set +e
  if [[ "$QUIET" -eq 1 ]]; then
    xcodebuild "${xcodebuild_args[@]}" >/tmp/ambrosia-test-output.log 2>&1
    test_status=$?
  elif command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${xcodebuild_args[@]}" 2>&1 | xcbeautify
    test_status=${PIPESTATUS[0]}
  else
    xcodebuild "${xcodebuild_args[@]}"
    test_status=$?
  fi
  set -e

  if [[ "$test_status" -ne 0 ]]; then
    status=1
    echo "==> Tests failed (exit $test_status)" >&2
    if [[ "$QUIET" -eq 1 ]]; then
      echo "    Full output: /tmp/ambrosia-test-output.log" >&2
    fi
    echo "    Result bundle: $RESULT_BUNDLE" >&2
  else
    echo "==> Tests passed"
    rm -rf "$RESULT_BUNDLE"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  echo "==> All checks passed"
else
  echo "==> One or more checks failed" >&2
fi

exit "$status"
