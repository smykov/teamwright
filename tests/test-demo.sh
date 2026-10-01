#!/usr/bin/env bash
# Regression: examples/demo.sh walks one task through every gate and ends with metrics.
# The demo exits non-zero when any gate decides differently than its walkthrough expects.
. "$(dirname "$0")/lib.sh"
echo "demo"
bash "$KIT/examples/demo.sh" > "$TMP/out" 2>&1
expect_rc "demo exits 0" 0 "$?"
for needle in "DENIED by analysis-gate" "DENIED by review-gate" "DENIED by verify-gate" \
    "chore(task): T-001 CODE_COMPLETE→DONE" "## 3. Hook journals" "demo: ok"; do
  if grep -qF -- "$needle" "$TMP/out"; then ok "output has: $needle"; else bad "output has: $needle"; fi
done
if grep -q "approvals (-> CODE_COMPLETE) with a journaled reviewer spawn | 100.0% (1/1)" "$TMP/out"; then
  ok "metrics join the approval to the journaled reviewer spawn"
else bad "metrics join the approval to the journaled reviewer spawn"; fi
[ "$FAIL" -eq 0 ] || sed 's/^/    | /' "$TMP/out"
finish
