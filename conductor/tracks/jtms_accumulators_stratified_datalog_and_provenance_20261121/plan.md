# Implementation Plan: Z-Set JTMS, Retractable Accumulators, Tarjan SCC Stratified Datalog, Semiring Causal Provenance, and 3-Phase Async Effects

> - **Track ID:** `jtms_accumulators_stratified_datalog_and_provenance_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`, `phreak_rete_ul_matcher_and_guard_vm_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/jtms-accumulators-stratified-datalog-and-provenance` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Z-Set JTMS, Negation (`not`/`exists`) & Retractable Accumulators

- [ ] Task: Implement Z-set JTMS support-count store and transitive cascade retraction (TDD)
    - [ ] Write failing unit & diamond-dependency tests verifying logical `assert` vs `assert! ... unconditional`, multi-justification survival, and transitive cascades
    - [ ] Implement `forseti/jtms.odin` and wire into `Session` / `Agenda`
- [ ] Task: Implement `not`/`exists` blocker counters & retractable accumulators (`count`, `sum`, `avg`, `min`, `max`, `distinct`, `collect`) (TDD)
    - [ ] Write failing property tests asserting accumulator outputs match brute-force recomputation across random insert/update/retract sequences (specifically stressing `min`/`max` ties and removals)
    - [ ] Implement `forseti/beta_negation.odin` and `forseti/beta_accum.odin` using explicit `Eval_Stack` pause/resume
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Z-Set JTMS, Negation & Accumulators' (Protocol in workflow.md)

---

## Phase 2: Tarjan SCC Stratification & Cyclic-Safe Semi-Naive Recursion

- [ ] Task: Implement compile-time Tarjan SCC stratification and `E4001` cycle diagnostics (TDD)
    - [ ] Write failing tests verifying unstratified negation/aggregation cycles emit `E4001` with exact cycle path while positive recursive rules compile into ordered strata
    - [ ] Implement `forseti/stratify.odin` (wired into `sema.odin` & `rulebase_compile.odin`)
- [ ] Task: Implement semi-naive delta evaluator with Soufflé-style `proof_height` tracking (TDD)
    - [ ] Write failing tests on cyclic org-parent and person-merge graphs proving guaranteed termination, minimal finite proof height, and clean JTMS retraction when cycle edges are removed
    - [ ] Implement `forseti/seminaive.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Stratified Semi-Naive Recursion' (Protocol in workflow.md)

---

## Phase 3: Compact `#soa` Provenance, Semirings, `xitdb` Persistence, 3-Phase Effects & Differential Oracle

- [ ] Task: Implement `#soa` Derivation arena, `xitdb` atomic provenance writer, semiring views, `explain`/`impact`/`diff_replay` (TDD)
    - [ ] Write failing tests verifying atomic `decisions` + `idx.decisions_*` + `__tx` commits, `Boolean`/`Why`/`How`/`Viterbi` semiring projections, `Core_Overlay`-backed `diff_replay`, and `.Audit_Full` vs `.Fast` modes
    - [ ] Implement `forseti/provenance.odin`, `forseti/semiring.odin`, `forseti/xitdb_provenance.odin`, and `forseti/diff_replay.odin`
- [ ] Task: Implement Runic-style 3-phase `Prepare -> Execute -> Apply` async effects and differential brute-force oracle fuzz suite (TDD)
    - [ ] Write failing tests for parallel `Effect_Job` execution + causal parent ancestry AND `>= 10,000`-op randomized differential oracle fuzz tests under `-sanitize:address`
    - [ ] Implement `forseti/effects.odin` and `tests/fuzz_oracle.odin`, verifying zero mismatches and zero leaks
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Provenance, Effects & Differential Oracle' (Protocol in workflow.md)
