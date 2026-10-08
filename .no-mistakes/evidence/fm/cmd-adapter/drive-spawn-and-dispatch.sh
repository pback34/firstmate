#!/usr/bin/env bash
# Ad-hoc driver: runs the real bin/fm-spawn.sh and bin/fm-bootstrap.sh against a
# disposable home with a fake backend binary, printing a transcript.
set -u
cd "$1"
. tests/fixtures.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/cc-drive.XXXXXX"); trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
home=$T/home; proj=$T/proj; wt=$T/wt
fm_test_spawn_home "$home" commandcode
fm_git_worktree "$proj" "$wt" cc-drive >/dev/null 2>&1
fakebin=$(make_spawn_fakebin "$T/fake" claude)
ln -s "$(command -v commandcode)" "$fakebin/commandcode"
spawn() { local id=$1; shift; fm_test_spawn_brief "$home" "$id"
  FM_FAKE_LAUNCH_LOG="$T/$id.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness commandcode "$@" 2>&1; }
echo "### effort routing (generated launch command, model/effort flags only)"
for pair in "deepseek/deepseek-v4.1-flash low" "deepseek/deepseek-v4.1-flash high" "deepseek/deepseek-v4.1-flash max" "deepseek/deepseek-v4.1-flash xhigh" "deepseek/deepseek-v4.1-flash-fast low" "deepseek/deepseek-v4.1-flash-fast max"; do
  set -- $pair; id="e-$(echo "$1-$2" | tr '/.' '--')"
  spawn "$id" --model "$1" --effort "$2" >/dev/null || { echo "spawn failed $pair"; continue; }
  flags=$(grep -o -- "--model '[^']*'\( --effort '[^']*'\)\?" "$T/$id.launch")
  printf '%-40s -> %s   (meta: %s)\n' "$pair" "$flags" "$(grep '^effort=' "$home/state/$id.meta")"
done
echo; echo "### backend guard (commandcode refused off tmux/herdr, nothing provisioned)"
cat > "$fakebin/orca" <<'O'
#!/bin/sh
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
O
chmod +x "$fakebin/orca"
for b in zellij cmux orca; do
  out=$(spawn "g-$b" --backend "$b"); rc=$?
  printf 'backend=%s rc=%s launched=%s task_record=%s busy_armed=%s\n  %s\n' "$b" "$rc" \
    "$([ -e "$T/g-$b.launch" ] && echo yes || echo no)" "$([ -e "$home/state/g-$b.meta" ] && echo yes || echo no)" \
    "$([ -e "$home/state/g-$b.busy-gen" ] && echo yes || echo no)" "$out"
done
echo; echo "### secondmate refusal"
fm_test_spawn_brief "$home" sm1
fm_test_run_spawn "$home" "$wt" "$fakebin" sm1 "$proj" --secondmate --harness commandcode 2>&1 | head -2; echo "rc=${PIPESTATUS[0]}"
