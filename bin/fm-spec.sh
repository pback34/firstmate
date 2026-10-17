#!/usr/bin/env bash
# fm-spec.sh - firstmate's spec-gate CLI (supervision side; never runs project code).
#
# Usage:
#   fm-spec.sh show <task-id>
#   fm-spec.sh approve <task-id> --decision-file <path> [--hold <backlog-id>]
#
# show prints the task's locked scenarios, or, before approval, the candidate
# scenarios committed under features/ in the task worktree.
# approve records the captain's exact words as a release on <backlog-id>
# (default <task-id>) through fm-captain-hold.sh answer --release, then archives
# features/**/*.feature exactly as committed at the worktree HEAD into
# data/<id>/spec/, writes data/<id>/spec-lock.json, and records
# spec_lock=<absolute lock path> in the task record under the meta lock.
# Re-approval first moves the previous lock, archive, and acceptance record to
# numbered copies. Every refusal happens before anything is written. Run it in
# the home that owns the task. bin/fm-spec-lib.sh owns every format.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CAPTAIN_HOLD="${FM_CAPTAIN_HOLD_BIN:-$FM_ROOT/bin/fm-captain-hold.sh}"
# shellcheck source=bin/fm-spec-lib.sh
. "$SCRIPT_DIR/fm-spec-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '4,6p' "$0" >&2; exit 2; }
meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

show() {  # <id>
  local id=$1 meta lock wt
  meta="$STATE/$id.meta"
  [ -r "$meta" ] || die "no task record for $id"
  lock=$(meta_value "$meta" spec_lock)
  if [ -n "$lock" ] && [ -r "$lock" ]; then
    echo "locked scenarios ($(jq -r '.approval' "$lock")):"
    jq -r '.scenarios[] | "\(.uri):\(.line)  \(.name)"' "$lock"
    return 0
  fi
  wt=$(meta_value "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || die "worktree for $id is missing (${wt:-none})"
  echo "candidate scenarios (not approved):"
  fm_spec_inventory "$wt" | jq -r '.[] | "\(.uri):\(.line)  \(.name)"'
}

META_LOCK=
META_LOCK_HELD=0
STAGE=
cleanup() {
  if [ "$META_LOCK_HELD" = 1 ]; then fm_lock_release "$META_LOCK"; fi
  if [ -n "$STAGE" ]; then rm -rf -- "$STAGE"; fi
}
trap cleanup EXIT

approve() {  # <id> <args...>
  local id=$1 hold words='' meta dir kind wt commit files lock_json n tmp
  shift
  hold=$id
  while [ $# -gt 0 ]; do
    case "$1" in
      --decision-file) words=${2:-}; shift 2 || usage ;;
      --hold) hold=${2:-}; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  [ -n "$words" ] && [ -s "$words" ] || die "approve needs --decision-file <path> holding the captain's exact approval words"
  meta="$STATE/$id.meta"
  dir="$DATA/$id"
  [ -r "$meta" ] || die "no task record for $id"
  kind=$(meta_value "$meta" kind)
  case "$kind" in
    scout) ;;
    ship) [ -n "$(meta_value "$meta" spec_lock)" ] || die "$id is a ship task without a spec lock; only a spec scout or a locked ship can be approved" ;;
    *) die "$id is kind=${kind:-unknown}; only a spec scout or a locked ship can be approved" ;;
  esac
  # Promote checks the record under its meta lock; approve checks it here, before
  # the captain-hold release, so a refusal leaves no release behind. The publish
  # below validates the same path again under the lock.
  fm_backlog_record_present "$meta" "task record" "$STATE" \
    || die "task record for $id is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)"
  wt=$(meta_value "$meta" worktree)
  if [ -z "$wt" ] || [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    die "worktree for $id is missing or not a git copy (${wt:-none}); nothing was written"
  fi
  commit=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || die "cannot resolve HEAD in $wt"
  [ -z "$(git -C "$wt" status --porcelain -- features)" ] || die "uncommitted changes under features/ in $wt; the spec must be committed first"
  files=$(git -C "$wt" ls-tree -r --name-only HEAD -- features | grep '\.feature$' || true)
  [ -n "$files" ] || die "no committed features/**/*.feature files at $commit in $wt"
  mkdir -p "$dir"
  STAGE="$dir/.spec.stage.${BASHPID:-$$}"
  rm -rf -- "$STAGE"
  printf '%s\n' "$files" | while IFS= read -r p; do
    mkdir -p "$STAGE/$(dirname "$p")" && git -C "$wt" show "HEAD:$p" > "$STAGE/$p" || exit 1
  done || die "could not archive the feature files from $commit"
  lock_json=$(fm_spec_build_lock "$STAGE" "$id" "$commit" \
    "captain-hold:$hold sha256:$(fm_spec_sha256 < "$words")" "$(date +%s)") || die "could not build the spec lock"
  [ "$(printf '%s' "$lock_json" | jq '.scenarios | length')" -gt 0 ] || die "the features at $commit define no scenarios"
  "$CAPTAIN_HOLD" answer "$hold" --decision-file "$words" --release \
    || die "the captain's approval could not be recorded as a release on $hold; resolve the captain-hold record first"

  META_LOCK=$(fm_meta_lock_path "$meta") || die "invalid task record path $meta"
  fm_lock_acquire_wait "$META_LOCK"
  META_LOCK_HELD=1
  # An interrupted earlier approve can leave spec/ with no lock; archive it too, or
  # the staged spec would nest inside it.
  if [ -e "$dir/spec-lock.json" ] || [ -e "$dir/spec" ] || [ -e "$dir/acceptance.json" ]; then
    n=1
    while [ -e "$dir/spec-lock.$n.json" ] || [ -e "$dir/spec.$n" ] || [ -e "$dir/acceptance.$n.json" ]; do n=$((n + 1)); done
    if [ -e "$dir/spec-lock.json" ]; then
      mv -- "$dir/spec-lock.json" "$dir/spec-lock.$n.json" || die "could not move the previous lock to $dir/spec-lock.$n.json"
    fi
    if [ -e "$dir/spec" ]; then
      mv -- "$dir/spec" "$dir/spec.$n" || die "could not move the previous spec to $dir/spec.$n"
    fi
    if [ -e "$dir/acceptance.json" ]; then
      mv -- "$dir/acceptance.json" "$dir/acceptance.$n.json" || die "could not move the previous acceptance record to $dir/acceptance.$n.json"
    fi
  fi
  mv -- "$STAGE" "$dir/spec" || die "could not move the staged spec into $dir/spec"
  STAGE=
  if ! { printf '%s\n' "$lock_json" > "$dir/spec-lock.json.tmp" \
    && mv -- "$dir/spec-lock.json.tmp" "$dir/spec-lock.json"; }; then
    die "could not write $dir/spec-lock.json"
  fi
  tmp="$STATE/.$id.meta.spec.${BASHPID:-$$}"
  { grep -v '^spec_lock=' "$meta"; echo "spec_lock=$dir/spec-lock.json"; } > "$tmp"
  if ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$STATE"; then
    rm -f -- "$tmp"
    die "task record for $id could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
  fi
  fm_lock_release "$META_LOCK"
  META_LOCK_HELD=0
  echo "locked $(printf '%s' "$lock_json" | jq '.scenarios | length') scenarios in $(printf '%s' "$lock_json" | jq '.files | length') files at $commit: $dir/spec-lock.json"
}

case "${1:-}" in
  show) [ -n "${2:-}" ] || usage; show "$2" ;;
  approve) [ -n "${2:-}" ] || usage; id=$2; shift 2; approve "$id" "$@" ;;
  *) usage ;;
esac
