# Forseti

[![CI](https://github.com/boxxxie/forseti/actions/workflows/ci.yml/badge.svg)](https://github.com/boxxxie/forseti/actions/workflows/ci.yml)
[![Release: v0.1.0](https://img.shields.io/badge/Release-v0.1.0-1E88E5)](CHANGELOG.md)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--10%2B-3882D2?logo=odin&logoColor=white)](https://odin-lang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Scale: 1M Rules](https://img.shields.io/badge/Scale-1%2C000%2C000%20Rules-7C4DFF)](docs/benchmarks.md)
[![AOT Tables: 776 ps](https://img.shields.io/badge/AOT%20Tables-776%20ps%20%7C%200%20Allocs-E91E63)](docs/benchmarks.md#32-decision-tables--hardware-counters-decision_tables)
[![Matcher: Lazy PHREAK + VM](https://img.shields.io/badge/Matcher-Lazy%20PHREAK%20%2B%20%23must__tail%20VM-00ACC1)](forseti/phreak_eval.odin)
[![Reasoning: Z-Set JTMS + Datalog](https://img.shields.io/badge/Reasoning-Z--Set%20JTMS%20%2B%20Stratified%20Datalog-FF6D00)](docs/dsl-reference.md)
[![Storage: xitdb v2](https://img.shields.io/badge/Storage-xitdb%20v2%20%2B%20CoW%20Overlays-5C6BC0)](https://github.com/boxxxie/odin-xitdb)
[![Memory: 0 Leaks](https://img.shields.io/badge/Memory-0%20Leaks%20%7C%203.16%20us%20%40zero__alloc%20Hot%20Match-00C853)](docs/benchmarks.md#37-v010-release-snapshot-434960b-253-benchmarks)
[![Tests: 4-Layer ATDD](https://img.shields.io/badge/Tests-4--Layer%20ATDD-2E7D32)](specs/)

**Turn tangled business logic and unverified spreadsheets into fast, explainable, compiler-checked rules.**

Forseti is a pure-Odin, data-oriented rules engine, statically verified DMN decision-table compiler, and stratified Datalog runtime with causal audit trails backed by [`xitdb`](https://github.com/boxxxie/odin-xitdb). Author policies in a readable `.forseti` DSL, programmatically inside Odin, or freeze hot decision tables into zero-allocation `"contextless"` machine code—while proving completeness, catching overlaps before deploy, automatically retracting stale conclusions when facts change, and embedding from Odin or C/Rust/Python/Elixir/Go via a stable C99 ABI.

[New to Rules Engines?](#what-is-a-rules-engineand-why-use-one) · [60-Second Quick Start](#60-second-quick-start) · [Why Forseti?](#why-forseti) · [Tour of Forseti](#tour-of-forseti) · [Benchmarks](#performance-highlights-10-to-1000000-rules) · [CLI & Tooling](#cli--editor-tooling) · [Documentation](#documentation--agent-guides)

---

## What Is a Rules Engine—and Why Use One?

If you have never used a rules engine before, the simplest way to understand one is to look at what happens when business logic outgrows a few `if`/`else` blocks.

### The `if`/`else` Trap

Most classification, pricing, fraud, compliance, and Master Data Management (MDM) code starts cleanly: three `if` checks and a helper function. Six months later, product owners add regional exceptions, VIP overrides, suppression lists, and multi-entity rollups. Procedural code quietly breaks in three places:

1. **Silent shadowing & missing cases:** Reordering two `else if` branches silently changes outcomes or leaves an input combination unhandled. Standard compilers type-check syntax, not whether 50 threshold rows have coverage gaps, overlapping branches, or dead rows.
2. **No automatic "undo" when inputs change:** Regular code runs forward once. When an upstream record changes—a risk score spikes, a domain gets added to a suppression list, or a corporate parent link is deleted—imperative code has to manually hunt down and clean up every downstream record it previously wrote, or recompute the entire database from scratch.
3. **No built-in "Why?" or safe "What-if?":** Application logs tell you *that* something ran, not a minimal mathematical proof tree explaining *why* an account earned `"enterprise"` today. And when legal or ops wants to tighten a threshold, you cannot easily preview the exact blast radius across `50,000` live accounts without risking production state.

### How a Rules Engine Flips the Model

Instead of encoding step-by-step control flow, you declare **what is true** (**facts**) and **what follows** (**tables and rules**), and let the engine handle ordering, incremental updates, cleanup, and proofs:

| Concept | In Plain English | In Forseti |
| :--- | :--- | :--- |
| **Facts** | Typed records of what is currently true (inputs you provide and outputs the engine derives) | `schema`, `source`, `derived` synced in RAM or from [`xitdb`](https://github.com/boxxxie/odin-xitdb) |
| **Verified Decision Tables** | Readable spreadsheets of conditions -> outputs, checked statically for gaps and overlaps | `table ... hit First \| Unique \| Priority \| Collect_Sum \| Merge` |
| **Incremental Rules & Datalog** | Pattern-matching rules that join across facts, aggregate, negate (`not`), and recurse on graphs | `rule ... { when { ... } then { ... } }` via lazy PHREAK (`O(delta)`) |
| **Truth Maintenance (JTMS)** | Conclusions remember what justified them and **auto-retract in cascade** when premises vanish | `assert` (logical, auto-retracted) vs `assert! ... unconditional` (permanent audit) |
| **Proofs & Counterfactuals** | Ask why a fact exists, what a rule affects, or simulate v2 rules without mutating production data | `explain`, `impact`, semirings (`Why`/`How`/`Viterbi`), zero-copy `diff-replay` |

### When Should You Use Forseti (and When Not To)?

- **Reach for Forseti when:**
  - Business rules change faster than application code, or non-compiler tooling (`forseti check`, `forseti lsp`, `diff-replay`) needs to validate policies before deployment.
  - Multiple entities interact (`Account` + `SuppressedDomain` + `HierarchyLink` + `Count` rollups) and downstream outputs must stay consistent as inputs arrive, change, or disappear.
  - Auditors or stewards ask *"Why did account X get classified this way?"* (`explain` + `.decisions` audit records) or *"What breaks if we change this rule?"* (`diff-replay` + `impact`).
  - You have tens to `1,000,000` rules, multi-tenant rule isolation, or sub-microsecond decision matrices.
- **Stick to plain `if`/`else` (or use Tier 3 `forseti gen`) when:**
  - You only have a couple of static branches that never join across records, retract derived state, or need audit proof trees.
  - *Best of both worlds:* author a decision table in `.forseti`, prove it has zero gaps/overlaps with `forseti verify-tables`, and run `forseti gen` to compile it into a standalone, zero-dependency, `0`-allocation Odin `if` procedure (`~776 ps`).

---

## 60-Second Quick Start

Forseti has **zero external C dependencies**. Core `forseti/`, `cmd/forseti`, and `examples/01..07` require only [Odin (`dev-2026-10+`)](https://odin-lang.org/) and [`odin-xitdb`](https://github.com/boxxxie/odin-xitdb). Clone sibling collections into a shared workspace:

```bash
mkdir -p odin-workspace && cd odin-workspace
git clone https://github.com/boxxxie/forseti.git
git clone https://github.com/boxxxie/odin-xitdb.git xitdb
# Optional: multi-threaded actor runtime (actors/, ex08) and longitudinal benchmarks (benchmarks/)
git clone https://github.com/boxxxie/sleipnir.git
git clone https://github.com/boxxxie/hugi.git
git -C hugi submodule update --init deps/obench
cd forseti
```

Run your first verified decision table, cascading JTMS example, or CLI check in seconds:

```bash
XITDB="-collection:xitdb=../xitdb/xitdb"

# 1. Verified decision tables (lazy cost skipping, Collect_Sum, Merge) + Tier 3 AOT codegen
odin run examples/01_decision_tables $XITDB

# 2. Truth maintenance in action: diamond survival, cascading retraction, and permanent assert! audit logs
odin run examples/03_jtms_steward_overrides $XITDB

# 3. Validate, execute, or inspect a .forseti policy from the CLI
odin run cmd/forseti $XITDB -- check --warnings-as-errors editors/fixtures/comprehensive.forseti
```

---

## Why Forseti?

- **Three Authoring Tiers over One Canonical IR:** Author policies in the **External `.forseti` DSL** (zero-copy lexer, multi-file `import` with `--include`, pure scalar built-ins, hot-reload, compiler diagnostics), build rules programmatically with the **Internal Odin DSL** (`Ir_Builder`), or freeze hot tables into `"contextless"` **AOT Odin procedures** (`forseti gen`).
- **Compiler-Verified DMN Decision Tables (`Tablex++` / `ZEN`):** Supports `First`, `Unique`, `Any`, `Priority`, `Collect` (`_Sum`, `_Min`, `_Max`, `_Count`), `Merge`, and `Reverse_Merge`. Static domain partitioning catches overlaps, dead/shadowed rules, unsatisfiable predicates, and coverage gaps with **concrete counterexample witnesses** before deployment.
- **Lazy PHREAK Matcher & `1,000,000`-Rule Scale:** Shared alpha DAG, `u64` segment bitmasks, Left/Right unlinking, 32-bit `#must_tail` guard VM, and lazy per-session memory allocation keep `session_init` at `O(1)` (`20.17 us`) even across `1,000,000` rules.
- **Z-Set JTMS + Stratified Semi-Naive Datalog:** Logical `assert` derivations retract automatically in cascade when premises vanish, while `assert! ... unconditional` preserves permanent audit entries. Supports `not`/`exists`, retractable accumulators (`count`, `sum`, `min`, `max`, `avg`, `distinct`, `collect`), and Tarjan SCC recursion over cyclic hierarchies.
- **Universal `xitdb` Substrate & Causal Provenance:** Syncs incrementally from `Core_Memory`, durable `Core_Buffered_File`, or zero-copy `Core_Overlay` counterfactual forks (`diff_replay`). Records `#soa` derivation DAGs, commits `.decisions` + `.idx.*` + `.__tx` atomically, and answers `explain`, `impact`, and algebraic semiring (`Boolean`, `Why`, `How`, `Viterbi`) queries.
- **Sleipnir Multi-Threaded Runtime (`actors/`):** Optional [`sleipnir`](https://github.com/boxxxie/sleipnir) layer pinning each `Session` to an actor (`Session_Actor` + SPSC ingest), single-writer `Xitdb_Commit_Actor`, OTP `Partitioned_Supervisor` tenant isolation, supervised `Effect_Dispatcher`, parallel `diff_replay`, and ref-counted hot-reload while keeping core `forseti/` zero-dependency.
- **Typed Odin Structs, Stable C99 ABI & Editor Tooling:** Struct-tag helpers (`session_insert_struct`, `decide_struct`, `query_unmarshal`), opaque C99 ABI (`capi/` -> `libforseti` + [`include/forseti.h`](include/forseti.h)), canonical formatter (`forseti fmt`), JSON-RPC 2.0 LSP (`forseti lsp`), and TextMate / Tree-sitter grammars (`editors/`).
- **Built-In Telemetry & Longitudinal Benchmarking:** Captures phase timings, rule/memory counters, and memory watermarks (`JSONL` / Chrome Trace) and ships [`hugi`](https://github.com/boxxxie/hugi) + [`obench`](https://github.com/zeybek/obench) benchmarks spanning `10` to `1,000,000` rules.

---

## Architecture Overview

```mermaid
flowchart LR
    T1["Tier 1: External .forseti DSL"] --> IR["Canonical Rulebase_IR"]
    T2["Tier 2: Internal Odin DSL (Ir_Builder)"] --> IR
    IR --> VER["Static Sema + Table Verifier + Tarjan Stratifier"]
    VER -->|forseti gen| AOT["Tier 3: AOT Odin Codegen ('contextless')"]
    VER -->|rulebase_compile| RB["Immutable Rulebase (Alpha DAG + Tree/Bitsets + VM)"]
    RB --> SESS["Pinned Session (Lazy PHREAK + Z-Set JTMS + #soa DAG)"]
    XIT["xitdb Store (Core_Memory / Buffered_File / Core_Overlay)"] <-->|"O(delta) Sync & Atomic Commit"| SESS
    SESS --> OUT["Explain / Impact / Semirings / diff_replay / Telemetry"]
```

---

## Tour of Forseti

### 1. External `.forseti` DSL (Tier 1)

Declare typed schemas, `xitdb` path bindings (`source` / `derived`), statically verified DMN decision tables with column `cost` ordering, phased rules with negation/pure built-ins/async effects, and parameterized queries in one readable policy file (or split shared declarations across files with `import "shared.forseti"`):

```forseti
module customer_mdm version "1.0"

schema RawAccount {
  id: string,
  domain: string,
  employees: i64,
  active: bool,
  risk_score: f64
}
schema SuppressedDomain { domain: string }
schema GoldenAccount {
  id: string,
  domain: string,
  tier: string
}
schema AuditLog { id: string, tier: string }

source RawAccount : RawAccount at .accounts.raw[?id]
source Suppressed : SuppressedDomain at .accounts.suppressed[?id]
derived GoldenAccount : GoldenAccount at .accounts.golden[?id]
derived AuditLog : AuditLog at .accounts.audit[?id]

// Lazy cost-ordered tree skips `risk_score` (cost 100) unless needed!
table survivorship_gate version "1.0" hit First verify(complete, no_dead_rules) {
  inputs {
    employees:  i64  cost 1,
    active:     bool cost 1,
    risk_score: f64  cost 100
  }
  outputs {
    tier:   string,
    action: string
  }
  rows {
    r_enterprise: >= 200 | true | < 0.70 || "enterprise" | "auto_merge";
    r_growth:     >= 50  | true | -      || "growth"     | "auto_merge";
    r_review:     -      | -    | -      || "standard"   | "steward_review";
  }
}

rule promote_account phase "survive" salience 50 {
  when {
    ?_raw := RawAccount(id: ?aid, domain: ?dom, employees: ?emp, active: ?ok, risk_score: ?risk)
    ?gate := decide survivorship_gate(employees: ?emp, active: ?ok, risk_score: ?risk)
    not Suppressed(domain: ?dom)
    where ?gate.action == "auto_merge" and len(?dom) > 0
  }
  then {
    assert GoldenAccount(id: ?aid, domain: ?dom, tier: ?gate.tier)
    assert! AuditLog(id: ?aid, tier: ?gate.tier) unconditional
  }
  effect "notify_steward" { account_id: ?aid, tier: ?gate.tier }
}

query golden_by_tier(tier: string) {
  GoldenAccount(id: ?aid, domain: ?dom, tier: ?tier)
}
```

> [!TIP]
> `assert` creates a logically justified fact maintained by Z-set JTMS (automatically retracted if `RawAccount` leaves or `Suppressed` arrives), whereas `assert! ... unconditional` writes an immutable audit record that survives upstream retractions.

#### Compile-Time Safety & Counterexample Witnesses

Running `forseti check` or `forseti verify-tables` catches overlaps, coverage gaps, dead rows, unbound variables, and unstratified negation cycles with exact `file:line:col` spans before a rule ever runs:

```text
policy.forseti:18:5: error[E3001]: overlapping rules "r_gold" and "r_platinum" in table "tier_gate" at witness {score=90, active=true}
  hint: make rule predicates disjoint or use First/Priority hit policy
policy.forseti:31:3: error[E4001]: unstratified negation cycle detected: A -(!)-> B -> A
  hint: separate base derivation from negated/aggregated stratum
```

---

### 2. Embedding in Odin — Typed Structs (`forseti:"..."`) & `decide_struct`

Compile a `Rulebase` once (immutable and shareable across threads), attach a pinned `Session`, ingest typed Odin structs using `forseti:"..."` tags, evaluate tables directly with `decide_struct`, and unmarshal parameterized query rows:

```odin
diags: forseti.Diagnostic_List
assert(forseti.diag_list_init(&diags) == nil)
defer forseti.diag_list_destroy(&diags)

ir, c_err := forseti.compile_source(policy_src, "customer_mdm.forseti", &diags)
assert(c_err == nil && diags.error_count == 0)
defer forseti.ir_destroy(&ir)

rb, rb_err := forseti.rulebase_compile(&ir)
assert(rb_err == .None)
defer forseti.rulebase_destroy(&rb)

// Pinned Session: heap-allocate via new(...) or keep in-place; never copy by value.
sess := new(forseti.Session)
assert(forseti.session_init(sess, &rb) == .None)
defer {
	forseti.session_destroy(sess)
	free(sess)
}

Account_Row :: struct {
	id:         string `forseti:"id"`,
	domain:     string `forseti:"domain"`,
	employees:  i64    `forseti:"employees"`,
	active:     bool   `forseti:"active"`,
	risk_score: f64    `forseti:"risk_score"`,
}
Golden_Row :: struct {
	id:     string `forseti:"?aid"`,
	domain: string `forseti:"?dom"`,
	tier:   string `forseti:"?tier"`,
}

_, _ = forseti.session_insert_struct(sess, "RawAccount", "acct:1", Account_Row{"acct:1", "acme.com", 250, true, 0.12})
_, _ = forseti.session_fire(sess)

qr: forseti.Query_Result
defer forseti.query_result_destroy(&qr)
tier_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "enterprise")
_ = forseti.session_query(sess, "golden_by_tier", {{name = "tier", value = tier_sid}}, &qr)

rows: [dynamic]Golden_Row
defer delete(rows)
_ = forseti.query_unmarshal(sess, &qr, &rows)

// Standalone decision-table call directly on ^Rulebase (no Session needed):
Gate_Out :: struct { tier: string, action: string }
gate_out: Gate_Out
_, _ = forseti.decide_struct(&rb, "survivorship_gate", Account_Row{"acct:1", "acme.com", 250, true, 0.12}, &gate_out)
```

---

### 3. `xitdb` Incremental Sync, Causal `explain`, Semirings & `diff_replay`

Attach a `Store_Bridge` (`Core_Buffered_File`, `Core_Memory`, or caller-owned `xitdb.Database`), sync deltas in `O(delta)` time, commit derived facts and `.decisions` / `.idx.*` / `.__tx` atomically, inspect causal proof trees, and test policy changes safely on a zero-copy `Core_Overlay` fork:

```odin
bridge: forseti.Store_Bridge
assert(forseti.store_bridge_open_file(&bridge, "mdm.xit") == nil)
defer forseti.store_bridge_destroy(&bridge)

syncer: forseti.Delta_Syncer
assert(forseti.delta_syncer_init(&syncer) == nil)
defer forseti.delta_syncer_destroy(&syncer)
_ = forseti.delta_syncer_watch(&syncer, ".accounts.raw")

// Incremental O(delta) sync -> PHREAK match -> Z-set JTMS -> atomic .decisions / .__tx commit
fired, s_err := forseti.session_sync_and_fire(sess, &bridge, &syncer, commit_derived = true)
assert(s_err == nil)
_ = fired

// Inspect causal proof tree, algebraic How-provenance, or counterfactual policy diff
tree := forseti.explain(sess, derived_fid)
defer forseti.explain_tree_destroy(&tree)

how := forseti.evaluate_semiring(sess, derived_fid, .How)
defer forseti.semiring_result_destroy(&how)

diff_rep, d_err := forseti.session_diff_replay(sess, &bridge, &candidate_rb, {".accounts.raw"})
assert(d_err == nil)
defer forseti.diff_replay_report_destroy(&diff_rep)
```

---

### 4. Internal Odin DSL (Tier 2 — `Ir_Builder`) & AOT Codegen (Tier 3 — `forseti gen`)

Build the exact same canonical `Rulebase_IR` programmatically in Odin without parsing text—or freeze verified decision tables into standalone `"contextless"`, zero-allocation native Odin code:

```odin
b: forseti.Ir_Builder
if forseti.ir_builder_init(&b, "mdm_internal", "1.0") != nil {
	return
}
defer forseti.ir_builder_destroy(&b)

_ = forseti.ir_schema(&b, "Account", {
	forseti.field("id", .String),
	forseti.field("employees", .I64),
	forseti.field("active", .Bool),
})
_ = forseti.ir_schema(&b, "Golden", {
	forseti.field("id", .String),
	forseti.field("tier", .String),
})
_ = forseti.ir_source(&b, "RawAcct", "Account", ".acct.raw[?id]")
_ = forseti.ir_derived(&b, "GoldenAcct", "Golden", ".acct.golden[?id]")

_ = forseti.ir_table(&b, forseti.Table_Spec{
	name       = "tier_table",
	version    = "1.0",
	hit_policy = .First,
	inputs     = {
		{name = "employees", type = .I64, cost = 1},
		{name = "active", type = .Bool, cost = 1},
	},
	outputs = {{name = "tier", type = .String}},
	rows = {
		{id = "r_ent", cells = {forseti.cond(.Gte, i64(200)), forseti.lit(true)}, outputs = {forseti.lit("enterprise")}},
		{id = "r_smb", cells = {forseti.wildcard(), forseti.wildcard()}, outputs = {forseti.lit("smb")}},
	},
})

_ = forseti.ir_rule(&b, forseti.Rule_Spec{
	name     = "classify_acct",
	phase    = "survive",
	salience = 50,
	when_clauses = {
		forseti.pat("?_r", "RawAcct", {
			forseti.field_bind("id", forseti.vref("?id")),
			forseti.field_bind("employees", forseti.vref("?emp")),
			forseti.field_bind("active", forseti.vref("?act")),
		}),
		forseti.decide_clause("?g", "tier_table", {
			forseti.field_bind("employees", forseti.vref("?emp")),
			forseti.field_bind("active", forseti.vref("?act")),
		}),
	},
	then_actions = {
		forseti.assert_fact("GoldenAcct", {
			forseti.field_bind("id", forseti.vref("?id")),
			forseti.field_bind("tier", forseti.fget("?g", "tier")),
		}),
	},
})

diags: forseti.Diagnostic_List
_ = forseti.diag_list_init(&diags)
defer forseti.diag_list_destroy(&diags)

ir, _ := forseti.ir_builder_build(&b, &diags)
defer forseti.ir_destroy(&ir)
```

Tier 3 `forseti gen` compiles decision tables like `tier_table` into `"contextless"` native Odin:

```odin
// Code generated by forseti. DO NOT EDIT.
package generated_tables

Tier_Table_Input :: struct {
	employees: i64,
	active:    bool,
}

Tier_Table_Output :: struct {
	matched:       bool,
	row_id:        string,
	matched_count: u32,
	tier:          string,
	tier_set:      bool,
}

decide_tier_table :: proc "contextless" (in_val: Tier_Table_Input) -> Tier_Table_Output {
	if in_val.employees >= 200 && in_val.active == true {
		return Tier_Table_Output{
			matched = true,
			row_id = tier_table_row_ids[0],
			matched_count = 1,
			tier = "enterprise",
			tier_set = true,
		}
	}
	if true {
		return Tier_Table_Output{
			matched = true,
			row_id = tier_table_row_ids[1],
			matched_count = 1,
			tier = "smb",
			tier_set = true,
		}
	}
	return {}
}
```

---

### 5. Polyglot C99 ABI (`include/forseti.h`) & Multi-Threaded Actors (`actors/`)

Embed Forseti from C, Rust, Python, Elixir, or Go via `libforseti` and [`include/forseti.h`](include/forseti.h) (see the full [**C99 ABI Guide (`docs/c-api.md`)**](docs/c-api.md)), or scale across worker threads and isolated tenants in Odin with [`package forseti_actors`](docs/odin-api.md#11-multi-threaded-actor-runtime-actors--sleipnir):

```c
#include "forseti.h"

forseti_rulebase_t *rb = NULL;
char *diags_json = NULL;
forseti_rulebase_compile(policy_src, "mdm.forseti", true, &rb, &diags_json);
forseti_free_string(diags_json);

forseti_session_t *sess = NULL;
forseti_session_create(rb, FORSETI_PROV_AUDIT_FULL, 0, &sess);

forseti_value_t fields[2] = {
	{ .kind = FORSETI_VAL_STRING, .as.str = "o1" },
	{ .kind = FORSETI_VAL_I64,    .as.i64 = 150 },
};
forseti_session_insert_fact(sess, "orders", "o1", fields, 2, NULL);

uint64_t fired = 0;
forseti_session_fire(sess, &fired);

char *rows_json = NULL;
forseti_session_query_json(sess, "flagged", NULL, NULL, 0, &rows_json);
forseti_free_string(rows_json);

forseti_session_destroy(sess);
forseti_rulebase_destroy(rb);
```

---

## Performance Highlights (`10` to `1,000,000` Rules)

Measured in the **`v0.1.0` Release Snapshot** (`434960b`, `253` benchmarks across `9` groups on Linux `x86_64`, `AMD Ryzen 7 7735U`, `performance` governor, `-o:speed -microarch:native`) using [`hugi`](https://github.com/boxxxie/hugi) + [`obench`](https://github.com/zeybek/obench) in [`benchmarks/history.hugidb`](benchmarks/history.hugidb). See the visual SVG charts and all `253` results in [`benchmarks/README.md`](benchmarks/README.md), and the full methodology, longitudinal history, and hardware PMU counters in [`docs/benchmarks.md`](docs/benchmarks.md).

| Workload | Scale | Median `p50` | Heap Allocs / Op | Key Invariant |
| :--- | :---: | :---: | :---: | :--- |
| **`aot_native_fast_path`** (Tier 3) | `10,000` rows | **`775.58 ps`** | **`0`** | `proc "contextless"` (`1.29B ops/s`; `716.48 ps` / `2.0 c` PMU) |
| **`lazy_cost_skip`** (`First` cost tree) | `10,000` rows | **`42.90 ns`** | **`0`** | `O(1)` eval; expensive `cost` columns skipped |
| **`bitset_collect_sum`** (`Collect_Sum`) | `1,000` rows | **`86.57 ns`** | **`0`** | Branchless ternary `u64` bitset matrix |
| **`lazy_session_init`** | `1,000,000` rules | **`20.17 us`** | `71 / 55.17 KiB` | **`O(1)`** init regardless of rule count (`R^2 = 0.994`) |
| **`sparse_alpha_match`** (`.Fast` / `.Audit_Full`) | `1,000,000` rules | **`1.87 us`** / **`2.64 us`** | `6.1 / 2.56 KiB` | Shared alpha DAG + lazy segment linking |
| **`compile_rules`** | `1,000,000` rules | **`1.942 s`** | `61 / 658.95 MiB` | `~556 B/rule` rulebase arena footprint |
| **`phreak_hot_match_zero_alloc`** (`.Fast`) | `10,000` bg facts | **`3.16 us`** | **`0`** | Verified `@zero_alloc` `O(1)` PHREAK + JTMS toggle |
| **`diff_10_of_10k_safe_v2`** (`xitdb`) | `10,000` records | **`3.93 us`** | **`0`** | Slot-skipping HAMT diff (`2.54 M items/s`) |
| **`incremental_sync_fire_audit_full_safe_v2`** | `10,000` records | **`352.65 us`** | `6.5 / 337.31 KiB` | Full `.Audit_Full` sync + fire + `.decisions` commit (`119.58 us` `.Fast`) |
| **`parallel_diff_replay_4_cands[4]`** (`actors/`) | `4` candidate RBs | **`939.51 us`** | `739 / 1.64 MiB` | Concurrent `Core_Overlay` forks across `4` Sleipnir workers |

---

## CLI & Editor Tooling

Run `cmd/forseti` directly with Odin (requires only `-collection:xitdb=../xitdb/xitdb`) or build a binary (`odin build cmd/forseti -out:forseti -collection:xitdb=../xitdb/xitdb`):

```bash
XITDB="-collection:xitdb=../xitdb/xitdb"

# 1. Compile, resolve imports, lint, verify decision tables, and check canonical formatting
odin run cmd/forseti $XITDB -- check --include shared --warnings-as-errors policy.forseti
odin run cmd/forseti $XITDB -- verify-tables policy.forseti
odin run cmd/forseti $XITDB -- fmt --check policy.forseti

# 2. Execute against JSON facts or a persisted xitdb v2 store
odin run cmd/forseti $XITDB -- run --facts facts.json --store mdm.xit --format=json policy.forseti

# 3. Audit causal lineage, rule blast radius, and counterfactual policy changes
odin run cmd/forseti $XITDB -- explain --facts facts.json --binding CanonOrg policy.forseti
odin run cmd/forseti $XITDB -- impact --facts facts.json --rule canonicalize --format=json policy.forseti
odin run cmd/forseti $XITDB -- diff-replay --candidate v2.forseti --facts facts.json --format=json v1.forseti

# 4. Capture telemetry, export visual graphs, emit AOT Odin tables, or launch the stdio LSP
odin run cmd/forseti $XITDB -- telemetry --facts facts.json --format=chrome-trace --out trace.json policy.forseti
odin run cmd/forseti $XITDB -- export-mermaid --graph=rulebase policy.forseti
odin run cmd/forseti $XITDB -- gen --package generated_tables --out generated_tables.odin policy.forseti
odin run cmd/forseti $XITDB -- lsp
```

<details>
<summary>All 14 CLI Subcommands + Editor Integrations</summary>

| Command | Purpose |
| :--- | :--- |
| `check` | Parse, resolve `import`s (`--include` / `-I`), typecheck, lint (`E1xxx–E4xxx`, `W2xxx–W3xxx`), and stratify |
| `verify-tables` | Static gap/overlap/dead-rule proofs across all DMN tables |
| `gen` | Emit `"contextless"` AOT Odin evaluators |
| `ast` | Print deterministic S-expression AST |
| `ir` | Print lowered canonical `Rulebase_IR` summary |
| `run` | Execute policy against `--facts` and/or `--store` |
| `explain` | Reconstruct causal proof trees for derived facts |
| `impact` | Report direct & transitive downstream impact of `--rule` |
| `diff-replay` | Compare baseline vs `--candidate` over a zero-copy `Core_Overlay` |
| `telemetry` | Export phase spans, counters, and watermarks (`jsonl` / `chrome-trace`) |
| `export-dot` | Export rulebase or derivation DAG as Graphviz DOT |
| `export-mermaid` | Export rulebase or derivation DAG as Mermaid flowchart |
| `fmt` | Format `.forseti` files canonically (`--write` / `-w`, `--check`, aligned table pipes) |
| `lsp` | Run the JSON-RPC 2.0 `.forseti` Language Server over stdio (also `cmd/forseti-lsp`) |

See [`docs/editors.md`](docs/editors.md) for Neovim, VS Code, and Zed setup using `forseti lsp`, TextMate, and Tree-sitter grammars.

</details>

---

## Runnable Examples (`examples/`)

Every example compiles cleanly under strict `-vet -strict-style -warnings-as-errors` and is verified end-to-end with Odin's `mem.Tracking_Allocator` by [`tests/test_examples_verify.odin`](tests/test_examples_verify.odin):

| Example | What It Demonstrates | Run Command |
| :--- | :--- | :--- |
| [`01_decision_tables`](examples/01_decision_tables/main.odin) | `First` lazy cost-skipping, `Collect_Sum`, `Merge`, and Tier 3 AOT codegen | `odin run examples/01_decision_tables -collection:xitdb=../xitdb/xitdb` |
| [`02_mdm_xitdb_pipeline`](examples/02_mdm_xitdb_pipeline/main.odin) | `xitdb` v2 disk store, `Delta_Syncer`, atomic `.decisions` & `.__tx` commit | `odin run examples/02_mdm_xitdb_pipeline -collection:xitdb=../xitdb/xitdb` |
| [`03_jtms_steward_overrides`](examples/03_jtms_steward_overrides/main.odin) | Diamond support survival, cascading retractions, and `assert!` audit logs | `odin run examples/03_jtms_steward_overrides -collection:xitdb=../xitdb/xitdb` |
| [`04_cyclic_hierarchies`](examples/04_cyclic_hierarchies/main.odin) | Tarjan-stratified cyclic recursion, `explain`, and cycle-break retraction | `odin run examples/04_cyclic_hierarchies -collection:xitdb=../xitdb/xitdb` |
| [`05_accumulators_and_effects`](examples/05_accumulators_and_effects/main.odin) | Tied-minimum retractable accumulators & 3-phase `core:thread` async effects | `odin run examples/05_accumulators_and_effects -collection:xitdb=../xitdb/xitdb` |
| [`06_internal_odin_dsl_and_aot`](examples/06_internal_odin_dsl_and_aot/main.odin) | Tier 2 `Ir_Builder` internal Odin DSL & Tier 3 AOT Odin output | `odin run examples/06_internal_odin_dsl_and_aot -collection:xitdb=../xitdb/xitdb` |
| [`07_telemetry_and_diff_replay`](examples/07_telemetry_and_diff_replay/main.odin) | Telemetry `JSONL` / Chrome Trace, `Core_Overlay` `diff_replay`, Mermaid export | `odin run examples/07_telemetry_and_diff_replay -collection:xitdb=../xitdb/xitdb` |
| [`08_sleipnir_actor_runtime`](examples/08_sleipnir_actor_runtime/main.odin) | Sleipnir `Session_Actor`, `Xitdb_Commit_Actor`, `Partitioned_Supervisor`, hot-reload & parallel `diff_replay` | `odin run examples/08_sleipnir_actor_runtime -collection:xitdb=../xitdb/xitdb -collection:actor=../sleipnir/actor` |

---

## Documentation & Agent Guides

| Guide | Audience | Contents |
| :--- | :--- | :--- |
| [**Documentation Hub (`docs/README.md`)**](docs/README.md) | Everyone | Vocabulary glossary, mental models, execution lifecycle, and reading paths |
| [**Odin Embedding Guide (`docs/odin-api.md`)**](docs/odin-api.md) | Odin Developers | Lifetimes, `Session`, `typed_api`, `Delta_Syncer`, `explain`/semirings, async effects, `actors/` |
| [**DSL & CLI Reference (`docs/dsl-reference.md`)**](docs/dsl-reference.md) | Policy & Tool Authors | Full EBNF grammar, built-ins, hit policies, CLI flags, verified `E*`/`W*` catalog |
| [**C99 ABI & Polyglot FFI (`docs/c-api.md`)**](docs/c-api.md) | C / Rust / Python / Elixir / Go | Building `libforseti`, [`include/forseti.h`](include/forseti.h), lifetimes, JSON & store API |
| [**Editors, Formatter & LSP (`docs/editors.md`)**](docs/editors.md) | Editor & Tool Users | `forseti fmt`, `forseti lsp`, TextMate & Tree-sitter grammars (Neovim, VS Code, Zed) |
| [**Benchmarks & Scaling (`docs/benchmarks.md`)**](docs/benchmarks.md) | Perf Engineers | `10`–`1M` rule scaling, hardware PMU counters, `@zero_alloc` hot-path audit |
| [**Agent Usage Rules (`usage-rules.md`)**](usage-rules.md) | AI Coding Agents | Prescriptive decision trees, canonical recipes, and top 16 pitfalls |
| [**Repository Guide (`AGENTS.md`)**](AGENTS.md) | Contributors & Agents | Package invariants, 4-layer ATDD rules, and canonical build/test gates |

---

## Full Verification & Build Suite

Every package and test suite runs under strict compiler vetting and `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` (matching [`.github/workflows/ci.yml`](.github/workflows/ci.yml); `-vet-packages:...` scopes vetting to Forseti packages so sibling deps compile cleanly):

```bash
XITDB="-collection:xitdb=../xitdb/xitdb"
ACTOR="-collection:actor=../sleipnir/actor"
HUGI="-collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"
VET="-vet -vet-tabs -strict-style -warnings-as-errors"

# Strict static checks across all packages
odin check forseti -no-entry-point $XITDB $VET -vet-packages:forseti
odin check lsp -no-entry-point $XITDB $VET -vet-packages:forseti,forseti_lsp
odin check actors -no-entry-point $XITDB $ACTOR $VET -vet-packages:forseti,forseti_actors
odin check capi -no-entry-point $XITDB $VET -vet-packages:forseti,forseti_capi
odin check cmd/forseti $XITDB $VET -vet-packages:forseti,forseti_lsp,main
odin check cmd/forseti-lsp $XITDB $VET -vet-packages:forseti,forseti_lsp,main

# Full leak-checked unit/property/doc/example tests & 4-layer ATDD specs
odin test tests $XITDB $ACTOR -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test specs $XITDB -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test specs_actors $XITDB $ACTOR -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# AddressSanitizer checks (Linux)
odin test tests -sanitize:address $XITDB $ACTOR -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test specs_actors -sanitize:address $XITDB $ACTOR -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# Build C99 shared library (add -linker:lld on Windows when linking with MSVC cl/link.exe)
odin build capi -build-mode:shared $XITDB -out:libforseti.so

# Package docs verification & longitudinal benchmarks
odin doc forseti $XITDB > /dev/null
hugi run
```

---

## Repository Layout

```text
.
├── forseti/        # Core library: lexer, parser, imports, IR, sema, DMN verifier/AOT, xitdb bridge, PHREAK, JTMS, Datalog, typed API, fmt
├── actors/         # Optional Sleipnir multi-threaded runtime (Session_Actor, Xitdb_Commit_Actor, Tenant_Rule_Runtime, Effect_Dispatcher)
├── lsp/            # Pure-Odin JSON-RPC 2.0 Language Server (diagnostics, hover, definition, symbols, completion, formatting, codeAction)
├── capi/           # Stable C99 ABI shared/static wrapper (libforseti)
├── include/        # Public C99 header (forseti.h)
├── cmd/forseti/    # Operational CLI (check, verify-tables, gen, ast, ir, run, explain, impact, diff-replay, telemetry, export-*, fmt, lsp)
├── cmd/forseti-lsp/# Standalone stdio LSP binary entrypoint
├── editors/        # TextMate grammar, Tree-sitter grammar + highlights.scm, and comprehensive smoke fixtures
├── specs/          # Black-box 4-layer ATDD executable specifications (package forseti_specs)
├── specs_actors/   # Black-box 4-layer ATDD specs for Sleipnir actor runtime (package forseti_actors_specs)
├── tests/          # Pattern E unit tests, Pattern D t.seed property/oracle tests, C99 ASan smoke test, doc-snippet & example verifiers
├── examples/       # 8 standalone leak-checked runnable examples (01_decision_tables .. 08_sleipnir_actor_runtime)
├── benchmarks/     # Longitudinal hugi + obench scaling suite (10 to 1,000,000 rules)
├── docs/           # Documentation hub, Odin embedding guide, DSL/CLI reference, C99 ABI guide, editor setup, benchmarks
├── conductor/      # Conductor specifications, architecture guidelines, and sequenced implementation tracks
└── scripts/        # Optional upstream reference repo fetcher (reference/README.md)
```

---

## Roadmap

Development is tracked sequentially in [`conductor/tracks.md`](conductor/tracks.md):

- [x] **Tracks 1–7:** Core `.forseti` & Internal DSL, `Rulebase_IR`, Verified DMN Tables & AOT Codegen, `xitdb` Substrate & `Core_Overlay`, Lazy PHREAK + `#must_tail` Guard VM, Z-Set JTMS / Stratified Datalog / Semirings / Async Effects, `1M`-Rule Benchmarks, and Full CLI + Verified Examples.
- [x] **Track 8:** Cross-OS CI Matrix (`ubuntu-latest`, `macos-latest`, `windows-latest`), Actions/Repo Hygiene & `v0.1.0` Release Prep ([spec](conductor/tracks/cross_os_ci_hygiene_and_v0_1_0_release_20261122/spec.md)).
- [x] **Track 9:** [**Sleipnir (`package actor`)**](https://github.com/boxxxie/sleipnir) Multi-Threaded Session Runtime — pinned `Session_Actor`s, `Chain=K` batching, single-writer `Xitdb_Commit_Actor`, OTP `Partitioned_Supervisor` tenant isolation, actor-native 3-phase async effects, parallel `Core_Overlay` `diff_replay`, and ref-counted hot-reload ([spec](conductor/tracks/sleipnir_actor_multithreaded_runtime_20261122/spec.md)).
- [x] **Track 10:** `.forseti` Language Server (LSP), Canonical Table-Aligning Formatter (`forseti fmt`) & TextMate / Tree-sitter Grammars ([spec](conductor/tracks/forseti_lsp_formatter_and_editor_tooling_20261122/spec.md)).
- [x] **Track 11:** Stable C99 ABI (`libforseti` + `forseti.h`), Typed Odin Struct Embeds & DSL v1.1 (`import` + pure built-ins) ([spec](conductor/tracks/c_abi_external_integration_and_dsl_v1_1_20261122/spec.md)).

---

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for full details.
