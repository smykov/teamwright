#!/usr/bin/env bash
# Regression: pre-commit (forbidden files + built-in secret fallback).
# Fake secrets are assembled at runtime so this file itself never contains one.
. "$(dirname "$0")/lib.sh"
echo "pre-commit"
export TEAMWRIGHT_NO_GITLEAKS=1
new_repo "$TMP/repo"
echo init > README; git add -A; git commit -qm "chore: init" || exit 1

try() {  # try DESC EXPECTED_RC FILE CONTENT
  printf '%s\n' "$4" > "$3"; git add -f "$3"
  git commit -qm "test" 2>"$TMP/err"; local rc=$?
  expect_rc "$1" "$2" "$rc"
  [ "$rc" -ne 0 ] && git reset -q HEAD -- "$3" && rm -f "$3"
  return 0
}
A="AKIA"; G="ghp_"; K="-----BEGIN"; S="sk-ant-"
PWK="DB_PASS""WORD="; CRED="hunter2""hunter"; JV="Zx81Kq""03Lm77Pp"
R36="$(printf 'a%.0s' $(seq 1 36))"

try "AWS access key is blocked"     1 cfg.py   "key = '${A}QWERTYUIOPASDFGH'"
try "GitHub token is blocked"       1 ci.sh    "export GH=${G}${R36}"
try "private key is blocked"        1 id.pem   "$K OPENSSH PRIVATE KEY-----"
try "LLM API key is blocked"        1 llm.py   "k='${S}${R36}'"
try "PASSWORD= literal is blocked"  1 app.ini  "${PWK}Sup3rS3cretValue"
try "URL credentials are blocked"   1 db.yml   "url: postgres://app:${CRED}@db/app"
grep -q "possible secret" "$TMP/err" && ok "finding is reported with file:line" || bad "finding reported"
try "placeholder password passes"   0 ex.ini   "${PWK}<set-in-env>"
# shellcheck disable=SC2016
try "env reference passes"          0 ex2.ini  'API_KEY=${API_KEY}'
try "variable reference passes"     0 v.py     "password = new_password"
try "function call passes"          0 f.py     "token = get_token(user)"
try "prose with 'secrets:' passes"  0 n.txt    "Secrets: stored in the vault, never here"
try "quoted JSON secret is blocked" 1 c.json   "{\"api_key\": \"${JV}\"}"
try "allow marker passes"           0 t.py     "key = '${A}QWERTYUIOPASDFGH'  # teamwright:allow-secret"
try "ordinary code passes"          0 ok.py    "def f(): return 1"
printf '++ not a header\nkey = %s\n' "${A}QWERTYUIOPASDFGH" > plus.txt; git add plus.txt
git commit -qm test 2>"$TMP/err"; git reset -q HEAD -- plus.txt; rm -f plus.txt
grep -q "at plus.txt:2" "$TMP/err" && ok "added '++ ' line is content, not a diff header" \
  || bad "added '++ ' line is content, not a diff header" "$(cat "$TMP/err")"
PWV="Zx81Kq""03Lm77Ppqq"
mkdir -p tests docs
try "test fixture: not blocking"    0 tests/conftest.py "db_password = '${PWV}'"
grep -q "looks like test-fixture (not blocking)" "$TMP/err" && ok "test fixture reported as a note" \
  || bad "test fixture reported as a note" "$(cat "$TMP/err")"
try "docs example: not blocking"    0 docs/setup.md "export API_KEY=${PWV}"
try "compose localhost: not blocking" 0 docker-compose.yml "DATABASE_URL: postgres://postgres:${CRED}@localhost/app"
try "strong token in tests still blocks" 1 tests/fixture.py "k='${S}${R36}'"
try "strong token marked example: note" 0 tests/aws.py "key = '${A}QWERTYUIOPASDFGH'  # example only"
try ".env is refused"               1 .env     "A=1"
try ".env.prod is refused"          1 .env.prod "A=1"
try "*.local.json is refused"       1 settings.local.json "{}"
try ".env.example is allowed"       0 .env.example "API_KEY=<your key>"
# N2: a staged gate stamp must match the local ledger where this checkout has one
mkdir -p docs/tasks/T-7.reviews .teamwright/sessions
STAMP_OK='{"agent_id": "a-rev", "agent_type": "code-reviewer", "gate": "review", "round": 1, "session_id": "s1", "verdict": "APPROVE"}'
try "a stamp without a ledger (fresh clone): allowed" 0 docs/tasks/T-7.reviews/1.gate.json "$STAMP_OK"
printf '%s\n' '{"agent_id": "a-rev", "agent_type": "code-reviewer", "round": 2, "session_id": "s1", "verdict": "APPROVE"}' > .teamwright/sessions/T-7.reviews.jsonl
try "a stamp matching a ledger line: allowed" 0 docs/tasks/T-7.reviews/2.gate.json "${STAMP_OK/\"round\": 1/\"round\": 2}"
try "a stamp with no ledger line for its round: refused" 1 docs/tasks/T-7.reviews/3.gate.json "${STAMP_OK/\"round\": 1/\"round\": 3}"
grep -q "not written by the gate here" "$TMP/err" && ok "the refusal names the stamp" || bad "the refusal names the stamp" "$(cat "$TMP/err")"
W2="${STAMP_OK/\"round\": 1/\"round\": 2}"
try "a stamp whose writer differs from the ledger: refused" 1 docs/tasks/T-7.reviews/2.gate.json "${W2/a-rev/a-x}"
finish
