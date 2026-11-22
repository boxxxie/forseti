[README](README.md) · [Docs Hub](docs/README.md) · [Odin API](docs/odin-api.md) · [DSL Reference](docs/dsl-reference.md) · [xitdb Modes](docs/xitdb-fast-mode.md) · [Benchmarks](docs/benchmarks.md) · **Agent Rules**

# Forseti Usage Rules & Agent Guide

Prescriptive rules, authoring decision trees, Odin embedding recipes, and pitfalls to avoid when writing `.forseti` policies, Odin integrations, and 4-layer `specs/` tests. For full grammar and diagnostic catalogs, see [`docs/dsl-reference.md`](docs/dsl-reference.md); for full Odin runtime details, see [`docs/odin-api.md`](docs/odin-api.md).

## Contents

- [Core Mental Model & Invariants](#core-mental-model--invariants)
- [Decision Trees](#decision-trees)
- [Canonical Recipes](#canonical-recipes)
- [Top 12 Agent Pitfalls (DO vs. DO NOT)](#top-12-agent-pitfalls-do-vs-do-not)

---

## Core Mental Model & Invariants

- **Single Canonical `Rulebase_IR`:** External `.forseti` policies (`compile_source`), Tier 2 internal Odin builders (`ir_builder_build`), and Tier 3 AOT Odin table generators (`codegen_odin_module`) all share one IR, semantic validator (`analyze_ir`), decision-table verifier (`verify_all_tables`), and Tarjan stratifier (`stratify_ir`).
- **Immutable `Rulebase` vs. Pinned `Session`:** Compile `Rulebase` once with `rulebase_compile` and share it read-only across sessions. `Session` and `Store_Bridge` hold internal self-pointers (arenas, maps, attached DB pointers) — **initialize in-place or heap-allocate via `new(...)` and never copy by value**.
- **Lazy Sparse `Session` Memory (`1M`-Rule Scale):** Alpha and Beta memories are allocated lazily on first activation. `session_init` over `1,000,000` rules allocates O(active) containers, not O(rules).
- **Safe `xitdb` Defaults & Audit-Full Default:** Default `Store_Bridge` mode is `Xitdb_Config{mode = .Safe_V2}` (SHA-1 HAMT + CRC-64/XZ trailers) and default `Session_Config` mode is `provenance_mode = .Audit_Full` (Z-set JTMS + `#soa[dynamic]Derivation` causal lineage).
- **Zero Hot-Path Crypto Hashing:** Never run SHA-1/SHA-256 per fact inside rule matching or `Derivation` recording. Compute HAMT digests only on store commit/sync using `Prehashed_Key`.

---

## Decision Trees

### Authoring Construct Selection

- **Decision Table (`table ... hit ...`):** Finite-domain column conditions, survivorship gates, tier routing, scoring sums (`Collect_Sum`), or field-priority merging (`Merge` / `Reverse_Merge`) requiring static overlap/completeness verification.
- **Standard Rule (`rule ...`):** Joins across multiple fact bindings, derived assertions (`assert`), logical retractions (`retract`), negation (`not` / `exists`), or incremental accumulators (`count`, `sum`, `min`, `max`, `avg`, `distinct`).
- **Recursive Rule (`derived X` feeding `derived X`):** Transitive graph/hierarchy closure (`OrgCluster`). Keep recursion positive (`E4001` rejects negative/aggregate cycles across an SCC).
- **Async Effect (`effect "kind" { ... }`):** Non-blocking external I/O executed via 3-phase `session_prepare_effects` -> worker threads -> `session_apply_effects`.
- **AOT Odin Codegen (`forseti gen`):** Zero-allocation `"contextless"` Odin procedures for hot-path decision tables (`First`, `Unique`, `Any`, `Priority`, `Collect*`, `Merge`, `Reverse_Merge`).

### Session & Store Mode Selection

- **`.Audit_Full` (default):** Full JTMS cascading retractions, `explain`, `impact`, `evaluate_semiring`, `diff_replay`, and atomic `decisions` / `idx.decisions_*` / `__tx` commits.
- **`.Support_Only`:** Tracks logical justification support without retaining `Derivation` proof DAGs.
- **`.Fast`:** Disables derivation/JTMS overhead for maximum ephemeral throughput when audit lineage is not needed.
- **`Xitdb_Mode.Safe_V2` (default) vs. `.Fast_Memory`:** Always use `.Safe_V2` for persisted `.xit` files (`Core_Buffered_File` / `Core_File`). Use `.Fast_Memory` only for trusted ephemeral RAM stores (`docs/xitdb-fast-mode.md`).

---

## Canonical Recipes

### 1. Clean Verification-Ready `.forseti` MDM Policy

```forseti
module usage_mdm version "1.0"

schema RawAccount {
  id: string,
  domain: string,
  revenue: i64,
  verified: bool
}
schema SuppressedDomain { domain: string }
schema GoldenAccount {
  id: string,
  domain: string,
  tier: string
}
schema AuditRecord { id: string }

source RawAccount : RawAccount at .accounts.raw[?id]
source Suppressed : SuppressedDomain at .accounts.suppressed[?id]
derived GoldenAccount : GoldenAccount at .accounts.golden[?id]
derived AuditRecord : AuditRecord at .accounts.audit[?id]

table account_tier version "1.0" hit First verify(complete, no_dead_rules) {
  inputs { revenue: i64 cost 1, verified: bool cost 1 }
  outputs { tier: string }
  rows {
    r_enterprise: >= 1_000_000 | true || "enterprise";
    r_growth:     >= 100_000   | true || "growth";
    r_standard:   -            | -    || "standard";
  }
}

rule promote_account phase "survive" salience 50 {
  when {
    ?_raw := RawAccount(id: ?aid, domain: ?dom, revenue: ?rev, verified: ?ok)
    ?res := decide account_tier(revenue: ?rev, verified: ?ok)
    not Suppressed(domain: ?dom)
  }
  then {
    assert GoldenAccount(id: ?aid, domain: ?dom, tier: ?res.tier)
    assert! AuditRecord(id: ?aid) unconditional
  }
}

query golden_by_domain(domain: string) {
  GoldenAccount(domain: ?domain)
}
```

### 2. Compiling, Firing & Destroying a `Rulebase` and `Session` in Odin

Always follow LIFO teardown (`session_destroy` -> `free(sess)` -> `rulebase_destroy` -> `ir_destroy` -> `diag_list_destroy`):

```odin
diags: forseti.Diagnostic_List
assert(forseti.diag_list_init(&diags) == nil)
defer forseti.diag_list_destroy(&diags)

ir, c_err := forseti.compile_source(policy_src, "policy.forseti", &diags)
assert(c_err == nil && diags.error_count == 0)
defer forseti.ir_destroy(&ir)

rb, rb_err := forseti.rulebase_compile(&ir)
assert(rb_err == .None)
defer forseti.rulebase_destroy(&rb)

sess := new(forseti.Session)
assert(forseti.session_init(sess, &rb) == .None)
defer {
	forseti.session_destroy(sess)
	free(sess)
}

s_id, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, "acct:1")
_, _ = forseti.session_insert_fact(sess, "RawAccount", "acct:1", {s_id, s_id, i64(2_000_000), true})
_, _ = forseti.session_fire(sess)
```

### 3. Incremental `xitdb` Sync & Atomic Audit Commit

```odin
bridge: forseti.Store_Bridge
assert(forseti.store_bridge_open_file(&bridge, "mdm.xit", forseti.Xitdb_Config{mode = .Safe_V2}) == nil)
defer forseti.store_bridge_destroy(&bridge)

syncer: forseti.Delta_Syncer
assert(forseti.delta_syncer_init(&syncer) == nil)
defer forseti.delta_syncer_destroy(&syncer)

_ = forseti.delta_syncer_watch(&syncer, ".accounts.raw")
fired, err := forseti.session_sync_and_fire(sess, &bridge, &syncer, commit_derived = true)
assert(err == nil)
_ = fired
```

### 4. Explaining, Evaluating Semirings, Counterfactual Replay & Visual Export

```odin
tree := forseti.explain(sess, derived_fid)
defer forseti.explain_tree_destroy(&tree)

rep := forseti.impact(sess, rule_id)
defer forseti.impact_report_destroy(&rep)

semi := forseti.evaluate_semiring(sess, derived_fid, .How)
defer forseti.semiring_result_destroy(&semi)

diff_rep, d_err := forseti.session_diff_replay(sess, &bridge, &cand_rb, {".accounts.raw"})
assert(d_err == nil)
defer forseti.diff_replay_report_destroy(&diff_rep)

dot_txt, _ := forseti.export_derivations_dot(sess, derived_fid)
defer delete(dot_txt)
```

### 5. Three-Phase Async Effects (`Prepare -> Execute -> Apply`)

```odin
jobs := forseti.session_prepare_effects(sess)
defer forseti.effects_jobs_destroy(jobs)
// Run worker threads reading only plain copied values inside `jobs[i].fields`
// (do NOT touch `Session` or `sess.interner` from worker threads).
// Back on the engine thread, build `[]Effect_Result`, then apply:
applied, a_err := forseti.session_apply_effects(sess, results)
assert(a_err == .None)
defer delete(applied)
_, _ = forseti.session_fire(sess)
```

---

## Top 12 Agent Pitfalls (DO vs. DO NOT)

1. **DO NOT** copy a `Session` or `Store_Bridge` by value after initialization (corrupts internal pointers and arenas). **DO** initialize in-place on a pinned local or `new(...)`.
2. **DO NOT** call `analyze_ir` twice on the same `Diagnostic_List` after `compile_source` or `ir_builder_build` (both already run semantic analysis, table verification, and stratification). **DO** check `diags` directly or pass `nil` before manual IR edits.
3. **DO NOT** add `verify(no_overlap)` onto a `First` table containing a `- | -` catch-all fallback row (`E3001` flags overlap with fallback). **DO** use `verify(complete, no_dead_rules)` on fallback `First` tables, or keep cells disjoint under `Unique`.
4. **DO NOT** leave unused `?var` bindings unprefixed (`W2001`). **DO** name intentionally ignored bindings `?_var` (e.g. `?_r := RawOrg(...)`).
5. **DO NOT** omit row labels on decision table rows (`E1005`). **DO** prefix every row with a unique identifier (`r1: ... || ...;`).
6. **DO NOT** use `assert!` when you want JTMS cascading retractions on premise removal. **DO** use `assert` for logical facts and reserve `assert! ... unconditional` for permanent audit logs.
7. **DO NOT** reference a variable bound inside `not { ... }` or `exists { ... }` in outer patterns or `then` actions (`E2003`). **DO** bind shared join variables in an outer positive pattern first.
8. **DO NOT** create negative or aggregation cycles across derived bindings (`E4001`). **DO** split raw/derived layers so every cycle through `not` or accumulators flows strictly across increasing strata.
9. **DO NOT** pass `Xitdb_Mode.Fast_Memory` or `fast_hasher()` to `store_bridge_open_file` (`Disk_Fast_Mode_Forbidden`). **DO** keep file-backed stores on `.Safe_V2`.
10. **DO NOT** forget cleanup on returned reports/strings (`explain_tree_destroy`, `impact_report_destroy`, `semiring_result_destroy`, `diff_replay_report_destroy`, `effects_jobs_destroy`, `sync_result_destroy`, `delete(applied)`, `delete(exported)`). **DO** test every test binary with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
11. **DO NOT** touch `sess.interner` or `Session` maps from worker threads during Phase 2 async effect execution. **DO** inspect `Effect_Job.fields` (`str` / `value`) on workers and intern result strings back on the engine thread before `session_apply_effects`.
12. **DO NOT** put internal `forseti` allocators, cursor walks, or `driver_*` helpers in `specs/*_spec_test.odin` (4-layer ATDD violation) or omit `loc = loc` forwarding in `specs/dsl_test.odin`. **DO** keep infrastructure/codec tests in `tests/` and behavioral specs pure in `specs/`.
