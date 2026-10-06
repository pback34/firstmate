#!/usr/bin/env bash
set -u
cd /home/peter/.no-mistakes/worktrees/6330e526ab0c/01M47J2F1RFP9FR0RT0A7BJQ6D
. tests/fixtures.sh
LAB=$(mktemp -d /tmp/ccb.XXXXXX); trap 'rm -rf "$LAB"' EXIT
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT
H=$LAB/h; WT=$LAB/wt; P=$LAB/p; ID=cc-sm
fm_test_spawn_home "$H" commandcode; fm_git_worktree "$P" "$WT" "$ID" >/dev/null 2>&1; fm_test_spawn_brief "$H" "$ID" x
fakebin=$(make_spawn_fakebin "$LAB/fake" claude); ln -s "$(command -v commandcode)" "$fakebin/commandcode"
echo '== 1. fm-spawn.sh --secondmate with harness commandcode =='
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$P" --secondmate commandcode
echo "exit=$?  launch command written: $([ -s "$LAB/launch.sh" ] && echo yes || echo no)"
echo
echo '== 2. fm-bootstrap.sh validating config/crew-dispatch.json =='
B=$LAB/boot; mkdir -p "$B/config" "$B/state" "$B/data"
for rules in \
  '{"rules":[{"when":"small, clear task or a second-opinion read","use":{"harness":"commandcode","model":"deepseek/deepseek-v4.1-flash","effort":"low"}}]}' \
  '{"rules":[{"when":"small task","use":{"harness":"cmd","model":"deepseek/deepseek-v4.1-flash"}}]}'; do
  printf '%s\n' "$rules" > "$B/config/crew-dispatch.json"
  echo "rules: $rules"
  out=$(env -u TYPESAFE_API_KEY FM_HOME="$B" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$B/state" FM_CONFIG_OVERRIDE="$B/config" FM_DATA_OVERRIDE="$B/data" FM_BOOTSTRAP_VERBOSE_FACTS=1 bin/fm-bootstrap.sh 2>&1 | grep -E 'CREW_DISPATCH|crew dispatch')
  echo "  -> ${out:-<no crew-dispatch complaint>}" | sed 's/^/  /'
done
echo
echo '== 3. commit-msg strip of the Command Code co-author trailer =='
printf 'Add answer\n\nCo-authored-by: CommandCodeBot <noreply@commandcode.ai>\nCo-authored-by: Jane Human <jane@example.com>\n' > "$LAB/msg"
echo '-- before:'; cat "$LAB/msg"
bin/fm-git-strip-ai-trailers.sh "$LAB/msg"; echo "-- after (exit $?):"; cat "$LAB/msg"
