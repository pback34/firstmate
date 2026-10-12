#!/usr/bin/env bash
# Behavior tests for bin/fm-spec.sh: show and approve.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spec)
fm_git_identity fmtest fmtest@example.invalid
FIX="$ROOT/tests/fixtures/spec-gate"

setup_scout() {  # <name>; sets HOME_DIR WT HOLD_LOG
  HOME_DIR="$TMP_ROOT/$1-home"
  WT="$TMP_ROOT/$1-wt"
  fm_test_spawn_home "$HOME_DIR"
  fm_git_worktree "$TMP_ROOT/$1-repo" "$WT" "fm/$1"
  mkdir -p "$WT/features" "$HOME_DIR/data/$1"
  cp "$FIX/demo.feature" "$WT/features/demo.feature"
  git -C "$WT" add features
  git -C "$WT" commit -q -m spec
  fm_write_meta "$HOME_DIR/state/$1.meta" "kind=scout" "project=shop" "worktree=$WT"
  printf 'The captain said: approved.\n' > "$TMP_ROOT/$1-words"
  HOLD_LOG="$TMP_ROOT/$1-hold.log"
  cat > "$TMP_ROOT/$1-hold" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HOLD_LOG"
exit \${FAKE_HOLD_EXIT:-0}
EOF
  chmod +x "$TMP_ROOT/$1-hold"
}

spec() {  # <name> <args...>
  local name=$1
  shift
  FM_HOME="$HOME_DIR" FM_CAPTAIN_HOLD_BIN="$TMP_ROOT/$name-hold" "$ROOT/bin/fm-spec.sh" "$@"
}

test_approve_records_release_archives_and_locks() {
  local out lock
  setup_scout s1
  out=$(spec s1 approve s1 --decision-file "$TMP_ROOT/s1-words") || fail "approve failed: $out"
  assert_contains "$(cat "$HOLD_LOG")" "answer s1 --decision-file $TMP_ROOT/s1-words --release" "the captain's words are recorded as a release"
  lock="$HOME_DIR/data/s1/spec-lock.json"
  assert_grep "spec_lock=$lock" "$HOME_DIR/state/s1.meta" "meta records the lock path"
  assert_equals 7 "$(jq '.scenarios | length' "$lock")" "seven scenarios locked"
  assert_equals "$(git -C "$WT" rev-parse HEAD)" "$(jq -r '.commit' "$lock")" "lock records the scout HEAD"
  assert_contains "$(jq -r '.approval' "$lock")" "captain-hold:s1 sha256:" "approval pointer"
  cmp -s "$FIX/demo.feature" "$HOME_DIR/data/s1/spec/features/demo.feature" || fail "archive holds the committed file"
  pass "approve records the release, archives, and locks"
}

test_approve_refusals_write_nothing() {
  local out
  setup_scout s2
  printf 'dirty\n' >> "$WT/features/demo.feature"
  out=$(spec s2 approve s2 --decision-file "$TMP_ROOT/s2-words" 2>&1) && fail "dirty features must refuse"
  assert_contains "$out" "uncommitted changes under features/" "dirty refusal"
  git -C "$WT" checkout -q -- features
  out=$(spec s2 approve s2 2>&1) && fail "missing decision file must refuse"
  assert_contains "$out" "--decision-file" "decision file required"
  out=$(FAKE_HOLD_EXIT=1 spec s2 approve s2 --decision-file "$TMP_ROOT/s2-words" 2>&1) && fail "a rejected release must refuse"
  assert_contains "$out" "captain's approval could not be recorded as a release" "release rejection"
  fm_write_meta "$HOME_DIR/state/s2.meta" "kind=scout" "project=shop" "worktree=$TMP_ROOT/gone"
  out=$(spec s2 approve s2 --decision-file "$TMP_ROOT/s2-words" 2>&1) && fail "a missing worktree must refuse"
  assert_contains "$out" "worktree for s2 is missing" "missing worktree refusal"
  assert_absent "$HOME_DIR/data/s2/spec-lock.json" "no lock written by any refusal"
  assert_no_grep "spec_lock=" "$HOME_DIR/state/s2.meta" "no meta change by any refusal"
  pass "approve refusals write nothing"
}

test_reapproval_archives_lock_spec_and_stale_record() {
  local d
  setup_scout s3
  spec s3 approve s3 --decision-file "$TMP_ROOT/s3-words" >/dev/null || fail "first approve"
  d="$HOME_DIR/data/s3"
  printf '{"version":1,"head":"old"}\n' > "$d/acceptance.json"
  printf '  Scenario: added later\n    Given a shop\n' >> "$WT/features/demo.feature"
  git -C "$WT" commit -q -am 'captain-approved change'
  spec s3 approve s3 --decision-file "$TMP_ROOT/s3-words" >/dev/null || fail "re-approve"
  assert_present "$d/spec-lock.1.json" "previous lock archived"
  assert_present "$d/spec.1/features/demo.feature" "previous spec archived"
  assert_present "$d/acceptance.1.json" "stale acceptance record archived"
  assert_absent "$d/acceptance.json" "no acceptance record survives re-approval"
  assert_equals 8 "$(jq '.scenarios | length' "$d/spec-lock.json")" "new lock has the added scenario"
  pass "re-approval archives the lock, spec, and stale record"
}

# An interrupted approve can leave spec/ behind with no lock. The next approve must
# archive that directory rather than nest its new stage inside it.
test_approve_archives_a_spec_directory_left_without_a_lock() {
  local d leftover
  setup_scout s5
  d="$HOME_DIR/data/s5"
  mkdir -p "$d/spec"
  printf 'left by an interrupted approve\n' > "$d/spec/marker.txt"
  spec s5 approve s5 --decision-file "$TMP_ROOT/s5-words" >/dev/null || fail "approve over a spec directory without a lock"
  assert_present "$d/spec/features" "the new spec did not land at spec/features"
  leftover=$(find "$d" -name '.spec.stage.*' 2>/dev/null)
  assert_equals "" "$leftover" "a staged spec was nested inside the directory"
  assert_present "$d/spec.1/marker.txt" "the left-behind spec directory was not archived to spec.1"
  pass "approve archives a spec directory left without a lock"
}

test_show_lists_candidate_then_locked() {
  local out
  setup_scout s4
  out=$(spec s4 show s4)
  assert_contains "$out" "candidate scenarios (not approved)" "before approval"
  assert_contains "$out" "features/demo.feature:7  plain passes" "lists a scenario"
  spec s4 approve s4 --decision-file "$TMP_ROOT/s4-words" >/dev/null || fail "approve"
  out=$(spec s4 show s4)
  assert_contains "$out" "locked scenarios" "after approval"
  pass "show lists candidate then locked scenarios"
}

test_approve_records_release_archives_and_locks
test_approve_refusals_write_nothing
test_reapproval_archives_lock_spec_and_stale_record
test_approve_archives_a_spec_directory_left_without_a_lock
test_show_lists_candidate_then_locked
echo "all fm-spec tests passed"
