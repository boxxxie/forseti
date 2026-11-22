# Specification: Sleipnir (`package actor`) Multi-Threaded Session Runtime, Partitioned Tenant Supervision & Parallel Async Effects

> - **Track ID:** `sleipnir_actor_multithreaded_runtime_20261122`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** Tracks 3, 4, 5, 6, 8 (`cross_os_ci_hygiene_and_v0_1_0_release_20261122`)

---

## 1. Problem Statement & Motivation

Forseti's core `Session` is intentionally single-threaded, pinned, and lock-free inside one rule evaluation cycle, while compiled `Rulebase` structures are immutable and `xitdb` supports stateless positional `core_read_at` snapshots across threads. However, scaling Forseti across multi-core production workloads (multi-tenant MDM pipelines, burst ingestion, parallel counterfactual `diff_replay`, fault-isolated rule sessions, and non-blocking async `effect` workers) currently forces callers to hand-roll OS threads, queues, and synchronization.

Rather than adding coarse mutexes around `Session` or inventing bespoke thread pools, Forseti can pair cleanly with sibling Odin actor runtime [**Sleipnir (`package actor`)**](https://github.com/boxxxie/sleipnir) (`v1.1.3+`, matching `heimdall` and `bifrost`):
1. **Zero-Actor Core Isolation:** `forseti/` stays zero-dependency (`base:*`, `core:*`, `xitdb`) so single-threaded embeds pay zero actor overhead. All Sleipnir integration lives in a clean sibling package **`actors/`** (`package forseti_actors`, importing `../forseti`, `xitdb:.`, and `actor:.`).
2. **Actor-Per-Session Ownership (`Session_Actor`):** Each `Session` is owned exclusively by one Sleipnir actor—eliminating locks inside PHREAK, JTMS, and `String_Interner` while running hundreds or thousands of independent tenant/shard sessions across Sleipnir's `M:N` work-stealing scheduler.
3. **Single-Writer `xitdb` + Lock-Free Snapshot Readers:** A single `Xitdb_Commit_Actor` serializes durable commits (`.decisions`, `.idx.*`, `.__tx`) and broadcasts O(1) `Commit_Notification{moment_idx}` messages while concurrent query/overlay actors read snapshots lock-free via `core_read_at`.
4. **OTP Supervision & Trapped Fault Recovery:** Sleipnir's `Supervisor`, `Partitioned_Supervisor`, `Registry(string)`, and `actor.try_call` isolate buggy policies or panicking effect handlers and re-hydrate recovered tenant sessions from the latest `xitdb` moment.

---

## 2. Architecture

```text
  Producers (HTTP / CDC / Tests)
      │  actor.send(pid, []Msg) [Chain=K single XCHG]  OR  Sharded_SPSC_Mailbox
      ▼
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Tenant_Rule_Runtime (actor.Partitioned_Supervisor + Registry)      │
  │   ├─ Partition 0 ──▶ Session_Actor("tenant:acme")  [pinned Session] │
  │   └─ Partition P ──▶ Session_Actor("tenant:beta")  [pinned Session] │
  └───────┬──────────────────────────┬───────────────────────────┬──────┘
          │ shared read-only         │ Effect_Job                │ Commit_Derived_Batch
          ▼                          ▼                           ▼
   ^forseti.Rulebase      Supervised Effect_Dispatcher     Xitdb_Commit_Actor
   (Immutable + CoW Swap)  (M:N workers, actor.reply)      (Single-Writer Store_Bridge)
                                                                 │
                                                                 ▼
                                                     Concurrent Overlay Diff_Replay
                                                     (Core_Overlay + core_read_at)
```

- **Plumbing & Collection Convention:**
  - Sibling checkout at `../sleipnir/actor` (`v1.1.3+`), declared in `ols.json` (`"actor": "../sleipnir/actor"`), `.github/workflows/ci.yml`, and `conductor/tech-stack.md`, matching `heimdall` and `bifrost`.
- **Package Boundaries:**
  - `forseti/` — Zero `actor` imports; provides immutable `^Rulebase` (audited for zero interior mutation post-compile) and stateless `xitdb` positional snapshot reads.
  - `actors/` (`package forseti_actors`) — Sleipnir runtime layer (`Session_Actor`, `Xitdb_Commit_Actor`, `Tenant_Rule_Runtime`, `Effect_Dispatcher`, `Parallel_Diff_Replay`, `Rulebase_Coordinator`).
  - `specs_actors/` (`package forseti_actors_specs`) — Black-box 4-layer ATDD behavioral specs (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true`), plus `tests/` concurrency tests and `examples/08_sleipnir_actor_runtime/`.

---

## 3. Functional Requirements

### FR-1: `Rulebase` & `Store_Bridge` Concurrency Contract Audit
- Audit `Rulebase`, `String_Interner`, `Compiled_Table`, `Alpha_Node.eq_buckets`, `Telemetry_Sink` interactions, and `schema_field_hashes`/`binding_path_hashes` to ensure 100% read-only thread safety across `N` concurrent `Session`s sharing one `^Rulebase`.
- Ensure per-session telemetry can isolate into per-actor `Telemetry_Sink` buffers (merged/exported without data races) when running multi-threaded.
- Add multi-threaded read-contention tests (`N` worker threads / actors reading one `Rulebase` and one `Store_Bridge` snapshot simultaneously under `-sanitize:address` / race stress).

### FR-2: `Session_Actor`, `Chain=K` Batching & `Xitdb_Commit_Actor`
- Implement `Session_Actor` pinning `^forseti.Session` inside actor state (initialized inside `on_init`, destroyed deterministically inside `on_stop`, never copied by value).
- Typed `Session_Msg` tagged union supporting `Insert_Fact`, `Insert_Batch`, `Retract_Fact`, `Fire_Session`, `Sync_And_Fire`, `Run_Query`, `Explain_Fact`, `Impact_Rule`, `Apply_Effects`, and `Swap_Rulebase`, driven via `actor.call`, `actor.try_call`, and `actor.send` slice batching (`Chain=K`).
- Optional `actor.Sharded_SPSC_Mailbox` ingest fast-path for dedicated producer threads feeding a hot `Session_Actor`.
- Implement single-writer `Xitdb_Commit_Actor` serializing derived/audit batch commits onto `Store_Bridge` (`Safe_V2`) and pushing lightweight `Commit_Notification{moment_idx}` messages back to subscriber actors.

### FR-3: Multi-Tenant `Partitioned_Rule_Supervisor`, Sleipnir `Effect_Dispatcher` & `Parallel_Diff_Replay`
- Wrap Sleipnir's `actor.Partitioned_Supervisor` + `actor.Registry(string)` into `Tenant_Rule_Runtime` with lazy on-demand tenant `Session_Actor` creation, OTP restart policies (`.One_For_One` / `.Rest_For_One`) that re-hydrate working memory from the latest persisted `xitdb` moment on crash recovery, and `sweep_idle_tenants` TTL eviction.
- Implement `Effect_Dispatcher`: `Session_Actor` calls `session_prepare_effects`, fans out `Effect_Job` envelopes by `job.kind` to supervised effect worker actors (reading only copied `Effect_Job.fields`—zero access to `Session` or `sess.interner`), and delivers `Effect_Result` via Sleipnir envelope-header `actor.reply` back to the originating `Session_Actor` for `session_apply_effects` + re-fire.
- Implement `Parallel_Diff_Replay` spawning concurrent actor tasks across candidate `^Rulebase` versions, each executing inside an isolated `xitdb.Core_Overlay` fork against the same frozen parent `Store_Bridge` snapshot (`parent_moments_before == parent_moments_after`).

### FR-4: Hot-Reload `Rulebase_Coordinator`, 4-Layer ATDD Specs, Example `08` & `hugi` Benchmarks
- Implement `Rulebase_Coordinator` compiling updated `.forseti` policies off the hot path, running `check` / `verify_all_tables` / `stratify_ir` validation, publishing new `^Rulebase` handles via `Swap_Rulebase`, and retiring old `^Rulebase` instances only after atomic ref-count drainage reaches `0`.
- Deliver Red-First 4-layer ATDD specs in `specs_actors/`, runnable leak-checked `examples/08_sleipnir_actor_runtime/`, and multi-worker `hugi` concurrency benchmarks (`1..8` workers, `Chain=K`, multi-tenant fan-out, and parallel `diff_replay`).

---

## 4. Non-Functional & Verification Requirements

- Core `forseti/` package MUST remain free of `actor` imports (`odin check forseti -no-entry-point -collection:xitdb=../xitdb/xitdb` passes without `-collection:actor`).
- Zero memory leaks and zero bad frees across actor spawns, supervisor restarts, tenant eviction, `Chain=K` bursts, and hot-reload swaps (`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` + `-sanitize:address`).
- Zero data races or `Session` / `String_Interner` cross-thread mutations.

---

## 5. Out of Scope

- Distributed multi-node actor networking / RPC across hosts.
- Replacing core single-threaded `forseti.Session` internals with mutexes.

---

## 6. Acceptance Criteria

- [ ] `Rulebase` and `Store_Bridge` snapshot read paths pass multi-threaded stress & immutability audits with zero shared writes.
- [ ] `Session_Actor`, `Xitdb_Commit_Actor`, `Tenant_Rule_Runtime`, `Effect_Dispatcher`, `Parallel_Diff_Replay`, and `Rulebase_Coordinator` pass all 4-layer `specs_actors/` behavioral specs and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` + ASan.
- [ ] `examples/08_sleipnir_actor_runtime/` runs leak-free and `hugi` actor scaling benchmarks (`1..8` workers) are recorded and documented.
