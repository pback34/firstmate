# Spec gate operator guide

The spec gate lets the captain approve executable acceptance scenarios before implementation starts.
It then holds a gated ship's `done:` until every approved scenario passes at the named head.
This page covers when to use the gate, how to register a project for it, the commands in lifecycle order, and which runners are supported.
The scout and captain-hold procedure is in the [`scout-completion` skill](../.agents/skills/scout-completion/SKILL.md#spec-scouts), and the lock and record formats are owned by [`bin/fm-spec-lib.sh`](../bin/fm-spec-lib.sh).

## When to use it

Use a spec scout when the captain wants approved, executable acceptance scenarios before any implementation is authorized.
The gate is opt-in: only a task promoted from an approved spec scout is gated, and every other ship or scout task behaves as before.
The scenarios live in the project repository under `features/`, which is the fixed spec directory, and Gherkin keywords are English only.

## Register the project

Add an `acceptance=<path>` bracket token to the project's `data/projects.md` entry, where `<path>` is an executable entrypoint relative to the project root with no spaces:

```
- my-project [no-mistakes acceptance=bin/acceptance] - Example project (added 2026-10-12)
```

The token's syntax is owned by [`bin/fm-project-mode.sh`](../bin/fm-project-mode.sh), and `bin/fm-project-mode.sh --acceptance <project>` prints the path firstmate will use.
A path that is absolute or escapes the project is refused.
A spec scout requires a registered entrypoint, and on a project that has none yet the first ship task creates the entrypoint at the registered path.

## Lifecycle

Run the commands in this order.

1. Scout: brief a spec scout with the registered entrypoint, `bin/fm-brief.sh <id> <repo> --scout --spec --acceptance "$(bin/fm-project-mode.sh --acceptance <project>)"`.
   The scout writes and commits `features/**/*.feature` in its scratch copy, and it never pushes.
2. Review: hold the scout for the captain with `bin/fm-captain-hold.sh hold <id> --reason "approve spec scenarios"`, and show the scenarios with `bin/fm-spec.sh show <id>`.
   If the captain asks for changes, the scout iterates and the hold stays.
3. Approve: `bin/fm-spec.sh approve <id> --decision-file <file holding the captain's exact words>` records those words as a release on the hold, archives the committed feature files under `data/<id>/spec/`, and writes `data/<id>/spec-lock.json`.
   A new approval re-locks, and the previous lock and archive move to numbered copies as [`bin/fm-spec.sh`](../bin/fm-spec.sh) documents.
4. Promote: promote the scout in place with [`bin/fm-promote.sh`](../bin/fm-promote.sh) as for any scout.
   For a locked task the promoted ship instructions carry the locked-spec contract, and promotion refuses when the archived files no longer match the lock.
5. Run acceptance: the worker runs `bin/fm-acceptance.sh run <id>` as its last step, on its final head, with no commits afterwards.
   [`bin/fm-acceptance.sh`](../bin/fm-acceptance.sh) owns its refusals and exit codes.
6. Gated done: a gated `done:` for a locked task is refused until the locked files are unchanged and every scenario passes at the named head.
   The check is `fm_spec_gate` in [`bin/fm-spec-lib.sh`](../bin/fm-spec-lib.sh), which `fm_dod_accept_ship_done` in [`bin/fm-dod-lib.sh`](../bin/fm-dod-lib.sh) calls.
   The no-mistakes pre-validation `done:` stays ungated, so the pipeline can start.
7. Spec change: a locked ship that needs a different spec goes back to the captain.
   Only a new approval with the captain's new words replaces the lock.

## Runners

The gate reads Cucumber JSON, so a runner needs an entrypoint that writes its report to the path it is given.
The entrypoint runs from the worktree root with one argument, the absolute path for the report, and only a zero exit can pass the gate.

For cucumber-js, the proven runner, a complete entrypoint is:

```bash
#!/usr/bin/env bash
# bin/acceptance - write a Cucumber JSON report to "$1"; exit non-zero on any failure.
set -euo pipefail
exec npx cucumber-js --format "json:$1"
```

Make it executable with `chmod +x bin/acceptance`, and register `acceptance=bin/acceptance`.

| Runner | Status |
| --- | --- |
| cucumber-js | Proven by captured fixtures. |
| godog, with `godog run --format "cucumber:$1"` | Unverified until captured fixtures exist. |
| Cucumber-JVM, with `--plugin "json:$1"` | Unverified until captured fixtures exist. |
| pytest-bdd | Unsupported: its Cucumber JSON omits undefined steps and reports skipped steps as `passed`, a false pass the gate cannot detect. |

The record format and the status mapping are owned by [`bin/fm-spec-lib.sh`](../bin/fm-spec-lib.sh).

## Herdr placement

Writing `off` to the home's `config/herdr-presentation-spaces` keeps a spec scout and its promoted ship in one task tab of the launcher's workspace, because promotion keeps the same endpoint.
The [presentation spaces](herdr-backend.md#presentation-spaces) section owns that setting.

## Limits

- The gate is confused-agent-grade, as [`bin/fm-lease-lib.sh`](../bin/fm-lease-lib.sh) defines that grade, so it is not adversary-proof: a worker can hand-write `acceptance.json`.
- The keyword parser can diverge from a runner on exotic Gherkin, and captured runner fixtures bound that risk.
- Scenarios outside the locked files are allowed, but they must also pass.
- Runners that cannot emit Cucumber JSON are unsupported until a converter exists.
- The gate needs `jq` and either `sha256sum` or `shasum`.
- For a no-mistakes ship the gate attests the worker copy's HEAD, not the head the pipeline pushed.
  The contract tells the worker to bring pipeline fixes into the copy before the final acceptance run, but nothing compares the two.
