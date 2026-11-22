[README](../README.md) · [Docs Hub](README.md) · [Odin API](odin-api.md) · [DSL Reference](dsl-reference.md) · [xitdb Modes](xitdb-fast-mode.md) · **Benchmarks** · [Agent Rules](../usage-rules.md)

# Forseti Benchmarks & Scaling Architecture

This report documents Forseti's longitudinal [`hugi`](https://github.com/boxxxie/hugi) / [`obench`](https://github.com/zeybek/obench) benchmark suite across `7` benchmark groups (`93` parameterized benchmarks total) scaling up to `1,000,000` rules, `10,000` working-memory facts, `10,000`-row JTMS cascades, and `5,000`-edge transitive closures, along with before/after measurements from the Phase 2 telemetry-guided optimization pass (`be8f675` -> `e9cd4fc`).

> [!IMPORTANT]
> **TL;DR Scaling Scorecard (`e9cd4fc` on Ryzen 7 7735U, `-o:speed -microarch:native`):**
> - **AOT Table (`10,000` rows):** `716.48 ps` (`2.0` CPU cycles, `0` allocs)
> - **Lazy Cost Tree (`10,000` rows):** `28.80 ns` (`O(1)`, `0` allocs)
> - **`1,000,000`-Rule Compile & Sparse Init:** `1.772 s` compile (`~556 B/rule`), `19.48 us` `session_init` (`O(1)`), `2.27 us` single-rule match
> - **`@zero_alloc` PHREAK Hot Match (`.Fast`):** `1.32 ms` at `1,000` background facts (`12.14x` speedup, `0` allocs)
> - **Incremental `xitdb` `Safe_V2` Diff (`10 / 10k`):** `3.56 us` (`2.81 M items/s`, `0` allocs)

## Contents

- [1. Testbed & Methodology](#1-testbed--methodology)
- [2. `10` to `1,000,000` Rule Scaling (`--profile-1m` & `scale_rules`)](#2-10-to-1000000-rule-scaling---profile-1m--scale_rules)
- [3. Longitudinal `hugi` Suite Results (`e9cd4fc`) & Phase 2 Deltas (`be8f675 -> e9cd4fc`)](#3-longitudinal-hugi-suite-results-e9cd4fc--phase-2-deltas-be8f675---e9cd4fc)
- [4. Telemetry-Guided Optimizations Implemented](#4-telemetry-guided-optimizations-implemented)
- [5. Reproduction Commands](#5-reproduction-commands)

---

## 1. Testbed & Methodology

- **Hardware:** `AMD Ryzen 7 7735U with Radeon Graphics` (`8` cores / `16` threads, `x86_64`, Linux `7.1.13-2-MANJARO`)
- **Compiler & Flags:** `odin version dev-2026-10:84bc3fc21`, built via `hugi` / `obench` with `-o:speed -microarch:native` (`extra_build_flags` in [`hugi.json`](../hugi.json))
- **CPU Governor Note:** `hugi` reported `scaling_governor = powersave` with turbo clocks enabled during measurement runs (`10`–`50` statistical samples per benchmark, `1` warmup iteration)
- **Verification Gates:**
  - Strict `-vet -vet-tabs -strict-style -warnings-as-errors` checks across `forseti/`, `cmd/forseti/`, and `benchmarks/`
  - `30/30` ATDD specs (`odin test specs -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`) and `30/30` unit/property tests (`odin test tests -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`), plus `-sanitize:address` (`30/30` passing)
  - `hugi run --test --groups decision_tables,xitdb_modes,beta_joins,jtms_churn,recursive_strata,mdm_e2e` confirming `0` `@zero_alloc` violations across `69` non-1M smoke checks, plus multi-sample `obench` verification on `phreak_hot_match_zero_alloc[10..10000]`

---

## 2. `10` to `1,000,000` Rule Scaling (`--profile-1m` & `scale_rules`)

The `scale_rules` workload generates `N` rules sharing upstream source patterns with a two-level equality `Hash_Split` alpha DAG and fires either `1` sparse rule or `100` matching rules against an initialized `Session`.

### Standalone `--profile-1m` Telemetry Sweep (`10`..`1,000,000` Rules)

Measured with Python `resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss` over `-o:speed -microarch:native`:

- **Phase 1 (`be8f675`):** `4.659 s` total wall time, `2,479,328 KiB` (`~2.36 GiB`) Peak RSS across the entire `10..1,000,000` sweep (`exit=0`).
- **Phase 2 (`e9cd4fc`):** `2.926 s` total wall time (`-37.2%`), `1,550,700 KiB` (`~1.48 GiB`, `-37.5%`) Peak RSS (`exit=0`).

| Rules (`N`) | Phase 1 Compile (`be8f675`) | Phase 2 Compile (`e9cd4fc`) | Phase 1 `rb_arena` | Phase 2 `rb_arena` | Bytes / Rule (`e9cd4fc`) | `sess_init` (`e9cd4fc`) | `fire_1` (`e9cd4fc`) | `fire_100` (`e9cd4fc`) | Live Mems | `alpha_shared` | `trace_ok` |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | :---: |
| `10` | `0.17 ms` | `0.10 ms` | `11,592 B` | `8,528 B` | `852.8 B` | `112.98 us` | `114.80 us` | `1266.29 us` | `20` | `18` | `true` |
| `100` | `0.27 ms` | `0.17 ms` | `97,296 B` | `61,072 B` | `610.7 B` | `15.34 us` | `12.38 us` | `2387.03 us` | `200` | `198` | `true` |
| `1,000` | `2.05 ms` | `1.19 ms` | `914,432 B` | `557,584 B` | `557.6 B` | `14.91 us` | `7.29 us` | `727.55 us` | `200` | `1,998` | `true` |
| `10,000` | `23.58 ms` | `11.86 ms` | `8,881,628 B` | `5,142,160 B` | `514.2 B` | `26.95 us` | `22.62 us` | `1089.61 us` | `200` | `19,998` | `true` |
| `100,000` | `275.83 ms` | `109.56 ms` | `94,284,604 B` | `57,813,548 B` | `578.1 B` | `42.22 us` | `27.13 us` | `879.15 us` | `200` | `199,998` | `true` |
| `1,000,000` | `3147.36 ms` | `1792.46 ms` | `913,445,348 B` | `556,083,744 B` | `556.1 B` | `34.51 us` | `32.67 us` | `1210.21 us` | `200` | `1,999,998` | `true` |

Key scaling properties verified at `1,000,000` rules:
- **O(1) Lazy Session Initialization (`R^2 = 1.000`):** `hugi run` reports `lazy_session_init` staying nearly flat from `18.81 us` at `10` rules (`54` allocs / `80.93 KiB`) to `19.48 us` at `1,000,000` rules (`54` allocs / `80.93 KiB`), allocating only `200` live session memories when firing `100` rules (`0` eager segment or beta allocations for the other `999,900` rules).
- **O(log N) / Flat Sparse Match Latency:** `sparse_alpha_match` runs at `1.60 us` (`10` rules), `2.23 us` (`1,000`), `2.24 us` (`100,000`), and `2.27 us` (`1,000,000` rules); `batch_100_alpha_match` holds at `476.00 us` (`100k`) to `487.60 us` (`1M`).
- **Rulebase Arena Compactness:** At `1,000,000` rules, `rb_arena_bytes` dropped from `913,445,348 B` (`~913 B/rule`) to `556,083,744 B` (`~556 B/rule`, `-39.1%`), and `segs_skipped = 0`.

---

## 3. Longitudinal `hugi` Suite Results (`e9cd4fc`) & Phase 2 Deltas (`be8f675 -> e9cd4fc`)

Overall `hugi compare --last` across the `77` shared benchmarks between `be8f675` and `e9cd4fc0fe6f`: **geomean delta `-49.18%`** (`65` improved, `12` flagged regressions — see the `mdm_e2e` correctness fix note below). Total ingested records in `e9cd4fc0fe6f`: `93` benchmarks (`4,244` samples).

### 3.1 Compiler & Matcher Scaling (`scale_rules`)

| Benchmark (`N`) | Baseline p50 (`be8f675`) | Candidate p50 (`e9cd4fc`) | Delta | Speedup | Allocs / op (`e9cd4fc`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `compile_rules[1000]` | `5.79 ms` | `1.09 ms` | `-81.21%` | `5.32x` | `15.0 / 107.38 KiB` |
| `compile_rules[10000]` | `66.47 ms` | `11.04 ms` | `-83.40%` | `6.02x` | `14.0 / 655.83 KiB` |
| `compile_rules[100000]` | `846.38 ms` | `109.41 ms` | `-87.07%` | `7.74x` | `15.0 / 12.51 MiB` |
| `compile_rules[1000000]` | `9.928 s` | `1.772 s` | `-82.15%` | `5.60x` | `15.0 / 104.03 MiB` |
| `lazy_session_init[1000000]` | `41.31 us` | `19.48 us` | `-52.84%` | `2.12x` | `54.0 / 80.93 KiB` |
| `sparse_alpha_match[1000000]` | `9.46 us` | `2.27 us` | `-75.96%` | `4.16x` | `8.1 / 2.30 KiB` |
| `batch_100_alpha_match[1000000]` | `3.82 ms` | `487.60 us` | `-87.22%` | `7.82x` | `1879.0 / 5.39 MiB` |

### 3.2 Decision Tables & Hardware Counters (`decision_tables`)

All `16` `decision_tables` benchmarks execute with **`0` heap allocations**. Running `hugi run --no-db --counters --runs 1 --groups decision_tables` collected hardware PMU counters alongside `obench` timings:

| Benchmark (`N` rows) | Standard Run p50 | Delta vs `be8f675` | Speedup | Counter Run p50 | Cycles | Instructions | IPC | Branch Misses | Cache Misses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `cost_tree_single_hit[10]` | `41.20 ns` | `-55.23%` | `2.23x` | `46.78 ns` | `126.1 c` | `638.4` | `2.89` | `0.0` | `0.1` |
| `lazy_cost_skip[10]` | `32.80 ns` | `-54.45%` | `2.20x` | `47.98 ns` | `129.3 c` | `543.1` | `2.36` | `0.0` | `0.1` |
| `bitset_collect_sum[1000]` | `83.00 ns` | `-64.31%` | `2.80x` | `89.56 ns` | `241.4 c` | `2.81k` | `3.37` | `1.3` | `1.3` |
| `cost_tree_single_hit[10000]` | `37.01 ns` | `-60.61%` | `2.54x` | `47.11 ns` | `127.0 c` | `7.38k` | `2.84` | `6.7` | `7.0` |
| `lazy_cost_skip[10000]` | `28.80 ns` | `-58.15%` | `2.39x` | `49.43 ns` | `133.2 c` | `7.73k` | `2.81` | `7.2` | `7.5` |
| `bitset_collect_sum[10000]` | `446.31 ns` | `-67.98%` | `3.12x` | `452.97 ns` | `1.22 Kc` | `76.44k` | `2.99` | `67.1` | `64.6` |
| `aot_native_fast_path[10000]` | `716.48 ps` | `-57.44%` | `2.35x` | `735.5 ps` | `2.0 c` | `13.0` | `4.08` | `0.0` | `0.0` |

Complexity fits remain `O(1)` for `cost_tree_single_hit`, `lazy_cost_skip`, and `aot_native_fast_path`, and `O(N log N)` for `bitset_collect_sum`.

### 3.3 Beta Joins & `@zero_alloc` Hot Match (`beta_joins`)

| Benchmark (`N`) | Baseline p50 (`be8f675`) | Candidate p50 (`e9cd4fc`) | Delta | Speedup | Allocs / op (`e9cd4fc`) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `two_way_mdm_join[10]` | `126.29 us` | `48.66 us` | `-61.47%` | `2.60x` | `144.0 / 222.35 KiB` |
| `two_way_mdm_join[100]` | `1.41 ms` | `425.08 us` | `-69.94%` | `3.33x` | `987.0 / 1.59 MiB` |
| `two_way_mdm_join[1000]` | `22.36 ms` | `3.95 ms` | `-82.32%` | `5.65x` | `9162.0 / 12.67 MiB` |
| `two_way_mdm_join[10000]` | `461.54 ms` | `118.65 ms` | `-74.29%` | `3.89x` | `90249.0 / 182.38 MiB` |
| `phreak_hot_match_zero_alloc[10]` | `74.57 us` | `17.04 us` | `-77.14%` | `4.37x` | **`0`** |
| `phreak_hot_match_zero_alloc[100]` | `610.78 us` | `126.76 us` | `-79.25%` | `4.82x` | **`0`** |
| `phreak_hot_match_zero_alloc[1000]` | `16.02 ms` | `1.32 ms` | `-91.77%` | `12.14x` | **`0`** |
| `phreak_hot_match_zero_alloc[10000]` | `320.68 ms` | `27.42 ms` | `-91.45%` | `11.69x` | **`0`** |
| `parameterized_query[10000]` | `4.85 ms` | `1.58 ms` | `-67.44%` | `3.07x` | `8.0 / 64.00 KiB` |

`phreak_hot_match_zero_alloc` executes full `Session` modification (`session_modify_fact_by_key`), PHREAK join evaluation, Agenda heap dispatch, and JTMS logical assertion/retraction toggles in `.Fast` mode with **`0` heap allocations** across all `10`–`10,000` background scales, delivering up to **`12.14x`** speedup.

### 3.4 JTMS Churn & Semi-Naive Recursive Closure (`jtms_churn`, `recursive_strata`)

*(First full ingestion in `e9cd4fc`; `be8f675` baseline did not ingest `[10]`/`[100]` due to filter syntax mismatch in that run.)*

| Workload (`N`) | `N = 10` | `N = 100` | `N = 1,000` | `N = 5,000` | `N = 10,000` | Allocs at Max `N` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `jtms_churn::cascade_retract_audit_full` | `112.20 us` | `1.09 ms` | `12.29 ms` | — | `281.87 ms` | `290,456 / 230.84 MiB` |
| `jtms_churn::cascade_retract_fast_mode` | `107.80 us` | `1.06 ms` | `11.65 ms` | — | `258.98 ms` | `260,417 / 219.48 MiB` |
| `jtms_churn::retractable_accum_sum` | `4.80 us` | `6.68 us` | `31.16 us` | — | `754.32 us` | `9.0 / 152 B` |
| `recursive_strata::seminaive_dag_closure` | `121.38 us` | `1.30 ms` | `21.70 ms` | `221.16 ms` | — | `155,355 / 167.15 MiB` |

### 3.5 `xitdb` Storage Profiles (`xitdb_modes`)

Measured on `10,000` HAMT records (`Safe_V2` SHA-1 with hardware SHA-NI on this CPU vs opt-in `Fast_Memory` `"fh16"` non-cryptographic hasher):

| Workload | `e9cd4fc` Median p50 | Speedup vs `be8f675` | Throughput | Allocs / op |
| --- | ---: | ---: | ---: | ---: |
| `insert_10k_safe_v2` | `2.92 ms` | `3.34x` | `342 tx/s` (`3.42 Mitem/s`) | `1.0 / 408 B` |
| `insert_10k_fast_memory` | `2.74 ms` | `3.35x` | `365 tx/s` (`3.65 Mitem/s`) | `1.0 / 408 B` |
| `lookup_10k_safe_v2` | `1.17 ms` | `3.71x` | `8.53 Mitem/s` | `0` |
| `lookup_10k_fast_memory` | `857.21 us` | `4.78x` | `11.67 Mitem/s` | `0` |
| `lookup_10k_safe_v2_prehashed_cursor` | `561.61 us` | `6.05x` | `17.81 Mitem/s` | `0` |
| `field_read_10k_safe_v2_string` | `1.03 ms` | `5.29x` | `9.75 Mitem/s` | `0` |
| `field_read_10k_safe_v2_prehashed` | `526.88 us` | `8.85x` | `18.98 Mitem/s` | `0` |
| `diff_10_of_10k_safe_v2` | `3.56 us` | `2.66x` | `280,928 diff/s` (`2.81 Mitem/s`) | `0` |
| `diff_10_of_10k_fast_memory` | `3.25 us` | `2.69x` | `307,898 diff/s` (`3.08 Mitem/s`) | `0` |
| `commit_cycle_safe_v2` | `1.97 us` | `2.98x` | `506,768 commit/s` | `0` |
| `commit_cycle_fast_memory` | `1.88 us` | `3.24x` | `532,998 commit/s` | `0` |
| `batch_write_1k_single_tx_safe_v2` | `306.22 us` | `2.74x` | `3.27 Mitem/s` | `1.0 / 408 B` |
| `single_write_1k_separate_tx_safe_v2` | `2.03 ms` | `2.93x` | `491.7 Kitem/s` | `1.0 / 408 B` |

### 3.6 End-to-End MDM Mode Tradeoffs (`mdm_e2e`: `Audit_Full` vs `Fast`, `Safe_V2` vs `Fast_Memory`)

> **Note on `hugi compare` `mdm_e2e` delta (`be8f675 -> e9cd4fc`):** In baseline `be8f675`, [`rulebase_compile`](../forseti/rulebase_compile.odin) shallow-copied `ir.schemas` and `ir.bindings` slices from the IR arena, leaving `rb.bindings[i].segments` invalid after `ir_destroy(&ir)` so `session_sync_and_fire` saw empty dot paths and skipped firing rules (`~114 us` constant no-op). Fixing that deep copy in `e9cd4fc` restored full decision-table matching (`canonicalize`), negative blocking (`not Suppress`), domain aggregation (`count_domain_canon`), and atomic derived + audit commits; `e9cd4fc` therefore represents the first real full-execution `mdm_e2e` numbers.

| Scale (`N` base orgs, `10` deltas/tx) | `Audit_Full` + `Safe_V2` | `Fast` + `Safe_V2` (no derived commit) | `Audit_Full` + `Fast_Memory` | `Audit_Full` + `Safe_V2` Allocs/op |
| ---: | ---: | ---: | ---: | ---: |
| `10` | `272.93 us` | `125.66 us` (`2.17x` vs audit) | `270.73 us` | `186.3 / 92.58 KiB` |
| `100` | `404.84 us` | `262.45 us` (`1.54x` vs audit) | `406.09 us` | `182.5 / 23.54 KiB` |
| `1,000` | `2.43 ms` | `1.93 ms` (`1.26x` vs audit) | `2.48 ms` | `191.0 / 6.52 KiB` |
| `10,000` | `39.37 ms` | `39.14 ms` | `39.45 ms` | `191.0 / 6.52 KiB` |

At `N = 10`–`1,000`, `Audit_Full` provenance plus incremental derived + audit persistence (`decisions`, `idx.*`, `__tx`) adds `~147 us` (`10`) to `~500 us` (`1,000`) with only `~6.52 KiB` per incremental transaction (`O(delta)` `xitdb` commit). At `N = 10,000`, runtime in `mdm_e2e` is dominated by re-evaluating the non-LIA `not Suppress` / `count(...)` accumulator rules over the `10,000`-fact `RawOrg` / `CanonOrg` working set rather than `xitdb` hashing or provenance writes.

---

## 4. Telemetry-Guided Optimizations Implemented

1. **Compiler & `Rulebase` Arena Compaction ([`forseti/rulebase_compile.odin`](../forseti/rulebase_compile.odin), [`forseti/segment_plan.odin`](../forseti/segment_plan.odin), [`forseti/vm_bytecode.odin`](../forseti/vm_bytecode.odin)):**
   - Scoped transient compiler structures (`sema`, `stratify`, `segment_plan`, `vm_bytecode`, and alpha-DAG construction) inside short-lived `vmem.Arena` scratch buffers freed before returning `Rulebase`.
   - Deep-copied `Schema_Def.fields` and `Binding_Def.segments` onto `rb.arena` so compiled `Rulebase` handles cleanly outlive `ir_destroy`.
   - Pre-reserved `rb.interner`, compacted `Alpha_Node` (`56 B` with `nil` edge pointers/slices on leaves and exact-sized `eq_buckets` on split nodes), replaced `map[u32][dynamic]` terminal subscribers with a flat `Alpha_Segment_Target` backing array, and replaced eager `1,000,000`-rule name pre-hashing with lazy per-fired-rule caching.
2. **Structural `Bytecode_Program` Interning ([`forseti/rulebase_compile.odin`](../forseti/rulebase_compile.odin), [`forseti/vm_bytecode.odin`](../forseti/vm_bytecode.odin)):**
   - Compiled expressions/`decide` calls into reusable scratch buffers (`vm_compile_*_to_scratch`), hashing and exact-comparing (`_values_bit_equal`, differentiating `i32` vs `i64` vs `f64` bit patterns) before materializing into `rb.arena`. Identical guard/action bytecode programs across thousands of rules share a single `Bytecode_Program`.
3. **Binary Max-Heap `Agenda` & Slot Pool ([`forseti/agenda.odin`](../forseti/agenda.odin)):**
   - Replaced `O(A)` linear scans + `ordered_remove` with per-stratum and per-(stratum, phase) binary max-heaps over a slot pool with generation-tagged `Agenda_Queued_Ref` cancellation (`O(log A)` stage/pop, `O(k_fact)` retraction via `fact_activations` capacity retention).
4. **Incremental LIA Delta Cursor, Beta Right-Index & Semi-Naive Waves ([`forseti/phreak_eval.odin`](../forseti/phreak_eval.odin), [`forseti/beta_join.odin`](../forseti/beta_join.odin), [`forseti/seminaive.odin`](../forseti/seminaive.odin)):**
   - Tracked `retract_epoch` on `Alpha_Memory`, delta cursors (`last_lia_epoch` / `last_lia_len`) on `pure_single_lia` segments, incremental right-bucket range indexing in `Beta_Memory`, and wave batching on `stratum_wave_safe` strata.
5. **O(delta) `xitdb` Derived & Audit Commit ([`forseti/provenance.odin`](../forseti/provenance.odin), [`forseti/xitdb_provenance.odin`](../forseti/xitdb_provenance.odin)):**
   - Tracked `dirty_derived_fids`, `retracted_derived_keys`, `committed_deriv_len`, and `dirty_retracted_derivs` against `committed_bridge_db` so incremental sync+commit writes only changed derived records, newly minted `dec:*` records, and alive/weight patches on retracted decisions (falling back to full commit when targeting a distinct snapshot bridge).
6. **`@zero_alloc` Hot Path & `.Fast` Recycling ([`forseti/session.odin`](../forseti/session.odin), [`forseti/jtms.odin`](../forseti/jtms.odin), [`forseti/alpha_eval.odin`](../forseti/alpha_eval.odin)):**
   - Pooled `Beta_Token` evaluation buffers on `Session.eval_buf_pool`, added in-place external fact modification in `.Fast` mode, retained dynamic slice capacities across `fact_alpha_mems`, `fact_activations`, and `logical_buckets`, embedded 4-parent inline storage (`inline_parents`) on `Justification`, and recycled `.Fast`-mode logical `Fact` and `Justification` slots across toggle churn.

---

## 5. Reproduction Commands

```bash
# 1. Full leak-checked ATDD + Unit specs and ASan checks
COLS="-collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"
VET="-vet -vet-tabs -strict-style -warnings-as-errors"
odin test specs -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test tests -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test tests -sanitize:address $COLS -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# 2. Verify @zero_alloc + smoke assertions across functional workloads
hugi run --test --groups decision_tables,xitdb_modes,beta_joins,jtms_churn,recursive_strata,mdm_e2e

# 3. Record full longitudinal benchmark run & inspect history/comparison
hugi run --runs 1 --warmup 1
hugi history
hugi compare --last --format md

# 4. Run 10..1,000,000 rule telemetry sweep directly
odin build benchmarks -out:/tmp/forseti_bench -o:speed -microarch:native $COLS $VET
/tmp/forseti_bench --profile-1m
```
