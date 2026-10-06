#!/usr/bin/env bash
# Command Code crewmate lifecycle on a named non-default Herdr lab session.
set -u
cd /home/peter/.no-mistakes/worktrees/6330e526ab0c/01M47J2F1RFP9FR0RT0A7BJQ6D
ROOT=$PWD
. tests/fixtures.sh
. tests/herdr-test-safety.sh
herdr_forget_inherited_pane
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI
SESSION=$(bin/fm-herdr-lab.sh name ccverify)
export HERDR_SESSION="$SESSION"
LAB=$(mktemp -d /tmp/cch.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
cleanup() { local s=$?; herdr_safe_stop_and_delete "$SESSION"; echo "# teardown of $SESSION rc=$?"; chmod -R u+w "$LAB"; rm -rf "$LAB"; exit $s; }
trap cleanup EXIT
fail() { echo "not ok - $1"; echo "--- pane:"; herdr pane read "$PANE" --session "$SESSION" --source recent --lines 30 2>/dev/null | tail -30; exit 1; }
pass() { echo "ok - $1"; }
echo "# session $SESSION, herdr $(herdr --version)"
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }
. bin/fm-backend.sh; fm_backend_source herdr
. bin/fm-busy-lib.sh
fm_backend_herdr_server_ensure "$SESSION" || fail 'server ensure'
H=$LAB/h; WT=$LAB/wt; P=$LAB/p; ID=cc-herdr
bin/fm-lab-home.sh create "$H" >/dev/null || fail "lab home"; fm_test_spawn_home "$H" commandcode; fm_git_worktree "$P" "$WT" "$ID" >/dev/null 2>&1
git -C "$WT" config user.name t; git -C "$WT" config user.email t@example.invalid
mkdir -p "$H/user-home/.commandcode"
cp ~/.commandcode/auth.json "$H/user-home/.commandcode/"; chmod 600 "$H/user-home/.commandcode/auth.json"
cp ~/.commandcode/settings.json "$H/user-home/.commandcode/settings.json"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt. Do no other work and stop as soon as this is done."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude); ln -s "$(command -v commandcode)" "$fakebin/commandcode"
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$P" \
  --mode local-only --yolo off --harness commandcode --model deepseek/deepseek-v4.1-flash --effort low > "$LAB/spawn.log" 2>&1 || { cat "$LAB/spawn.log"; exit 1; }
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
WS=$(lab workspace create --label fm-cc-verify --cwd "$WT" 2>&1) || fail "workspace create: $WS"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
TARGET="$SESSION:$PANE"
meta="$H/state/$ID.meta"
sed -i "s|^window=.*|window=$TARGET|" "$meta"
WSID=$(printf '%s' "$WS" | jq -r '.result.workspace.workspace_id // .result.workspace_id // .result.root_pane.workspace_id // empty')
TABID=$(printf '%s' "$WS" | jq -r '.result.tab.tab_id // .result.root_pane.tab_id // empty')
echo "# workspace=$WSID tab=$TABID pane=$PANE"
printf 'backend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$WSID" "$TABID" "$PANE" >> "$meta"
export FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
lab pane run "$PANE" "export HOME='$H/user-home'" >/dev/null
sleep 0.5
lab pane run "$PANE" "sh '$LAB/launch.sh'" >/dev/null || fail 'pane run'
wait_file() { local i; for i in $(seq 1 360); do [ -s "$1" ] && return 0; sleep 0.5; done; fail "timeout waiting for ${1##*/}"; }
classify() { fm_busy_classify herdr "$TARGET" commandcode "$ID" "$H/state"; }
wait_idle() { local i; for i in $(seq 1 240); do [ "$(classify)" = 'idle commandcode-mod' ] && return 0; sleep 0.5; done; fail "not idle: $(classify)"; }
wait_empty() { local i v=; for i in $(seq 1 60); do v=$(fm_backend_composer_state herdr "$TARGET" 2>/dev/null); [ "$v" = empty ] && return 0; sleep 0.5; done; fail "composer read '$v'"; }
screen() { herdr pane read "$PANE" --session "$SESSION" --source recent --lines 40 2>/dev/null; }
wait_file "$WT/answer.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'brief result'
wait_idle
echo "# agent get: $(herdr agent get "$PANE" --session "$SESSION" 2>/dev/null | jq -c '{agent: .result.agent.agent, status: .result.agent.agent_status}')"
echo "# fm_backend_agent_state: $(fm_backend_agent_state herdr "$TARGET")"
wait_empty
echo "# fm_backend_composer_state: $(fm_backend_composer_state herdr "$TARGET")"
pass "herdr: spawn-generated launch ran the brief on deepseek/deepseek-v4.1-flash; mod records 'idle commandcode-mod'; composer empty"
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "fm-send: $(cat "$LAB/send.log")"
wait_file "$WT/steer.txt"; wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'steer result'
wait_idle
pass "herdr: fm-send steer delivered ($(cat "$WT/steer.txt")) and inbox acknowledged"
wait_empty
"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool in the foreground, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail "fm-send 2"
for _ in $(seq 1 240); do [ "$(classify)" = 'busy commandcode-mod' ] && break; sleep 0.5; done
[ "$(classify)" = 'busy commandcode-mod' ] || fail 'never busy'
sleep 3
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/int.log" 2>&1 || fail "interrupt: $(cat "$LAB/int.log")"
echo "# interrupt: $(tail -1 "$LAB/int.log")"
for _ in $(seq 1 60); do screen | grep -q 'Interrupted · What should Command Code do instead?' && break; sleep 0.5; done
screen | grep -q 'Interrupted · What should Command Code do instead?' || fail 'no Interrupted render'
wait_idle
[ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail 'interrupt killed agent'
pass "herdr: fm-control interrupt cancelled the busy turn with one Escape; agent alive; mod records idle"
wait_empty
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit: $(cat "$LAB/exit.log")"
echo "# exit: $(tail -1 "$LAB/exit.log")"
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail 'exit left agent'
pass "herdr: fm-control exit via /quit; agent state dead"
gen_before=$(cat "$H/state/$ID.busy-gen" 2>/dev/null)
"$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Runtime relaunch probe: write the product of 13 and 7 into relaunched.txt, then stop.' > "$LAB/rel.log" 2>&1 || fail "relaunch: $(cat "$LAB/rel.log")"
echo "# relaunch: $(tail -1 "$LAB/rel.log")"
wait_file "$WT/relaunched.txt"
[ "$(tr -d '[:space:]' < "$WT/relaunched.txt")" = 91 ] || fail 'relaunch result'
wait_idle
gen_after=$(cat "$H/state/$ID.busy-gen" 2>/dev/null)
[ "$gen_before" != "$gen_after" ] || fail 'busy generation not refreshed'
pass "herdr: fm-control relaunch ran the note (91) and re-armed the mod on a fresh generation"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "final exit: $(cat "$LAB/exit.log")"
pass "herdr: relaunched agent exited cleanly"
