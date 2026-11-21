# Specification: `xitdb` Fact/Audit Substrate, `diff_collection` Z-Set Delta Bridge, `Core_Overlay` Forks, and Opt-In Fast-Memory Adaptations

> - **Track ID:** `xitdb_substrate_and_optin_fast_memory_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`

---

## 1. Problem Statement & Motivation

Forseti uses `xitdb` (`Core_Memory` default at ~3M ops/sec, attachable `Core_Buffered_File`, and `Core_Overlay`) as its universal fact and audit-trail store. To serve as an incremental rules engine substrate without breaking wire compatibility or bloating append-only history:
1. We need a clean delta bridge translating `xitdb.diff_collection` across committed moments into Z-set (`+1` / `-1`) working-memory deltas while skipping untouched subtrees by 9-byte `Slot` equality.
2. We need lazy `xitdb.Read_Cursor` field projection supporting nested maps, B+Trees, sets, lists, and EAV triples without copying whole records unless matched.
3. Because in-memory rule evaluation stresses hash lookups, byte diffs, and header commits differently than crash-safe disk logs, we can adapt `xitdb` with **strictly opt-in fast-memory options** (preserving 100% safe `xitdb` v2 wire-compatible defaults) and thoroughly document every tradeoff and limitation.

---

## 2. Architecture

```text
  xitdb Moment M_{t-1} ──┐
                         ├─▶ xitdb.diff_collection (Slot-skipping O(changes * depth))
  xitdb Moment M_t     ──┘         │
                                   ▼
                          Z-Set Fact_Delta (+1 Added, -1 Removed, -1/+1 Changed)
                                   │
                                   ▼
                     Forseti Working Memory Sync + Logical Key Identity Map
                                   │
                    (atomic commit back to M_{t+1}: derived + JTMS + decisions + __tx)
```

### Safe Defaults vs. Opt-In Fast-Memory `xitdb` Profile
- **Default (`Xitdb_Mode.Safe_V2`):** Standard `xitdb` `sha1_hasher()`, `CRC-64/XZ` commit trailers, `Core_Memory` (`vmem.reserve`) or attached `Core_Buffered_File`. 100% wire-compatible with Zig/Go/Java/Elixir `xitdb` tools.
- **Opt-In Fast-Memory (`Xitdb_Mode.Fast_Memory`):**
  1. **Fast Non-Crypto `Hasher` Preset (e.g., 64-bit `wyhash`/`xxhash` padded or `xxh3`):** Replaces SHA-1 HAMT key hashing for trusted in-memory scratch/rule stores (eliminates SHA-1 per HAMT path lookup). *Limitation:* non-wire-compatible `hash_id` with SHA-1 disk files; vulnerable to adversarial hash flooding if keys are untrusted.
  2. **Scratch-RAM Fast Commit Option (Skip `CRC-64/XZ` trailer verification/computation in non-durable `Core_Memory`):** Eliminates trailer checksum sweeps when durability is disabled. *Limitation:* zero corruption detection; forbidden for disk-backed or replicated databases.
  3. **Zero-Heap Scratch Diff Buffer & Direct `Read_Cursor` Scalar Unpacking:** `diff_collection` into caller-owned scratch arenas + direct `Short_Bytes` / `Uint` / `Int` / `Float` decoding directly from 9-byte `Slot`s into Forseti's 16-byte `Value`.

---

## 3. Functional Requirements

### FR-1: Attachable `xitdb` Fact Store (`Store_Bridge`)
- Support standalone mode (auto-initializes in-memory `xitdb.Core_Memory` with moments root) and attached mode (wraps caller's `^xitdb.Database` at any moment).
- Map `source` / `derived` DSL bindings (`.path.to.collection[?key]`, EAV collections, B+Tree `Sorted_Map` prefix scans) onto `xitdb` cursors.
- Implement lazy field path evaluation (`?raw.address.country`, `?org.locked_fields.domain`) directly on `xitdb.Read_Cursor` without materializing unused fields.

### FR-2: `diff_collection` -> Z-Set Delta Sync & Compaction-Safe Identity
- Track `last_synced_moment` and `last_synced_slots` per watched `source` collection.
- Compute deltas across `M_prev` -> `M_cur` using `xitdb.diff_collection`, emitting `+1` (`Added`), `-1` (`Removed`), and `(-1, +1)` (`Changed`) `Fact_Delta` streams with telemetry counters (`slots_skipped`, `keys_decoded`, `delta_sync_ns`).
- Key persisted provenance/JTMS identities by logical `(collection_path, key_bytes, moment_index)`, detecting compaction (`moment` or root slot mismatch) to trigger a clean resync without stale physical offsets.

### FR-3: `Core_Overlay` Zero-Copy Fork Primitive
- Wrap `xitdb.Core_Overlay` in a clean Forseti `Fork_Handle` for counterfactual rule replay (`diff_replay`) and isolated speculative rule runs (`O(1)` fork cost, zero mutation to parent DB).

### FR-4: Opt-In `xitdb` Fast-Memory Adaptations & Limitation Docs
- Implement the opt-in `Xitdb_Config` (`mode: .Safe_V2 | .Fast_Memory`, `custom_hasher`, `skip_memory_crc: bool`) cleanly in `../xitdb` (keeping default `database_init` / `core_memory_init` 100% unchanged and guarded by existing `xitdb` tests) and consume it from Forseti.
- Author `docs/xitdb-fast-mode.md` explicitly documenting every optimization, exact configuration flags, failure modes/limitations (no disk wire-compat when custom hasher/CRC skip enabled, untrusted key hash-flooding caveat), and before/after `hugi` micro-benchmarks.

---

## 4. Non-Functional & Verification Requirements

- Zero regressions in `../xitdb/tests` under `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` (both safe default and fast-memory configs tested).
- `diff_collection` delta sync scales sub-linearly (`O(changes * depth)`) when 1 key changes in a 100k-record `xitdb` collection.

---

## 5. Out of Scope

- Alpha/Beta Rete network matching (Track 4).
- JTMS justification storage and `decisions` schema projection (Track 5).

---

## 6. Acceptance Criteria

- [ ] Forseti standalone store creates and commits moments in `xitdb.Core_Memory` AND attaches cleanly to caller-owned `Core_Buffered_File` databases.
- [ ] Changing 10 records inside a 100,000-record `xitdb` map syncs only those 10 deltas via `diff_collection` (`slots_skipped` verified by telemetry).
- [ ] Lazy `Read_Cursor` field reads decode `Short_Bytes`, `Bytes`, `Int`, `Uint`, `Float`, `Bool`, and nested sub-maps cleanly into `Value`.
- [ ] `Core_Overlay` forks isolate writes completely from the parent DB and destroy with zero leaks.
- [ ] Safe default `xitdb` v2 wire tests pass 100%; opt-in `Fast_Memory` benchmarks & `docs/xitdb-fast-mode.md` document measured speedups and exact limitations.
