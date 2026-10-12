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
  sed 's/$/\r/' "$FIX/demo.feature" > "$TMP_ROOT/crlf.feature"
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

test_parser_matches_the_probe_feature
test_parser_ignores_docstrings_comments_tags_and_step_tables
test_parser_treats_crlf_like_lf
test_lock_hashes_files_and_lists_scenarios
echo "all fm-spec-lib tests passed"
