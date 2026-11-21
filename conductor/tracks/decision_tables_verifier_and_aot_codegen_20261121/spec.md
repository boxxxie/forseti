# Specification: Verified DMN Decision Tables (`Tablex++` / `ZEN`), Static Gap/Overlap Proofs, Dual Cost-Tree/Bitset Compilers, and Tier 3 AOT Odin Codegen

> - **Track ID:** `decision_tables_verifier_and_aot_codegen_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`

---

## 1. Problem Statement & Motivation

Studying `Tablex` (`reference/tablex`) in CAASA Connect and `ZEN` (`reference/zen/core/engine/src/analysis/table/`) revealed two critical needs for MDM policy matrices (`survivorship_gate`, `identity_routing`, `career_consolidation`, `event_lifecycle`):
1. **Static correctness proofs:** Real policy tables silently accumulate shadowed rows, `Unique` policy overlaps, unsatisfiable cells, and missing domain gaps unless verified by domain partitioning with concrete counterexample witnesses.
2. **Cost-ordered lazy execution & fast multi-hit:** Forcing callers to eagerly precompute expensive inputs (e.g., Jev AI arbitration or DB lookups) before entering a table wastes huge compute when cheap columns decide 90% of rows; meanwhile `Collect`/`Merge` policies must compile to branchless `u64` bitset matrices rather than closure lists.

---

## 2. Architecture

- **Domain Partitioning Verifier (ZEN-inspired):** Decompose each typed input column (`bool`, `enum`, bounded integer/float intervals, string literal sets + `-` wildcard) into atomic disjoint partitions encoded as bitmasks (`u64` words), bounded by configurable search budgets (`MAX_TABLE_FRAGMENTS`, `MAX_VERIFY_BUDGET`) to guarantee compile-time termination.
- **Dual Runtime Compilation:**
  - *Single-Hit (`F`, `U`, `A`, `P`):* Compile into a compact flat **Cost-Weighted Decision Tree** where columns with lower `cost` and higher information gain split first. Input slots support lazy callback/thunk evaluation so expensive inputs never evaluate unless reached on a tree branch.
  - *Multi-Hit (`C`, `C+`, `C<`, `C>`, `C#`, `M`, `R`):* Compile into a **Ternary Bitset Matrix** evaluating up to 64 rules per bitwise `AND` + `intrinsics.count_trailing_zeros` extraction.
- **Tier 3 AOT Odin Codegen (`forseti gen`):** Emits standalone `"contextless"` Odin procedures for compiled decision tables plus `@(rodata)` metadata tables (`table_id`, `version`, `row_id`, formatted display rows) suitable for direct native embedding or UI rendering.

---

## 3. Functional Requirements

### FR-1: Hit Policies & Decision Table Evaluation
- Support all DMN hit policies: `First` (`F`), `Unique` (`U`), `Any` (`A`), `Priority` (`P`), `Collect` (`C` + aggregators `C+`, `C<`, `C>`, `C#`), `Merge` (`M`), and `Reverse_Merge` (`R`).
- Return structured `Decision_Result` containing output values, `matched_row_ids`, `table_name`, `table_version`, and compact `Decision_Trace` (evaluated column bitmask, skipped lazy columns, winning rule ID).

### FR-2: Static Soundness Verifier & Counterexample Witnesses
- Emit compile-time diagnostics with exact row/column `Span` and concrete failing input tuples:
  - `E3001`: `Unique` (`U`) rule overlap (or `Any` conflicting outputs on overlap) + exact witness tuple.
  - `E3002`: Unsatisfiable cell constraint (e.g., `>10 and <5`).
  - `W3001`: Completeness gap when `verify(complete)` or non-exhaustive table leaves uncovered domain regions + up to `K` concrete missing witness cases.
  - `W3002`: Unreachable / dead rule shadowed by earlier rows (with shadowing row IDs).
  - `W3003`: Duplicate or adjacent mergeable rules (optimization suggestion).
  - `W3004`: Cell covers entire column domain (suggest `-`).
  - `W3005`: Declared `enum` output variant never produced by any row.
  - `W3006`: Verification budget exceeded (`ChecksIncomplete` notice on oversized open tables).

### FR-3: Cost-Ordered Lazy Decision Tree & Bitset Matrix Compilers
- Implement cost-weighted optimal split compiler (exact DP when small `<= 12` columns, greedy cost/entropy heuristic above) producing a flat `[]DT_Node` array.
- Support lazy input evaluation (`Input_Thunk` / on-demand getter) so columns only compute when branched upon.
- Implement `u64`-word bitset matrix evaluator for `C`/`M`/`R` policies and `Collect` numeric aggregators (`+`, `<`, `>`, `#`).

### FR-4: Tier 3 AOT Odin Codegen (`forseti gen`)
- Emit formatted, `-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors`-clean `"contextless"` Odin files from any verified `Rulebase_IR` table.
- Expose `forseti verify-tables` and `forseti gen --out <file.odin>` in `cmd/forseti`.

### FR-5: Initial `hugi` + `obench` Table Benchmarks
- Benchmark single-hit (10 to 10,000 rows), lazy vs. eager expensive columns, bitset multi-hit, and AOT generated Odin code vs. interpreted tree under `hugi`/`obench` with `@zero_alloc` hot-path checks.

---

## 4. Non-Functional & Verification Requirements

- **4-Layer ATDD & Pattern D/E Split:** Author behavioral table specifications in `specs/decision_tables_spec_test.odin` using `#caller_location` row-constructor decision matrices (covering MDM tables like `survivorship_gate`, `identity_routing`, `career_consolidation`, lazy-cost skipping, static gap/overlap witnesses, and AOT parity). Keep interval-partition math and bitset matrix internals in Pattern E unit tests + Pattern D `t.seed` property invariants (`prop_*` with `testing.set_fail_timeout`).
- Zero allocations during `decide(&compiled_table, inputs)` hot-path evaluation.
- AOT generated Odin files must pass `odin check -vet -vet-tabs -strict-style -disallow-do -warnings-as-errors` automatically in tests.
- All `specs/` and `tests/` pass with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

---

## 5. Out of Scope

- Cross-fact Rete/PHREAK joins and working memory (Track 4).
- `xitdb` persistence of `decisions` records (Track 5).

---

## 6. Acceptance Criteria

- [ ] All DMN hit policies (`F`, `U`, `A`, `P`, `C*`, `M`, `R`) execute deterministically and match a brute-force table oracle across Pattern D `t.seed` randomized inputs.
- [ ] Static verifier detects overlaps, gaps, shadowed rows, and unused output variants with exact concrete counterexample witnesses.
- [ ] Cost-ordered decision tree skips unreached expensive columns (verified via thunk invocation counters and telemetry).
- [ ] `forseti gen` emits valid `"contextless"` Odin code passing strict `odin check` and matching runtime evaluator output identically.
- [ ] Row-attributed 4-layer ATDD specs (`specs/decision_tables_spec_test.odin`) and zero-alloc `decide` checks pass under `odin test specs -all-packages ... -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
