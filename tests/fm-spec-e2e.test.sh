#!/usr/bin/env bash
# End-to-end behavior test for the spec gate through its public CLIs:
# approve, promote-time restore, acceptance run, and the done: gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spec-e2e)
fm_git_identity fmtest fmtest@example.invalid
FIX="$ROOT/tests/fixtures/spec-gate"

test_end_to_end_spec_gate() {
  local home wt repo id=e2e1 lock restore reason meta
  home="$TMP_ROOT/home"
  repo="$TMP_ROOT/repo"
  wt="$TMP_ROOT/wt"
  meta="$home/state/$id.meta"
  fm_test_spawn_home "$home"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  mkdir -p "$wt/features" "$home/data/$id"
  cp "$FIX/demo.feature" "$wt/features/demo.feature"
  git -C "$wt" add features
  git -C "$wt" commit -q -m 'scout spec'
  fm_write_meta "$meta" "kind=scout" "project=shop" "worktree=$wt"
  printf 'Acceptance entrypoint: bin/acceptance\n' > "$home/data/$id/brief.md"
  printf 'approved\n' > "$TMP_ROOT/words"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/hold"
  chmod +x "$TMP_ROOT/hold"

  FM_HOME="$home" FM_CAPTAIN_HOLD_BIN="$TMP_ROOT/hold" "$ROOT/bin/fm-spec.sh" approve "$id" --decision-file "$TMP_ROOT/words" >/dev/null \
    || fail "approve"
  lock="$home/data/$id/spec-lock.json"
  assert_grep "spec_lock=$lock" "$meta" "meta carries the lock"

  # The promoted worker returns to a clean base without the scout's commit,
  # then restores the spec with the exact command its contract names.
  git -C "$wt" reset -q --hard HEAD~1
  # shellcheck disable=SC2016 # The sed pattern matches the contract's literal backticks.
  restore=$(fm_spec_ship_contract "$id" "$lock" bin/acceptance "$ROOT" "$home" \
    | sed -n 's/^1\..*`\(mkdir -p features .*\)`, and commit.*/\1/p')
  [ -n "$restore" ] || fail "the contract names the restore command"
  (cd "$wt" && eval "$restore") || fail "restore"
  mkdir -p "$wt/bin"
  # shellcheck disable=SC2016 # The "$1" is written into the generated script, not expanded here.
  printf '#!/usr/bin/env bash\njq %s %s > "$1"\n' \
    "'[.[] | .elements |= map(.steps |= map(.result.status = \"passed\"))]'" "'$FIX/cucumber-js-11.json'" > "$wt/bin/acceptance"
  chmod +x "$wt/bin/acceptance"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m 'implement'
  git -C "$wt" push -q -f origin "fm/$id"
  fm_write_meta "$meta" "kind=ship" "mode=direct-PR" "project=shop" "worktree=$wt" "spec_lock=$lock"

  FM_HOME="$home" "$ROOT/bin/fm-acceptance.sh" run "$id" >/dev/null || fail "the acceptance run should pass"
  fm_dod_accept_ship_done ship direct-PR "$wt" "$repo" 'done: PR https://github.com/o/r/pull/9' "$home/state" "$id" "$meta" >/dev/null \
    || fail "a passing locked task must be accepted"

  printf '  Scenario: sneaky\n    Given a shop\n' >> "$wt/features/demo.feature"
  git -C "$wt" commit -q -am 'weaken'
  git -C "$wt" push -q -f origin "fm/$id"
  reason=$(fm_dod_accept_ship_done ship direct-PR "$wt" "$repo" 'done: PR https://github.com/o/r/pull/9' "$home/state" "$id" "$meta") \
    && fail "an edited locked spec must be refused"
  assert_equals "locked spec changed: features/demo.feature; needs captain re-approval" "$reason" "the edit is refused"
  pass "spec gate end to end"
}

test_end_to_end_spec_gate
echo "all fm-spec-e2e tests passed"
