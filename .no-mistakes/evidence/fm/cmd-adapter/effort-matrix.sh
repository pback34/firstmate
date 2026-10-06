#!/usr/bin/env bash
# Drives real fm-spawn.sh for Command Code crewmates across model/effort pairs,
# then runs each generated launch command against the real commandcode binary
# in a private tmux server with an isolated HOME (auth copied, read-only source).
set -u
cd /home/peter/.no-mistakes/worktrees/6330e526ab0c/01M47J2F1RFP9FR0RT0A7BJQ6D
. tests/fixtures.sh
REAL_TMUX=$(command -v tmux)
CC=$(command -v commandcode)
LAB=$(mktemp -d /tmp/ccm.XXXXXX); LAB=$(cd "$LAB" && pwd -P)
SOCK="$LAB/t.sock"
trap '"$REAL_TMUX" -S "$SOCK" kill-server >/dev/null 2>&1; [ -n "${KEEP:-}" ] || { chmod -R u+w "$LAB"; rm -rf "$LAB"; }' EXIT
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS GEMINI_CLI
i=0
for pair in deepseek/deepseek-v4.1-flash:low deepseek/deepseek-v4.1-flash:medium deepseek/deepseek-v4.1-flash:high deepseek/deepseek-v4.1-flash:xhigh deepseek/deepseek-v4.1-flash:max deepseek/deepseek-v4.1-flash-fast:low; do
  i=$((i+1)); model=${pair%:*}; effort=${pair##*:}
  H="$LAB/h$i"; WT="$LAB/wt$i"; P="$LAB/p$i"; ID=cc-effort-$i
  fm_test_spawn_home "$H" commandcode
  fm_git_worktree "$P" "$WT" "$ID" >/dev/null 2>&1
  git -C "$WT" config user.name t; git -C "$WT" config user.email t@example.invalid
  fm_test_spawn_brief "$H" "$ID" "Runtime verification only: write the word ok into ok.txt using your shell tool, then stop. Do nothing else."
  fakebin=$(make_spawn_fakebin "$LAB/fake$i" claude); ln -s "$CC" "$fakebin/commandcode"
  FM_FAKE_LAUNCH_LOG="$LAB/launch$i.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$P" \
    --mode local-only --yolo off --harness commandcode --model "$model" --effort "$effort" > "$LAB/spawn$i.log" 2>&1
  src=$?
  ef=$(grep -o -- "--effort '[a-z]*'" "$LAB/launch$i.sh" || echo '(no --effort flag)')
  mf=$(grep -o -- "--model '[^']*'" "$LAB/launch$i.sh")
  mkdir -p "$H/user-home/.commandcode"; cp ~/.commandcode/auth.json "$H/user-home/.commandcode/auth.json"; chmod 600 "$H/user-home/.commandcode/auth.json"
  "$REAL_TMUX" -S "$SOCK" new-session -d -s "s$i" -x 120 -y 40 -c "$WT" \
    "HOME='$H/user-home' /bin/sh '$LAB/launch$i.sh'; echo LAUNCH-EXIT=\$?; exec sleep 600"
  res=timeout
  for _ in $(seq 1 120); do
    [ -s "$WT/ok.txt" ] && { res="worker wrote ok.txt"; break; }
    "$REAL_TMUX" -S "$SOCK" capture-pane -p -t "s$i" | grep -q 'LAUNCH-EXIT=' && { res="launch exited: $("$REAL_TMUX" -S "$SOCK" capture-pane -p -t "s$i" | grep -E 'Unknown|Error|LAUNCH-EXIT' | tr '\n' ' ')"; break; }
    sleep 1
  done
  busy=$(cat "$H/state/$ID.busy" 2>/dev/null | tr '\n' ' ')
  printf 'request %-38s spawn_rc=%s %s %-22s -> %s\n' "$pair" "$src" "$mf" "$ef" "$res"
  "$REAL_TMUX" -S "$SOCK" send-keys -t "s$i" Escape; sleep 0.3
  "$REAL_TMUX" -S "$SOCK" kill-session -t "s$i"
done
# Contrast: what the vendor does with the omitted values if they were passed through.
for e in medium xhigh; do
  printf 'vendor direct: commandcode --model deepseek/deepseek-v4.1-flash --effort %s -> ' "$e"
  HOME="$LAB/h1/user-home" timeout 20 "$CC" --model deepseek/deepseek-v4.1-flash --effort "$e" --print 'x' </dev/null 2>&1 | tr '\n' ' ' | cut -c1-140; echo " (exit ${PIPESTATUS[0]})"
done
