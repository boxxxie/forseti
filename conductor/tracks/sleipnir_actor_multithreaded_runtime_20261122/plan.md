# Implementation Plan: Sleipnir (`package actor`) Multi-Threaded Session Runtime, Partitioned Tenant Supervision & Parallel Async Effects

> - **Track ID:** `sleipnir_actor_multithreaded_runtime_20261122`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Tracks 3, 4, 5, 6, 8
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/sleipnir-actor-multithreaded-runtime` branch, Red-First 4-layer ATDD + TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Concurrency Contract Audit (`Rulebase` & `Store_Bridge`) & Sleipnir Plumbing

- [x] Task: Wire sibling Sleipnir dependency (`-collection:actor=../sleipnir/actor`, `v1.1.3+`) into `ols.json`, CI, and `conductor/tech-stack.md`
    - [x] Add `actor` collection to `ols.json`, `conductor/tech-stack.md`, and `.github/workflows/ci.yml` (`boxxxie/sleipnir` checkout for `actors/` / `specs_actors/` / `examples/08_*`) while keeping `forseti/` zero-actor
    - [x] Scaffold `actors/` (`package forseti_actors`), `specs_actors/` (`package forseti_actors_specs`), and strict `odin check` commands
- [x] Task: Audit & test `Rulebase` read-only immutability and lock-free `Store_Bridge` concurrent reads (TDD)
    - [x] Audit `Rulebase` fields (`String_Interner.lookup`, `Alpha_Node.eq_buckets`, `Compiled_Table`, `Telemetry_Sink` pointer handling, `schema_field_hashes`, `binding_path_hashes`) for zero mutation during concurrent session evaluation
    - [x] Write multi-threaded stress tests spawning N concurrent `Session`s sharing one `^Rulebase` and reading one frozen `Store_Bridge` snapshot (`core_read_at`), verified under `-sanitize:address` and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [x] Task: Conductor - User Manual Verification 'Phase 1: CI Hygiene, Actions Upgrade & Repo Polish' -> 'Phase 1: Concurrency Contract Audit & Sleipnir Plumbing' (Protocol in workflow.md)

---

## Phase 2: `Session_Actor`, Batched Ingestion (`Chain=K`) & Single-Writer `Xitdb_Commit_Actor`

- [x] Task: Implement `Session_Actor` with pinned `^forseti.Session`, `actor.call` / `try_call`, and `Chain=K` batching (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 behavioral specs in `specs_actors/session_actor_spec_test.odin` covering lifecycle (`on_init` / `on_stop`), synchronous `Run_Query` / `Explain_Fact` via `actor.call`, and slice-batched `Insert_Batch` (`Chain=K`)
    - [x] Implement `actors/session_actor.odin` (`Session_Actor`, `Session_Msg` union, pinned `^forseti.Session`, optional `Sharded_SPSC_Mailbox` ingest lane, per-actor `Telemetry_Sink`)
- [x] Task: Implement single-writer `Xitdb_Commit_Actor` with `Commit_Notification` broadcasting (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 specs verifying serialized multi-session derived/audit commits (`decisions`, `idx.*`, `__tx`) into `Store_Bridge` with zero `xitdb` write contention and accurate `moment_idx` notifications
    - [x] Implement `actors/commit_actor.odin` (`Xitdb_Commit_Actor`) and verify zero leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Session_Actor & Single-Writer Xitdb_Commit_Actor' (Protocol in workflow.md)

---

## Phase 3: Multi-Tenant `Partitioned_Rule_Supervisor`, Sleipnir `Effect_Dispatcher` & Parallel `diff_replay`

- [x] Task: Implement `Tenant_Rule_Runtime` on Sleipnir `Partitioned_Supervisor` + `Registry(string)` (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 specs covering lazy tenant spawn, trapped worker fault recovery (`actor.try_call` + `.One_For_One` restart re-hydrating state from `xitdb`), and `sweep_idle_tenants` cleanup
    - [x] Implement `actors/tenant_supervisor.odin` (`Tenant_Rule_Runtime`, lifecycle hooks, per-tenant isolation)
- [x] Task: Implement Sleipnir `Effect_Dispatcher` (3-phase async effects) and `Parallel_Diff_Replay` over `Core_Overlay` forks (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 specs verifying `Effect_Job` routing by `kind`, worker crash isolation via supervisor, `actor.reply` correlation back into `session_apply_effects`, and concurrent multi-candidate `Parallel_Diff_Replay` with zero parent store mutation
    - [x] Implement `actors/effect_dispatcher.odin` and `actors/parallel_diff_replay.odin`
- [x] Task: Conductor - User Manual Verification 'Phase 3: Partitioned Tenant Supervision, Effect Dispatcher & Parallel Diff Replay' (Protocol in workflow.md)

---

## Phase 4: Hot-Reload `Rulebase_Coordinator`, Example `08` & `hugi` Concurrency Benchmarks

- [ ] Task: Implement off-hot-path `Rulebase_Coordinator` with ref-counted `^Rulebase` grace reclamation (Red-First 4-Layer ATDD)
    - [ ] Write failing Layer 1 specs verifying live `.forseti` recompile, atomic `Swap_Rulebase` rollout across active `Session_Actor`s, rejection of invalid policies without disrupting running sessions, and zero leaks of retired `Rulebase`s
    - [ ] Implement `actors/rulebase_coordinator.odin`
- [ ] Task: Create leak-checked `examples/08_sleipnir_actor_runtime/`, update `tests/test_examples_verify.odin`, and add `hugi` concurrency benchmarks
    - [ ] Implement `examples/08_sleipnir_actor_runtime/main.odin`, register in `tests/test_examples_verify.odin` (passing `-collection:actor=../sleipnir/actor`), and document actor embedding in `docs/odin-api.md` / `README.md`
    - [ ] Add `hugi` actor scaling benchmarks (`1..8` workers, `Chain=K`, parallel `diff_replay`), run full strict check + `specs` + `specs_actors` + `tests` (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true`) + ASan
- [ ] Task: Conductor - User Manual Verification 'Phase 4: Hot-Reload Coordinator, Example 08 & Concurrency Benchmarks' (Protocol in workflow.md)
