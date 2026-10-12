# Spec gate design

Status: proposed, awaiting captain review.
Branch: `feat/swarmforge-concepts`.
Inspired by the specifier role and operator approval gate in [SwarmForge](https://github.com/unclebob/swarm-forge).

## Summary

A spec gate lets the captain approve executable acceptance scenarios before implementation starts, and makes a ship task's `done:` mechanically depend on every approved scenario passing.
A spec scout writes Gherkin `.feature` files, the captain approves them, firstmate locks them by content hash, promotion carries the lock into the ship task, the worker records an acceptance run, and the existing `done:` gate refuses until the locked spec is unchanged and fully passing at the shipped head.

## Motivation

Today a scout report is free-form prose set by one sentence in `bin/fm-brief.sh`, promotion never passes the report or any approval record to the ship worker, and the only machine gate on a ship `done:` is named-head reachability in `bin/fm-dod-lib.sh`.
Acceptance criteria therefore exist only as prose in `## Captain's intent`, which a reviewer interprets.
SwarmForge shows the value of separating "what to build" (approved, deterministic scenarios) from "how to build it" (implementation under test), with a hard operator gate between them.
The spec gate brings that separation to firstmate without adopting SwarmForge's fixed role pipeline, language-specific quality tools, or tmux runtime.

## Goals

- The captain approves concrete, executable scenarios before any implementation is authorized.
- A ship task promoted from an approved spec cannot report a gated `done:` unless every approved scenario passes at the named head.
- Nobody, including firstmate, can weaken an approved spec without the captain's recorded re-approval.
- The spec lives in the project repo, reviewable in the PR, and outlives the task.
- Works for any language with a Cucumber-family runner that can emit Cucumber JSON.

## Non-goals

- Role pipelines (refactor or architecture passes by further agents), role prompts, a project constitution, and coverage, duplication, or mutation quality gates.
  Each may follow as a separate design.
- Running project code from firstmate's own scripts.
  Workers run acceptance suites; firstmate only reads their records.
- Non-English Gherkin keywords.
- A configurable spec directory; the Cucumber convention `features/` is fixed for now.
- Changing any behavior of ship or scout tasks that do not opt in.

## Lifecycle

```
captain request
   |
   v
1. spec scout      fm-brief.sh <id> <repo> --scout --spec
   |               writes/extends features/*.feature in its worktree, commits locally, writes report.md
   v
2. captain review  firstmate relays scenarios (fm-spec.sh show); captain approves or requests changes
   |
   v
3. approve + lock  fm-spec.sh approve <id> --decision-file <captain words>
   |               -> data/<id>/spec-lock.json, meta spec_lock=1
   v
4. promote         fm-promote.sh <id> --mode ... --yolo ...   (CLI unchanged; detects the lock)
   |               ship instructions add the locked-spec contract
   v
5. worker          fm-acceptance.sh run <id>   (inside its worktree, clean tree)
   |               -> data/<id>/acceptance.json bound to HEAD
   v
6. done: gate      fm_dod_accept_ship_done additionally runs the spec check when spec_lock is set
```

Rules:

- Opt-in: only tasks promoted from an approved spec scout carry `spec_lock`; all other ship and scout paths are unchanged.
- The spec scout never pushes; its feature files are committed only in its scratch copy, and promotion's existing "carry only the intended changes" step carries them.
- Mid-task spec changes: the worker asks firstmate, firstmate escalates to the captain, and only `fm-spec.sh approve` with the captain's recorded words replaces the lock.
- A spec scout is refused when the project registers no `acceptance=` entrypoint.
  On a new project, the first ship task creates the entrypoint at the registered path.

## Components

| Unit | Status | Owns |
|---|---|---|
| `bin/fm-spec-lib.sh` | new | The single owner of the spec-gate contract: lock format, scenario parsing, lock computation from a git tree, and the gate checks. Side-effect free. |
| `bin/fm-spec.sh` | new | Firstmate CLI. `approve <id> --decision-file <f>` resolves the scout's worktree from task meta, locks the `features/**/*.feature` files committed at that worktree's HEAD, and records the captain's words through the existing `fm-captain-hold.sh` answer path. `show <id>` prints locked or candidate scenarios. Re-approval archives the previous lock. |
| `bin/fm-acceptance.sh` | new | Worker CLI. `run <id>` requires a clean tree, invokes the registered entrypoint with a report path, parses Cucumber JSON, and writes the acceptance record. |
| `bin/fm-project-mode.sh` | changed | Recognizes the `acceptance=<repo-relative path>` bracket token and prints it with `--acceptance`, remaining the one registry parser. |
| `bin/fm-brief.sh` | changed | `--scout --spec` renders the spec-scout brief: declarative Gherkin with concrete examples under `features/`, no implementation prescription, open questions in `report.md`. Refuses without `acceptance=`. |
| `bin/fm-promote.sh` | changed | When meta has `spec_lock`, appends the locked-spec steps to `ship-instructions.md` and to `brief.md` for relaunch parity. |
| `bin/fm-dod-lib.sh` | changed | `fm_dod_block` states the acceptance requirement when locked; `fm_dod_accept_ship_done` calls the spec check after the reachability check, so `fm-crew-state.sh`, `fm-pr-check.sh`, and `fm-inactive-reconcile.sh` inherit it unchanged. |
| `scout-completion` skill and `AGENTS.md` section 7 | changed | The skill owns the relay, approval, iteration, and re-approval procedure; `AGENTS.md` gains one pointer line. |
| `docs/spec-gate.md` | new | Operator-facing guide: the `acceptance=` contract and runner examples per language. |

## Registry token

`data/projects.md` bracket tokens gain `acceptance=<path>`, an executable path relative to the project root, containing no spaces.
Like `forge=`, it is a captain-confirmed project fact, not a per-task choice.
The entrypoint contract: invoked from the worktree root with one argument, the absolute path where it must write a Cucumber JSON report; its exit status is informational.

## Data formats

`data/<id>/spec-lock.json`, written by `fm-spec.sh approve`:

```json
{ "version": 1, "task": "<id>", "commit": "<scout HEAD sha>",
  "approved_at": 1791400000, "decision_digest": "<sha256 of captain words>",
  "files":     [ { "path": "features/accounts.feature", "sha256": "..." } ],
  "scenarios": [ { "uri": "features/accounts.feature", "line": 12, "name": "Customer signs up with email" } ] }
```

Re-approval moves the previous lock to `spec-lock.<n>.json`; the unnumbered file is authoritative.

Scenario identity is `uri:line`, not name, so duplicate names cannot collide.
Line numbers are stable because the gate requires locked files to be byte-identical.
Each Scenario Outline example row is its own scenario at its row's line, matching how Cucumber JSON reports expanded examples.
The parser recognizes `Scenario:`, `Example:`, `Scenario Outline:`, `Scenario Template:`, `Examples:`/`Scenarios:` tables, and `Rule:`, and ignores tags, comments, docstrings, and `Background:`.

`data/<id>/acceptance.json`, written by `fm-acceptance.sh run`:

```json
{ "version": 1, "head": "<sha>", "ran_at": 1791400500, "entrypoint": "bin/acceptance",
  "scenarios": [ { "uri": "features/accounts.feature", "line": 12, "name": "...", "status": "passed" } ],
  "counts": { "passed": 14, "failed": 0, "undefined": 0, "pending": 0, "skipped": 0 } }
```

A scenario's status is the worst of its steps and hooks, ordered failed, undefined, pending, skipped, passed.
A non-zero entrypoint exit with readable JSON still records, because statuses carry the truth.
No readable JSON means no record is written and the command fails.

## Gate

When meta has `spec_lock`, `fm_dod_accept_ship_done` runs these checks in order after the reachability check, and a failure downgrades the `done:` to `blocked` through the existing path:

| Condition | Refusal reason |
|---|---|
| `spec-lock.json` missing or unreadable | `spec lock unreadable` (fail closed) |
| A locked file absent or with a different hash at the named head | `locked spec changed: <paths>; needs captain re-approval` |
| No acceptance record, or its `head` differs from the named head | `acceptance run missing` or `acceptance run is for <sha>, not head <sha>` |
| A locked scenario absent from the record | `scenarios not run: <uri:line ...>` |
| Any recorded scenario not `passed` | `scenarios not passing: <uri:line status ...>` |

Scenarios outside the locked files are allowed but must also pass.

## Failure handling

- `fm-spec.sh approve` refuses with no feature files, uncommitted feature changes in the scout copy, or no decision file.
- `fm-acceptance.sh run` refuses a dirty tree, a missing `acceptance=` token, or a non-executable entrypoint.
- Required tools are `jq` and `sha256sum` or `shasum`, both existing firstmate dependencies.

## Accepted limits

- A worker can hand-write `acceptance.json`; the gate is confused-agent-grade, as `bin/fm-lease-lib.sh` defines that grade, not adversary-proof.
- The keyword parser can diverge from a runner on exotic Gherkin; fixtures from real runners bound that risk.
- Runners that cannot emit Cucumber JSON are unsupported until a converter exists.

## Testing

New suites, all through public interfaces:

- `tests/fm-spec-lib.test.sh`: scenario parsing (plain, `Example:`, multi-table outlines, `Rule:`, tags, comments, docstrings mentioning "Scenario"), lock computation from a git tree, and every gate refusal plus the pass case.
- `tests/fm-spec.test.sh`: approve refusals, captain-word recording through the captain-hold path, re-approval archiving, and `show`.
- `tests/fm-acceptance.test.sh`: a fake entrypoint replaying captured cucumber-js and godog Cucumber JSON fixtures, including an outline, to prove `uri:line` identity against real runner output; status derivation, non-zero exit with JSON, missing JSON, dirty tree, and missing token.

Extended suites:

- `tests/fm-project-mode.test.sh`: `--acceptance` parsing and no confusion with the mode token.
- `tests/fm-brief.test.sh`: the `--scout --spec` scaffold and its refusal without `acceptance=`.
- `tests/fm-task-delivery.test.sh`: promotion with a lock adds the contract to both instruction files; promotion without a lock is byte-for-byte unchanged.
- `tests/fm-dod-lib.test.sh` and `tests/fm-crew-state.test.sh`: each gate refusal downgrades to `blocked` with its reason, the pass case is accepted, and unlocked ships behave exactly as before.

Manual end-to-end evidence, not CI: a throwaway project with a small cucumber-js suite taken through spec scout, approval, promotion, acceptance run, and `done:` on the herdr backend.

## First consumer

The HydroBar customer backend (accounts, delivery ordering, subscriptions) in `hydrobar-platform` is the first intended use, once the gate lands in the captain's fork.
