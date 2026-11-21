# Specification: Z-Set JTMS, Retractable Accumulators, Tarjan SCC Stratified Datalog, Semiring Causal Provenance, and 3-Phase Async Effects

> - **Track ID:** `jtms_accumulators_stratified_datalog_and_provenance_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`, `phreak_rete_ul_matcher_and_guard_vm_20261121`

---

## 1. Problem Statement & Motivation

This track brings Forseti to full MDM & expert-system sophistication, resolving every limitation identified across `Tablex`, `Runic`, `O'Doyle/Pararules`, and `Clara Rules`:
- **Automatic Consistency on Upstream Edits:** Source corrections and steward overrides require automatic transitive retraction (JTMS) so derived facts never go stale.
- **Aggregations & Negation:** Real MDM escalation rules (`count`, `sum`, `min`, `max`, `not FrozenOrg(...)`) must incrementally update on both inserts and retractions.
- **Cycle-Safe Recursive Hierarchies:** Org parent-child freeze propagation and person merge closures need stratified semi-naive recursion that terminates on cyclic CRM graphs while recording minimal finite proof trees.
- **First-Class Causal Audit Trails:** Replace `Runic`'s per-fact SHA-256 + `:_step_trace` workaround with a compact `#soa[dynamic]Derivation` arena, atomic `xitdb` persistence (`decisions`, `idx.decisions_by_entity`, `idx.decisions_by_rule`, `__tx`), algebraic semiring evaluators, `explain`, `impact`, `diff_replay`, and Runic-style 3-phase external effects (`Prepare -> Execute -> Apply`).

---

## 2. Architecture

- **Z-Set JTMS (`assert` logical vs `assert! ... unconditional`):** Every logical assertion records a justification `{rule_id, token_id -> fact_id}` and increments support weight `+1`. Retracting a premise emits `-1` and transitively cascades retractions when support hits `0`, preserving independently justified facts.
- **Negation (`not`/`exists`) & Retractable Accumulators:** Per-left-token blocker counts + PHREAK subnetwork pause/resume (`Eval_Stack`). Accumulators (`count`, `sum`, `avg`, `min`/`max` via `O(log k)` indexed sorted bag, `distinct`, `collect`) implement `{init, insert, retract, finalize}` cleanly.
- **Tarjan SCC Stratification + Semi-Naive Recursion:** Compile-time Tarjan SCC detects rule cycles; rejects unstratified `not`/aggregation cycles (`E4001`); executes positive recursive strata via delta-driven semi-naive saturation with Soufflé-style `proof_height` so cyclic graphs yield minimal acyclic proof DAGs.
- **Compact `#soa` Provenance + Semiring Views:**
  - `#soa[dynamic]Derivation` (`32 B` per derivation: `derived_fact`, `rule_id`, `rule_ver`, `table_row_id`, `parent_span`, `origin_kind`, `weight`). Zero hot-path crypto hashing!
  - Atomic `xitdb` commit of `derived.*`, `decisions[id]`, `idx.decisions_by_entity`, `idx.decisions_by_rule`, and `__tx` metadata.
  - Pluggable semiring evaluators (`Boolean`, `Why`, `How`, `Viterbi`) over the stored derivation DAG + `explain()`, `impact()`, and `Core_Overlay`-backed `diff_replay()`.
  - Provenance modes: `.Audit_Full` (default), `.Support_Only`, `.Fast` (opt-out).
- **3-Phase Async Effects:** `Prepare -> Execute -> Apply` (`session_prepare_effects` -> host parallel/async execution -> `session_apply_effects` linking returned facts to parent `Derivation_Id`).

---

## 3. Functional Requirements

### FR-1: Z-Set JTMS, Negation (`not`/`exists`) & Retractable Accumulators
- Support logical `assert` (default) and `assert! ... unconditional` in DSL/IR.
- Implement transitive JTMS cascades (`100`% parity with brute-force re-evaluation from scratch after any insert/retract sequence).
- Implement `not`, `exists`, and retractable `count`, `sum`, `avg`, `min`, `max`, `distinct`, `collect`.

### FR-2: Tarjan SCC Stratification & Cyclic-Safe Semi-Naive Recursion
- Detect SCCs at compile time; emit `E4001` with full offending cycle trace on unstratified negation/aggregation.
- Execute recursive strata via semi-naive delta loop with `proof_height` tracking for minimal proof selection.

### FR-3: Compact Provenance, Semirings, `xitdb` Audit Persistence & Counterfactual `diff_replay`
- Commit compact decision provenance atomically into `xitdb` (`decisions`, `idx.decisions_by_entity`, `idx.decisions_by_rule`, `__tx.decision_ids`, `__tx.rule_versions`).
- Implement `explain(fact_id)`, `impact(rule_id, version)`, `evaluate_semiring(.Why | .How | .Viterbi)`, and `diff_replay(sess, candidate_rulebase)` over `xitdb.Core_Overlay`.

### FR-4: Runic-Style 3-Phase Async Effects
- Implement `effect "<kind>" { ... }`, `session_prepare_effects`, and `session_apply_effects` with full causal ancestry preservation.

### FR-5: Differential Brute-Force Oracle Fuzz/Property Suite
- Randomized operation sequences (`insert`, `update`, `retract`, `fire`, `apply_effect`, `diff_replay`) compared against a clean ground-truth non-incremental oracle under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and `-sanitize:address`.

---

## 4. Non-Functional & Verification Requirements

- Differential oracle must achieve `0` state mismatches across `>= 10,000` randomized mutation/retraction steps (including cycles, diamond supports, `min`/`max` retractions, and `not` toggles).
- Provenance mode `.Audit_Full` performs zero per-fact SHA-1/SHA-256 computations during hot matching.

---

## 5. Out of Scope

- Full `10`–`1,000,000`-rule performance benchmarking & tuning campaign (Track 6).

---

## 6. Acceptance Criteria

- [ ] Retracting or updating a premise automatically cascades retractions across multi-hop rules, recursive closures, negation blockers, and accumulators while keeping multi-justified facts alive.
- [ ] Unstratified negation/aggregation cycles fail compile with `E4001` pointing to exact cycle lines; cyclic positive recursion always terminates with finite minimal proof height.
- [ ] `decisions`, `idx.decisions_by_entity`, `idx.decisions_by_rule`, and `__tx` commit atomically into `xitdb`; `explain`, `impact`, `evaluate_semiring`, and `diff_replay` match ground truth.
- [ ] 3-phase `Prepare -> Execute -> Apply` effects run concurrently off-engine and preserve causal lineage back to originating facts.
- [ ] Differential oracle fuzz suite passes under ASan and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
