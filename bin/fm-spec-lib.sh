#!/usr/bin/env bash
# fm-spec-lib.sh - the spec gate's single contract owner (sourced, side-effect free).
#
# A spec scout's captain-approved Gherkin scenarios are archived under
# data/<id>/spec/ and locked in data/<id>/spec-lock.json; the task record
# carries spec_lock=<absolute lock path>. The worker records its acceptance run
# in the lock's sibling acceptance.json. docs/superpowers/specs/2026-10-12-spec-gate-design.md
# is the design; this header owns the formats.
#
# Lock (version 1):
#   {version, task, commit, approved_at, approval,
#    files: [{path, sha256}],
#    scenarios: [{uri, line, name, steps[, outline_line, ordinal]}]}
# Record (version 1):
#   {version, head, ran_at, entrypoint, exit,
#    scenarios: [{uri, line, name, steps, status}],
#    counts: {passed, failed, undefined, pending, skipped, ambiguous, unknown}}
#
# Scenario identity is (uri, line). Outline rows also carry outline_line and a
# 1-based ordinal because some runners report every row at the outline's line.
# steps counts a scenario's own steps plus the Background steps that apply to
# it. The parser understands English keywords only.

[ -z "${FM_SPEC_LIB_SOURCED:-}" ] || return 0
FM_SPEC_LIB_SOURCED=1

fm_spec_sha256() {  # reads stdin, prints the hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

fm_spec_parse_feature() {  # <file> <uri>
  awk -v uri="$2" '
    function bg() { return fbg + (in_rule ? rbg : 0) }
    function title(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
    function flush() {
      if (kind == "scenario") printf "%s\t%d\t%d\t\t\t%s\n", uri, sline, bg() + own, sname
      kind = ""
    }
    {
      t = $0
      sub(/\r$/, "", t)
      sub(/^[ \t]+/, "", t)
      if (t ~ /^("""|```)/) { doc = !doc; next }
      if (doc || t == "" || t ~ /^#/ || t ~ /^@/) next
      if (t ~ /^Rule:/) { flush(); in_rule = 1; rbg = 0; mode = ""; next }
      if (t ~ /^Background:/) { flush(); mode = in_rule ? "rbg" : "fbg"; next }
      if (t ~ /^Scenario (Outline|Template):/) { flush(); mode = "outline"; oline = NR; oname = title(t); own = 0; ord = 0; next }
      if (t ~ /^(Scenario|Example):/) { flush(); mode = "scenario"; kind = "scenario"; sline = NR; sname = title(t); own = 0; next }
      if (t ~ /^(Examples|Scenarios):/) { if (mode == "outline" || mode == "examples") { mode = "examples"; header = 0 }; next }
      if (t ~ /^(Given|When|Then|And|But)[ \t]/ || t ~ /^\*[ \t]/) {
        if (mode == "fbg") fbg++
        else if (mode == "rbg") rbg++
        else if (mode == "scenario" || mode == "outline") own++
        next
      }
      if (t ~ /^\|/ && mode == "examples") {
        if (!header) { header = 1; next }
        ord++
        printf "%s\t%d\t%d\t%d\t%d\t%s\n", uri, NR, bg() + own, oline, ord, oname
      }
    }
    END { flush() }
  ' "$1"
}

fm_spec_inventory() {  # <root>
  local root=$1
  (cd "$root" && find features -type f -name '*.feature' 2>/dev/null | LC_ALL=C sort) \
    | while IFS= read -r rel; do fm_spec_parse_feature "$root/$rel" "$rel"; done \
    | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t")
        | {uri: .[0], line: (.[1] | tonumber), name: (.[5:] | join("\t")), steps: (.[2] | tonumber)}
          + (if .[3] != "" then {outline_line: (.[3] | tonumber), ordinal: (.[4] | tonumber)} else {} end)]'
}

fm_spec_build_lock() {  # <root> <task> <commit> <approval> <approved-at>
  local root=$1 files scen
  scen=$(fm_spec_inventory "$root") || return 1
  files=$( (cd "$root" && find features -type f -name '*.feature' | LC_ALL=C sort) \
    | while IFS= read -r p; do printf '%s\t%s\n' "$p" "$(fm_spec_sha256 < "$root/$p")"; done \
    | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {path: .[0], sha256: .[1]}]') || return 1
  jq -n -c --arg task "$2" --arg commit "$3" --arg approval "$4" --argjson at "$5" \
    --argjson files "$files" --argjson sc "$scen" \
    '{version: 1, task: $task, commit: $commit, approved_at: $at, approval: $approval, files: $files, scenarios: $sc}'
}
