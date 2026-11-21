# Forseti DSL Reference (Track 1 Draft)

**Forseti** unifies external `.forseti` policies, an internal Odin DSL (`forseti/dsl_odin.odin`), and downstream AOT codegen over a single canonical `Rulebase_IR`.

---

## 1. Lexical Conventions

- **Identifiers:** `[A-Za-z_][A-Za-z0-9_]*`
- **Variables:** `?name` (prefix `?_name` marks an intentionally unused binding and suppresses `W2001`)
- **Strings:** `"..."` supporting escapes `\"`, `\\`, `\n`, `\t`, `\r`, `\0`
- **Numbers:** integers (`42`, `1_000`) and floats (`0.85`, `1.5e-3`)
- **Comments:** `// line comment` and `/* block comment */`
- **Table Delimiters:** `|` separates input columns or output columns; `||` separates inputs from outputs; `-` denotes a wildcard cell in inputs (`- | ...`) or an unset/omitted output in `Merge` / `Reverse_Merge` tables (`|| "Primary" | -`).
- **Logical vs. Unconditional Assertion:** `assert` creates a logically justified assertion (for downstream JTMS); `assert!` (optionally followed by `unconditional`) creates an unconditional assertion.

### Decision Table Hit Policies

| Policy | Short | Behavior |
| :--- | :---: | :--- |
| `First` | `F` | First matching row in declaration order wins; compiled to a cost-ordered lazy decision tree |
| `Unique` | `U` | At most one row may match; static verifier rejects overlaps (`E3001`) |
| `Any` | `A` | Multiple overlapping rows allowed only if their outputs agree (`E3001` on conflict) |
| `Priority` | `P` | Priority ordered by first output `enum(...)` variant declaration order |
| `Collect` | `C` | Collects all matching rows (`bitset` matrix); `Collect_Sum` (`C+`), `Collect_Min` (`C<`), `Collect_Max` (`C>`), `Collect_Count` (`C#`) |
| `Merge` | `M` | Merges matching rows top-to-bottom; first non-`-` value per output column wins |
| `Reverse_Merge` | `R` | Merges matching rows bottom-to-top; later non-`-` values override earlier rows |

---

## 2. Grammar & MDM Policy Structure

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
              | "Merge" | "Reverse_Merge" | "F" | "U" | "A" | "P" | "C" | "M" | "R"
VerifySpec  ::= "verify" "(" Ident ("," Ident)* ")"
TableRows   ::= "rows" "{" (Ident ":" Cell ("|" Cell)* "||" Expr ("|" Expr)* ";"?)* "}"

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
Action      ::= ("assert" | "assert!") (Ident "(" FieldAssigns ")" | "[" Expr "," Expr "," Expr "]") "unconditional"?
              | "retract" Expr
              | EffectDecl
EffectDecl  ::= "effect" String "{" FieldAssigns "}"

QueryDecl   ::= "query" Ident ("(" (Ident ":" TypeSpec ("," ...)*)? ")")? "{" Clause* "}"
```

### Example Policy

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

table survivorship_gate version "1.0" hit First verify(complete, no_overlap) {
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
```

---

## 3. Tier 2 Internal Odin DSL

Construct the identical `Rulebase_IR` directly from Odin code via `Ir_Builder` (`forseti/dsl_odin.odin`):
- `ir_builder_init(&b, name, ver)` / `defer ir_builder_destroy(&b)`
- `ir_schema`, `ir_source`, `ir_derived`, `ir_table`, `ir_rule`, `ir_query`
- Procedure group `cond` + `lit`, `vref`, `fget`, `pat`, `decide_clause`, `where_clause`, `assert_fact`, `assert_unconditional`, `retract_fact`, `effect_spec`, `field_bind`
- Note: Odin reserves `when` as a keyword, so `Rule_Spec` and `Query_Spec` name the fields `when_clauses` and `then_actions`.
- `ir_builder_build(&b, &diags, &telemetry)` runs the exact same `analyze_ir` semantic pass as `compile_source`.

---

## 4. Diagnostic Catalog (`E1xxx`, `E2xxx`, `W2xxx`)

| Code | Severity | Meaning | Broken Example | Fixed Example |
| :--- | :--- | :--- | :--- | :--- |
| `E1001` | Error | Lexer error (unterminated string/comment, invalid escape, bare `?`, single `=`) | `where ?x = "open` | `where ?x == "open"` |
| `E1002` | Error | Parse syntax error | `where 1 + * 2` | `where 1 + 2` |
| `E1003` | Error | Expression/clause nesting exceeded `MAX_PARSE_DEPTH` (256) | `((((...))))` | Flatten expression |
| `E1004` | Error | Unknown decision table hit policy | `hit RandomPolicy` | `hit First` |
| `E1005` | Error | Missing explicit `<row_id>:` on decision table row | `>= 1 \|\| true;` | `r1: >= 1 \|\| true;` |
| `E2001` | Error | Unknown schema, binding, field, or table | `?o := Unknown(x: 1)` | Declare `schema Unknown` / check name |
| `E2002` | Error | Type mismatch (`where`, `decide`, `assert`, `sum`/`avg`/`min`/`max`, table cells) | `where ?name == 42` | `where ?name == "Acme"` |
| `E2003` | Error | Unbound `?variable` in head, `where`, `effect`, or leaked from `not` | `not Org(name: ?x)` then `assert Out(name: ?x)` | Bind `?x` in a positive pattern |
| `E2004` | Error | Duplicate schema, field, binding, table, column, row ID, rule, or query | Two `r1:` rows in table | Unique IDs (`r1:`, `r2:`) |
| `E2005` | Error | Invalid `decide` arity/argument name or missing/unknown `assert` field | `decide gate(bad: 1)` / missing schema field | Supply every declared input/field |
| `E3001` | Error | Overlapping rules in `Unique` table or conflicting outputs in `Any` table (with witness) | Two `Unique` rows both matching `priority=90` | Tighten predicates or switch to `First` |
| `E3002` | Error | Unsatisfiable decision table cell | `> 10 and < 5` | Fix contradictory cell bounds |
| `W2001` | Warning | Unused `?variable` in rule | `RawOrg(name: ?unused)` | `RawOrg(name: ?_unused)` |
| `W2002` | Warning | Unreferenced `schema`, `source`, or `table` | `table dead { ... }` | Reference in a rule/query or remove |
| `W2003` | Warning | Potential Cartesian join across adjacent positive patterns | `RawOrg(name: ?a)` then `RawOrg(domain: ?b)` | Join on shared variable `?domain` |
| `W2004` | Warning | Direct self-triggering rule (`when` & `assert` target same binding without `not`) | `when { Raw(x: ?x) } then { assert Raw(x: ?x) }` | Add `not` guard or assert distinct `derived` |
| `W2005` | Warning | Shadowed `?variable` name across `:=` bindings | `?o := ...` then `not { ?o := ... }` | Use distinct name `?o_inner` |
| `W3001` | Warning | Completeness gap in decision table (with concrete witness tuples) | Missing `false` row in bool column | Add missing rules or fallback `-` row |
| `W3002` | Warning | Unreachable / dead rule shadowed by earlier rows | Row placed after `- \| -` catch-all | Reorder specific rows above catch-all |
| `W3003` | Warning | Duplicate or adjacent mergeable rows with identical outputs | Two adjacent rows differing in one column | Merge into `in (...)` / `or` cell |
| `W3004` | Warning | Non-wildcard cell covers entire column domain | `true or false` | Simplify cell to `-` wildcard |
| `W3005` | Warning | Declared output `enum` variant never produced by any reachable row | `enum("a", "b")` with `"b"` unused | Add row producing `"b"` or prune variant |
| `W3006` | Warning | Verification budget exceeded (`checks incomplete`) | Huge multi-interval table | Increase `MAX_VERIFY_BUDGET` or simplify |

---

## 5. `cmd/forseti` CLI (Track 1 & Track 2 Commands)

```bash
# Validate policy (human diagnostics with file:line:col carets)
forseti check policy.forseti

# Fail CI on warnings and emit structured JSON + Chrome Trace telemetry
forseti check --warnings-as-errors --format=json --telemetry trace.json policy.forseti

# Verify decision table coverage/overlaps/dead rules explicitly
forseti verify-tables --warnings-as-errors policy.forseti

# Emit standalone "contextless" Odin procedures for decision tables
forseti gen --package mdm_tables --out generated_tables.odin policy.forseti

# Inspect S-expression AST or lowered canonical IR
forseti ast policy.forseti
forseti ir policy.forseti
```
