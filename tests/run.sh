#!/usr/bin/env bash
# tests/run.sh — run every tests/test-*.sh; non-zero exit if any fails.
set -u
cd "$(dirname "$0")" || exit 1
rc=0
for t in test-*.sh; do
  bash "$t" || rc=1
  echo
done
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$rc"
