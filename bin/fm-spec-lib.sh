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

fm_spec_gate_scenarios() {  # <lock> <record>
  jq -r -n --slurpfile L "$1" --slurpfile R "$2" '
    def at($rs; $u; $l): [$rs[] | select(.uri == $u and .line == $l)];
    def find($rs; $s): (at($rs; $s.uri; $s.line)[0])
      // (if $s.outline_line then at($rs; $s.uri; $s.outline_line)[$s.ordinal - 1] else null end);
    ($L[0].scenarios) as $ls | ($R[0].scenarios) as $rs
    | [$ls[] | select(find($rs; .) == null) | "\(.uri):\(.line)"] as $notrun
    | [$ls[] | . as $s | find($rs; $s) | select(. != null and .steps < $s.steps)
        | "\($s.uri):\($s.line) unknown(steps \(.steps)/\($s.steps))"] as $short
    | [$rs[] | select(.status != "passed") | "\(.uri):\(.line) \(.status)"] as $bad
    | (if ($notrun | length) > 0 then "notrun " + ($notrun | join(" ")) else empty end),
      (if (($short + $bad) | length) > 0 then "notpassing " + (($short + $bad) | unique | join(" ")) else empty end)
  '
}

# 0 when the locked spec passes at <worktree>'s HEAD; otherwise one reason line
# on stdout and 1. The checks run in the order the design's gate table lists.
fm_spec_gate() {  # <lock> <worktree>
  local lock=$1 wt=$2 head rec rhead ex out notrun bad changed
  if [ ! -r "$lock" ] || ! jq -e '.version == 1 and (.files | type == "array") and (.scenarios | type == "array")' "$lock" >/dev/null 2>&1; then
    printf '%s\n' "spec lock unreadable"
    return 1
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! head=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null); then
    printf '%s\n' "named head cannot be verified for a locked spec"
    return 1
  fi
  changed=$(jq -r '.files[] | "\(.sha256) \(.path)"' "$lock" | while IFS=' ' read -r want path; do
    if ! git -C "$wt" cat-file -e "HEAD:$path" 2>/dev/null \
      || [ "$(git -C "$wt" show "HEAD:$path" | fm_spec_sha256)" != "$want" ]; then
      printf '%s\n' "$path"
    fi
  done | paste -sd' ' -)
  if [ -n "$changed" ]; then
    printf 'locked spec changed: %s; needs captain re-approval\n' "$changed"
    return 1
  fi
  rec="${lock%/*}/acceptance.json"
  if [ ! -r "$rec" ] || ! rhead=$(jq -er '.head' "$rec" 2>/dev/null); then
    printf '%s\n' "acceptance run missing"
    return 1
  fi
  if [ "$rhead" != "$head" ]; then
    printf 'acceptance run is for %s, not head %s; rerun fm-acceptance.sh as the last step\n' "$rhead" "$head"
    return 1
  fi
  ex=$(jq -r '.exit' "$rec")
  if [ "$ex" != 0 ]; then
    printf 'acceptance entrypoint exited %s\n' "$ex"
    return 1
  fi
  out=$(fm_spec_gate_scenarios "$lock" "$rec") || { printf '%s\n' "acceptance run unreadable"; return 1; }
  notrun=$(printf '%s\n' "$out" | sed -n 's/^notrun //p')
  bad=$(printf '%s\n' "$out" | sed -n 's/^notpassing //p')
  if [ -n "$notrun" ]; then
    printf 'scenarios not run: %s\n' "$notrun"
    return 1
  fi
  if [ -n "$bad" ]; then
    printf 'scenarios not passing: %s\n' "$bad"
    return 1
  fi
  return 0
}

fm_spec_archive_matches_lock() {  # <lock>
  local lock=$1 bad
  if [ ! -r "$lock" ] || ! jq -e '.version == 1' "$lock" >/dev/null 2>&1; then
    printf '%s\n' "spec lock unreadable"
    return 1
  fi
  bad=$(jq -r '.files[] | "\(.sha256) \(.path)"' "$lock" | while IFS=' ' read -r want path; do
    f="${lock%/*}/spec/$path"
    if [ ! -f "$f" ] || [ "$(fm_spec_sha256 < "$f")" != "$want" ]; then printf '%s\n' "$path"; fi
  done | paste -sd' ' -)
  [ -z "$bad" ] || { printf 'archived spec does not match the lock: %s\n' "$bad"; return 1; }
}

fm_spec_ship_contract() {  # <task-id> <lock> <entrypoint> <fm-root> <fm-home>
  local id=$1 lock=$2 ep=$3 root=$4 home=$5 dir=${2%/*}
  cat <<EOF
# Locked acceptance spec
Spec lock: $lock
The captain approved the scenarios archived in \`$dir/spec/features/\`; they are locked by content hash.
1. Before implementing, restore them into this branch unchanged with \`mkdir -p features && cp -R "$dir/spec/features/." features/\`, and commit them as your branch's first commit.
2. Never edit, rename, delete, tag-filter, or skip a locked feature file or scenario. If a scenario looks wrong or impossible, stop and escalate to firstmate; only the captain can change the spec.
3. Implement test-first and make every locked scenario executable through \`$ep\`: run from the worktree root with one argument, an absolute path, it must write a Cucumber JSON report there and exit 0 only when everything passed. Create it if the project lacks it.
4. As your LAST step, run \`FM_HOME=$home $root/bin/fm-acceptance.sh run $id\`: after implementation, after any no-mistakes pipeline fixes are in this copy (and after Gerrit custody recovery where it applies), on the exact head your ready report names, with no commits afterwards.
5. Your ready \`done:\` is refused until the locked files are unchanged at that head and the recorded run shows exit 0 with every scenario passed. If it is refused, rerun step 4; re-implement only when the refusal names failing scenarios.
EOF
}
