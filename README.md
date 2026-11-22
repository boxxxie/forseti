# `forseti` — Data-Oriented Rules Engine for Odin

**Forseti** is a high-performance, data-oriented rules engine for [Odin](https://odin-lang.org/), built primarily for **Master Data Management (MDM) with verifiable causal audit trails**, backed by [`xitdb`](../xitdb/README.md) (`Core_Memory` default at ~3M ops/sec, attachable `Core_Buffered_File`, and `Core_Overlay` zero-copy counterfactual forks).

It unifies the strongest techniques across modern rule-engine paradigms over one shared canonical IR (`Rulebase_IR`):

- **3 Authoring Tiers over One IR:**
  1. **External `.forseti` DSL** *(Priority #1)* — zero-copy parser, hot-reload, compiler-grade errors/warnings, and static table verification.
  2. **Internal Odin DSL** — typed `proc{...}` combinators building the exact same IR without a separate build step.
  3. **AOT Odin Codegen (`forseti gen`)** — emits `"contextless"` zero-allocation Odin procedures for frozen hot paths.
- **Compiled DMN Decision Tables (`Tablex++` / `ZEN`):** `U`/`A`/`P`/`F`/`C`/`M`/`R` hit policies, ZEN-style static gap/overlap/dead-rule proofs with concrete counterexample witnesses, cost-ordered lazy decision trees, and branchless `u64` bitset matrices.
- **Lazy PHREAK + Rete/UL Matcher:** Shared alpha network, `u64` segment bitmasks, Left & Right unlinking, lazy per-session memory allocation scaling from `10` to `1,000,000` rules, and a 32-bit `#must_tail` expression/guard VM.
- **Clara-Grade Reasoning + Stratified Datalog:** DBSP-style Z-set (`+1`/`-1`) JTMS with automatic cascading retractions, `not`/`exists`, retractable incremental accumulators (`count`, `sum`, `avg`, `min`, `max`, `distinct`), and Tarjan SCC semi-naive recursion for cyclic hierarchies.
- **Causal Provenance, Semirings & 3-Phase Effects:** Compact `#soa` derivation DAG committed atomically into `xitdb` (`decisions`, `idx.decisions_by_entity`, `idx.decisions_by_rule`, `__tx`), algebraic semiring evaluators (`Boolean`, `Why`, `How`, `Viterbi`), `explain`/`impact`/`diff_replay`, and Runic-style `Prepare -> Execute -> Apply` async effects.
- **First-Class Telemetry & Longitudinal Benchmarks:** Built-in phase/rule/memory telemetry (`JSONL` / Chrome Trace) and [`hugi`](../hugi/README.md) + `obench` benchmarks in [`hugi.json`](hugi.json) spanning `10` to `1,000,000` rules.

---

## Navigation

- **Agent Quick Reference & Rules:** [`usage-rules.md`](usage-rules.md) | [`AGENTS.md`](AGENTS.md)
- **DSL, Table & CLI Documentation:** [`docs/dsl-reference.md`](docs/dsl-reference.md) | [`docs/xitdb-fast-mode.md`](docs/xitdb-fast-mode.md) | [`docs/benchmarks.md`](docs/benchmarks.md)
- **Verified Runnable Examples (`examples/`):**
  - [`01_decision_tables`](examples/01_decision_tables/main.odin) — DMN tables (`First`/`Unique`/`Collect_Sum`/`Merge`), lazy column skipping & AOT codegen
  - [`02_mdm_xitdb_pipeline`](examples/02_mdm_xitdb_pipeline/main.odin) — `Safe_V2` `xitdb` persistence, `Delta_Syncer`, derived commit & index verification
  - [`03_jtms_steward_overrides`](examples/03_jtms_steward_overrides/main.odin) — Diamond support, JTMS cascades & unconditional `assert!` audit logs
  - [`04_cyclic_hierarchies`](examples/04_cyclic_hierarchies/main.odin) — Tarjan-stratified cyclic recursion, `explain` & cycle-break retraction
  - [`05_accumulators_and_effects`](examples/05_accumulators_and_effects/main.odin) — Tied-min retractable accumulators & 3-phase `core:thread` async effects
  - [`06_internal_odin_dsl_and_aot`](examples/06_internal_odin_dsl_and_aot/main.odin) — Tier 2 `Ir_Builder` internal DSL + Tier 3 AOT Odin output
  - [`07_telemetry_and_diff_replay`](examples/07_telemetry_and_diff_replay/main.odin) — Telemetry JSONL/Chrome Trace, `Core_Overlay` `diff_replay` & Mermaid/DOT export
- **Conductor Context & Sequenced Tracks:** [`conductor/tracks.md`](conductor/tracks.md) | [`conductor/index.md`](conductor/index.md)
- **Benchmark Config:** [`hugi.json`](hugi.json)
- **Reference Engines:** [`reference/README.md`](reference/README.md) (populate via `./scripts/clone_references.sh`)

---

## Quick Start & CLI

```bash
COLS="-collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"

# Validate, verify decision tables, or run policies from the CLI
odin run cmd/forseti $COLS -- check policy.forseti --warnings-as-errors
odin run cmd/forseti $COLS -- verify-tables policy.forseti
odin run cmd/forseti $COLS -- run --facts facts.json --store mdm.xit --format=json policy.forseti
odin run cmd/forseti $COLS -- explain --facts facts.json --binding CanonOrg policy.forseti
odin run cmd/forseti $COLS -- impact --facts facts.json --rule canonicalize --format=json policy.forseti
odin run cmd/forseti $COLS -- diff-replay --candidate v2.forseti --facts facts.json --format=json v1.forseti
odin run cmd/forseti $COLS -- export-mermaid --graph=rulebase policy.forseti
odin run cmd/forseti $COLS -- gen --package generated_tables --out generated_tables.odin policy.forseti
```
