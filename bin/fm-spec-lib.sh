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
  # Fails closed: prints no lock unless every feature entry under <root>/features
  # is a readable regular file, hashes, and yields at least one scenario.
  local root=$1 found p sha line rows='' files scen n
  if [ ! -d "$root/features" ]; then
    printf 'error: no features/ directory under %s\n' "$root" >&2
    return 1
  fi
  found=$(cd "$root" && find features -name '*.feature') || {
    printf 'error: cannot list features under %s\n' "$root" >&2
    return 1
  }
  if [ -z "$found" ]; then
    printf 'error: no feature scenarios under %s/features\n' "$root" >&2
    return 1
  fi
  # A symlink is refused too: the inventory reads only regular files (-type f),
  # so a symlinked feature would be hashed but contribute no scenarios.
  while IFS= read -r p; do
    if [ -L "$root/$p" ] || [ ! -f "$root/$p" ] || [ ! -r "$root/$p" ]; then
      printf 'error: cannot hash %s\n' "$p" >&2
      return 1
    fi
    sha=$(fm_spec_sha256 < "$root/$p") && [ -n "$sha" ] || {
      printf 'error: cannot hash %s\n' "$p" >&2
      return 1
    }
    printf -v line '%s\t%s\n' "$p" "$sha"
    rows=$rows$line
  done < <(printf '%s\n' "$found" | LC_ALL=C sort)
  files=$(printf '%s' "$rows" | jq -R -s -c '[split("\n")[] | select(length > 0) | split("\t") | {path: .[0], sha256: .[1]}]') || return 1
  scen=$(fm_spec_inventory "$root") || return 1
  n=$(printf '%s' "$scen" | jq 'length') || return 1
  if [ "$n" -eq 0 ]; then
    printf 'error: no feature scenarios under %s/features\n' "$root" >&2
    return 1
  fi
  jq -n -c --arg task "$2" --arg commit "$3" --arg approval "$4" --argjson at "$5" \
    --argjson files "$files" --argjson sc "$scen" \
    '{version: 1, task: $task, commit: $commit, approved_at: $at, approval: $approval, files: $files, scenarios: $sc}'
}

fm_spec_record_from_cucumber() {  # <cucumber-json> <worktree> <head> <entrypoint> <exit> <ran-at>
  local real
  real=$(cd "$2" 2>/dev/null && pwd -P) || real=$2
  jq -c --arg wt "$2" --arg real "$real" --arg head "$3" --arg ep "$4" --argjson exit "$5" --argjson ran "$6" '
    def strip($p): if startswith($p + "/") then .[($p | length) + 1:] else . end;
    def norm: sub("^classpath:"; "") | sub("^file:(//)?"; "") | gsub("\\\\"; "/")
      | strip($wt) | strip($real) | sub("^\\./"; "");
    def canon: . as $s | if (["passed","failed","undefined","pending","skipped","ambiguous"] | any(. == $s)) then $s else "unknown" end;
    def rank: {"passed":0,"skipped":1,"pending":2,"undefined":3,"unknown":4,"ambiguous":5,"failed":6}[.];
    def worst: if length == 0 then "unknown" else max_by(rank) end;
    def hook: (.hidden == true) or (((.keyword // "") | gsub("^\\s+|\\s+$"; "")) as $k | $k == "Before" or $k == "After");
    def results: [(.before[]?, .steps[]?, .after[]?) | (.result.status // "unknown") | ascii_downcase | canon];
    [ .[] | (.uri | norm) as $u
      | (.elements // []) | reduce .[] as $e ({bg: null, out: []};
          if ($e.type // "scenario") == "background" then .bg = $e
          else .out += [{e: $e, bg: .bg}] | .bg = null end)
      | .out[]
      | { uri: $u, line: .e.line, name: (.e.name // ""),
          steps: ([(.bg // {}).steps[]?, .e.steps[]? | select(hook | not)] | length),
          status: (((.bg // {}) | results) + (.e | results) | worst) } ] as $sc
    | { version: 1, head: $head, ran_at: $ran, entrypoint: $ep, exit: $exit, scenarios: $sc,
        counts: (reduce ("passed","failed","undefined","pending","skipped","ambiguous","unknown") as $k
          ({}; .[$k] = ([$sc[] | select(.status == $k)] | length))) }
  ' "$1"
}
