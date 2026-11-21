# Specification: Core `.forseti` External & Internal DSL, Canonical `Rulebase_IR`, Compile-Time Diagnostics, and Telemetry Foundation

> - **Track ID:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** None (Step 1 — Foundation)

---

## 1. Problem Statement & Motivation

All three authoring tiers of Forseti—the priority #1 **External `.forseti` DSL**, the **Internal Odin DSL**, and the downstream **AOT Odin Codegen**—must share one canonical, compact, arena-allocated intermediate representation (`Rulebase_IR`) and one deterministic diagnostic/telemetry foundation. Without a strict compile-time diagnostic pass and built-in instrumentation from day one, agents writing `.forseti` policies hit silent runtime failures (unbound variables, misspelled fields, shadowed rules, Cartesian joins), and performance bottlenecks remain invisible.

---

## 2. Architecture

```text
  .forseti Source ─▶ Zero-Copy Lexer + Line Map ─▶ Pratt Parser ─▶ Flat Ast_Pool (<=32B/Node)
                                                                            │
                                                                            ▼
  Internal Odin DSL (proc{...} builders) ─────────────────────────▶ Canonical Rulebase_IR
                                                                            │
                                                   ┌────────────────────────┴────────────────────────┐
                                                   ▼                                                 ▼
                                       Semantic & Lint Pass                               Telemetry Recorder
                                    (E1xxx/E2xxx/E4xxx, W* + spans)                  (Phase timers, counts, RAM, JSONL)
```

- **Lexing & Interning:** 8-byte `Span{offset, len: u32}`, sticky `.EOF` token, ASCII fast path with safe UTF-8 fallback, lazy `line_starts: [dynamic]u32` resolution, hybrid `String_Interner` (`vmem.Arena` string bytes + heap `[dynamic]string` / `map[string]String_Id`).
- **Flat `Ast_Pool`:** `Node_Id :: distinct u32`, `Node` struct `#assert(size_of(Node) <= 32)`, scratch-staged `extra_children` spans, `Error_Expr` nodes for bounded error recovery without cascading noise.
- **Canonical `Rulebase_IR`:** Typed `Schema_Def`, `Binding_Def` (`source` / `derived` `xitdb` paths), `Table_Def` (headers, columns, rows, hit policy), `Rule_Def` (phase, salience, patterns, `not`/`exists`, accumulators, `decide`, `where`, `assert` / `assert!`, `effect`), `Query_Def`, and `Expr_IR`.
- **Diagnostics (`Diagnostic`):** Exact `Span`, `Severity` (`.Error`, `.Warning`, `.Hint`), code (`E1xxx` syntax, `E2xxx` type/binding, `W1xxx–W2xxx` lints), human caret renderer, `--format=json`, and `--warnings-as-errors`.
- **Telemetry:** `#config(FORSETI_TELEMETRY, true)` compile-time switch + runtime enable flag, zero-cost disabled path, hierarchical phase spans (`lex`, `parse`, `ir_lower`, `analyze`, `match`, `tms`, `commit`), per-rule counters, memory watermarks, JSONL and Chrome Trace Event Format exporters.

---

## 3. Functional Requirements

### FR-1: Zero-Copy Lexer, `String_Interner`, and Pratt Parser
- Implement full tokenization and bounded-depth (`MAX_PARSE_DEPTH :: #config(MAX_PARSE_DEPTH, 256)`) recursive-descent + Pratt parser covering:
  - `module <ident> version "<ver>"`
  - `schema <Name> { field: type, ... }` (`bool`, `i32`, `i64`, `f64`, `string`, `entity`, `time`, `enum(...)`)
  - `source <Name> at <selector_pattern>` and `derived <Name> at <selector_pattern>`
  - `table <name> version "<ver>" hit <First|Unique|Any|Priority|Collect|Merge|Reverse_Merge> [verify(...)] { inputs {...} outputs {...} rows {...} }`
  - `rule <name> [phase "<p>"] [salience <n>] { when { ... } [then { ... } | effect "<kind>" { ... }] }`
  - Pattern clauses: typed/source patterns (`?v := Name(...)`), EAV patterns, `not (...)`, `exists (...)`, accumulators (`?x := count|sum|min|max|avg|distinct|collect(...) from ...`), `decide <table>(...)`, `where <expr>`, and `assert` (logical) vs `assert!` (unconditional).
  - `query <name>(...) { ... }`
- Implement deterministic S-expression AST printer for readable precedence & recovery tests.

### FR-2: Shared Canonical `Rulebase_IR` & Tier 2 Internal Odin DSL
- Lower `Ast_Pool` to immutable `Rulebase_IR` stored in a dedicated `vmem.Arena`.
- Expose Tier 2 Internal Odin DSL builders (`ir_builder_init`, `schema`, `source`, `derived`, `table`, `rule`, `query`, `cond` procedure group) emitting the exact same `Rulebase_IR` validated by the same semantic pass.

### FR-3: Compile-Time Semantic Errors & Lints
- **Errors (`E1xxx` / `E2xxx`):**
  - `E1001–E1099`: Lex/parse syntax errors with synchronized statement recovery.
  - `E2001`: Unknown schema, binding, field, or table reference.
  - `E2002`: Type mismatch in `where`, `decide`, `assert`, or accumulator expression.
  - `E2003`: Unbound `?variable` in rule head (`assert`/`effect`), `where`, or negated `not` body (range-restriction violation).
  - `E2004`: Duplicate schema, table, rule, or query name; duplicate table row ID.
  - `E2005`: Invalid `decide` arity/argument names or missing required fields on `assert`.
- **Warnings (`W1xxx` / `W2xxx`):**
  - `W2001`: Unused `?variable` bound in LHS (suggest `_` prefix).
  - `W2002`: Unreachable/never-referenced `source`, `schema`, or `table`.
  - `W2003`: Potential Cartesian join (adjacent patterns sharing zero join variables).
  - `W2004`: Direct self-triggering rule (`assert X` when LHS matches `X` without negating guard or distinct phase) risk warning.
  - `W2005`: Shadowed `?variable` name across nested scopes.

### FR-4: Built-In Telemetry Core & `cmd/forseti` Inspection CLI
- Implement `Telemetry_Sink` capturing phase durations (`time.tick_now`), alloc/arena bytes, rule/node/event counters, and exporting JSONL + Chrome Trace JSON (`traceEvents`).
- Create initial `cmd/forseti` CLI supporting: `forseti check <file.forseti> [--warnings-as-errors] [--format=json|human]`, `forseti ast <file>`, `forseti ir <file>`, and `--telemetry <out.json>`.

---

## 4. Non-Functional & Verification Requirements

- Zero memory leaks and bad frees across valid and intentionally malformed inputs under `odin test tests -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and `-sanitize:address`.
- Zero warnings under `odin check -vet -vet-tabs -strict-style -disallow-do -warnings-as-errors`.
- Update `docs/dsl-reference.md` (draft grammar & `E1xxx`/`E2xxx`/`W2xxx` catalog) alongside implementation.

---

## 5. Out of Scope

- Decision table domain partitioning & runtime execution (Track 2).
- `xitdb` runtime attachment & delta syncing (Track 3).
- PHREAK matcher, guard VM, JTMS, and Datalog execution (Tracks 4 & 5).

---

## 6. Acceptance Criteria

- [ ] `.forseti` lexer, Pratt parser, `String_Interner`, and `Ast_Pool` parse complete MDM modules (schemas, bindings, tables, rules, queries, effects) and recover deterministically on malformed inputs.
- [ ] Both External `.forseti` DSL and Internal Odin DSL lower to the exact same `Rulebase_IR` and pass identical semantic checks.
- [ ] All specified `E1xxx`/`E2xxx` errors and `W2xxx` warnings emit exact `file:line:col` spans and pass `--format=json` and `--warnings-as-errors` CLI tests.
- [ ] `Telemetry_Sink` records compile phases + memory watermarks with zero leaks and exports valid Chrome Trace JSON.
- [ ] `cmd/forseti check`, `ast`, and `ir` work end-to-end; all tests pass under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and ASan.
