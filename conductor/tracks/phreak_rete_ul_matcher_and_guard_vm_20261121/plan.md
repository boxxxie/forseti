# Implementation Plan: Lazy PHREAK + Rete/UL Matcher, 32-bit `#must_tail` Guard VM, Deterministic Agenda, and `1M`-Rule Sparse Session Memory

> - **Track ID:** `phreak_rete_ul_matcher_and_guard_vm_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`, `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/phreak-rete-ul-matcher-and-guard-vm` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Immutable `Rulebase` Compiler & 32-bit `#must_tail` Expression/Guard VM

- [ ] Task: Implement 32-bit `#must_tail` register bytecode compiler and VM (`proc "preserve/none"`) (TDD)
    - [ ] Write failing unit tests covering register watermark recycling (`< 256` overflow diagnostics), arithmetic traps (`div 0`, `min(i64) / -1`), string/enum equality, `decide` call opcodes, and lazy `xitdb.Read_Cursor` field reads
    - [ ] Implement `forseti/vm_bytecode.odin` and `forseti/vm_eval.odin`
- [ ] Task: Implement `Rulebase` compiler (Alpha sharing, hash splits, PHREAK segment decomposition) (TDD)
    - [ ] Write failing tests verifying Alpha node sharing across rules, `O(1)` hash-split lookup tables, segment bitmask assignment (`BuildtimeSegmentUtilities` pattern), and compile telemetry on 1k–100k rule fixtures
    - [ ] Implement `forseti/rulebase_compile.odin` and `forseti/segment_plan.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Rulebase Compiler & Guard VM' (Protocol in workflow.md)

---

## Phase 2: Lazy Sparse `Session`, PHREAK Evaluation Stack & Deterministic Agenda

- [ ] Task: Implement sparse lazy `Session` memory page directory + Left/Right unlinking + hash-indexed Beta joins (TDD)
    - [ ] Write failing tests asserting `session_init` on 100k–1M rules allocates zero unused Beta memories, `segments_skipped_unlinked` skips unpopulated joins, and 2-way/3-way joins match brute-force oracle across inserts and retracts
    - [ ] Implement `forseti/session.odin`, `forseti/alpha_eval.odin`, `forseti/beta_join.odin`, and `forseti/phreak_eval.odin`
- [ ] Task: Implement Salience + Phase Focus Stack Agenda, Refraction, Queries & Matcher Telemetry (TDD)
    - [ ] Write failing tests for phase ordering, salience tie-breaking, refraction, `query` lookups, and `sync_and_fire` over `xitdb` `Store_Bridge`
    - [ ] Implement `forseti/agenda.odin`, `forseti/query_exec.odin`, and wire per-stage telemetry counters
- [ ] Task: Conductor - User Manual Verification 'Phase 2: PHREAK Matcher, Sparse Session & Agenda' (Protocol in workflow.md)
