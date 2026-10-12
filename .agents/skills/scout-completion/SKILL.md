---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, record the report as the Done artifact, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.

## Spec scouts

Use a spec scout (`fm-brief.sh --scout --spec --acceptance "$(bin/fm-project-mode.sh --acceptance <project>)"`) when the captain wants approved, executable acceptance scenarios before implementation; the project must register `acceptance=`.
When it reports done, hold the scout itself with `bin/fm-captain-hold.sh hold <id> --reason "approve spec scenarios"` and relay `bin/fm-spec.sh show <id>` plus the report's open questions.
If the captain asks for changes, steer the scout and keep the hold.
On approval, run `bin/fm-spec.sh approve <id> --decision-file <captain's exact words>`; it records the release and locks the spec, and only then promote in place.
A locked ship that needs a spec change goes back to the captain; a new approval re-locks with the same command.
For a secondmate-owned task every command runs in that home, and the captain's words travel over the parent channel.
`bin/fm-spec-lib.sh`'s header owns the formats; `docs/spec-gate.md` is the operator guide.
