[README](../README.md) · [Docs Hub](README.md) · **Odin API** · [DSL Reference](dsl-reference.md) · [Benchmarks](benchmarks.md) · [Agent Rules](../usage-rules.md)

# Forseti Odin Embedding & Runtime Guide

Practical guide to embedding `package forseti` in Odin applications: compilation, memory lifetimes, standalone decision tables, incremental `xitdb` sync, JTMS queries, provenance semirings, counterfactual replay, 3-phase async effects, and telemetry.

> [!NOTE]
> For `.forseti` language syntax, EBNF grammar, and the full diagnostic catalog, see [`docs/dsl-reference.md`](dsl-reference.md).

## Contents

- [1. Memory Ownership & LIFO Lifecycle](#1-memory-ownership--lifo-lifecycle)
- [2. Compiling Policies & Formatting Diagnostics](#2-compiling-policies--formatting-diagnostics)
- [3. Standalone Decision Tables & Lazy Column Thunks](#3-standalone-decision-tables--lazy-column-thunks)
- [4. Working Memory, Provenance Modes & Queries](#4-working-memory-provenance-modes--queries)
- [5. `xitdb` Persistence, `Delta_Syncer` & Atomic Audit Layout](#5-xitdb-persistence-delta_syncer--atomic-audit-layout)
- [6. Causal Explanations, Impact, Semirings, `diff_replay` & Graphs](#6-causal-explanations-impact-semirings-diff_replay--graphs)
- [7. Three-Phase Async Effects (`Prepare -> Execute -> Apply`)](#7-three-phase-async-effects-prepare---execute---apply)
- [8. Tier 2 Internal Odin DSL & Tier 3 AOT Codegen](#8-tier-2-internal-odin-dsl--tier-3-aot-codegen)
- [9. Built-In Telemetry & Compile-Time Toggle](#9-built-in-telemetry--compile-time-toggle)

---

## 1. Memory Ownership & LIFO Lifecycle

Forseti separates immutable rule topology (`Rulebase`) from mutable per-execution state (`Session`).

> [!IMPORTANT]
> **`Session` and `Store_Bridge` are pinned handles:** both hold internal `vmem.Arena` instances, maps, and self/DB pointers. Always initialize them in-place on a stable stack frame or heap-allocate with `new(...)`—never return them by value or copy them after initialization.

Follow strict **LIFO teardown** order so `Session` never outlives its `^Rulebase`:

```odin
import "forseti"

diags: forseti.Diagnostic_List
assert(forseti.diag_list_init(&diags) == nil)
defer forseti.diag_list_destroy(&diags)

ir, c_err := forseti.compile_source(src, "policy.forseti", &diags)
assert(c_err == nil && diags.error_count == 0)
defer forseti.ir_destroy(&ir)

rb, rb_err := forseti.rulebase_compile(&ir)
assert(rb_err == .None)
defer forseti.rulebase_destroy(&rb) // Safe even after ir_destroy(&ir): Rulebase deep-copies schemas/bindings

sess := new(forseti.Session)
assert(forseti.session_init(sess, &rb) == .None)
defer {
	forseti.session_destroy(sess)
	free(sess)
}
```

### String Interning Across `Rulebase` and `Session`

String field values passed into `session_insert_fact` or `session_query` use `forseti.String_Id`:

```odin
acct_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "acct:42")
fid, ins_err := forseti.session_insert_fact(sess, "RawAccount", "acct:42", {acct_sid, i64(250), true})
```

Interning via `intern_session_string(&rb.interner, &sess.interner, text)` reuses existing immutable `Rulebase` string IDs whenever `text` was already interned at compile time, and allocates runtime strings in `sess.interner` (tagged with `RUNTIME_STRING_BIT`) only when new.

---

## 2. Compiling Policies & Formatting Diagnostics

`compile_source` runs lexing (`lexer.odin`), Pratt parsing (`parser.odin`), IR lowering (`lower.odin`), semantic/type/binding analysis (`sema.odin`), static decision-table verification (`table_verify.odin`), and Tarjan SCC stratification (`stratify.odin`) in one call:

```odin
diags: forseti.Diagnostic_List
_ = forseti.diag_list_init(&diags)
defer forseti.diag_list_destroy(&diags)

ir, c_err := forseti.compile_source(src, "policy.forseti", &diags)
defer forseti.ir_destroy(&ir)

if c_err != nil || forseti.diag_has_errors(&diags) {
	for d in diags.items {
		txt, _ := forseti.format_diagnostic_human(d, src, "policy.forseti")
		defer delete(txt)
		fmt.eprint(txt)
	}
	// Or emit machine-readable JSON for tooling:
	json_txt, _ := forseti.format_diagnostics_json(&diags, "policy.forseti")
	defer delete(json_txt)
}
```

> [!TIP]
> `compile_source` and `ir_builder_build` already run `analyze_ir` internally. Do **not** call `analyze_ir` a second time on the same `Diagnostic_List` unless you manually mutate `Rulebase_IR` afterward.

---

## 3. Standalone Decision Tables & Lazy Column Thunks

Use [`compile_table`](../forseti/table_eval.odin) and [`decide`](../forseti/table_eval.odin) when you want to evaluate a single DMN decision table directly without spinning up a full working-memory `Session`.

To avoid computing expensive input columns (e.g., ML scores, external feature lookups) when cheaper high-selectivity columns already decide the row, assign `cost <n>` in `.forseti` and pass an `Input_Getter_Proc`:

```odin
Lazy_Probe :: struct {
	calls: [3]int,
}

getter :: proc(col_idx: int, user_data: rawptr) -> forseti.Value {
	probe := (^Lazy_Probe)(user_data)
	probe.calls[col_idx] += 1
	switch col_idx {
	case 0: return i64(250)
	case 1: return true
	case 2: return f64(0.92)
	}
	return nil
}

ct, t_err := forseti.compile_table(&ir, 0)
assert(t_err == nil)
defer forseti.compiled_table_destroy(&ct)

probe: Lazy_Probe
res := forseti.decide(&ct, forseti.Table_Input{getter = getter, user_data = &probe})

winning_row := forseti.compiled_table_winning_row_id(&ct, res)
tier := forseti.compiled_table_output_string(&ct, res.outputs[0])
skipped_col2 := (res.trace.skipped_col_mask & (u64(1) << 2)) != 0
```

Lookups for string inputs on a standalone `Compiled_Table` use `forseti.compiled_table_string_value(&ct, "enterprise")`. See [`examples/01_decision_tables`](../examples/01_decision_tables/main.odin) for `First`, `Collect_Sum`, and `Merge` examples.

---

## 4. Working Memory, Provenance Modes & Queries

Configure `Session_Config` to choose audit level, phase firing order, and safety caps:

```odin
cfg := forseti.Session_Config{
	max_activations = 100_000,
	initial_phases  = {"validate", "survive", "rollup"}, // optional custom phase order
	provenance_mode = .Audit_Full,                       // default: .Audit_Full | .Support_Only | .Fast
}
```

| `Provenance_Mode` | JTMS Cascades | Derivation Proof DAG (`explain` / `impact` / `semiring`) | Use Case |
| :--- | :---: | :---: | :--- |
| **`.Audit_Full`** *(default)* | Yes | Yes | MDM, compliance, explainable policy execution, `xitdb` `.decisions` |
| **`.Support_Only`** | Yes | No | Retractable rule execution when causal proof trees aren't needed |
| **`.Fast`** | No | No | Ephemeral `@zero_alloc` scoring/routing hot loops (`session_modify_fact_by_key`) |

### Inserting, Modifying, Retracting & Querying Facts

```odin
// Insert and fire
fid, _ := forseti.session_insert_fact(sess, "RawAccount", "acct:1", {s_id, s_dom, i64(500), true})
fired, f_err := forseti.session_fire(sess)

// Modify by binding + key (in .Fast mode, recycles slots with 0 heap allocations)
_ = forseti.session_modify_fact_by_key(sess, "RawAccount", "acct:1", {s_id, s_dom, i64(900), true})
_, _ = forseti.session_fire(sess)

// Retract by Fact_Id or (binding, key) -> automatically cascades logical assertions in .Audit_Full / .Support_Only
_ = forseti.session_retract_fact(sess, fid)

// Execute a compiled parameterized query
qres: forseti.Query_Result
q_err := forseti.session_query(sess, "golden_by_tier", {{name = "tier", value = tier_sid}}, &qres)
assert(q_err == .None)
defer forseti.query_result_destroy(&qres)

for row in qres.rows {
	// Access row.fact_ids, row.var_names, row.var_values, row.var_strings
}
```

---

## 5. `xitdb` Persistence, `Delta_Syncer` & Atomic Audit Layout

### Opening or Attaching a Store (`Store_Bridge`)

- `store_bridge_open_file(&bridge, "mdm.xit")` — Durable `Core_Buffered_File` (standard `xitdb` v2 SHA-1 HAMT + CRC-64/XZ trailers by default; accepts an optional `Xitdb_Config{custom_hasher = ...}`).
- `store_bridge_init_standalone(&bridge)` — In-memory `Core_Memory` store (same wire-compatible v2 defaults).
- `store_bridge_init_attached(&bridge, &my_xitdb)` — Attaches without taking ownership of your existing `xitdb.Database`.

### Incremental `Delta_Syncer` & Atomic Moment Layout

`session_sync_and_fire` diffs watched `xitdb` collections in `O(delta)` time via `xitdb.diff_collection_with_stats` (skipping unchanged 9-byte subtree slots), converts `+1`/`-1` changes into session insertions/retractions, fires the PHREAK engine, and when `commit_derived = true`, writes all derived bindings plus causal audit metadata in **one atomic `xitdb` moment**:

- **Derived collections:** Your declared `derived ... at .path.to.col[?id]` maps
- **`.decisions["dec:<id>"]`:** Rule name/version, `table`, `table_row`, `proof_height`, `weight` (`+1`/`-1`), `alive`, `tx_seq`, `derived_binding`, `derived_key`, `parents`
- **`.idx.decisions_by_entity[<key>]`** and **`.idx.decisions_by_rule[<rule>]`:** Secondary `Hash_Set` indexes pointing to decision IDs
- **`.__tx`:** Reified transaction metadata (`tx_seq`, `module`, `decision_ids`, `rule_versions`)

See [`examples/02_mdm_xitdb_pipeline`](../examples/02_mdm_xitdb_pipeline/main.odin) for a complete disk-backed roundtrip.

---

## 6. Causal Explanations, Impact, Semirings, `diff_replay` & Graphs

All inspection reports own their returned strings/slices and provide dedicated `*_destroy` helpers:

```odin
// 1. Minimal acyclic proof tree for a derived fact
tree := forseti.explain(sess, derived_fid)
defer forseti.explain_tree_destroy(&tree)
txt := forseti.explain_format(&tree)
defer delete(txt)

// 2. Blast-radius analysis for a rule name / version
rep := forseti.impact(sess, rule_id)
defer forseti.impact_report_destroy(&rep)

// 3. Algebraic provenance semirings (.Boolean, .Why, .How, .Viterbi)
why := forseti.evaluate_semiring(sess, derived_fid, .Why)
defer forseti.semiring_result_destroy(&why)

how := forseti.evaluate_semiring(sess, derived_fid, .How)
defer forseti.semiring_result_destroy(&how)

// 4. Zero-copy Core_Overlay counterfactual replay (parent store stays untouched)
diff_rep, d_err := forseti.session_diff_replay(sess, &bridge, &candidate_rb, {".accounts.raw"})
assert(d_err == nil)
defer forseti.diff_replay_report_destroy(&diff_rep)

// Or replay two Rulebases from scratch against a frozen store snapshot:
// diff_rep2, _ := forseti.diff_replay(&bridge, &base_rb, &candidate_rb, {".accounts.raw"})

// 5. Visual exporters (Graphviz DOT & Mermaid)
mmd, _ := forseti.export_rulebase_mermaid(&rb)
defer delete(mmd)
dot, _ := forseti.export_derivations_dot(sess, derived_fid)
defer delete(dot)
```

---

## 7. Three-Phase Async Effects (`Prepare -> Execute -> Apply`)

Rules declaring `effect "kind" { ... }` stage pure `Effect_Job` payloads during `session_fire` instead of executing blocking I/O inside matching:

1. **Phase 1 (`session_prepare_effects`):** Drains staged jobs into owned `Effect_Job` values (`job_id`, `kind`, `rule_name`, `fields` containing copied `str` & `value`).
2. **Phase 2 (Off-Engine Workers):** Dispatch `jobs` across worker threads. Workers inspect **only** `job.fields`.
3. **Phase 3 (`session_apply_effects`):** Back on the engine thread, intern output strings (`intern_session_string`), build `[]Effect_Result`, call `session_apply_effects`, and re-run `session_fire`. Resulting facts preserve causal provenance pointing back to the originating rule and parent facts!

> [!WARNING]
> Never read or mutate `sess`, `sess.interner`, or `s.facts` from Phase 2 worker threads—worker threads must read only the plain copied values inside `Effect_Job.fields`.

See [`examples/05_accumulators_and_effects`](../examples/05_accumulators_and_effects/main.odin) for a runnable `core:thread` example.

---

## 8. Tier 2 Internal Odin DSL & Tier 3 AOT Codegen

- **Tier 2 (`Ir_Builder`, [`forseti/dsl_odin.odin`](../forseti/dsl_odin.odin)):** Assemble schemas (`ir_schema`), `xitdb` bindings (`ir_source`, `ir_derived`), tables (`ir_table`), rules (`ir_rule` with `when_clauses` and `then_actions`), and queries (`ir_query`), then call `ir_builder_build(&b, &diags)`.
- **Tier 3 (`codegen_odin_module`, [`forseti/codegen_odin.odin`](../forseti/codegen_odin.odin)):** Emits standalone `"contextless"` Odin structs (`<Table>_Input`, `<Table>_Output`) and evaluator procedures (`decide_<table_name>`) for `First`, `Unique`, `Any`, `Priority`, `Collect*`, `Merge`, and `Reverse_Merge` tables:

```odin
aot_src, aot_err := forseti.codegen_odin_module(&ir, pkg_name = "generated_tables")
assert(aot_err == nil)
defer delete(aot_src)
```

---

## 9. Built-In Telemetry & Compile-Time Toggle

Pass `&tel` (`Telemetry_Sink`) into `compile_source`, `rulebase_compile`, `session_init`, `store_bridge_*`, or `delta_syncer_init` to capture hierarchical phase spans (`lex`, `parse`, `ir_lower`, `analyze`, `table_verify`, `compile`, `sync`, `match`, `tms`, `commit`), counters (`alpha_tests`, `alpha_hits`, `segments_skipped_unlinked`, `rules_fired`, `slots_skipped`, `derivations_recorded`), and peak memory watermarks:

```odin
tel: forseti.Telemetry_Sink
assert(forseti.telemetry_init(&tel, enabled = true) == nil)
defer forseti.telemetry_destroy(&tel)

// ... run compile / sync / fire passing &tel ...

jsonl, _ := forseti.telemetry_export_jsonl(&tel)
defer delete(jsonl)

chrome_trace, _ := forseti.telemetry_export_chrome_trace(&tel)
defer delete(chrome_trace) // Load directly into chrome://tracing or Perfetto UI
```

To compile out all instrumentation overhead completely on ultra-tight production builds, pass `-define:FORSETI_TELEMETRY=false` to `odin build` / `odin test`.

---

## 9. Multi-Threaded Actor Runtime (`actors/` + Sleipnir)

Core `package forseti` stays single-threaded, zero-lock, and zero-actor. When scaling across multiple OS threads or isolated tenants, import the sibling package **`actors/`** (`package forseti_actors`, requiring `-collection:actor=../sleipnir/actor`):

- **`Session_Actor` (`actors/session_actor.odin`):** Owns a pinned `^forseti.Session` and per-actor `forseti.Telemetry_Sink`, sharing an immutable compiled `^forseti.Rulebase` across threads. Supports `Insert_Fact`, `Chain=K` slice batching via `actor.send`, `Session_SPSC_Mailbox` (`Drain_SPSC`), `Run_Query`, `Explain_Fact`, `Impact_Rule`, and `Commit_Derived_To_Writer`.
- **`Xitdb_Commit_Actor` (`actors/commit_actor.odin`):** Single-writer `Store_Bridge` owner serializing derived/audit moments (`.decisions`, `.idx.*`, `.__tx`) and broadcasting `Commit_Notification` messages to subscribed `Session_Actor`s.
- **`Tenant_Rule_Runtime` (`actors/tenant_supervisor.odin`):** Wraps Sleipnir's `actor.Partitioned_Supervisor` + `.One_For_One` per-tenant supervision, trapped panic recovery with `xitdb` rehydration, and `tenant_runtime_sweep_idle` TTL eviction.
- **`Effect_Dispatcher` (`actors/effect_dispatcher.odin`):** Routes `Effect_Job`s by `kind` to supervised effect workers without touching `Session.interner`, recovering worker panics cleanly under `.One_For_One` and delivering results via `Apply_Actor_Effects`.
- **`Parallel_Diff_Replay` (`actors/parallel_diff_replay.odin`):** Fans out concurrent `Core_Overlay` `diff_replay` actors over a frozen `Store_Bridge` snapshot and merges per-worker telemetry via `forseti.telemetry_merge`.
- **`Rulebase_Coordinator` (`actors/rulebase_coordinator.odin`):** Compiles and validates updated `.forseti` policies off the hot path, atomically broadcasts `Swap_Rulebase` across subscribed `Session_Actor`s, rejects invalid policies without disrupting running sessions, and reclaims retired `Rulebase` instances via atomic reference counting (`Rulebase_Ref`).

See [`examples/08_sleipnir_actor_runtime/main.odin`](../examples/08_sleipnir_actor_runtime/main.odin) for a full leak-checked end-to-end walkthrough.

---

## 10. Typed Odin Struct Embeds (`forseti/typed_api.odin`)

For pure-Odin hosts, `session_insert_struct`, `session_modify_struct`, `decide_struct` / `decide_table_struct`, and `query_unmarshal` map Odin struct fields using `forseti:"field_name"` tags (falling back to the Odin field name, and skipping `forseti:"-"`):

```odin
Org_Input :: struct {
	id:        string `forseti:"org_id"`,
	employees: i64    `forseti:"employees"`,
	active:    bool   `forseti:"active"`,
	ignored:   string `forseti:"-"`,
}

Org_Row :: struct {
	org_id:    string `forseti:"oid"`,
	tier:      string `forseti:"tier"`,
	employees: i64    `forseti:"emp"`,
}

_, _ = forseti.session_insert_struct(sess, "raw_orgs", "org:acme", Org_Input{id = "org:acme", employees = 250, active = true})
_, _ = forseti.session_fire(sess)

qr: forseti.Query_Result
defer forseti.query_result_destroy(&qr)
_ = forseti.session_query(sess, "list_tiered", {{name = "tier", value = "enterprise"}}, &qr)

rows: [dynamic]Org_Row
defer delete(rows)
_ = forseti.query_unmarshal(sess, &qr, &rows) // String fields borrow `sess`/`qr` storage
```
