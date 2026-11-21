# Implementation Plan: Verified DMN Decision Tables (`Tablex++` / `ZEN`), Static Gap/Overlap Proofs, Dual Cost-Tree/Bitset Compilers, and Tier 3 AOT Odin Codegen

> - **Track ID:** `decision_tables_verifier_and_aot_codegen_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/decision-tables-verifier-and-aot-codegen` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Interval/Domain Partitioning & ZEN-Style Static Table Verifier

- [ ] Task: Implement column domain representations and disjoint interval/enum partitioning (TDD)
    - [ ] Write failing unit tests for boolean, enum, integer/float interval constraints, string literal sets, wildcards (`-`), unsatisfiable cells (`E3002`), and domain exhaustion
    - [ ] Implement `forseti/table_domain.odin` with bounded work budget telemetry
- [ ] Task: Implement overlap, completeness gap, dead-rule, and witness generator (`E3001`, `W3001–W3006`) (TDD)
    - [ ] Write failing tests matching real Connect policy tables (`survivorship_gate`, `identity_routing`, `career_consolidation`, `event_lifecycle`) intentionally injected with overlaps, gaps, and shadowed rows, asserting exact witness counterexamples
    - [ ] Implement `forseti/table_verify.odin` and wire diagnostics into `sema.odin` and `forseti verify-tables`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Static Decision Table Verifier' (Protocol in workflow.md)

---

## Phase 2: Cost-Ordered Lazy Decision Tree & Ternary Bitset Matrix Compilers

- [ ] Task: Implement cost-weighted decision tree builder and zero-alloc lazy evaluator (`F`, `U`, `A`, `P`) (TDD)
    - [ ] Write failing tests verifying lazy thunk invocation counts (expensive column cost `100` skipped when cheap cost `1` decides), exact parity with brute-force row scanning, and zero heap allocations during `decide`
    - [ ] Implement `forseti/table_tree.odin` and `forseti/table_eval.odin`
- [ ] Task: Implement ternary `u64` bitset matrix evaluator for multi-hit policies (`C`, `C+`, `C<`, `C>`, `C#`, `M`, `R`) (TDD)
    - [ ] Write failing property tests comparing bitset evaluation against oracle across 1–500-row randomized tables (`C`, `M`, `R` and aggregators)
    - [ ] Implement `forseti/table_bitset.odin` with `intrinsics.count_trailing_zeros` hit extraction and `Decision_Trace` population
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Cost-Tree & Bitset Matrix Evaluators' (Protocol in workflow.md)

---

## Phase 3: Tier 3 AOT Odin Codegen (`forseti gen`) & Initial `hugi` Table Benchmarks

- [ ] Task: Implement Tier 3 AOT Odin code generator emitting `"contextless"` Odin procedures (TDD)
    - [ ] Write failing tests generating Odin code for `F`/`U`/`C`/`M` tables, running `odin check -vet -vet-tabs -strict-style -disallow-do -warnings-as-errors` on generated files, and executing differential parity checks
    - [ ] Implement `forseti/codegen_odin.odin` and wire `forseti gen` in `cmd/forseti/main.odin`
- [ ] Task: Add initial `hugi`/`obench` decision-table scaling benchmarks (10..10,000 rows; lazy vs eager; runtime vs AOT) and update `docs/dsl-reference.md` (TDD)
    - [ ] Write benchmark targets under `benchmarks/bench_tables.odin` with `@zero_alloc` check and register table diagnostics `E3xxx`/`W3xxx` in `docs/dsl-reference.md`
    - [ ] Run `hugi run` baseline check and verify all tests + ASan pass cleanly
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Tier 3 AOT Codegen & Benchmarks' (Protocol in workflow.md)
