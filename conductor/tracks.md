# Project Tracks

Sequenced implementation roadmap for **Forseti**. Tracks are ordered by dependency from core DSL/IR/Telemetry up through `xitdb` adaptation, PHREAK matching, JTMS/Datalog/Provenance, `10`–`1,000,000` rule benchmarks, and agent-ready documentation/CLI tooling.

---

- [x] **Track 1: Core `.forseti` External & Internal DSL, Canonical `Rulebase_IR`, Compile-Time Diagnostics, Telemetry Foundation, and 4-Layer `specs/` Harness** *(Priority: Step 1 — Foundation)*
  *Link: [./tracks/dsl_ir_diagnostics_and_telemetry_foundation_20261121/](./tracks/dsl_ir_diagnostics_and_telemetry_foundation_20261121/)*

---

- [x] **Track 2: Verified DMN Decision Tables (`Tablex++` / `ZEN`), Static Gap/Overlap Proofs, Dual Cost-Tree/Bitset Compilers, and Tier 3 AOT Odin Codegen** *(Priority: Step 2 — Depends on Track 1)*
  *Link: [./tracks/decision_tables_verifier_and_aot_codegen_20261121/](./tracks/decision_tables_verifier_and_aot_codegen_20261121/)*

---

- [x] **Track 3: `xitdb` Fact/Audit Substrate, `diff_collection` Z-Set Delta Bridge, `Core_Overlay` Forks, and Opt-In Fast-Memory Adaptations** *(Priority: Step 3 — Depends on Track 1)*
  *Link: [./tracks/xitdb_substrate_and_optin_fast_memory_20261121/](./tracks/xitdb_substrate_and_optin_fast_memory_20261121/)*

---

- [x] **Track 4: Lazy PHREAK + Rete/UL Matcher, 32-bit `#must_tail` Guard VM, Deterministic Agenda, and 1M-Rule Sparse Session Memory** *(Priority: Step 4 — Depends on Tracks 1, 2, 3)*
  *Link: [./tracks/phreak_rete_ul_matcher_and_guard_vm_20261121/](./tracks/phreak_rete_ul_matcher_and_guard_vm_20261121/)*

---

- [x] **Track 5: Z-Set JTMS, Retractable Accumulators, Tarjan SCC Stratified Datalog, Semiring Causal Provenance, and 3-Phase Async Effects** *(Priority: Step 5 — Depends on Tracks 2, 3, 4)*
  *Link: [./tracks/jtms_accumulators_stratified_datalog_and_provenance_20261121/](./tracks/jtms_accumulators_stratified_datalog_and_provenance_20261121/)*

---

- [x] **Track 6: Longitudinal `hugi`/`obench` Scaling Benchmarks (`10` to `1,000,000` Rules) & Telemetry-Guided Optimization** *(Priority: Step 6 — Depends on Tracks 2, 3, 4, 5)*
  *Link: [./tracks/million_rule_benchmarks_and_telemetry_suite_20261121/](./tracks/million_rule_benchmarks_and_telemetry_suite_20261121/)*

---

- [~] **Track 7: Agent-Proof DSL Reference (`docs/` & `usage-rules.md`), CI-Verified Examples, Full CLI (`cmd/forseti`), and E2E ATDD Audit** *(Priority: Step 7 — Depends on Tracks 1–6; docs & specs kept fresh incrementally)*
  *Link: [./tracks/agent_dsl_docs_examples_and_cli_tooling_20261121/](./tracks/agent_dsl_docs_examples_and_cli_tooling_20261121/)*
