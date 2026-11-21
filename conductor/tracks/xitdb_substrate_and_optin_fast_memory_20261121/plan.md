# Implementation Plan: `xitdb` Fact/Audit Substrate, `diff_collection` Z-Set Delta Bridge, `Core_Overlay` Forks, and Opt-In Fast-Memory Adaptations

> - **Track ID:** `xitdb_substrate_and_optin_fast_memory_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/xitdb-substrate-and-optin-fast-memory` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: `Store_Bridge`, Lazy `Read_Cursor` Field Decoding & `diff_collection` Z-Set Sync

- [ ] Task: Implement `Store_Bridge` supporting standalone `Core_Memory` and attached `^xitdb.Database` moments (TDD)
    - [ ] Write failing unit tests covering standalone init, attaching existing `Core_Buffered_File` DBs, reading nested maps / `Sorted_Map`s / sets / EAV collections, and `Short_Bytes`/scalar decoding into 16-byte `Value`
    - [ ] Implement `forseti/xitdb_bridge.odin` and `forseti/xitdb_cursor_eval.odin`
- [ ] Task: Implement `diff_collection` Z-Set delta sync + compaction detection + `Core_Overlay` fork wrapper (TDD)
    - [ ] Write failing tests modifying 10 out of 100,000 records across moments and verifying exact `+1`/`-1` deltas, `slots_skipped` telemetry, post-compaction safe resync fallback, and isolated `Core_Overlay` forks
    - [ ] Implement `forseti/xitdb_delta.odin` and `forseti/xitdb_overlay.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: xitdb Store Bridge & Incremental Delta Sync' (Protocol in workflow.md)

---

## Phase 2: Opt-In `xitdb` Fast-Memory Profile, Safety Gates & Tradeoff Documentation

- [ ] Task: Add opt-in non-crypto `Hasher` preset and fast-memory CRC/scratch options in `../xitdb` preserving safe v2 defaults (TDD)
    - [ ] Write failing tests verifying default `xitdb` behavior remains bit-for-bit wire-compatible with v2, while explicit opt-in `.Fast_Memory` rejects mismatched disk opens cleanly and passes all functional/differential tests
    - [ ] Implement opt-in `Fast_Memory` hooks in `../xitdb` (with explicit config flags & zero changes to default paths) and verify `../xitdb/tests` passes 100% under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [ ] Task: Benchmark safe v2 default vs opt-in `Fast_Memory` in `benchmarks/` and write `docs/xitdb-fast-mode.md` (TDD)
    - [ ] Write comparative `hugi`/`obench` benchmarks (`insert`, `lookup`, `diff_collection`, `commit`) for safe v2 vs `Fast_Memory`
    - [ ] Author `docs/xitdb-fast-mode.md` documenting exact options, known limitations, security/wire-compat boundaries, and observed benchmark numbers
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Opt-In Fast-Memory xitdb & Docs' (Protocol in workflow.md)
