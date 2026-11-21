# `xitdb` Safe Defaults vs. Opt-In Fast-Memory Profile

Forseti uses `xitdb` as its universal append-only fact and audit-trail store. By default, every store runs in `Xitdb_Mode.Safe_V2` to preserve bit-for-bit wire compatibility, SHA-1 HAMT collision resistance, and CRC-64/XZ commit trailer verification. For trusted, non-durable in-memory scratch and matching workloads, `Xitdb_Mode.Fast_Memory` provides explicit opt-in optimizations with documented safety and compatibility boundaries.

---

## 1. Configuration Profiles

### Default Profile (`Xitdb_Mode.Safe_V2`)
```odin
cfg := forseti.Xitdb_Config{
	mode            = .Safe_V2, // default
	skip_memory_crc = false,    // required; true is rejected with .Invalid_Config
}
```
- **Hasher:** `xitdb.sha1_hasher()` (20-byte SHA-1 digest, `hash_id = 0`, hardware SHA-NI accelerated on `amd64`).
- **Commit Integrity:** Full `CRC-64/XZ` trailer checksum written on commit and validated on read/open (`Root_Trailer` at `file_size - 25`).
- **Backends:** `Core_Memory`, `Core_Buffered_File`, `Core_File`, and `Core_Overlay`.
- **Wire Compatibility:** 100% compatible with upstream Zig/Go/Java/Elixir `xitdb` v2 readers and replication streams.

### Opt-In Fast-Memory Profile (`Xitdb_Mode.Fast_Memory`)
```odin
cfg := forseti.Xitdb_Config{
	mode            = .Fast_Memory,
	skip_memory_crc = true, // explicit opt-in; forbidden on disk-backed cores
}
```
Implemented via explicit `../xitdb` extensions without altering default `database_init` or `core_memory_init` behavior:
1. **128-bit Non-Cryptographic HAMT Hasher (`xitdb.fast_hasher()`):**
   - Replaces SHA-1 per key with `xitdb.fast_hash128_sum_into` (`64x64->128`-bit multiply-xor mixing), reducing HAMT KV pair digest overhead (`hash_size = 16`, distinct header `hash_id = 0x66683136` / `"fh16"`).
2. **Optional Memory-Only CRC Trailer Skip (`xitdb.Database_Options{skip_memory_crc = true}`):**
   - Skips `CRC-64/XZ` root-trailer calculation on `database_commit_root` (writing `checksum = 0`) and trailer verification on `database_read_root_trailer`.
3. **Reusable Scratch Diff Buffer (`xitdb.diff_collection_with_stats`):**
   - Routes transient HAMT/B+Tree diff allocations into a caller-owned `vmem.Arena` (`Delta_Syncer.scratch_arena`, freed via `vmem.arena_free_all` per sync) while reporting `slots_skipped`, `blocks_compared`, and `keys_decoded` counters.
4. **Zero-Allocation 9-Byte `Slot` Scalar & `Short_Bytes` Unpacking:**
   - Decodes `Int`, `Uint`, `Float`, inline `"bl"` booleans (`BOOL_FORMAT_TAG` packed in `Short_Bytes`), pre-interned `Short_Bytes`, and `Bytes` (`<= 256 B`) directly on stack buffers into Forseti's 16-byte `Value`.

---

## 2. Explicit Guardrails, Failure Modes & Limitations

Do **not** enable `.Fast_Memory` or `skip_memory_crc = true` outside trusted ephemeral RAM sessions:

- **Disk Cores Forbidden:** Opening `Core_Buffered_File` or `Core_File` with `.Fast_Memory` is rejected with `Store_Bridge_Error.Disk_Fast_Mode_Forbidden`; passing `skip_memory_crc = true` on disk cores fails with `Store_Bridge_Error.Invalid_Config` (and `xitdb.Xitdb_Error.Invalid_Database_Options`).
- **Safe Mode CRC Guard:** Enabling `skip_memory_crc = true` under `Xitdb_Mode.Safe_V2` is rejected with `Store_Bridge_Error.Invalid_Config`.
- **No Cross-Format Wire Compatibility:** Files or memory images initialized with `xitdb.fast_hasher()` carry `hash_id = "fh16"` (`0x66683136`) and `hash_size = 16`. Attempting to open a `Safe_V2` SHA-1 database with `fast_hasher()` (or vice versa) fails deterministically with `xitdb.Xitdb_Error.Invalid_Hash_Id`.
- **Adversarial Hash-Flooding Risk:** `fast_hash128_sum_into` uses fixed constants and is non-cryptographic; never feed untrusted adversarial keys directly into a `Fast_Memory` HAMT.
- **No Corruption Detection:** Setting `skip_memory_crc = true` writes zeroed `Root_Trailer` checksums (`0`). Memory corruptions, partial copies, or replicated byte streams will not fail trailer validation and are unsupported for replication or persistent recovery.

---

## 3. Comparative Benchmarks (`Safe_V2` vs. `Fast_Memory`)

Measured on `linux/amd64` with `hugi run --runs 3 --warmup 1` (`-o:Speed`, `10,000` HAMT records, hardware SHA-NI enabled on host CPU):

| Workload | `Safe_V2` (median p50) | `Fast_Memory` (median p50) | Throughput (`Safe_V2` vs. `Fast_Memory`) | Speedup | Heap Allocs / bytes |
| --- | --- | --- | --- | --- | --- |
| `insert_10k` (single tx) | `3.36 ms` | `3.06 ms` | `2.98 Mitem/s` vs. `3.27 Mitem/s` | `1.10x` | `1.0 / 424 B` |
| `lookup_10k` (`Store_Bridge` + `Value` decode) | `1.10 ms` | `739.07 us` | `9.08 Mitem/s` vs. `13.53 Mitem/s` | `1.49x` | `0 allocs` |
| `diff_10_of_10k` (`diff_collection_with_stats`) | `3.62 us` | `3.25 us` | `2.76 Mitem/s` vs. `3.08 Mitem/s` | `1.11x` | `0 allocs` |
| `commit_cycle` (1k base + 1-key moment) | `2.18 us` | `2.02 us` | `458.1 Kitem/s` vs. `496.1 Kitem/s` | `1.08x` | `0 allocs` |

*Notes:* Because this `amd64` CPU accelerates `sha1_sum_into` via hardware SHA-NI instructions, `Safe_V2` already achieves `~9.08 M lookups/s` and sub-4 microsecond incremental diffs (`~3.62 us` for `10` changed keys across `10,000` records); `Fast_Memory` still delivers a `1.49x` lookup speedup with `0` heap allocations and eliminates trailer CRC sweeps. Software-SHA-1 targets without SHA-NI see larger gains on write/lookup-heavy streams.
