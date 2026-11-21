# `forseti` — Data-Oriented Rules Engine Research & Design (Odin)

Research and architecture workspace for designing a high-performance, data-oriented rules engine in [Odin](https://odin-lang.org/), synthesizing the strongest ideas across modern rule-engine paradigms:

- **Compiled DMN Decision Tables** (Tablex, GoRules ZEN / JDM) — gap/overlap/dead-rule static proofs, cost-ordered decision trees, and ternary bitset evaluation.
- **Lazy PHREAK & Rete/UL Pattern Matching** (Drools PHREAK, Soar Rete/UL, CLIPS, Clara Rules, O'Doyle / Pararules) — segment bitmask linking, hash-indexed joins, pause/resume evaluation stacks, and dual typed-struct / EAV working memory.
- **Truth Maintenance & Retractable Aggregations** (Clara Rules JTMS, CLIPS `logical` CE, DBSP Z-sets) — automatic cascading retractions (`+1` / `-1` weights) and incremental `min` / `max` / `sum` / `count` accumulators.
- **Stratified Recursion & Relational Engines** (Soufflé, Ascent, Egglog, Feldera DBSP) — Tarjan SCC stratification, semi-naive fixed-point evaluation, and E-graphs / congruence closure.
- **Causal Provenance, Semirings & 3-Phase Effects** (Runic, Radul & Sussman Propagators, ProvSQL) — compact `#soa` derivation lineage, algebraic provenance semirings, counterfactual `diff_replay`, and lock-free `Prepare -> Execute -> Apply` external effects.

## Reference Repositories

All upstream reference codebases are cloned locally (gitignored) into `reference/` using:

```bash
./scripts/clone_references.sh
```

See [reference/README.md](reference/README.md) for the annotated source map, commit SHAs, and specific algorithms/modules to inspect in each repository.
