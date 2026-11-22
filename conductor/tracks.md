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

- [x] **Track 7: Agent-Proof DSL Reference (`docs/` & `usage-rules.md`), CI-Verified Examples, Full CLI (`cmd/forseti`), and E2E ATDD Audit** *(Priority: Step 7 — Depends on Tracks 1–6; docs & specs kept fresh incrementally)*
  *Link: [./tracks/agent_dsl_docs_examples_and_cli_tooling_20261121/](./tracks/agent_dsl_docs_examples_and_cli_tooling_20261121/)*

---

- [ ] **Track 8: Cross-OS CI Matrix (`ubuntu-latest`, `macos-latest`, `windows-latest`), Repo/Actions Hygiene & `v0.1.0` Release Prep** *(Priority: Step 8 — Depends on Track 7)*
  *Link: [./tracks/cross_os_ci_hygiene_and_v0_1_0_release_20261122/](./tracks/cross_os_ci_hygiene_and_v0_1_0_release_20261122/)*

---

- [ ] **Track 9: Sleipnir (`package actor`) Multi-Threaded Session Runtime, Partitioned Tenant Supervision & Parallel Async Effects** *(Priority: Step 9 — Depends on Tracks 3–6, 8)*
  *Link: [./tracks/sleipnir_actor_multithreaded_runtime_20261122/](./tracks/sleipnir_actor_multithreaded_runtime_20261122/)*

---

- [ ] **Track 10: `.forseti` Language Server (LSP), Canonical Formatter (`forseti fmt`) & TextMate / Tree-sitter Editor Tooling** *(Priority: Step 10 — Depends on Tracks 1, 2, 7, 8)*
  *Link: [./tracks/forseti_lsp_formatter_and_editor_tooling_20261122/](./tracks/forseti_lsp_formatter_and_editor_tooling_20261122/)*

---

- [ ] **Track 11: External Consumer Integration, Stable C99 ABI (`libforseti`) & DSL v1.1 Ergonomics (`import` & Pure Built-Ins)** *(Priority: Step 11 — Depends on Tracks 7, 8, 9)*
  *Link: [./tracks/c_abi_external_integration_and_dsl_v1_1_20261122/](./tracks/c_abi_external_integration_and_dsl_v1_1_20261122/)*
