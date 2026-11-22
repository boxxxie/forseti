[README](../README.md) · **Docs Hub** · [Odin API](odin-api.md) · [DSL Reference](dsl-reference.md) · [Benchmarks](benchmarks.md) · [Agent Rules](../usage-rules.md)

# Forseti Documentation Hub

Welcome to the **Forseti** documentation hub. This guide helps you pick the right document, understand Forseti's core execution architecture, and jump straight into runnable examples.

---

## Choose Your Path

| If you are... | Start Here | What You Will Learn |
| :--- | :--- | :--- |
| **Writing `.forseti` policies** | [`dsl-reference.md`](dsl-reference.md) | Complete EBNF grammar, hit policies (`F`/`U`/`A`/`P`/`C*`/`M`/`R`), `E*`/`W*` error catalog, CLI |
| **Embedding Forseti in Odin** | [`odin-api.md`](odin-api.md) | Lifetimes, `Rulebase` vs `Session`, `Delta_Syncer`, `explain`/semirings, async effects, AOT |
| **Evaluating performance & scale** | [`benchmarks.md`](benchmarks.md) | `10`–`1,000,000` rule latency/RAM scaling, PMU counters, `@zero_alloc` hot paths |
| **Integrating as an AI coding agent** | [`usage-rules.md`](../usage-rules.md) | Decision trees, copy-paste recipes, top 12 pitfalls, and 4-layer ATDD rules |
| **Contributing to Forseti** | [`AGENTS.md`](../AGENTS.md) | Package invariants, canonical check/test/ASan commands, and [`conductor/tracks.md`](../conductor/tracks.md) |

---

## End-to-End Execution Lifecycle

```mermaid
flowchart TD
    SRC["1. Compile Source or Ir_Builder"] --> CHK["2. Sema + Table Verifier + Tarjan SCC"]
    CHK -->|rulebase_compile| RB["3. Immutable Rulebase (Alpha DAG + Tree/Bitsets + Bytecode)"]
    RB --> INIT["4. session_init (O(1) Lazy Sparse Allocation)"]
    INIT --> SYNC["5. Delta_Syncer.sync (Slot-Skipping Z-Set +1/-1 Deltas)"]
    SYNC --> MATCH["6. PHREAK Evaluation + #must_tail Guard VM"]
    MATCH --> AGENDA["7. Stratum & Phase Max-Heap Agenda Dispatch"]
    AGENDA --> JTMS["8. Z-Set JTMS Assert / Cascade Retract + #soa Provenance"]
    JTMS -->|dirty recursive stratum| MATCH
    JTMS -->|commit_derived = true| XIT["9. Atomic xitdb Commit (.derived, .decisions, .idx.*, .__tx)"]
    JTMS -->|effect staged| EFF["10. 3-Phase Async Effects (Prepare -> Workers -> Apply)"]
```

---

## Core Mental Models

### 1. Three Authoring Tiers over One Canonical `Rulebase_IR`
Every path lowers into the exact same validated `Rulebase_IR` (`forseti/ir.odin`):
- **Tier 1 (External `.forseti`):** Textual policies parsed via zero-copy lexer + Pratt parser (`compile_source`), hot-reloadable and statically checked with `file:line:col` diagnostics.
- **Tier 2 (Internal Odin DSL):** Typed `Ir_Builder` combinators (`forseti/dsl_odin.odin`) that emit `Rulebase_IR` directly inside Odin code without text parsing.
- **Tier 3 (AOT Odin Codegen):** `codegen_odin_module` / `forseti gen` compiles decision tables directly to standalone `"contextless"` Odin procedures with `0` runtime dependencies or heap allocations.

### 2. Immutable `Rulebase` vs. Pinned `Session`
- **`Rulebase`** is compiled once (`rulebase_compile`), packs all rules, alpha nodes, segments, decision tables, and interned bytecode programs into a compact `vmem.Arena`, and is read-only during inference.
- **`Session`** (`forseti/session.odin`) holds mutable working memory, lazy `Alpha_Memory` / `Segment_Memory` / `Beta_Memory` tables, the `Agenda`, Z-set JTMS justifications, and `#soa[dynamic]Derivation` provenance records. `Session` and `Store_Bridge` contain internal self-pointers and arenas: **always initialize in-place or heap-allocate with `new(...)` and never copy by value**.

### 3. Logical (`assert`) vs. Unconditional (`assert!`) Truth Maintenance
- **`assert Foo(...)`:** Recorded as a logically justified derivation (`Fact_Origin.Logical`) inside the Z-set JTMS. When any supporting premise retracts or becomes blocked by `not`, Forseti automatically cascades retractions downstream—unless another independent justification keeps the fact supported (diamond support).
- **`assert! Audit(...) unconditional`:** Permanently asserted (`Fact_Origin.Unconditional`) even if all triggering premises are later retracted, making it ideal for compliance audit trails.

### 4. Causal Provenance, Algebraic Semirings & Counterfactual `diff_replay`
In default `.Audit_Full` mode, every rule firing appends a compact 32-byte `Derivation` record into `#soa[dynamic]Derivation` with **zero hot-path SHA-1/SHA-256 hashing**:
- **`explain`:** Walks derivations backward to build a minimal acyclic proof tree (safe even when rules contain cyclic recursion).
- **`impact`:** Computes direct and transitive facts/derivations produced by a specific rule or version.
- **`evaluate_semiring`:** Evaluates provenance algebraically across `.Boolean` (exists), `.Why` (minimal witness fact sets), `.How` (symbolic `AND`/`OR` derivation formula), and `.Viterbi` (shortest/highest-confidence proof path).
- **`session_diff_replay` / `diff_replay`:** Forks a frozen snapshot of `Store_Bridge` using `xitdb.Core_Overlay` (`O(1)` fork cost, `0` mutations to the parent store) and reports exact `added`, `removed`, and `unchanged_count` derived facts for candidate rule changes.

---

## Verified Runnable Examples

All 7 examples in [`examples/`](../examples/) are compiled and leak-checked on CI by [`tests/test_examples_verify.odin`](../tests/test_examples_verify.odin):

1. [`01_decision_tables`](../examples/01_decision_tables/main.odin) — `First` lazy cost skipping (`cost 100`), `Collect_Sum`, `Merge`, and AOT codegen
2. [`02_mdm_xitdb_pipeline`](../examples/02_mdm_xitdb_pipeline/main.odin) — persisted `xitdb` v2 `.xit` pipeline, `Delta_Syncer`, and `.decisions` / `.idx.*` / `.__tx` verification
3. [`03_jtms_steward_overrides`](../examples/03_jtms_steward_overrides/main.odin) — Diamond support survival, cascading retractions, and `assert!` unconditional audit retention
4. [`04_cyclic_hierarchies`](../examples/04_cyclic_hierarchies/main.odin) — Tarjan SCC semi-naive recursion on a 3-node cycle, `explain`, and cycle-break retraction
5. [`05_accumulators_and_effects`](../examples/05_accumulators_and_effects/main.odin) — Tied-minimum retractable accumulators (`count`, `sum`, `min`, `max`) & 3-phase `core:thread` async effects
6. [`06_internal_odin_dsl_and_aot`](../examples/06_internal_odin_dsl_and_aot/main.odin) — Tier 2 `Ir_Builder` internal Odin DSL and Tier 3 AOT Odin code generation
7. [`07_telemetry_and_diff_replay`](../examples/07_telemetry_and_diff_replay/main.odin) — `Telemetry_Sink` (`JSONL` + Chrome Trace), `Core_Overlay` `diff_replay`, and Mermaid graph export
