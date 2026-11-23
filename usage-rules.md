[README](README.md) · [Docs Hub](docs/README.md) · [Odin API](docs/odin-api.md) · [DSL Reference](docs/dsl-reference.md) · [C99 ABI](docs/c-api.md) · [Editors & LSP](docs/editors.md) · [Benchmarks](docs/benchmarks.md) · **Agent Rules**

# Forseti Usage Rules & Agent Guide

Prescriptive rules, authoring decision trees, Odin/C99/Actor embedding recipes, and pitfalls to avoid when writing `.forseti` policies, integrations, and 4-layer `specs/` tests. For full grammar and diagnostic catalogs, see [`docs/dsl-reference.md`](docs/dsl-reference.md); for full Odin runtime details, see [`docs/odin-api.md`](docs/odin-api.md); for C99 ABI details, see [`docs/c-api.md`](docs/c-api.md).

## Contents

- [Core Mental Model & Invariants](#core-mental-model--invariants)
- [Decision Trees](#decision-trees)
- [Canonical Recipes](#canonical-recipes)
- [Top 16 Agent Pitfalls (DO vs. DO NOT)](#top-16-agent-pitfalls-do-vs-do-not)

---

## Core Mental Model & Invariants

- **Single Canonical `Rulebase_IR`:** External `.forseti` policies (`compile_source`, `compile_file`, `compile_source_with_imports`), Tier 2 internal Odin builders (`ir_builder_build`), and Tier 3 AOT Odin table generators (`codegen_odin_module`) all share one IR, semantic validator (`analyze_ir`), decision-table verifier (`verify_all_tables`), and Tarjan stratifier (`stratify_ir`).
- **DSL v1.1 `import` & Pure Built-Ins:** Share `schema`/`table` declarations with `import "shared.forseti"` (diamond-deduplicated; cycles report `E2006`) and use pure scalar built-ins (`lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, `max`) in `where` / `:=` clauses.
- **Immutable `Rulebase` vs. Pinned `Session`:** Compile `Rulebase` once with `rulebase_compile` and share it read-only across threads/sessions. `Session` and `Store_Bridge` hold internal self-pointers (arenas, maps, attached DB pointers) — **initialize in-place or heap-allocate via `new(...)` and never copy by value**.
- **Lazy Sparse `Session` Memory (`1M`-Rule Scale):** Alpha and Beta memories are allocated lazily on first activation. `session_init` over `1,000,000` rules allocates `O(active)` containers, not `O(rules)`.
- **Safe `xitdb` Defaults & Audit-Full Default:** Default `Store_Bridge` uses standard `xitdb` v2 defaults (`xitdb.sha1_hasher()` HAMT + CRC-64/XZ trailers) and default `Session_Config` mode is `provenance_mode = .Audit_Full` (Z-set JTMS + `#soa[dynamic]Derivation` causal lineage).
- **Zero Hot-Path Crypto Hashing:** Never run SHA-1/SHA-256 per fact inside rule matching or `Derivation` recording. Compute HAMT digests only on store commit/sync using `Prehashed_Key`.

---

## Decision Trees

### Authoring Construct Selection

- **Decision Table (`table ... hit ...`):** Finite-domain column conditions, survivorship gates, tier routing, scoring sums (`Collect_Sum`), or field-priority merging (`Merge` / `Reverse_Merge`) requiring static overlap/completeness verification.
- **Standard Rule (`rule ...`):** Joins across multiple fact bindings, derived assertions (`assert`), logical retractions (`retract`), negation (`not` / `exists`), or incremental accumulators (`count`, `sum`, `min`, `max`, `avg`, `distinct`, `collect`).
- **Recursive Rule (`derived X` feeding `derived X`):** Transitive graph/hierarchy closure (`OrgCluster`). Keep recursion positive (`E4001` rejects negative/aggregate cycles across an SCC).
- **Async Effect (`effect "kind" { ... }`):** Non-blocking external I/O executed via 3-phase `session_prepare_effects` -> worker threads -> `session_apply_effects` (or `actors.Effect_Dispatcher`).
- **AOT Odin Codegen (`forseti gen`):** Zero-allocation `"contextless"` Odin procedures for hot-path decision tables (`First`, `Unique`, `Any`, `Priority`, `Collect*`, `Merge`, `Reverse_Merge`).

### Compilation Entrypoint Selection

- **`compile_source(src, name, &diags, &tel)`:** Single in-memory `.forseti` string with no `import` statements.
- **`compile_source_with_imports(src, name, include_paths, &diags, &tel)`:** In-memory root source that transitively resolves `import "..."` relative to `name` and `include_paths`.
- **`compile_file(file_path, include_paths, &diags, &tel)`:** Disk entrypoint resolving relative and `--include` / `-I` imports with diamond deduplication and `E2006` cycle detection.
- **`ir_builder_build(&b, &diags)`:** Programmatic Tier 2 Odin IR builder (no `.forseti` parsing).

### Session & Store Mode Selection

- **`.Audit_Full` (default):** Full JTMS cascading retractions, `explain`, `impact`, `evaluate_semiring`, `diff_replay`, and atomic `decisions` / `idx.decisions_*` / `__tx` commits.
- **`.Support_Only`:** Tracks logical justification support without retaining `Derivation` proof DAGs.
- **`.Fast`:** Disables derivation/JTMS overhead for maximum ephemeral throughput when audit lineage is not needed (`session_modify_fact_by_key` reuses slots with `0` allocations).

### Host Runtime & Boundary Selection

- **Single-Threaded Odin (`package forseti`):** Direct `Session` + `Store_Bridge` + [`typed_api.odin`](forseti/typed_api.odin) struct helpers (`session_insert_struct`, `decide_struct`, `query_unmarshal`).
- **Multi-Threaded / Multi-Tenant Odin (`package forseti_actors` in `actors/`):** [`sleipnir`](https://github.com/boxxxie/sleipnir)-backed `Session_Actor`, single-writer `Xitdb_Commit_Actor`, `Tenant_Rule_Runtime`, `Effect_Dispatcher`, `Parallel_Diff_Replay`, and `Rulebase_Coordinator` hot-reload.
- **External Language Host (`capi/` + `include/forseti.h`):** Stable opaque C99 ABI (`libforseti`) returning JSON query/explain/impact/diff/telemetry outputs freed via `forseti_free_string`.
- **Zero-Dependency Hot Table (`forseti gen`):** Standalone `"contextless"` Odin `decide_<table>` procedure (`~776 ps`, `0` allocs).

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
    where len(?dom) > 0
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

### 3. Typed Odin Struct Ingestion, `decide_struct` & `query_unmarshal`

Struct fields map via `forseti:"..."` tags (falling back to Odin field names; `forseti:"-"` skips a field). Passed `Query_Arg` strings must still be interned as `String_Id`:

```odin
Account_In :: struct {
	id:       string `forseti:"id"`,
	domain:   string `forseti:"domain"`,
	revenue:  i64    `forseti:"revenue"`,
	verified: bool   `forseti:"verified"`,
}
Tier_Out :: struct {
	tier: string `forseti:"tier"`,
}
Golden_Row :: struct {
	id:     string `forseti:"?aid"`,
	domain: string `forseti:"?dom"`,
	tier:   string `forseti:"?tier"`,
}

_, _ = forseti.session_insert_struct(sess, "RawAccount", "acct:1", Account_In{"acct:1", "acme.com", 2_000_000, true})
_, _ = forseti.session_fire(sess)

tier_out: Tier_Out
_, _ = forseti.decide_struct(&rb, "account_tier", Account_In{"acct:1", "acme.com", 2_000_000, true}, &tier_out)

qr: forseti.Query_Result
defer forseti.query_result_destroy(&qr)
dom_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "acme.com")
_ = forseti.session_query(sess, "golden_by_domain", {{name = "domain", value = dom_sid}}, &qr)

rows: [dynamic]Golden_Row
defer delete(rows)
_ = forseti.query_unmarshal(sess, &qr, &rows) // String fields borrow sess/qr storage
```

### 4. Incremental `xitdb` Sync & Atomic Audit Commit

```odin
bridge: forseti.Store_Bridge
assert(forseti.store_bridge_open_file(&bridge, "mdm.xit") == nil)
defer forseti.store_bridge_destroy(&bridge)

syncer: forseti.Delta_Syncer
assert(forseti.delta_syncer_init(&syncer) == nil)
defer forseti.delta_syncer_destroy(&syncer)

_ = forseti.delta_syncer_watch(&syncer, ".accounts.raw")
fired, err := forseti.session_sync_and_fire(sess, &bridge, &syncer, commit_derived = true)
assert(err == nil)
_ = fired
```

### 5. Explaining, Evaluating Semirings, Counterfactual Replay & Visual Export

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

### 6. Three-Phase Async Effects (`Prepare -> Execute -> Apply`)

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

### 7. Multi-Threaded Sleipnir Actor Runtime (`actors/`)

```odin
sched := actor.scoped_scheduler(num_workers = 4) // Auto-joins & cleans up on scope exit

coord, c_err := actors.rulebase_coordinator_spawn(sched, v1_policy, "v1.forseti", &snap, {".orgs.raw"})
assert(c_err == .None)
sa, s_err := actors.rulebase_coordinator_spawn_session(sched, coord)
assert(s_err == nil)

q1 := actor.call(sched, sa, actors.Session_Msg(actors.Run_Query{query_name = "ent_orgs"}), actors.Session_Query_Reply)
defer forseti.query_result_destroy(&q1.result)

// Atomically validate, compile, and swap all subscribed Session_Actors onto v2:
rel := actor.call(sched, coord, actors.Coordinator_Msg(actors.Reload_Policy{source = v2_policy, filename = "v2.forseti"}), actors.Coordinator_Reload_Reply)
assert(rel.ok)
```

---

## Top 16 Agent Pitfalls (DO vs. DO NOT)

1. **DO NOT** copy a `Session` or `Store_Bridge` by value after initialization (corrupts internal pointers and arenas). **DO** initialize in-place on a pinned local or `new(...)`.
2. **DO NOT** call `analyze_ir` twice on the same `Diagnostic_List` after `compile_source` or `ir_builder_build` (both already run semantic analysis, table verification, and stratification). **DO** check `diags` directly or pass `nil` before manual IR edits.
3. **DO NOT** add `verify(no_overlap)` onto a `First` table containing a `- | -` catch-all fallback row (`E3001` flags overlap with fallback). **DO** use `verify(complete, no_dead_rules)` on fallback `First` tables, or keep cells disjoint under `Unique`.
4. **DO NOT** leave unused `?var` bindings unprefixed (`W2001`). **DO** name intentionally ignored bindings `?_var` (e.g. `?_r := RawOrg(...)`).
5. **DO NOT** omit row labels on decision table rows (`E1005`). **DO** prefix every row with a unique identifier (`r1: ... || ...;`).
6. **DO NOT** use `assert!` when you want JTMS cascading retractions on premise removal. **DO** use `assert` for logical facts and reserve `assert! ... unconditional` for permanent audit logs.
7. **DO NOT** reference a variable bound inside `not { ... }` or `exists { ... }` in outer patterns or `then` actions (`E2003`). **DO** bind shared join variables in an outer positive pattern first.
8. **DO NOT** create negative or aggregation cycles across derived bindings (`E4001`). **DO** split raw/derived layers so every cycle through `not` or accumulators flows strictly across increasing strata.
9. **DO NOT** re-hash static schema/path keys on every lookup or commit (`xitdb.hash_map_get_slot` hashes on each call). **DO** keep default `Xitdb_Config{}` (SHA-1 v2 wire compatibility) and reuse `Prehashed_Key` or a single `xitdb.database_digest_string_buf` digest across maps/sets.
10. **DO NOT** forget cleanup on returned reports/strings (`explain_tree_destroy`, `impact_report_destroy`, `semiring_result_destroy`, `diff_replay_report_destroy`, `effects_jobs_destroy`, `sync_result_destroy`, `delete(applied)`, `delete(exported)`). **DO** test every test binary with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
11. **DO NOT** touch `sess.interner` or `Session` maps from worker threads during Phase 2 async effect execution. **DO** inspect `Effect_Job.fields` (`str` / `value`) on workers and intern result strings back on the engine thread before `session_apply_effects`.
12. **DO NOT** put internal `forseti` allocators, cursor walks, or `driver_*` helpers in `specs/*_spec_test.odin` (4-layer ATDD violation) or omit `loc = loc` forwarding in `specs/dsl_test.odin`. **DO** keep infrastructure/codec tests in `tests/` and behavioral specs pure in `specs/`.
13. **DO NOT** pass a raw Odin `string` inside `Query_Arg.value` (`Value` holds `String_Id`, not `string`), omit schema fields in `session_insert_struct` (triggers `.Missing_Field`), or let `query_unmarshal` / `decide_struct` string fields outlive `Session`, `Query_Result`, or `Compiled_Table`. **DO** intern query strings via `intern_session_string(&rb.interner, &sess.interner, s)` and clone borrowed strings if retained past teardown.
14. **DO NOT** call `compile_source` on `.forseti` policies that contain `import "..."` declarations (`compile_source` handles single-unit strings without import resolution). **DO** use `compile_file` or `compile_source_with_imports` with `include_paths` (or `--include` / `-I` on the CLI).
15. **DO NOT** access a `Session` (`forseti_session_t`) concurrently from multiple threads or call C `free()` on strings returned by `libforseti`. **DO** pin each `Session` to an actor (`actors.Session_Actor`) sharing immutable `^Rulebase` and free C99 output strings exclusively via `forseti_free_string`.
16. **DO NOT** pass `-disallow-do` to `odin check` / `odin test` when compiling with `-collection:xitdb=../xitdb/xitdb` (`xitdb/lua.odin` uses `do`). **DO** use `-vet -vet-tabs -strict-style -warnings-as-errors -vet-packages:forseti,...`.
