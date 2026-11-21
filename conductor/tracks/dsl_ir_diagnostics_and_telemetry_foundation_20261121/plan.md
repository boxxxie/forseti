# Implementation Plan: Core `.forseti` External & Internal DSL, Canonical `Rulebase_IR`, Compile-Time Diagnostics, and Telemetry Foundation

> - **Track ID:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (dedicated branch `track/dsl-ir-diagnostics-and-telemetry-foundation`, strict TDD Red -> Green -> Refactor, strict `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Project Package Bootstrap, `String_Interner`, Lexer & Telemetry Core

- [ ] Task: Scaffold `forseti/`, `tests/`, and `Telemetry_Sink` core (TDD)
    - [ ] Write failing unit tests covering `String_Interner` deduplication, `EMPTY_STRING` sentinel, `resolve_line_col` UTF-8 boundary resolution, and `Telemetry_Sink` hierarchical span recording + JSONL/Chrome Trace export + disabled zero-cost `#config(FORSETI_TELEMETRY, false)` build
    - [ ] Implement `forseti/types.odin` (`Span`, `String_Id`, `Value`, distinct IDs), `forseti/interner.odin`, `forseti/telemetry.odin`, and verify strict `odin check` + leak-checked `odin test`
- [ ] Task: Implement zero-copy `.forseti` lexer with sticky `.EOF` and malformed UTF-8 progress safety (TDD)
    - [ ] Write failing unit + fuzz-input tests covering all `.forseti` keywords, table pipe/separator tokens (`|`, `||`, `-`), comparisons, `?var` sigils, string escapes, comments, line map offsets, and malformed byte sequences
    - [ ] Implement `forseti/lexer.odin` with ASCII fast path and `utf8.decode_rune_in_string` fallback
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Lexer, String Interner & Telemetry Core' (Protocol in workflow.md)

---

## Phase 2: Flat `Ast_Pool`, Bounded-Recovery Pratt Parser & Canonical `Rulebase_IR`

- [ ] Task: Implement compact `Ast_Pool` (`#assert(size_of(Node) <= 32)`) and S-expression AST printer (TDD)
    - [ ] Write failing tests verifying `Node` size invariant, scratch-staged `extra_children` non-interleaving on nested calls, and deterministic S-expression formatting
    - [ ] Implement `forseti/ast.odin` and `forseti/ast_print.odin`
- [ ] Task: Implement Pratt expression parser and full `.forseti` module/schema/table/rule/query parser with error recovery (TDD)
    - [ ] Write failing tests for operator precedence, associativity, `MAX_PARSE_DEPTH` protection, error recovery synchronization (never spinning on stray tokens or `.EOF`), and full MDM policy constructs
    - [ ] Implement `forseti/parser.odin` and `forseti/diagnostics.odin` (caret excerpt + JSON diagnostic renderer)
- [ ] Task: Implement canonical `Rulebase_IR`, AST->IR lowering, and Tier 2 Internal Odin DSL builders (TDD)
    - [ ] Write failing tests proving identical `Rulebase_IR` structure whether authored via `.forseti` text or Tier 2 Odin `ir_builder` combinators
    - [ ] Implement `forseti/ir.odin`, `forseti/lower.odin`, and `forseti/dsl_odin.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Ast_Pool, Pratt Parser & Rulebase_IR' (Protocol in workflow.md)

---

## Phase 3: Compile-Time Semantic Validator, Lints, `cmd/forseti` CLI & Initial DSL Reference

- [ ] Task: Implement semantic validation and static lint passes (`E2001–E2005`, `W2001–W2005`) (TDD)
    - [ ] Write failing tests for every error and warning code (unbound `?var` in `assert`/`where`/`not`, type mismatches, Cartesian join warning, self-loop warning, unused vars/tables, shadowed vars) asserting exact `Span` and diagnostic code
    - [ ] Implement `forseti/sema.odin` with telemetry spans around each pass
- [ ] Task: Implement `cmd/forseti` CLI (`check`, `ast`, `ir`) and author initial `docs/dsl-reference.md` (TDD)
    - [ ] Write failing CLI integration tests verifying exit codes (`0` clean, non-zero on error or `--warnings-as-errors`), `--format=json`, and `--telemetry` output
    - [ ] Implement `cmd/forseti/main.odin`, document initial grammar + `E1xxx`/`E2xxx`/`W2xxx` codes in `docs/dsl-reference.md`, and run full ASan + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` verification
- [ ] Task: Conductor - User Manual Verification 'Phase 3: Semantic Diagnostics, CLI & DSL Reference' (Protocol in workflow.md)
