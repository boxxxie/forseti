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

- **Agent & Build Guide:** [`AGENTS.md`](AGENTS.md)
- **Conductor Context & Sequenced Tracks:** [`conductor/tracks.md`](conductor/tracks.md) | [`conductor/index.md`](conductor/index.md)
- **Benchmark Config:** [`hugi.json`](hugi.json)
- **Reference Engines (16 Cloned Repos):** [`reference/README.md`](reference/README.md) (populate via `./scripts/clone_references.sh`)
