# Product Definition: `forseti`

## Vision

**Forseti** is a pure-Odin, data-oriented rules and decision engine purpose-built for **Master Data Management (MDM), policy governance, and high-throughput incremental reasoning with complete, queryable causal audit trails**.

Rather than gluing together separate stateless decision-table libraries and closure-heavy workflow DAGs, Forseti compiles **one external `.forseti` DSL** (alongside an **internal Odin DSL** and **AOT Odin codegen**) into a single shared `Rulebase_IR` executed over an attachable **`xitdb`** store (`Core_Memory` by default, durable `Core_Buffered_File` on demand).

## Target User & Primary Workload

- **Primary Workload:** MDM entity matching, survivorship gating, identity routing, career/account consolidation, event/org hierarchy propagation, steward escalation, and counterfactual rule simulation (`diff_replay`).
- **Primary Consumers:** Odin systems/services, AI coding agents authoring/auditing `.forseti` policies, and data stewards inspecting persisted `decisions` lineage and highlighted decision tables.

## Core Capabilities

1. **All 3 Authoring Tiers over One Canonical `Rulebase_IR`:**
   - *Tier 1 (Priority #1):* External `.forseti` text DSL with zero-copy lexing, bounded error recovery, hot-reload, and compiler-grade compile-time errors/warnings.
   - *Tier 2:* Internal Odin DSL combinators constructing the exact same `Rulebase_IR`.
   - *Tier 3:* AOT Odin code generator (`forseti gen`) emitting `"contextless"` native procedures for ultra-hot frozen tables and filters.
2. **Verified DMN Decision Tables (`Tablex++` / `ZEN`):**
   - Hit policies `U`, `A`, `P`, `F`, `C` (`C+`, `C<`, `C>`, `C#`), `M`, `R`.
   - Compile-time domain partitioning verifying overlap, dead/shadowed rules, unsatisfiable cells, and completeness gaps with concrete counterexample witnesses.
   - Cost-ordered lazy decision trees (`F`/`U`) and branchless `u64` bitset matrices (`C`/`M`/`R`).
3. **`xitdb` Universal Data Substrate + Opt-In Fast-Memory Profile:**
   - Supports nested MDM documents, flat relations, B+Tree indexes, sets, and EAV triples through `xitdb.Read_Cursor` bindings.
   - Incremental `diff_collection` delta bridge skipping unchanged 9-byte `Slot`s (`+1` / `-1` Z-sets).
   - Zero-copy `Core_Overlay` counterfactual forks for `diff_replay`.
   - Safe v2 wire-compatible defaults preserved; opt-in fast-memory mode (`Hasher` preset, scratch-RAM options) explicitly gated and documented.
4. **Lazy PHREAK / Rete-UL Inference Core + 32-bit `#must_tail` Guard VM:**
   - Immutable thread-shared `Rulebase` + lazy-allocated `Session` scaling smoothly across `10`, `100`, `1,000`, `10,000`, `100,000`, and `1,000,000` rules.
   - Left/Right unlinking, `u64` segment bitmasks, hash-indexed Beta joins, and non-recursive pause/resume stack evaluation.
5. **Clara-Grade Reasoning, Stratified Datalog & Causal Provenance:**
   - Default `.Audit_Full` mode: Z-set JTMS automatic cascading retractions, `not`/`exists` negation, retractable incremental accumulators, Tarjan SCC semi-naive recursion (with Soufflé-style `proof_height`), `#soa` derivation DAG committed atomically to `xitdb`, pluggable semiring evaluators (`Boolean`, `Why`, `How`, `Viterbi`), `explain`/`impact`/`diff_replay`, and Runic-style `Prepare -> Execute -> Apply` async effects.
6. **Observability, Scaling & Agent Ergonomics:**
   - First-class per-phase, per-rule, and per-memory telemetry (`JSONL` + Chrome Trace JSON).
   - Longitudinal `hugi` + `obench` benchmarks from `10` to `1,000,000` rules.
   - Comprehensive, unambiguous agent-ready DSL docs (`docs/dsl-reference.md`, `usage-rules.md`) and CI-checked runnable examples.
