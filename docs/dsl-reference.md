# Forseti DSL Reference

**Forseti** unifies external `.forseti` policies (Tier 1), an internal Odin DSL via [`Ir_Builder`](../forseti/dsl_odin.odin) (Tier 2), and AOT Odin codegen via [`codegen_odin_module`](../forseti/codegen_odin.odin) (Tier 3) over one canonical `Rulebase_IR`. Every compiled module shares the same semantic validator, Tarjan SCC stratifier, and decision-table verifier.

---

## 1. Architecture & Authoring Decision Tree

- **Choose a `table` (`hit First | Unique | Any | Priority | Collect* | Merge | Reverse_Merge`):** Pure column-to-output classification, thresholds, routing, survivorship gates, or scoring matrices where static gap/overlap verification (`W3001`, `E3001`, `W3002`), cost-ordered lazy evaluation, or AOT `"contextless"` codegen adds value.
- **Choose a `rule`:** Cross-entity relational joins, multi-step derived facts (`assert`), JTMS-maintained truth maintenance (`retract`), negation (`not` / `exists`), or streaming aggregations (`count`, `sum`, `avg`, `min`, `max`, `distinct`, `collect`).
- **Choose recursive `rule`s:** Transitive closure over hierarchies or entity-resolution graphs (`OrgCluster`, `SamePerson`). Cycles across positive derived bindings stratify cleanly via semi-naive delta evaluation with finite `proof_height`. Negative or aggregate cycles emit `E4001`.
- **Choose `effect "kind" { ... }`:** Asynchronous external I/O (LLM calls, registry lookups, HTTP enrichment) using 3-phase `Prepare -> Execute -> Apply` without blocking the single-threaded rule evaluation cycle.
- **Choose Tier 2 Internal Odin DSL:** Programmatic rulebases assembled inside Odin tests or host apps without parsing `.forseti` source text.
- **Choose Tier 3 AOT Codegen (`forseti gen`):** Frozen decision-table hot paths embedded into `"contextless"` callers with zero heap allocations.

---

## 2. Lexical Conventions

- **Identifiers:** `[A-Za-z_][A-Za-z0-9_]*`
- **Keywords (35):** `module`, `version`, `schema`, `source`, `derived`, `at`, `table`, `hit`, `verify`, `inputs`, `outputs`, `rows`, `cost`, `rule`, `phase`, `salience`, `when`, `then`, `effect`, `where`, `decide`, `assert`, `assert!`, `unconditional`, `retract`, `not`, `exists`, `from`, `query`, `true`, `false`, `and`, `or`, `in`, `enum`
- **Variables:** `?name` (prefix `?_name` marks an intentionally unused binding and suppresses `W2001`)
- **Strings:** `"..."` supporting escapes `\"`, `\\`, `\n`, `\t`, `\r`, `\0` (note: backslash-newline escapes advance the lexer's line map accurately)
- **Numbers:** integers (`42`, `1_000`, `-7`) and floats (`0.85`, `1.5e-3`)
- **Comments:** `// line comment` and `/* block comment */`
- **Operators:** `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `not`, `and`, `or`, `in`, `..`, `..=`
- **Table Delimiters:** `|` separates input columns or output columns; `||` separates inputs from outputs; `-` denotes a wildcard input cell (`- | ...`) or an unset/omitted output in `Merge` / `Reverse_Merge` tables (`|| "Primary" | -`).
- **Logical vs. Unconditional Assertion:** `assert` creates a logically justified assertion tracked by Z-set JTMS; `assert!` (optionally followed by `unconditional`) creates an unconditional fact that survives premise retractions (ideal for immutable audit trails).

---

## 3. Complete EBNF Grammar & Type System

```ebnf
Module      ::= ("module" Ident ("version" String)?)? Decl*
Decl        ::= SchemaDecl | BindingDecl | TableDecl | RuleDecl | QueryDecl

SchemaDecl  ::= "schema" Ident "{" (FieldDecl ("," | ";")?)* "}"
FieldDecl   ::= Ident ":" TypeSpec
TypeSpec    ::= "bool" | "i32" | "i64" | "f64" | "string" | "entity" | "time"
              | "enum" "(" ((String | Ident) ("," (String | Ident))*)? ")"

BindingDecl ::= ("source" | "derived") Ident (":" Ident)? "at" SelectorSeg+
SelectorSeg ::= "." Ident | "[" ("?" Ident | String | "*") "]"

TableDecl   ::= "table" Ident ("version" String)? ("hit" HitPolicy)? VerifySpec? "{"
                  TableInputs? TableOutputs? TableRows?
                "}"
HitPolicy   ::= "First" | "Unique" | "Any" | "Priority" | "Collect"
              | "Collect_Sum" | "Collect_Min" | "Collect_Max" | "Collect_Count"
              | "CollectSum" | "CollectMin" | "CollectMax" | "CollectCount"
              | "Merge" | "Reverse_Merge" | "ReverseMerge"
              | "F" | "U" | "A" | "P" | "C" | "M" | "R"
VerifySpec  ::= "verify" "(" VerifyOpt ("," VerifyOpt)* ")"
VerifyOpt   ::= "complete" | "no_overlap" | "no_dead_rules" | "strict"
TableInputs ::= "inputs" "{" (TableCol ("," | ";")?)* "}"
TableOutputs::= "outputs" "{" (TableCol ("," | ";")?)* "}"
TableCol    ::= Ident ":" TypeSpec ("cost" Int)?
TableRows   ::= "rows" "{" (Ident ":" CellExpr ("|" CellExpr)* "||" Expr ("|" Expr)* ";"?)* "}"

RuleDecl    ::= "rule" Ident ("phase" String)? ("salience" "-"? Int)? "{"
                  ("when" "{" Clause* "}")?
                  ("then" "{" Action* "}")?
                  EffectDecl?
                "}"
Clause      ::= (Var ":=")? Ident "(" FieldAssigns ")"
              | (Var ":=")? "[" Expr "," Expr "," Expr "]"
              | (Var ":=")? "decide" Ident "(" FieldAssigns ")"
              | Var ":=" AccumOp "(" Expr ")" "from" Clause ("where" Expr)?
              | Var ":=" Expr
              | ("not" | "exists") ("{" Clause* "}" | "(" Clause* ")" | Clause)
              | "where" Expr
AccumOp     ::= "count" | "sum" | "min" | "max" | "avg" | "distinct" | "collect"
Action      ::= ("assert" | "assert!") (Ident "(" FieldAssigns ")" | "[" Expr "," Expr "," Expr "]") "unconditional"?
              | "retract" Expr
              | EffectDecl
EffectDecl  ::= "effect" String "{" FieldAssigns "}"

QueryDecl   ::= "query" Ident ("(" (Ident ":" TypeSpec ("," Ident ":" TypeSpec)*)? ")")? "{" Clause* "}"
```

### Type System & `xitdb` Selectors

- **Scalar types:** `bool`, `i32` (`-2147483648..2147483647`), `i64`, `f64`, `string`, `entity` (`u64`), `time` (nanoseconds `i64`), and closed `enum("a", "b", ...)`.
- **Literal narrowing for `i32`:** Integer literals written in expressions, `==`/ordering predicates, ranges (`1..=10`), and `in (1, 2)` lists automatically check against `i32` bounds at compile time and reject out-of-range constants cleanly without wrap-around.
- **Collection selectors (`at .path[?id]`):** Dot segments map to `xitdb` nested `Hash_Map` containers (e.g. `.orgs.raw[?id]`). Source facts sync incrementally via [`Delta_Syncer`](../forseti/xitdb_delta.odin), and derived facts/audit moments commit atomically into `.orgs.canon` (etc.), `.decisions`, `.idx.decisions_by_rule`, `.idx.decisions_by_entity`, and `.__tx`.

---

## 4. Decision Tables, Hit Policies & Static Verification

| Policy | Short | Evaluation Strategy | Behavior & Static Rules |
| :--- | :---: | :--- | :--- |
| `First` | `F` | Lazy cost-ordered tree | First matching row in declaration order wins (`W3002` checks top-to-bottom). |
| `Unique` | `U` | Lazy cost-ordered tree | Rows must be pairwise disjoint; overlaps emit `E3001` with counterexample tuple. |
| `Any` | `A` | Lazy cost-ordered tree | Overlapping rows allowed only when outputs match identically; conflicting overlaps emit `E3001`. |
| `Priority` | `P` | Lazy cost-ordered tree | Evaluates rows sorted by first output `enum(...)` variant rank (`W3002`/`W3005` verify in rank order). |
| `Collect` | `C` | Ternary `u64` bitset matrix | Returns all matching rows in `matched_rows`. |
| `Collect_Sum` | `CollectSum` | Ternary `u64` bitset matrix | Sums matching numeric output columns. |
| `Collect_Min` | `CollectMin` | Ternary `u64` bitset matrix | Computes minimum across matching rows. |
| `Collect_Max` | `CollectMax` | Ternary `u64` bitset matrix | Computes maximum across matching rows. |
| `Collect_Count` | `CollectCount` | Ternary `u64` bitset matrix | Counts matching rows. |
| `Merge` | `M` | Ternary `u64` bitset matrix | Merges matching rows top-to-bottom; first non-`-` value per output column wins. |
| `Reverse_Merge` | `R`, `ReverseMerge` | Ternary `u64` bitset matrix | Merges matching rows bottom-to-top; last non-`-` value wins. |

### Verified Policy Example (DMN Table + Rule + Query)

```forseti
module mdm_core version "1.0"

schema Organization {
  name: string,
  domain: string,
  employees: i64,
  active: bool
}

source RawOrg : Organization at .orgs.raw[?id]
derived CanonOrg : Organization at .orgs.canon[?id]

table survivorship_gate version "1.0" hit First verify(complete, no_dead_rules) {
  inputs {
    employees: i64 cost 1,
    active: bool cost 1
  }
  outputs {
    action: string
  }
  rows {
    r1: >= 100 | true || "auto_merge";
    r2: -      | -    || "steward_review";
  }
}

rule apply_survivorship phase "survive" salience 50 {
  when {
    ?raw := RawOrg(domain: ?dom, employees: ?emp, active: ?act)
    ?gate := decide survivorship_gate(employees: ?emp, active: ?act)
    where ?gate.action == "auto_merge"
  }
  then {
    assert CanonOrg(name: ?raw.name, domain: ?dom, employees: ?emp, active: ?act)
  }
}

query find_canon_by_domain(domain: string) {
  CanonOrg(domain: ?domain)
}
```

> **Note:** `verify(no_overlap)` enforces pairwise disjointness even on `First` tables. When using a catch-all `- | -` fallback row under `hit First`, use `verify(complete, no_dead_rules)` or `hit Unique` with explicit disjoint cells (`< 100` / `false`).

---

## 5. Rules, Reasoning, Stratification & Async Effects

```forseti
module mdm_reasoning version "2.0"

schema RawOrg { org_id: string, domain: string, employees: i64 }
schema Link { a: string, b: string }
schema Suppress { domain: string }
schema CanonOrg { org_id: string, domain: string }
schema AuditEntry { org_id: string }
schema Cluster { a: string, b: string }
schema DomainStats { domain: string, cnt: i64 }

source RawOrg : RawOrg at .raw[?id]
source Link : Link at .links[?id]
source Suppress : Suppress at .suppress[?id]
derived CanonOrg : CanonOrg at .canon[?id]
derived AuditEntry : AuditEntry at .audit[?id]
derived Cluster : Cluster at .cluster[?id]
derived DomainStats : DomainStats at .stats[?id]

rule canonicalize phase "survive" salience 50 {
  when {
    ?_r := RawOrg(org_id: ?oid, domain: ?dom, employees: ?emp)
    not Suppress(domain: ?dom)
    where ?emp >= 50
  }
  then {
    assert CanonOrg(org_id: ?oid, domain: ?dom)
    assert! AuditEntry(org_id: ?oid) unconditional
  }
  effect "enrich" { org_id: ?oid }
}

rule domain_rollup phase "stats" salience 20 {
  when {
    ?_c := CanonOrg(domain: ?dom)
    ?cnt := count(?oid) from CanonOrg(domain: ?dom, org_id: ?oid)
  }
  then {
    assert DomainStats(domain: ?dom, cnt: ?cnt)
  }
}

rule cluster_base phase "graph" {
  when { ?_l := Link(a: ?x, b: ?y) }
  then { assert Cluster(a: ?x, b: ?y) }
}

rule cluster_close phase "graph" {
  when {
    ?_p := Cluster(a: ?x, b: ?y)
    ?_q := Cluster(a: ?y, b: ?z)
  }
  then { assert Cluster(a: ?x, b: ?z) }
}
```

---

## 6. Tier 2 Internal Odin DSL

Construct the exact same `Rulebase_IR` in Odin via [`forseti/dsl_odin.odin`](../forseti/dsl_odin.odin):

```odin
b: forseti.Ir_Builder
if err := forseti.ir_builder_init(&b, "mdm_internal", "1.0"); err != nil {
	return
}
defer forseti.ir_builder_destroy(&b)

_ = forseti.ir_schema(&b, "Org", {forseti.field("id", .String), forseti.field("employees", .I64)})
_ = forseti.ir_source(&b, "RawOrg", "Org", ".orgs.raw[?id]")
_ = forseti.ir_derived(&b, "CanonOrg", "Org", ".orgs.canon[?id]")

_ = forseti.ir_rule(&b, forseti.Rule_Spec{
	name     = "promote_large",
	phase    = "survive",
	salience = 50,
	when_clauses = {
		forseti.pat("?_r", "RawOrg", {
			forseti.field_bind("id", forseti.vref("?id")),
			forseti.field_bind("employees", forseti.cond(.Gte, i64(100))),
		}),
		forseti.let_clause("?ok", forseti.lit(true)),
		forseti.where_clause(forseti.vref("?ok")),
	},
	then_actions = {
		forseti.assert_fact("CanonOrg", {
			forseti.field_bind("id", forseti.vref("?id")),
			forseti.field_bind("employees", forseti.lit(i64(100))),
		}),
	},
})

diags: forseti.Diagnostic_List
_ = forseti.diag_list_init(&diags)
defer forseti.diag_list_destroy(&diags)
ir, _ := forseti.ir_builder_build(&b, &diags)
defer forseti.ir_destroy(&ir)
```

> **Note:** Odin reserves `when` as a keyword, so `Rule_Spec` and `Query_Spec` name the fields `when_clauses` and `then_actions`. Always use `forseti.let_clause` (or `has_expr = true` on `Clause_Spec`) when constructing `.Let` / `.Where` clauses manually.

---

## 7. Complete Diagnostic Catalog (`E1xxx–E4xxx`, `W2xxx–W3xxx`)

| Code | Severity | Meaning | Fix Guidance |
| :--- | :--- | :--- | :--- |
| `E1001` | Error | Lexer error (unterminated string/comment, invalid escape, bare `?`, single `=`) | Close quotes/comments; use `==` for equality and `?name` for variables. |
| `E1002` | Error | Parser syntax error | Fix delimiters (`{`, `}`, `(`, `)`), expressions, or missing clauses. |
| `E1003` | Error | Expression or clause nesting exceeded `MAX_PARSE_DEPTH` (256) | Flatten deeply nested parenthesized expressions or blocks. |
| `E1004` | Error | Unknown or malformed decision table hit policy | Use one of `First`/`F`, `Unique`/`U`, `Any`/`A`, `Priority`/`P`, `Collect*`/`C*`, `Merge`/`M`, `Reverse_Merge`/`R`. |
| `E1005` | Error | Missing explicit `<row_id>:` label on decision table row | Prefix every row with a unique identifier such as `r1: ...`. |
| `E2001` | Error | Unknown schema, binding, field, or table reference | Declare the symbol or correct its spelling. |
| `E2002` | Error | Type mismatch (`where`, `decide`, `assert`, accumulator input, table cell, or `in`) | Match field/column types (e.g. `i64` vs `string` vs `bool`). |
| `E2003` | Error | Unbound `?variable` (or leaked out of `not` / `exists` / `from`) | Bind `?var` in a positive clause or query parameter before reading it. |
| `E2004` | Error | Duplicate schema, field, binding, table, column, row ID, rule, or query | Rename duplicate declarations or table row labels. |
| `E2005` | Error | Wrong arity / duplicate / missing argument in `decide` or `assert` | Supply every required table input / schema field once. |
| `E3001` | Error | Overlapping rules in `Unique`/`no_overlap` table or conflicting `Any` overlap | Tighten predicates so rows are disjoint, or switch policy to `First`. |
| `E3002` | Error | Unsatisfiable decision table cell (contradictory range or compound predicate) | Fix impossible bounds (e.g. `> 10 and < 5`). |
| `E4001` | Error | Unstratified `not` or aggregation cycle across rule dependency SCC | Separate base derivation from negated/aggregated stratum. |
| `W2001` | Warning | Unused bound `?variable` in rule | Prefix intentionally unused variables with `?_` (e.g. `?_r`). |
| `W2002` | Warning | Unreferenced `schema`, `source`, or `table` | Reference it in a rule/query or remove dead declarations. |
| `W2003` | Warning | Potential Cartesian join across adjacent positive patterns | Share at least one bound `?variable` across adjacent patterns. |
| `W2004` | Warning | Direct self-triggering rule (`when` and `assert` share target without `not`) | Assert a distinct `derived` binding or add a guarding `not` pattern. |
| `W2005` | Warning | Shadowed `?variable` name across `:=` bindings | Use a distinct variable name in inner/later bindings. |
| `W3001` | Warning | Completeness gap in decision table (emits uncovered witness tuple) | Cover missing cases or add a fallback `-` row. |
| `W3002` | Warning | Unreachable / dead row shadowed by higher-precedence rows | Move more specific rows before catch-all rows (or higher enum priority). |
| `W3003` | Warning | Mergeable adjacent/duplicate rows with identical outputs | Combine conditions with `or` or `in (...)`. |
| `W3004` | Warning | Non-wildcard cell covers the entire column domain | Simplify redundant tautologies such as `true or false` to `-`. |
| `W3005` | Warning | Declared output `enum(...)` variant never produced by any reachable row | Add a reachable row producing the variant or remove the variant. |
| `W3006` | Warning | Table verification budget or `MAX_VERIFY_ROWS` exceeded | Simplify open intervals, split table, or pass `verify(...)`. |

### Verified *Broken -> Fixed* Examples

Every snippet below is compile-checked automatically by [`tests/test_doc_snippets.odin`](../tests/test_doc_snippets.odin).

#### `E1004` — Unknown Hit Policy

```forseti
// expect-error: E1004
module e1004_bad version "1.0"
table gate hit RandomPolicy {
  inputs { ok: bool }
  outputs { out: string }
  rows { r1: - || "ok"; }
}
rule r { when { ?_g := decide gate(ok: true) } }
```

```forseti
module e1004_ok version "1.0"
table gate hit First {
  inputs { ok: bool }
  outputs { out: string }
  rows { r1: - || "ok"; }
}
query q() { ?_g := decide gate(ok: true) }
```

#### `E1005` — Missing Row ID

```forseti
// expect-error: E1005
module e1005_bad version "1.0"
table gate hit First {
  inputs { ok: bool }
  outputs { out: string }
  rows { - || "ok"; }
}
```

#### `E2002` / `E2003` — Type Mismatch & Unbound Variable

```forseti
// expect-error: E2002
// expect-error: E2003
module e2002_2003_bad version "1.0"
schema Rec { id: string, flag: bool }
source Src : Rec at .recs[?id]
derived Out : Rec at .out[?id]
rule bad_check {
  when { ?_r := Src(id: ?id, flag: ?flag); where ?flag == 1 }
  then { assert Out(id: ?id, flag: ?missing) }
}
```

#### `E3001` & `E3002` — Table Overlap & Unsatisfiable Cell

```forseti
// expect-error: E3001
// expect-error: E3002
module e3001_3002_bad version "1.0"
table t hit Unique {
  inputs { score: i64 }
  outputs { tier: string }
  rows {
    r1: > 10 and < 5 || "impossible";
    r2: >= 80        || "gold";
    r3: >= 90        || "platinum";
  }
}
query q() { ?_g := decide t(score: 90) }
```

#### `E4001` — Unstratified Negation Cycle

```forseti
// expect-error: E4001
module e4001_bad version "1.0"
schema Flag { id: string }
source Seed : Flag at .seed[?id]
derived A : Flag at .a[?id]
derived B : Flag at .b[?id]
rule make_a {
  when { ?_s := Seed(id: ?id); not B(id: ?id) }
  then { assert A(id: ?id) }
}
rule make_b {
  when { ?_a := A(id: ?id) }
  then { assert B(id: ?id) }
}
```

#### `W2001` & `W2003` — Unused Variable & Cartesian Join

```forseti
// expect-warning: W2001
// expect-warning: W2003
module w2001_2003_warn version "1.0"
schema Item { id: string }
source S1 : Item at .s1[?id]
source S2 : Item at .s2[?id]
rule cartesian_and_unused {
  when {
    ?_a := S1(id: ?x)
    ?_b := S2(id: ?unused_y)
  }
}
```

#### `W3001` / `W3002` / `W3004` / `W3005` — Gaps, Shadowing, Full-Domain Cell & Unused Enum

```forseti
// expect-warning: W3001
// expect-warning: W3002
// expect-warning: W3004
// expect-warning: W3005
module w3_warn version "1.0"
table review hit First {
  inputs { score: i64, active: bool }
  outputs { action: enum("keep", "archive", "drop") }
  rows {
    r1: >= 10 | true or false || "keep";
    r2: >= 20 | true          || "drop";
  }
}
query q() { ?_g := decide review(score: 5, active: false) }
```

Clean fix covering all inputs with `-` wildcard, reachable rows, and no unused enum variant:

```forseti
module w3_fixed version "1.0"
table review hit First verify(complete, no_dead_rules) {
  inputs { score: i64, active: bool }
  outputs { action: enum("keep", "drop") }
  rows {
    r1: >= 20 | true || "drop";
    r2: -     | -    || "keep";
  }
}
query q() { ?_g := decide review(score: 5, active: false) }
```

---

## 8. Complete `cmd/forseti` CLI Reference

Build or run the CLI from repo root with sibling collections:

```bash
odin run cmd/forseti -collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench -- check policy.forseti
```

| Command | Purpose | Key Options |
| :--- | :--- | :--- |
| `check` | Parse, typecheck, lint, verify tables & stratify | `--format=human\|json`, `--warnings-as-errors`, `--telemetry` |
| `verify-tables` | Static domain verification for all decision tables | `--format=human\|json`, `--warnings-as-errors` |
| `gen` | Generate `"contextless"` AOT Odin table evaluators | `--package <name>`, `--out <file.odin>`, `--warnings-as-errors` |
| `ast` | Print deterministic S-expression AST | `--out <file>` |
| `ir` | Print lowered canonical `Rulebase_IR` summary | `--out <file>`, `--warnings-as-errors` |
| `run` | Compile & execute against JSON facts / `xitdb` store | `--facts`, `--store`, `--mode=audit\|support\|fast`, `--format=human\|json` |
| `explain` | Print minimal proof tree(s) for derived facts | `--facts`, `--store`, `--binding`, `--key`, `--fact-id`, `--format=human\|json` |
| `impact` | List direct/transitive facts & derivations for a rule | `--rule <name>`, `--version <ver>`, `--facts`, `--store`, `--format=human\|json` |
| `diff-replay` | Compare baseline vs `--candidate` over `Core_Overlay` | `--candidate`, `--facts`, `--store`, `--format=human\|json` |
| `telemetry` | Capture phase timings, counters & watermarks | `--facts`, `--store`, `--format=human\|jsonl\|json\|chrome-trace`, `--out` |
| `export-dot` | Export rulebase or derivation DAG as Graphviz DOT | `--graph=rulebase\|derivations` / `--derivations`, `--facts`, `--binding`, `--key`, `--out` |
| `export-mermaid` | Export rulebase or derivation DAG as Mermaid | `--graph=rulebase\|derivations` / `--derivations`, `--facts`, `--binding`, `--key`, `--out` |

### JSON Input Schema (`--facts facts.json`)

Accepts either a top-level array `[...]` or `{"facts": [...]}`:

```json
{
  "facts": [
    {
      "binding": "RawOrg",
      "key": "org:1",
      "fields": {
        "name": "Acme Corp",
        "domain": "acme.com",
        "employees": 250,
        "active": true
      }
    }
  ]
}
```
