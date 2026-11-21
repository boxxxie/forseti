# Specification: Longitudinal `hugi`/`obench` Scaling Benchmarks (`10` to `1,000,000` Rules) & Telemetry-Guided Optimization

> - **Track ID:** `million_rule_benchmarks_and_telemetry_suite_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`, `phreak_rete_ul_matcher_and_guard_vm_20261121`, `jtms_accumulators_stratified_datalog_and_provenance_20261121`

---

## 1. Problem Statement & Motivation

Claiming PHREAK/Rete-UL scales to `1,000,000` rules or that `xitdb` + provenance stays fast in MDM pipelines is meaningless without reproducible, longitudinal measurements across scale orders of magnitude. Using [`hugi`](../../../../hugi/README.md) (`hugi.json`) and [`obench`](../../../../hugi/deps/obench/README.md), we need an automated scaling benchmark suite across **`10`, `100`, `1,000`, `10,000`, `100,000`, and `1,000,000` rules** paired with deep Forseti telemetry breakdowns so every hotspot is quantified and eliminated.

---

## 2. Architecture

- **Deterministic Rule/Fact Scale Generator (`benchmarks/gen_workload.odin`):** Generates seeded `.forseti` / `Rulebase_IR` suites and `xitdb` datasets at `N in {10, 100, 1_000, 10_000, 100_000, 1_000_000}` rules without skewing timed loops.
- **6 Benchmark Suites (`benchmarks/`):**
  1. `bench_scale_selective_fanout` (`10`..`1,000,000` rules): Compile time, `Rulebase` RAM, `Session` init time/RAM, and single-fact / 100-fact incremental `fire()` latency testing PHREAK lazy unlinking and sparse memory.
  2. `bench_scale_beta_joins` (`10`..`100,000` join rules): 2-way and 3-way hash-indexed Beta joins with selective match rates.
  3. `bench_scale_jtms_churn`: High-churn insert/update/retract cascades synced via `xitdb.diff_collection`.
  4. `bench_decision_tables`: `10`..`10,000` table rows, cost-tree lazy evaluation vs eager evaluation, `C`/`M` bitset matrix, and Tier 3 AOT Odin procs.
  5. `bench_recursive_strata`: Cyclic & deep DAG org/event hierarchy saturation (`10`..`100,000` edges) + JTMS edge removals.
  6. `bench_mdm_e2e_modes`: Full MDM ingestion pipeline comparing `.Audit_Full` vs `.Support_Only` vs `.Fast`, and `xitdb` `Safe_V2` vs opt-in `Fast_Memory`.
- **Telemetry & Hardware Counters:** Capture per-phase nanoseconds (`lex/parse/compile`, `diff_sync`, `alpha`, `beta_join`, `vm`, `jtms`, `provenance`, `xitdb_commit`), RAM footprint, `obench` `@zero_alloc` assertions, and `hugi` hardware perf counters (`cycles`, `instructions`, `branch_misses`, `cache_misses`) persisted to `benchmarks/history.hugidb`.

---

## 3. Functional Requirements

### FR-1: Parameterized `hugi` / `obench` Scaling Suite (`10`..`1,000,000` Rules)
- Implement all 6 benchmark groups using `hugi` stateful `Pipeline` + `obench` `@params` sweeps (`10, 100, 1_000, 10_000, 100_000, 1_000_000`).
- Separate setup/compile/teardown cleanly from timed incremental execution passes (`0 ns` telemetry/allocator wrapper overhead in unwrapped baseline pass, plus dedicated telemetry & `@zero_alloc` passes).

### FR-2: Telemetry Profiler Analysis & Hotspot Optimization Pass
- Inspect Chrome Trace JSON and per-phase telemetry reports at `100k` and `1M` rules to find and optimize top bottlenecks (cache locality, hash bucket density, bitmask scanning, `xitdb` delta batching, memory compaction).
- Record before/after `hugi` statistical deltas (`Mann-Whitney U` / `Welch's t-test`) in `benchmarks/history.hugidb`.

### FR-3: Published Scaling & Telemetry Report (`docs/benchmarks.md`)
- Export formatted Markdown tables and scaling curves/summaries into `docs/benchmarks.md` documenting latency, memory per rule (`Rulebase` vs `Session`), throughput, and `.Audit_Full` vs `.Fast` overhead.

---

## 4. Non-Functional & Verification Requirements

- Generated benchmark workloads (`10`..`10,000` smoke scale) must pass `specs/` behavioral sanity assertions (confirming expected derived MDM outcomes and zero memory leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`) before executing longitudinal `hugi run` sweeps.
- `1,000,000`-rule compile + `session_init` + incremental `fire` benchmark must complete cleanly on the local machine without OOM or pathological quadratic scaling.
- `hugi run` executes end-to-end and persists clean snapshots into `benchmarks/history.hugidb`.

---

## 5. Out of Scope

- End-user tutorials and non-benchmark CLI docs (Track 7).

---

## 6. Acceptance Criteria

- [ ] All 6 benchmark workloads run cleanly under `hugi run` across `10, 100, 1_000, 10_000, 100_000, 1_000_000` rules and record into `benchmarks/history.hugidb`.
- [ ] Telemetry exports phase-by-phase breakdown + Chrome Trace JSON at `1,000,000` rules, confirming sub-linear matching work for unlinked rules.
- [ ] Hot-path incremental matching passes dedicated `@zero_alloc` check (per-tick scratch stays in pre-reserved arenas).
- [ ] At least one telemetry-driven optimization pass shows statistically verified speedup/memory reduction in `hugi`, documented in `docs/benchmarks.md`.
