#!/usr/bin/env bash
# Live Command Code worker on a real Herdr backend, inside a guarded fm-lab-*
# session owned by bin/fm-herdr-lab.sh. The launch command is the one the real
# bin/fm-spawn.sh generates (fixture spawn records it); the process then runs in
# a real Herdr pane with the task record pointing at that pane, and every later
# read and verb goes through the real Firstmate backend and control plane.
# Usage: drive-commandcode-herdr-lab.sh <worktree-root>
set -u
ROOT=$1
cd "$ROOT" || exit 2
. tests/fixtures.sh
. tests/herdr-test-safety.sh
herdr_forget_inherited_pane
VERSION="commandcode $(commandcode --version 2>/dev/null)"
MODEL=deepseek/deepseek-v4.1-flash
SESSION=$(bin/fm-herdr-lab.sh name cc-gate)
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/cch.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
cleanup() {
  herdr_safe_stop_and_delete "$SESSION" && echo "teardown: lab session $SESSION removed; fleet tripwire verified"
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
trap cleanup EXIT
fail() { printf 'not ok - %s: %s\n' "$VERSION" "$1"; echo '--- pane:'; herdr pane read "$PANE_ID" --session "$SESSION" 2>/dev/null | tail -25; exit 1; }
ok() { printf 'ok - %s: %s\n' "$VERSION" "$1"; }
fm_herdr_lab_prepare "$SESSION" || { echo 'could not prepare lab'; exit 1; }
echo "lab session: $SESSION"
. bin/fm-busy-lib.sh
. bin/fm-backend.sh
. bin/fm-composer-lib.sh
fm_backend_source herdr || fail 'fm_backend_source herdr'

H="$LAB/home"; WT="$LAB/wt"; PROJ="$LAB/project"; ID=cc-herdr
fm_test_spawn_home "$H" commandcode
fm_git_worktree "$PROJ" "$WT" cc-herdr >/dev/null 2>&1
git -C "$WT" config user.name 'CC Herdr Gate'; git -C "$WT" config user.email cc-herdr@example.invalid
mkdir -p "$H/user-home/.commandcode"
cp ~/.commandcode/auth.json "$H/user-home/.commandcode/auth.json"; chmod 600 "$H/user-home/.commandcode/auth.json"
cp ~/.commandcode/settings.json "$H/user-home/.commandcode/settings.json"   # Herdr's own cmd SessionStart hook
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt. Do no other work and stop as soon as this is done."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$(command -v commandcode)" "$fakebin/commandcode"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness commandcode --model "$MODEL" --effort low > "$LAB/spawn.log" 2>&1 || fail "fm-spawn: $(cat "$LAB/spawn.log")"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail 'container_ensure'
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED=${CONTAINER_RAW#*$'\t'}; WS=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED")
EOF
[ -n "$PANE_ID" ] || fail 'create_task'
grep -v -E '^(window|backend|herdr_[a-z_]*)=' "$H/state/$ID.meta" > "$LAB/meta"
{ cat "$LAB/meta"; echo "window=$SESSION:$PANE_ID"; echo backend=herdr; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"; } > "$H/state/$ID.meta"
TARGET="$SESSION:$PANE_ID"
export FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
herdr pane run "$PANE_ID" "cd '$WT' && HOME='$H/user-home' /bin/sh '$LAB/launch.sh'; HOME='$H/user-home' exec /bin/bash --noprofile --norc" --session "$SESSION" >/dev/null \
  || fail 'pane run'
classify() { fm_busy_classify herdr "$TARGET" commandcode "$ID" "$H/state"; }
wait_for() { local i; for i in $(seq 1 "$2"); do eval "$1" && return 0; sleep 0.5; done; return 1; }
wait_for '[ -s "$WT/answer.txt" ]' 480 || fail 'launch brief never executed'
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'wrong answer'
wait_for '[ "$(classify)" = "idle commandcode-mod" ]' 240 || fail "no mod idle: $(classify)"
herdr_agent=$(herdr pane get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '{agent: (.result.pane.agent // .agent), status: (.result.pane.agent_status // .status)}' 2>/dev/null)
echo "herdr pane get: $herdr_agent"
st=$(fm_backend_agent_state herdr "$TARGET"); echo "fm_backend_agent_state: $st"
[ "$st" = alive ] || fail 'not alive'
wait_for '[ "$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null)" = empty ]' 40 \
  || fail "composer read $(fm_backend_composer_state herdr "$TARGET" 2>/dev/null)"
echo "fm_backend_composer_state: empty"
ok 'herdr: real fm-spawn launch ran the brief on deepseek-v4.1-flash; agent alive; idle composer reads empty; mod idle'
bin/fm-send.sh "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "send: $(cat "$LAB/send.log")"
sed 's/^/  fm-send: /' "$LAB/send.log"
wait_for '[ -s "$WT/steer.txt" ] && [ -s "$H/state/$ID.inbox/handled/001.msg" ]' 480 || fail 'steer not done/acknowledged'
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steer result'
wait_for '[ "$(classify)" = "idle commandcode-mod" ]' 240 || fail 'no idle after steer'
ok 'herdr: fm-send steer delivered, executed (1147), and inbox acknowledged'
wait_for '[ "$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null)" = empty ]' 40 || fail 'composer not empty before probe'
bin/fm-send.sh "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool in the foreground, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send2.log" 2>&1 || fail 'send2'
wait_for '[ "$(classify)" = "busy commandcode-mod" ]' 240 || fail 'never busy'
sleep 2
bin/fm-control.sh "$ID" interrupt > "$LAB/int.log" 2>&1 || fail "interrupt: $(cat "$LAB/int.log")"
sed 's/^/  interrupt: /' "$LAB/int.log"
wait_for '[ "$(classify)" = "idle commandcode-mod" ]' 120 || fail "interrupt did not settle idle: $(classify)"
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail 'interrupt killed agent'
herdr pane read "$PANE_ID" --session "$SESSION" 2>/dev/null | grep -q 'Interrupted' || fail 'no Interrupted render'
ok 'herdr: busy turn interrupted with one Escape; agent alive; mod records idle'
wait_for '[ "$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null)" = empty ]' 40 || fail 'composer not empty before exit'
bin/fm-control.sh "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit: $(cat "$LAB/exit.log")"
sed 's/^/  exit: /' "$LAB/exit.log"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail 'exit left agent running'
ok 'herdr: fm-control exit via /quit; agent state dead'
gen_before=$(cat "$H/state/$ID.busy-gen" 2>/dev/null)
bin/fm-control.sh "$ID" relaunch --note 'Runtime relaunch probe: write the product of 13 and 7 into relaunched.txt, then stop.' > "$LAB/relaunch.log" 2>&1 \
  || fail "relaunch: $(cat "$LAB/relaunch.log")"
sed 's/^/  relaunch: /' "$LAB/relaunch.log"
wait_for '[ -s "$WT/relaunched.txt" ]' 480 || fail 'relaunch note not processed'
[ "$(tr -d '[:space:]' < "$WT/relaunched.txt")" = 91 ] || fail 'wrong relaunch result'
wait_for '[ "$(classify)" = "idle commandcode-mod" ]' 240 || fail 'relaunch mod not idle'
gen_after=$(cat "$H/state/$ID.busy-gen" 2>/dev/null)
echo "busy generation: before=$gen_before after=$gen_after"
[ "$gen_before" != "$gen_after" ] || fail 'relaunch did not re-arm a fresh generation'
ok 'herdr: fm-control relaunch ran the note (91) and re-armed the mod on a fresh generation'
bin/fm-control.sh "$ID" exit > "$LAB/exit2.log" 2>&1 || fail "final exit: $(cat "$LAB/exit2.log")"
echo "all herdr scenarios passed"
