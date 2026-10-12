#!/usr/bin/env bash
# fm-acceptance.sh - record a spec-locked task's acceptance run (worker-invoked).
#
# Usage:
#   fm-acceptance.sh run <task-id>
#
# Runs the entrypoint named by data/<id>/brief.md's "Acceptance entrypoint:"
# line from the physical worktree root with one argument, the absolute path
# where it must write a Cucumber JSON report, and writes data/<id>/acceptance.json
# bound to the worktree HEAD (format owned by bin/fm-spec-lib.sh).
# Refuses, writing no record, on: a dirty worktree, a missing or non-executable
# entrypoint, a HEAD that moves during the run, or no readable report.
# Exit: 0 recorded and passing; 1 recorded but not passing; 2 refused.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-spec-lib.sh
. "$SCRIPT_DIR/fm-spec-lib.sh"

refuse() { echo "error: $*" >&2; exit 2; }
[ "${1:-}" = run ] && [ -n "${2:-}" ] || { sed -n '4,5p' "$0" >&2; exit 2; }
ID=$2
META="$STATE/$ID.meta"
[ -r "$META" ] || refuse "no task record for $ID at $META"
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2-)
[ -n "$WT" ] && [ -d "$WT" ] || refuse "task $ID has no worktree on record"
WT=$(cd "$WT" && pwd -P)
EP=$(sed -n 's/^Acceptance entrypoint: //p' "$DATA/$ID/brief.md" 2>/dev/null | head -n 1)
[ -n "$EP" ] || refuse "$DATA/$ID/brief.md records no Acceptance entrypoint"
[ -x "$WT/$EP" ] || refuse "acceptance entrypoint $EP is missing or not executable in $WT"
[ -z "$(git -C "$WT" status --porcelain)" ] || refuse "$WT has uncommitted changes; commit before recording acceptance"
HEAD_BEFORE=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null) || refuse "cannot resolve HEAD in $WT"

OUT="$DATA/$ID/acceptance.json"
REPORT="$DATA/$ID/.cucumber.${BASHPID:-$$}.json"
TMP="$OUT.${BASHPID:-$$}.tmp"
trap 'rm -f -- "$REPORT" "$TMP"' EXIT
rm -f -- "$REPORT"
(cd "$WT" && "./$EP" "$REPORT")
EXIT=$?
HEAD_AFTER=$(git -C "$WT" rev-parse --verify HEAD 2>/dev/null)
[ "$HEAD_AFTER" = "$HEAD_BEFORE" ] || refuse "HEAD moved during the acceptance run ($HEAD_BEFORE -> ${HEAD_AFTER:-none}); no record written"
jq -e 'type == "array"' "$REPORT" >/dev/null 2>&1 \
  || refuse "the entrypoint (exit $EXIT) wrote no readable Cucumber JSON to $REPORT; no record written"
fm_spec_record_from_cucumber "$REPORT" "$WT" "$HEAD_BEFORE" "$EP" "$EXIT" "$(date +%s)" > "$TMP" \
  || refuse "could not build the acceptance record"
mv -f -- "$TMP" "$OUT"
jq -r '"recorded \(.scenarios | length) scenarios at \(.head) exit=\(.exit): "
  + ([.counts | to_entries[] | select(.value > 0) | "\(.key)=\(.value)"] | join(" "))' "$OUT"
jq -e '.exit == 0 and (.scenarios | length) > 0 and .counts.passed == (.scenarios | length)' "$OUT" >/dev/null && exit 0
exit 1
