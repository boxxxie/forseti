# Project Workflow: `forseti`

## Guiding Principles

1. **Plan Is Source of Truth:** All implementation work is sequenced and tracked in `conductor/tracks.md` and each track's `plan.md`.
2. **Tech Stack Changes First:** Any dependency, compiler flag, or wire-format deviation must be documented in `conductor/tech-stack.md` before implementation.
3. **Strict Test-Driven Development (TDD):** Every task follows **Red (failing test) -> Green (minimal passing implementation) -> Refactor**.
4. **Leak-Checked & Style-Strict Verification:** Every change must pass `odin check` (`-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors`) and `odin test` (`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).
5. **Documentation Freshness:** Any change to `.forseti` DSL grammar, semantics, or diagnostic codes must update `docs/dsl-reference.md`, `usage-rules.md`, and affected `examples/` in the same track.

---

## Branching & Commit Protocol

1. **Dedicated Track Branch Off `master`:** Never commit track implementation directly on `master`. Before coding a track, create a branch or worktree:
   ```bash
   git checkout -b track/<track_id> master
   ```
2. **Consolidated Commits with Updated `plan.md`:** Group implementation, tests, docs, and `plan.md` checkbox updates into cohesive commits (typically one commit per logical task group or phase—never separate "plan-only" commits).
3. **Manual Track Closure Only:** Keep active tracks as `[~]` in `conductor/tracks.md` until the user explicitly authorizes closing `[x]` or archiving.

---

## Standard Task Lifecycle

1. **Select & Mark Active:** Pick the next `[ ]` task in `plan.md` and mark it `[~]`.
2. **Red Phase:** Write failing unit, property, differential, or 4-layer ATDD tests; run `odin test` to confirm they fail for the right reason.
3. **Green Phase:** Implement the minimal clean solution in `forseti/` / `cmd/forseti/`.
4. **Refactor:** Eliminate duplication, verify shallow nesting, ensure ZII defaults and explicit allocator cleanup.
5. **Verify Gates:**
   ```bash
   COLS="-collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"
   VET="-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors"
   odin check forseti -no-entry-point $COLS $VET
   odin test tests -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
   ```
   *(Include `specs/` once ATDD harness exists, ASan checks on parser/matcher tracks, and `hugi run` on benchmarked tracks.)*
6. **Check Off & Commit:** Mark the task `[x]` in `plan.md` and commit code, tests, docs, and `plan.md` together.

---

## Phase Completion Verification and Checkpointing Protocol

At the end of every Phase (marked `- [ ] Task: Conductor - User Manual Verification '<Phase Name>' (Protocol in workflow.md)`):
1. Run the full strict `odin check`, leak-checked `odin test -all-packages`, example compile/run checks, and (where applicable) ASan / `hugi` benchmark gates.
2. Verify all task checkboxes in the phase reflect actual tested state and `docs/` / `usage-rules.md` reflect any DSL/API additions.
3. Present a concise verification checkpoint report (what ran, exact pass/fail counts, telemetry/benchmark numbers if applicable) and await explicit user verification before advancing to the next phase or marking the track complete.
