#!/usr/bin/env bash
# Behavior tests for bin/fm-spec-lib.sh: the spec gate's parser, inventory,
# lock, Cucumber JSON record, and gate contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-spec-lib.sh
. "$ROOT/bin/fm-spec-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spec-lib)
fm_git_identity fmtest fmtest@example.invalid
FIX="$ROOT/tests/assets/spec-gate"
TAB=$(printf '\t')

row() {  # <line> <steps> <outline-line> <ordinal> <name>
  printf 'features/demo.feature%s%s%s%s%s%s%s%s%s%s\n' "$TAB" "$1" "$TAB" "$2" "$TAB" "$3" "$TAB" "$4" "$TAB" "$5"
}

test_parser_matches_the_probe_feature() {
  local want got
  want="$(row 7 2 '' '' 'plain passes')
$(row 11 2 '' '' 'inside rule undefined')
$(row 19 2 14 1 'outline <n>')
$(row 20 2 14 2 'outline <n>')
$(row 24 2 14 3 'outline <n>')
$(row 26 2 '' '' 'ambiguous one')
$(row 29 2 '' '' 'pending one')"
  got=$(fm_spec_parse_feature "$FIX/demo.feature" features/demo.feature)
  assert_equals "$want" "$got" "parser rows for the probe feature (lines match cucumber-js 11 output)"
  pass "parser matches the probe feature"
}

test_parser_ignores_docstrings_comments_tags_and_step_tables() {
  local f got
  f="$TMP_ROOT/edge.feature"
  cat > "$f" <<'EOF'
Feature: Edge
  # Scenario: commented out
  @tag
  Scenario Template: templated <x>
    Given a value
      | not | an example |
    Then text
      """
      Scenario: inside a docstring
      Given not a step
      """
    Scenarios:
      | x |
      | a |
  Rule: second
    Background:
      * rule step
    Example: in rule
      When it runs
EOF
  got=$(fm_spec_parse_feature "$f" features/edge.feature | cut -f2-5)
  assert_equals "$(printf '14\t2\t4\t1\n18\t2\t\t')" "$got" "template rows, rule background, and skipped docstring/comment/tag/table lines"
  pass "parser ignores docstrings, comments, tags, and step tables"
}

test_parser_treats_crlf_like_lf() {
  local lf crlf
  awk '{ printf "%s\r\n", $0 }' "$FIX/demo.feature" > "$TMP_ROOT/crlf.feature"
  lf=$(fm_spec_parse_feature "$FIX/demo.feature" x)
  crlf=$(fm_spec_parse_feature "$TMP_ROOT/crlf.feature" x)
  assert_equals "$lf" "$crlf" "CRLF feature parses like LF"
  pass "parser treats CRLF like LF"
}

test_lock_hashes_files_and_lists_scenarios() {
  local root lock
  root="$TMP_ROOT/lock-root"
  mkdir -p "$root/features/sub dir"
  cp "$FIX/demo.feature" "$root/features/demo.feature"
  cp "$FIX/demo.feature" "$root/features/sub dir/copy.feature"
  lock=$(fm_spec_build_lock "$root" t1 abc123 'captain-hold:t1 sha256:x' 1791400000)
  assert_equals 2 "$(printf '%s' "$lock" | jq '.files | length')" "both feature files are locked"
  assert_equals "features/demo.feature" "$(printf '%s' "$lock" | jq -r '.files[0].path')" "files sorted by path"
  assert_equals "$(fm_spec_sha256 < "$FIX/demo.feature")" "$(printf '%s' "$lock" | jq -r '.files[0].sha256')" "file hash is the content sha256"
  assert_equals 14 "$(printf '%s' "$lock" | jq '.scenarios | length')" "seven scenarios per file"
  assert_equals "features/sub dir/copy.feature" "$(printf '%s' "$lock" | jq -r '.scenarios[13].uri')" "path with a space survives"
  assert_equals "t1 abc123 1791400000" "$(printf '%s' "$lock" | jq -r '"\(.task) \(.commit) \(.approved_at)"')" "header fields"
  pass "lock hashes files and lists scenarios"
}

# expect_lock_refused <root> <msg>: the builder must exit non-zero, print no
# lock JSON on stdout, and name the refusal with an error: line on stderr.
expect_lock_refused() {
  local out code err
  out=$(fm_spec_build_lock "$1" t1 abc123 'captain-hold:t1' 1791400000 2>"$TMP_ROOT/refused.err")
  code=$?
  err=$(cat "$TMP_ROOT/refused.err")
  assert_not_equals 0 "$code" "$2 exits non-zero"
  assert_equals "" "$out" "$2 prints no lock JSON"
  assert_contains "$err" "error:" "$2 names the refusal on stderr"
}

test_lock_fails_closed_on_missing_or_empty_features() {
  local root
  expect_lock_refused "$TMP_ROOT/absent-root" "missing root"
  root="$TMP_ROOT/no-features-root"
  mkdir -p "$root"
  expect_lock_refused "$root" "root without features/"
  root="$TMP_ROOT/empty-features-root"
  mkdir -p "$root/features"
  expect_lock_refused "$root" "empty features/"
  root="$TMP_ROOT/no-scenario-root"
  mkdir -p "$root/features"
  printf 'Feature: Empty\n' > "$root/features/empty.feature"
  expect_lock_refused "$root" "feature file with no scenarios"
  pass "lock refuses a missing root, a root without features, an empty features dir, and a feature with no scenarios"
}

test_lock_fails_closed_on_dangling_or_symlinked_feature() {
  local root
  root="$TMP_ROOT/dangling-root"
  mkdir -p "$root/features"
  ln -s "$TMP_ROOT/nowhere.feature" "$root/features/dangling.feature"
  expect_lock_refused "$root" "dangling feature symlink"
  root="$TMP_ROOT/linked-root"
  mkdir -p "$root/features"
  cp "$FIX/demo.feature" "$TMP_ROOT/linked-target.feature"
  ln -s "$TMP_ROOT/linked-target.feature" "$root/features/linked.feature"
  expect_lock_refused "$root" "valid feature symlink"
  pass "lock refuses a dangling or symlinked feature file"
}

record() {  # <cucumber-json> [<worktree>] [<exit>]
  fm_spec_record_from_cucumber "$1" "${2:-$TMP_ROOT/wt}" abc123 bin/acceptance "${3:-0}" 1791400500
}

test_record_reads_cucumber_js_statuses() {
  local rec
  rec=$(record "$FIX/cucumber-js-11.json")
  assert_equals "7:passed 11:undefined 19:passed 20:failed 24:passed 26:ambiguous 29:pending" \
    "$(printf '%s' "$rec" | jq -r '[.scenarios[] | "\(.line):\(.status)"] | join(" ")')" "per-scenario status"
  assert_equals "2 2 2 2 2 2 2" "$(printf '%s' "$rec" | jq -r '[.scenarios[].steps] | map(tostring) | join(" ")')" "background steps are counted"
  assert_equals '{"passed":3,"failed":1,"undefined":1,"pending":1,"skipped":0,"ambiguous":1,"unknown":0}' \
    "$(printf '%s' "$rec" | jq -c '.counts')" "counts"
  assert_equals "abc123 0 bin/acceptance" "$(printf '%s' "$rec" | jq -r '"\(.head) \(.exit) \(.entrypoint)"')" "header"
  pass "record reads cucumber-js statuses"
}

test_record_keeps_pytest_bdd_shape_for_the_gate() {
  local rec
  rec=$(record "$FIX/pytest-bdd.json")
  assert_equals "7 11 14 14 14 26 29" "$(printf '%s' "$rec" | jq -r '[.scenarios[].line] | map(tostring) | join(" ")')" "outline rows at the outline line"
  assert_equals 1 "$(printf '%s' "$rec" | jq '.scenarios[1].steps')" "the omitted undefined step is visible as a short step count"
  pass "record keeps the pytest-bdd shape for the gate"
}

test_record_normalizes_uri_forms() {
  local wt real link u got
  wt="$TMP_ROOT/wt"
  mkdir -p "$wt"
  real=$(cd "$wt" && pwd -P)
  link="$TMP_ROOT/wt-link"
  ln -s "$real" "$link"
  for u in "file://$real/features/demo.feature" "classpath:features/demo.feature" "$real/features/demo.feature" \
    'features\demo.feature' "./features/demo.feature"; do
    jq --arg u "$u" 'map(.uri = $u)' "$FIX/cucumber-js-11.json" > "$TMP_ROOT/u.json"
    got=$(fm_spec_record_from_cucumber "$TMP_ROOT/u.json" "$real" h ep 0 1 | jq -r '.scenarios[0].uri')
    assert_equals "features/demo.feature" "$got" "uri $u normalizes"
  done
  jq --arg u "$real/features/demo.feature" 'map(.uri = $u)' "$FIX/cucumber-js-11.json" > "$TMP_ROOT/u.json"
  got=$(fm_spec_record_from_cucumber "$TMP_ROOT/u.json" "$link" h ep 0 1 | jq -r '.scenarios[0].uri')
  assert_equals "features/demo.feature" "$got" "a symlinked worktree argument still strips the runner's physical path"
  pass "record normalizes uri forms"
}

test_record_merges_backgrounds_hides_hooks_and_maps_unknown() {
  local rec
  cat > "$TMP_ROOT/jvm.json" <<'EOF'
[{"uri":"features/demo.feature","elements":[
 {"type":"background","line":4,"steps":[{"keyword":"Given ","result":{"status":"passed"}}]},
 {"type":"scenario","line":7,"name":"plain passes","steps":[{"keyword":"Given ","result":{"status":"passed"}},{"keyword":"After","hidden":true,"result":{"status":"failed"}}]},
 {"type":"scenario","line":26,"name":"x","steps":[{"keyword":"Given ","result":{"status":"Flaky"}}]}]}]
EOF
  rec=$(record "$TMP_ROOT/jvm.json")
  assert_equals "7:2:failed 26:1:unknown" "$(printf '%s' "$rec" | jq -r '[.scenarios[] | "\(.line):\(.steps):\(.status)"] | join(" ")')" \
    "background merged into the next scenario, hidden hook excluded from steps but failing it, unmapped status is unknown"
  pass "record merges backgrounds, hides hooks, and maps unknown statuses"
}

test_parser_matches_the_probe_feature
test_parser_ignores_docstrings_comments_tags_and_step_tables
test_parser_treats_crlf_like_lf
test_lock_hashes_files_and_lists_scenarios
test_lock_fails_closed_on_missing_or_empty_features
test_lock_fails_closed_on_dangling_or_symlinked_feature
test_record_reads_cucumber_js_statuses
test_record_keeps_pytest_bdd_shape_for_the_gate
test_record_normalizes_uri_forms
test_record_merges_backgrounds_hides_hooks_and_maps_unknown
echo "all fm-spec-lib tests passed"
