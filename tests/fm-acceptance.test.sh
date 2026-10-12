#!/usr/bin/env bash
# Behavior tests for bin/fm-acceptance.sh run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-acceptance)
fm_git_identity fmtest fmtest@example.invalid
FIX="$ROOT/tests/fixtures/spec-gate"

setup() {  # <name> <entrypoint-body>; sets HOME_DIR WT
  HOME_DIR="$TMP_ROOT/$1-home"
  WT="$TMP_ROOT/$1-wt"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$TMP_ROOT/$1-repo" "$WT" "fm/$1"
  mkdir -p "$WT/bin" "$HOME_DIR/data/$1"
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$WT/bin/acceptance"
  chmod +x "$WT/bin/acceptance"
  git -C "$WT" add bin
  git -C "$WT" commit -q -m entrypoint
  fm_write_meta "$HOME_DIR/state/$1.meta" "kind=ship" "worktree=$WT"
  printf 'Acceptance entrypoint: bin/acceptance\n' > "$HOME_DIR/data/$1/brief.md"
}

run_acc() { FM_HOME="$HOME_DIR" "$ROOT/bin/fm-acceptance.sh" run "$1"; }

test_passing_run_records_and_exits_zero() {
  setup a1 "jq '[.[] | .elements |= map(.steps |= map(.result.status = \"passed\"))]' '$FIX/cucumber-js-11.json' > \"\$1\""
  run_acc a1 >/dev/null
  expect_code 0 $? "all passed"
  assert_equals "$(git -C "$WT" rev-parse HEAD) 0 7" \
    "$(jq -r '"\(.head) \(.exit) \(.counts.passed)"' "$HOME_DIR/data/a1/acceptance.json")" "record bound to HEAD"
  pass "a passing run records and exits 0"
}

test_failing_run_still_records() {
  setup a2 "cp '$FIX/cucumber-js-11.json' \"\$1\"; exit 1"
  run_acc a2 >/dev/null
  expect_code 1 $? "not passing"
  assert_equals 1 "$(jq '.exit' "$HOME_DIR/data/a2/acceptance.json")" "exit recorded"
  pass "a failing run still records"
}

test_refusals_write_no_record() {
  local out
  setup a3 'exit 0'
  out=$(run_acc a3 2>&1)
  expect_code 2 $? "no JSON"
  assert_contains "$out" "wrote no readable Cucumber JSON" "missing report"
  setup a4 "cp '$FIX/cucumber-js-11.json' \"\$1\""
  printf 'x\n' > "$WT/dirty"
  out=$(run_acc a4 2>&1)
  expect_code 2 $? "dirty tree"
  assert_contains "$out" "uncommitted changes" "dirty refusal"
  setup a5 "git commit -q --allow-empty -m sneaky; cp '$FIX/cucumber-js-11.json' \"\$1\""
  out=$(run_acc a5 2>&1)
  expect_code 2 $? "HEAD moved"
  assert_contains "$out" "HEAD moved during the acceptance run" "moving HEAD refused"
  setup a6 'exit 0'
  printf 'no entrypoint line\n' > "$HOME_DIR/data/a6/brief.md"
  out=$(run_acc a6 2>&1)
  expect_code 2 $? "no entrypoint recorded"
  for n in a3 a4 a5 a6; do assert_absent "$TMP_ROOT/$n-home/data/$n/acceptance.json" "$n wrote no record"; done
  pass "refusals write no record"
}

test_passing_run_records_and_exits_zero
test_failing_run_still_records
test_refusals_write_no_record
echo "all fm-acceptance tests passed"
