# Implementation Plan: Longitudinal `hugi`/`obench` Scaling Benchmarks (`10` to `1,000,000` Rules) & Telemetry-Guided Optimization

> - **Track ID:** `million_rule_benchmarks_and_telemetry_suite_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`, `phreak_rete_ul_matcher_and_guard_vm_20261121`, `jtms_accumulators_stratified_datalog_and_provenance_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/million-rule-benchmarks-and-telemetry-suite` branch, strict TDD, `hugi` + `-vet`).

---

## Phase 1: Parameterized `hugi`/`obench` Scaling Harness (`10`..`1,000,000` Rules)

- [x] Task: Build deterministic workload generator, `specs/` behavioral sanity verification, and `10`..`1,000,000`-rule fan-out & Beta-join benchmarks (TDD + ATDD sanity)
    - [x] Write smoke tests and `specs/` behavioral sanity checks (`10`..`10k` scale smoke mode) confirming zero leaks and expected MDM rule derivations before timed runs
    - [x] Implement `benchmarks/gen_workload.odin`, `benchmarks/bench_scale_rules.odin`, and `benchmarks/bench_joins.odin`
- [x] Task: Build JTMS churn, recursive strata, and E2E MDM mode comparison (`Audit_Full` vs `Fast`, `Safe_V2` vs `Fast_Memory`) benchmarks (TDD)
    - [x] Write smoke verification tests covering all 6 workloads and `@zero_alloc` hot-path checks
    - [x] Implement `benchmarks/bench_jtms.odin`, `benchmarks/bench_recursive.odin`, and `benchmarks/bench_mdm_e2e.odin`; execute baseline `hugi run`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: 10–1M Rule Benchmark Baseline' (Protocol in workflow.md)

---

## Phase 2: Telemetry Flamegraph Audit, Optimization Pass & `docs/benchmarks.md`

- [x] Task: Profile `100k`/`1M` runs with Forseti Telemetry + hardware perf counters and implement bottleneck optimizations (TDD)
    - [x] Write regression/correctness checks covering any optimized matcher/hash/delta paths before refactoring
    - [x] Apply targeted data-oriented optimizations driven by telemetry/perf-counter evidence and record post-optimization `hugi run` deltas
- [x] Task: Export longitudinal results and author `docs/benchmarks.md`
    - [x] Export tables/JSON from `benchmarks/history.hugidb` via `hugi` and document `10`..`1,000,000` rule latency, RAM/rule, telemetry breakdowns, and mode tradeoffs in `docs/benchmarks.md`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Telemetry Optimization & Benchmark Report' (Protocol in workflow.md)
