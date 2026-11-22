# Implementation Plan: `xitdb` Fact/Audit Substrate, `diff_collection` Z-Set Delta Bridge, `Core_Overlay` Forks, and Opt-In Fast-Memory Adaptations

> - **Track ID:** `xitdb_substrate_and_optin_fast_memory_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/xitdb-substrate-and-optin-fast-memory` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: `Store_Bridge`, Lazy `Read_Cursor` Field Decoding & `diff_collection` Z-Set Sync

- [x] Task: Implement `Store_Bridge` supporting standalone `Core_Memory` and attached `^xitdb.Database` moments (Red-First 4-Layer ATDD + Pattern E)
    - [x] Write failing Layer 1 ATDD specs in `specs/xitdb_substrate_spec_test.odin` (standalone vs attached MDM moments across nested maps / `Sorted_Map` / sets / EAV) plus Pattern E unit tests for `Short_Bytes`/scalar decoding into 16-byte `Value`
    - [x] Implement `forseti/xitdb_bridge.odin` and `forseti/xitdb_cursor_eval.odin` (keeping cursor plumbing in Layer 3 `specs/driver_test.odin`)
- [x] Task: Implement `diff_collection` Z-Set delta sync + compaction detection + `Core_Overlay` fork wrapper (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 ATDD scenarios in `specs/xitdb_substrate_spec_test.odin` modifying 10 out of 100,000 records across moments and verifying exact `+1`/`-1` deltas, `slots_skipped` telemetry, post-compaction safe resync fallback, and isolated `Core_Overlay` forks
    - [x] Implement `forseti/xitdb_delta.odin` and `forseti/xitdb_overlay.odin`
- [x] Task: Conductor - User Manual Verification 'Phase 1: xitdb Store Bridge & Incremental Delta Sync' (Protocol in workflow.md)

---

## Phase 2: Opt-In `xitdb` Fast-Memory Profile, Safety Gates & Tradeoff Documentation

- [x] Task: Add opt-in non-crypto `Hasher` preset and fast-memory CRC/scratch options in `../xitdb` preserving safe v2 defaults (Red-First ATDD + Pattern E)
    - [x] Write failing Layer 1 ATDD specs in `specs/xitdb_substrate_spec_test.odin` (including scoped `log.nil_logger()` negative guardrail specs verifying `.Fast_Memory` rejects mismatched disk opens cleanly) plus Pattern E wire tests confirming default `xitdb` remains bit-for-bit v2 compatible
    - [x] Implement opt-in `Fast_Memory` hooks in `../xitdb` (explicit config flags, zero changes to default paths) and verify both `odin test specs -all-packages` and `../xitdb/tests` pass 100% under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [x] Task: Benchmark safe v2 default vs opt-in `Fast_Memory` in `benchmarks/` and write `docs/xitdb-fast-mode.md` (TDD)
    - [x] Write comparative `hugi`/`obench` benchmarks (`insert`, `lookup`, `diff_collection`, `commit`) for safe v2 vs `Fast_Memory`
    - [x] Author `docs/xitdb-fast-mode.md` documenting exact options, known limitations, security/wire-compat boundaries, and observed benchmark numbers
- [x] Task: Conductor - User Manual Verification 'Phase 2: Opt-In Fast-Memory xitdb & Docs' (Protocol in workflow.md)
