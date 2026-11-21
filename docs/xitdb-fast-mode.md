# `xitdb` Safe Defaults vs. Opt-In Fast-Memory Profile

Forseti uses `xitdb` as its universal append-only fact and audit-trail store. By default, every store runs in `Xitdb_Mode.Safe_V2` to preserve bit-for-bit wire compatibility, SHA-1 HAMT collision resistance, and CRC-64/XZ commit trailer verification. For trusted, non-durable in-memory scratch and matching workloads, `Xitdb_Mode.Fast_Memory` provides an explicit opt-in non-cryptographic HAMT hasher (`forseti.fast_hasher()`) with documented safety and compatibility boundaries while leaving `../xitdb` wire defaults untouched.

---

## 1. Configuration Profiles

### Default Profile (`Xitdb_Mode.Safe_V2`)
```odin
cfg := forseti.Xitdb_Config{
	mode = .Safe_V2, // default
}
```
- **Hasher:** `xitdb.sha1_hasher()` (`20`-byte SHA-1 digest, `hash_id = 0`, hardware SHA-NI accelerated on supported `amd64` CPUs). Optionally accepts a non-`fh16` `custom_hasher`.
- **Commit Integrity:** Full `CRC-64/XZ` trailer checksum written on commit and validated on read/open.
- **Backends:** `Core_Memory`, `Core_Buffered_File`, `Core_File`, and `Core_Overlay` (`store_bridge_open_file` and `store_bridge_init_standalone`).
- **Wire Compatibility:** 100% compatible with upstream `xitdb` v2 (`SLOT_LENGTH = 9`, big-endian encoding, SHA-1 HAMT hashing).

### Opt-In Fast-Memory Profile (`Xitdb_Mode.Fast_Memory`)
```odin
cfg := forseti.Xitdb_Config{
	mode          = .Fast_Memory,
	custom_hasher = forseti.fast_hasher(), // default when omitted under .Fast_Memory
}
```
Implemented inside Forseti ([`forseti/xitdb_bridge.odin`](../forseti/xitdb_bridge.odin), [`forseti/xitdb_key_hash.odin`](../forseti/xitdb_key_hash.odin)) without modifying upstream `../xitdb` defaults:

1. **128-bit Non-Cryptographic HAMT Hasher (`forseti.fast_hasher()`):**
   - Replaces SHA-1 per key with `forseti.fast_hash128_sum_into` (`u128` multiply-xor mixing), reducing HAMT KV pair digest overhead (`FAST_HASH_SIZE = 16`, distinct header `FAST_HASH_ID = 0x66683136` / `"fh16"`).
2. **Pre-Hashed Static Keys (`Prehashed_Key`):**
   - Static schema field names, selector path segments, and audit schema keys are pre-hashed into both `[20]u8` (`sha1`) and `[16]u8` (`fast128`) digests via `prehashed_key_make` ([`forseti/xitdb_key_hash.odin`](../forseti/xitdb_key_hash.odin)) for zero-allocation `*_prehashed` HAMT/cursor operations in both `.Safe_V2` and `.Fast_Memory`.
3. **Reusable Scratch Diff Buffer (`Delta_Syncer`):**
   - Routes transient HAMT diff allocations into a caller-owned `vmem.Arena` (`Delta_Syncer.scratch_arena`, freed via `vmem.arena_free_all` per sync) while reporting incremental diff counters.
4. **Zero-Allocation Scalar & Cursor Unpacking:**
   - Decodes `bool`, `i32`/`i64`, `f64`, `String_Id`, `Entity_Id`, `Time_Ns`, and `Enum_Val` directly into Forseti's 16-byte `Value` without heap allocations.

---

## 2. Explicit Guardrails, Failure Modes & Limitations

Do **not** enable `.Fast_Memory` or `forseti.fast_hasher()` (`"fh16"`) outside trusted ephemeral RAM sessions:

- **Disk Cores Forbidden:** Opening `Core_Buffered_File` via `store_bridge_open_file` (or any disk-backed store checked by `_core_has_disk_backing`) with `cfg.mode == .Fast_Memory` or `cfg.custom_hasher.id == FAST_HASH_ID` is rejected with `Store_Bridge_Error.Disk_Fast_Mode_Forbidden`.
- **Safe Mode Hasher Guard:** Passing `custom_hasher` with `id == FAST_HASH_ID` (`"fh16"`) while `cfg.mode == .Safe_V2` is rejected with `Store_Bridge_Error.Invalid_Config`.
- **No Cross-Format Wire Compatibility:** Memory images initialized with `forseti.fast_hasher()` carry `hash_id = 0x66683136` (`"fh16"`) and `hash_size = 16`. Attempting to open a `Safe_V2` SHA-1 image with `fast_hasher()` (or vice versa) fails deterministically with `xitdb.Xitdb_Error.Invalid_Hash_Id`.
- **Adversarial Hash-Flooding Risk:** `fast_hash128_sum_into` uses fixed constants and is non-cryptographic; never expose untrusted adversarial keys directly to a `Fast_Memory` HAMT.

---

## 3. Comparative Benchmarks (`Safe_V2` vs. `Fast_Memory`)

Measured on `linux/amd64` (`AMD Ryzen 7 7735U`, hardware SHA-NI enabled, `-o:speed -microarch:native`, `e9cd4fc` in [`benchmarks/history.hugidb`](../benchmarks/history.hugidb), `10,000` HAMT records):

| Workload | `Safe_V2` (median p50) | `Fast_Memory` (median p50) | Speedup | Allocs / op |
| --- | ---: | ---: | ---: | ---: |
| `insert_10k` (single tx) | `2.92 ms` | `2.74 ms` | `1.07x` | `1.0 / 408 B` |
| `lookup_10k` (string key) | `1.17 ms` | `857.21 us` | `1.36x` | `0` |
| `lookup_10k_safe_v2_prehashed_cursor` | `561.61 us` | — | `2.08x` vs string `Safe_V2` | `0` |
| `diff_10_of_10k` (incremental diff) | `3.56 us` | `3.25 us` | `1.10x` | `0` |
| `commit_cycle` (`1k` base + `1`-key moment) | `1.97 us` | `1.88 us` | `1.05x` | `0` |

*Notes:* Because this `amd64` CPU accelerates `xitdb.sha1_sum_into` with hardware SHA-NI instructions, `Safe_V2` achieves `8.53 M lookups/s` (`17.81 M lookups/s` via `Prehashed_Key` cursors) and `3.56 us` incremental diffs (`0` allocs); `Fast_Memory` provides an additional `1.36x` speedup on uncached string lookups while maintaining zero-allocation reads. For full scaling results up to `1,000,000` rules, see [`docs/benchmarks.md`](./benchmarks.md).
