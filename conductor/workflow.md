# Project Workflow: `forseti`

## Guiding Principles

1. **Plan Is Source of Truth:** All implementation work is sequenced and tracked in `conductor/tracks.md` and each track's `plan.md`.
2. **Tech Stack Changes First:** Any dependency, compiler flag, or wire-format deviation must be documented in `conductor/tech-stack.md` *before* implementation.
3. **Red-First 4-Layer ATDD + TDD:**
   - **Behavioral capabilities** start Red-First with a Layer 1 scenario in `specs/*_spec_test.odin` (plus minimal Layer 2 `dsl_test.odin` & Layer 3 `driver_test.odin` wiring), run via `-define:ODIN_TEST_NAMES=forseti_specs.<spec_name>` to confirm expected behavioral failure before editing Layer 4 (`forseti/`).
   - **Low-level infrastructure** (lexer, AST pool, bytecode VM ops, interval/bitset math, `xitdb` binary slot/hasher codecs) uses direct Pattern E unit tests + Pattern D `t.seed` property tests—never ceremonial 4-layer wrappers.
4. **Leak-Checked & Style-Strict Verification:** Every change must pass `odin check` (`-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors`) and `odin test specs -all-packages ... -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
5. **Documentation Freshness:** Any change to `.forseti` DSL grammar, semantics, or diagnostic codes must update `docs/dsl-reference.md`, `usage-rules.md`, and affected `examples/` in the same track.

---

## Branching & Commit Protocol

1. **Dedicated Track Branch Off `master`:** Never commit track implementation directly on `master`. Before coding a track, create a branch or worktree:
   ```bash
   git checkout -b track/<track_id> master
   ```
2. **Consolidated Commits with Updated `plan.md`:** Group implementation, tests, specs, docs, and `plan.md` checkbox updates into cohesive commits (typically one commit per logical task group or phase—never separate "plan-only" commits).
3. **Manual Track Closure Only:** Keep active tracks as `[~]` in `conductor/tracks.md` until the user explicitly authorizes closing `[x]` or archiving.

---

## Standard Task Lifecycle

1. **Select & Mark Active:** Pick the next `[ ]` task in `plan.md` and mark it `[~]`.
2. **Red Phase:**
   - For behavioral tasks: write/update one Layer 1 scenario in `specs/*_spec_test.odin` (with Layer 2 `#caller_location` verbs in `specs/dsl_test.odin` and composable drivers in `specs/driver_test.odin`) and confirm the targeted spec fails for the expected behavioral reason (`-define:ODIN_TEST_NAMES=forseti_specs.<spec_name> -define:ODIN_TEST_FANCY=false`).
   - For infrastructure tasks: write failing Pattern E unit or Pattern D `t.seed` property tests and confirm expected failure.
3. **Green Phase:** Implement the minimal clean solution in `forseti/` / `cmd/forseti/`.
4. **Refactor:** Eliminate duplication, verify shallow nesting, ensure ZII defaults, mark internal symbols `@(private)` / `#+private`, and verify zero leaks.
5. **Verify Gates:**
   ```bash
   COLS="-collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"
   VET="-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors"
   odin check forseti -no-entry-point $COLS $VET
   odin test specs -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
   odin test tests -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
   ```
   *(Include ASan checks on parser/matcher/oracle tracks and `hugi run` on benchmarked tracks.)*
6. **Check Off & Commit:** Mark the task `[x]` in `plan.md` and commit code, specs, tests, docs, and `plan.md` together.

---

## Phase Completion Verification and Checkpointing Protocol

At the end of every Phase (marked `- [ ] Task: Conductor - User Manual Verification '<Phase Name>' (Protocol in workflow.md)`):
1. Run the full strict `odin check`, `odin test specs -all-packages ... -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`, `odin test tests -all-packages ...`, example compile/run checks, and (where applicable) ASan / `hugi` benchmark gates.
2. Perform an **ATDD Audit** on any new or touched `specs/`:
   - No zero-argument DSL theater in Layer 1; domain parameters & expectations live visibly in `*_spec_test.odin`.
   - Every Layer 2 assertion helper and row-constructor table forwards `loc := #caller_location`.
   - SUT internals are `@(private)` / `#+private`; `specs/` compiles black-box against `../forseti`.
   - Zero vacuous/shape-only assertions, zero shared globals across scenarios, and SUT allocations tracked by `context.allocator`.
3. Verify all task checkboxes in the phase reflect actual tested state and `docs/` / `usage-rules.md` reflect any DSL/API additions.
4. Present a concise verification checkpoint report (what ran, exact pass/fail counts, telemetry/benchmark numbers if applicable) and await explicit user verification before advancing to the next phase or marking the track complete.
