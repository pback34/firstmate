# Spec gate design

Status: revised after review (findings in `.reviews/REVIEW-2026-10-12-spec-gate-design.md`, local only); approved for planning.
Branch: `feat/swarmforge-concepts`.
Inspired by the specifier role and operator approval gate in [SwarmForge](https://github.com/unclebob/swarm-forge).

## Summary

A spec gate lets the captain approve executable acceptance scenarios before implementation starts, and makes a ship task's ready report mechanically depend on every approved scenario passing.
A spec scout writes Gherkin `.feature` files, the captain approves them, firstmate archives and locks them by content hash, promotion restores them into the ship branch, the worker records an acceptance run as its last step, and every path that accepts a gated ship `done:` refuses until the locked spec is unchanged and fully passing at the named head.

## Motivation

Today a scout report is free-form prose set by one sentence in `bin/fm-brief.sh`, promotion never passes the report or any approval record to the ship worker, and the only machine gate on a ship `done:` is named-head reachability in `bin/fm-dod-lib.sh`.
Acceptance criteria therefore exist only as prose in `## Captain's intent`, which a reviewer interprets.
SwarmForge shows the value of separating "what to build" (approved, deterministic scenarios) from "how to build it" (implementation under test), with a hard operator gate between them.
The spec gate brings that separation to firstmate without adopting SwarmForge's fixed role pipeline, language-specific quality tools, or tmux runtime.

## Goals

- The captain approves concrete, executable scenarios before any implementation is authorized.
- A ship task promoted from an approved spec cannot have a gated `done:` accepted unless every approved scenario passes at the named head.
- Nobody, including firstmate, can weaken an approved spec without the captain's recorded re-approval.
- The spec lives in the project repo, reviewable in the PR, and outlives the task.
- Works for runners whose Cucumber JSON is proven faithful by captured fixtures: cucumber-js is proven; godog and Cucumber-JVM are verified in the plan's first task or documented as unverified.
- pytest-bdd is unsupported: a 2026-10-12 probe showed its `--cucumberjson` omits undefined steps and reports `pytest.skip` steps as `passed`, a false pass the gate cannot detect.

## Non-goals

- Role pipelines, role prompts, a project constitution, and coverage, duplication, or mutation quality gates; each may follow as a separate design.
- Firstmate's supervision executing project code: the worker-invoked `fm-acceptance.sh` runs the project's entrypoint, and the gate only reads records.
- Non-English Gherkin keywords.
- A configurable spec directory; the Cucumber convention `features/` is fixed for now.
- Changing any behavior of ship or scout tasks that do not opt in.
- Herdr placement changes; see [Herdr](#herdr).

## Lifecycle

```
captain request
   |
   v
1. spec scout      fm-brief.sh <id> <repo> --scout --spec --acceptance <path>
   |               writes/extends features/*.feature, commits in its scratch copy, writes report.md
   v
2. captain review  firstmate holds the scout (fm-captain-hold.sh hold <id>), relays scenarios (fm-spec.sh show)
   |               captain approves or requests changes (scout iterates, hold stays)
   v
3. approve + lock  fm-spec.sh approve <id> --decision-file <words> [--hold <backlog-id>]
   |               records the captain's words via fm-captain-hold.sh answer <hold> --decision-file <words> --release
   |               -> data/<id>/spec/features/** (archived contents) + data/<id>/spec-lock.json, meta spec_lock=<absolute path to data/<id>/spec-lock.json>
   v
4. promote         fm-promote.sh <id> --mode ... --yolo ...   (CLI unchanged; preflights and appends the locked-spec contract)
   |
   v
5. worker          restores data/<id>/spec/features/** into the branch, implements test-first,
   |               finishes the delivery path, then as its LAST step on the final head:
   |               fm-acceptance.sh run <id>  -> data/<id>/acceptance.json bound to that head
   v
6. done: gate      fm_dod_spec_gate runs first for every gated done of a locked task, on every acceptance path
```

Rules:

- Opt-in: only tasks promoted from an approved spec scout carry `spec_lock`; all other ship and scout paths are unchanged.
- The scout never pushes, and its scratch copy is disposable; `approve` archives the feature file contents into the task's data directory, so nothing depends on the scratch copy surviving.
- Approval is a release, not a completion: the scout task is held while the captain reviews, and `fm-spec.sh approve` records the captain's words with `fm-captain-hold.sh answer <hold> --decision-file <words> --release` so the same task proceeds to promotion.
  That recording is idempotent on an exact retry and is rejected when the newest captain-hold record has another mode, which makes `approve` refuse.
- Mid-task spec changes: the worker escalates to firstmate, firstmate holds the task for the captain, and only a new `fm-spec.sh approve` with the captain's new decision file replaces the lock.
- Owning home: every `fm-spec.sh` and captain-hold command runs in the home that owns the task; for a secondmate-owned scout, scenario relay and the captain's answer travel over the existing marked-request parent channel (`bin/fm-send.sh`, `bin/fm-pending-reply-lib.sh`).
- A spec scout requires a registered `acceptance=` entrypoint; on a new project the first ship task creates the entrypoint at the registered path.

## Components

| Unit | Status | Owns |
|---|---|---|
| `bin/fm-spec-lib.sh` | new | The single owner of the spec-gate contract: lock and record formats, scenario parsing, URI normalization, the status map, `fm_dod_spec_gate`'s checks, and the locked-spec contract text (`fm_spec_ship_contract`). Side-effect free. |
| `bin/fm-spec.sh` | new | Firstmate CLI. `show <id>` prints candidate (scout copy) or locked scenarios. `approve <id> --decision-file <words> [--hold <backlog-id>]` (`--hold` defaults to the task id) resolves the scout worktree from task meta, archives `features/**/*.feature` committed at that HEAD into a staging copy, and records the captain's words as a release with `fm-captain-hold.sh answer <hold> --decision-file <words> --release` before the lock is written. It then writes `data/<id>/spec/`, the lock with `approval` set to `captain-hold:<hold-id> sha256:<sha of the decision file>`, and sets `spec_lock=<absolute path to data/<id>/spec-lock.json>` under the meta lock with atomic publish. Re-approval archives the previous lock and spec directory. |
| `bin/fm-acceptance.sh` | new | Worker CLI. `run <id>` requires a clean tree, invokes the entrypoint recorded in the brief with an absolute report path, parses Cucumber JSON, and writes the acceptance record. |
| `bin/fm-project-mode.sh` | changed | Recognizes `acceptance=<path>` as a keyed token (never the mode) and prints it only through a separate `--acceptance` query, leaving the posture line and its branch-last invariant untouched. |
| `bin/fm-brief.sh` | changed | `--scout --spec --acceptance <path>` renders the spec-scout brief and records `Acceptance entrypoint: <path>` machine-readably; refuses `--spec` without `--acceptance` and `--acceptance` without `--spec`. It still never reads the registry. |
| `bin/fm-spawn.sh` | changed | Refuses a spec-scout brief whose recorded entrypoint disagrees with `fm-project-mode.sh --acceptance`, mirroring its existing mode and branch agreement checks. |
| `bin/fm-promote.sh` | changed | When meta has `spec_lock`: preflights that the archived files match the lock hashes (refuses otherwise), and appends the locked-spec contract (`fm_spec_ship_contract` in `bin/fm-spec-lib.sh`) after the delivery contract to `ship-instructions.md` and `brief.md`. |
| `bin/fm-dod-lib.sh` | changed | `fm_dod_block` is unchanged; the acceptance-last requirement comes from the locked-spec contract instead. `fm_dod_accept_ship_done` calls `fm_dod_spec_gate` immediately after `fm_dod_should_gate_ship_done` and before every early acceptance return. |
| `bin/fm-pr-check.sh` | changed | Its forge-head shortcut that skips `fm_dod_accept_ship_done` does not apply to a locked task. |
| `scout-completion` skill, `captain-hold-lifecycle` skill, `AGENTS.md` section 7 | changed | The skills own the hold, relay, release-approval, iteration, and re-approval procedure; `AGENTS.md` gains one pointer line. |
| `docs/spec-gate.md` | new | Operator guide: when to use a spec scout, registering `acceptance=`, and per-runner entrypoint examples; formats are linked to their script owners, not restated. Classified in `docs/documentation-audiences.json`. |

## Registry token

`data/projects.md` bracket tokens gain `acceptance=<path>`, an executable path relative to the project root, containing no spaces.
Like `forge=`, it is a captain-confirmed project fact, not a per-task choice; firstmate resolves it with `fm-project-mode.sh --acceptance` and passes it explicitly to `fm-brief.sh`.
The entrypoint contract: invoked from the worktree root with one argument, the absolute path where it must write a Cucumber JSON report; its exit status is recorded, and only a zero exit can pass the gate.

## Data formats

`data/<id>/spec/` holds the archived `features/**/*.feature` files exactly as committed at the scout HEAD.

`data/<id>/spec-lock.json`, written by `fm-spec.sh approve`:

```json
{ "version": 1, "task": "<id>", "commit": "<scout HEAD sha>", "approved_at": 1791400000,
  "approval": "captain-hold:<hold-id> sha256:<sha of the decision file>",
  "files":     [ { "path": "features/accounts.feature", "sha256": "..." } ],
  "scenarios": [
    { "uri": "features/accounts.feature", "line": 12, "name": "Customer signs up with email", "steps": 4 },
    { "uri": "features/accounts.feature", "line": 31, "name": "Plan <plan>", "steps": 3, "outline_line": 25, "ordinal": 1 } ] }
```

`steps` counts the scenario's own steps plus every `Background:` step that applies to it (feature-level, and rule-level inside a `Rule:`); outline rows additionally carry `outline_line` and a 1-based `ordinal`.

The task's meta `spec_lock=` holds the absolute path of `data/<id>/spec-lock.json`, and the acceptance record is always the sibling `acceptance.json` of that lock.

Re-approval moves the previous lock and spec directory to `spec-lock.<n>.json` and `spec.<n>/`; the unnumbered ones are authoritative.

Scenario identity is `(uri, line)`, with the outline fallback below, and with `uri` normalized to a repo-relative path by stripping `file:` and `classpath:` schemes, converting absolute paths under the worktree to relative ones, and normalizing separators.
Line numbers are stable because the gate requires locked files to be byte-identical.
Runners disagree on Scenario Outline rows: cucumber-js reports each example row at the row's own line, while pytest-bdd reports every row at the outline's line (2026-10-12 probe).
The lock therefore records each outline row with its row `line`, its `outline_line`, and its `ordinal` among that outline's rows in document order, and a recorded element matches a row by row line or, failing that, by outline line and its order of appearance among elements reported at that line.
The parser recognizes `Scenario:`, `Example:`, `Scenario Outline:`, `Scenario Template:`, `Examples:`/`Scenarios:` tables, `Rule:`, and `Background:` (for step counts), counts lines starting with a step keyword (`Given`, `When`, `Then`, `And`, `But`, `*`), and ignores tags, comments, data tables, and docstring contents.

`data/<id>/acceptance.json`, written by `fm-acceptance.sh run`:

```json
{ "version": 1, "head": "<sha>", "ran_at": 1791400500, "entrypoint": "bin/acceptance", "exit": 0,
  "scenarios": [ { "uri": "features/accounts.feature", "line": 12, "name": "...", "steps": 4, "status": "passed" } ],
  "counts": { "passed": 14, "failed": 0, "undefined": 0, "pending": 0, "skipped": 0, "ambiguous": 0, "unknown": 0 } }
```

The status map is closed: `passed`, `failed`, `undefined`, `pending`, `skipped`, `ambiguous`, and `unknown` for any other runner status.
A scenario's status is the worst of its steps and hooks, ordered failed, ambiguous, unknown, undefined, pending, skipped, passed; only `passed` passes.
A recorded scenario with fewer steps than the locked file defines for it (its background steps plus its own) gets status `unknown`, because some runners omit undefined steps instead of reporting them.
Recorded step counts exclude hook entries (elements of `before`/`after`, and `steps` entries that are `hidden: true` or have keyword `Before`/`After`), while hook statuses still contribute to the scenario's status.
A non-zero entrypoint exit with readable JSON still records, with `exit` stored in the record; no readable JSON means no record is written and the command fails.

## Gate

`fm_dod_spec_gate` applies only to a gated done: `fm_dod_should_gate_ship_done` already exempts the no-mistakes pre-validation `done:` handoff, and that exemption is unchanged, so a locked task can still start its pipeline.
For a gated done of a task whose meta has `spec_lock`, `fm_dod_accept_ship_done` calls it before the recorded-PR, Gerrit, and reachability acceptance paths, and `fm-pr-check.sh` never skips the gate for a locked task.
The gate's named head is the worker copy's `HEAD`; a locked task whose copy is missing is refused rather than accepted on recorded PR metadata.

| Condition | Refusal reason |
|---|---|
| `spec-lock.json` missing or unreadable | `spec lock unreadable` (fail closed) |
| Worker copy missing or HEAD unresolvable | `named head cannot be verified for a locked spec` |
| A locked file absent or with a different hash at the named head | `locked spec changed: <paths>; needs captain re-approval` |
| No acceptance record, or its `head` differs from the named head | `acceptance run missing` or `acceptance run is for <sha>, not head <sha>; rerun fm-acceptance.sh as the last step` |
| The record's entrypoint `exit` is non-zero | `acceptance entrypoint exited <n>` |
| A locked scenario absent from the record | `scenarios not run: <uri:line ...>` |
| Any recorded scenario not `passed` | `scenarios not passing: <uri:line status ...>` |

Scenarios outside the locked files are allowed but must also pass.
A refusal downgrades the done to `blocked` through the existing callers: `fm-crew-state.sh`, `fm-pr-check.sh`, and `fm-inactive-reconcile.sh`.

## Ordering against delivery

The locked-spec contract tells the worker to run `fm-acceptance.sh run` last: after implementation, after the no-mistakes pipeline's fixes are in the copy (and after Gerrit custody recovery where that applies), on the exact head its ready report names, with no commits afterwards.
A refused gated done is retried from the acceptance step, not re-implemented, unless the refusal names failing scenarios.

## Failure handling

- `fm-spec.sh approve` refuses: no feature files at the scout HEAD; uncommitted feature changes; a missing or unreadable scout worktree (with the reason, and before writing anything); a captain-hold release that `fm-captain-hold.sh answer` rejects, such as a newest record with another mode.
- `fm-promote.sh` refuses a locked task whose archived files do not match the lock.
- `fm-acceptance.sh run` refuses a dirty tree, a missing recorded entrypoint, or a non-executable entrypoint.
- Required tools are `jq` and `sha256sum` or `shasum`, both existing firstmate dependencies.

## Accepted limits

- A worker can hand-write `acceptance.json`; the gate is confused-agent-grade, as `bin/fm-lease-lib.sh` defines that grade, not adversary-proof.
- The keyword parser can diverge from a runner on exotic Gherkin; real-runner fixtures bound that risk.
- Runners that cannot emit Cucumber JSON are unsupported until a converter exists.

## Herdr

The spec gate needs no Herdr change: promotion is in place, so a spec scout and its ship share one endpoint from scenarios to PR.
One-tab-per-task in the launcher's workspace is already available by writing `off` to the home's `config/herdr-presentation-spaces` ([herdr-backend.md](../../herdr-backend.md#presentation-spaces)).
A pane-per-task placement would be new adapter capability with restart-recovery and prune-safety costs and is out of scope.

## Testing

New suites, all through public interfaces:

- `tests/fm-spec-lib.test.sh`: scenario parsing (plain, `Example:`, multi-table outlines, `Rule:`, tags, comments, docstrings mentioning "Scenario"), URI normalization for each form, the status map including `ambiguous` and unknown values, every gate refusal plus the pass case, and the `fm_spec_ship_contract` text.
- `tests/fm-spec.test.sh`: approve refusals (no files, dirty, missing worktree, a rejected release such as a default-mode answer), the release-approval sequence through a fake captain-hold binary (`FM_CAPTAIN_HOLD_BIN`) that records the `answer <hold> --decision-file <words> --release` call, archiving and locking, the lock's `approval` field, meta write, re-approval archiving, and `show`.
- `tests/fm-acceptance.test.sh`: a fake entrypoint replaying captured cucumber-js fixtures (and godog and Cucumber-JVM where captured) including outlines, Rule blocks, ambiguous and pending steps, an outline-line-only shape, and a step-omitting shape; non-zero exit with JSON; missing JSON; dirty tree; missing entrypoint.

Extended suites:

- `tests/fm-project-mode.test.sh`: `--acceptance`, the token never becoming the mode, and an empty `branch=` still parsing with `acceptance=` present.
- `tests/fm-brief.test.sh`: the `--scout --spec --acceptance` scaffold and its flag refusals.
- `tests/fm-spawn*` (the suite owning brief agreement): entrypoint disagreement refusal.
- `tests/fm-task-delivery.test.sh`: promotion with a lock appends the contract to both instruction files and refuses mismatched archives; promotion without a lock is unchanged.
- `tests/fm-dod-lib.test.sh`, `tests/fm-crew-state.test.sh`, `tests/fm-pr-check-security.test.sh`, and the `fm-inactive-reconcile` suite: a locked task's gated done is refused through the recorded-PR path, the Gerrit path, the reachability path, and the `fm-pr-check.sh` forge-head shortcut; the pre-validation done stays ungated; unlocked ships behave exactly as before.
- `tests/fm-spec-e2e.test.sh`: an end-to-end fixture test in a throwaway git repo: approve, promote, restore, record, and gate acceptance, runnable in CI without a real runner.

`tests/fm-captain-hold-lifecycle.test.sh` is not extended, because the release-approval sequence is covered by `tests/fm-spec.test.sh` through the fake captain-hold binary.

Manual evidence, not CI: a throwaway project with a small cucumber-js suite taken through the full lifecycle on the Herdr backend, one secondmate-owned spec scout, and the real `fm-captain-hold.sh` release-approval check in Task 12 of `docs/superpowers/plans/2026-10-12-spec-gate.md`.

## First consumer

The HydroBar customer backend (accounts, delivery ordering, subscriptions) in `hydrobar-platform` is the first intended use, once the gate lands in the captain's fork.
