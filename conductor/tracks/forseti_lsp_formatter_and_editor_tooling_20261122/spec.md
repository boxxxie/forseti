# Specification: `.forseti` Language Server (LSP), Canonical Formatter & Editor Tooling

> - **Track ID:** `forseti_lsp_formatter_and_editor_tooling_20261122`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** Tracks 1, 2, 7, 8 (`cross_os_ci_hygiene_and_v0_1_0_release_20261122`)

---

## 1. Problem Statement & Motivation

While `forseti check` and `forseti verify-tables` catch policy errors, unbound variables, overlapping DMN rows, and unstratified cycles from the terminal, authors editing `.forseti` files in Neovim, Zed, or VS Code currently lack real-time editor diagnostics, table-column alignment formatting, hover types, jump-to-definition, quick-fixes, and syntax highlighting.

This track adds:
1. A lossless canonical `.forseti` formatter (`forseti fmt` / `forseti fmt --check`) that preserves comments and aligns DMN decision-table `|` and `||` pipes.
2. A pure-Odin JSON-RPC 2.0 Language Server (`cmd/forseti-lsp` and `forseti lsp`) reusing Forseti's own lexer, parser, `Rulebase_IR`, semantic analyzer, table verifier, and Tarjan stratifier.
3. First-class editor grammars (`editors/textmate/forseti.tmLanguage.json` and `editors/tree-sitter-forseti/`).

---

## 2. Architecture

- **Formatter (`forseti/format.odin` + `cmd/forseti` `fmt`):**
  - Trivia-preserving token/AST formatter normalizing block indentation, spacing, and tabular column alignment (`|` / `||`) inside `table ... rows { ... }`.
  - Supports `forseti fmt <path...>`, `--write` / `-w`, `--check` (CI exit `1` if unformatted), and stdin/stdout mode.
- **Language Server (`lsp/` + `cmd/forseti-lsp` / `forseti lsp`):**
  - Framed `Content-Length` JSON-RPC 2.0 stdio transport using pure Odin `core:*` packages.
  - Incremental document store (`didOpen`, `didChange`, `didClose`) running `compile_source` -> `analyze_ir` -> `verify_all_tables` -> `stratify_ir` with UTF-8 byte offsets mapped accurately to LSP UTF-16 `(line, character)` ranges.
  - Capabilities: `textDocument/publishDiagnostics`, `hover`, `definition`, `documentSymbol`, `completion`, `formatting`, and `codeAction`.
- **Editor Grammars (`editors/`):**
  - TextMate grammar (`editors/textmate/forseti.tmLanguage.json`) for VS Code, GitHub linguist/code blocks, and Shiki.
  - Tree-sitter `grammar.js` + `queries/highlights.scm` (`editors/tree-sitter-forseti/`) for Neovim and Zed.

---

## 3. Functional Requirements

### FR-1: Canonical `.forseti` Formatter (`forseti fmt`)
- Preserve all `//` line comments and `/* ... */` block comments without losing or reordering tokens.
- Align decision-table row IDs, input `|` columns, `||` boundary, and output columns cleanly.
- Guarantee idempotence (`fmt(fmt(src)) == fmt(src)`) across all valid `.forseti` files, `docs/` snippets, and `examples/`.

### FR-2: JSON-RPC 2.0 Language Server (`forseti lsp` / `cmd/forseti-lsp`)
- Publish live `E1xxx–E4xxx` and `W2xxx–W3xxx` diagnostics (including decision-table witness counterexamples) on open/change.
- Provide `hover` showing schema field types, `source`/`derived` `xitdb` selector paths, table hit policy/costs, inferred `?var` types, and rule phase/salience/stratum.
- Provide `definition` (jump from rule/query references to `schema`, `source`, `derived`, `table`, or `?var` binder), `documentSymbol` outline, context-aware `completion` (keywords, bindings, fields, table columns/enums), and `codeAction` quick-fixes (`W2001` prefix `?var` -> `?_var`; `W3001` append missing `- | -` fallback row or witness scaffold).

### FR-3: Editor Grammars & ATDD Specs
- Ship TextMate and Tree-sitter highlighting grammars covering all 35 `.forseti` keywords, `?var` / `?_var` sigils, `at .path[?id]` selectors, table delimiters `|` / `||` / `-`, `assert!`, and comments.
- Drive behavioral LSP & formatter scenarios Red-First in `specs/lsp_and_fmt_spec_test.odin` plus Pattern D `t.seed` idempotence/UTF-16 range property tests in `tests/`.

---

## 4. Non-Functional & Verification Requirements

- Zero memory leaks across open/edit/close LSP sessions under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and `-sanitize:address`.
- Graceful resilience to incomplete/syntax-broken buffers while typing (`E1001`/`E1002` recovery without crashes or infinite loops).

---

## 5. Out of Scope

- Remote multi-workspace build indexing or DAP debugger integration.

---

## 6. Acceptance Criteria

- [ ] `forseti fmt` / `--check` aligns tables, preserves comments, passes `t.seed` idempotence properties, and compiles cleanly across all snippets.
- [ ] `forseti lsp` passes end-to-end JSON-RPC 2.0 4-layer ATDD specs for diagnostics (UTF-16 accurate), hover, definition, symbols, completion, formatting, and quick-fix code actions with zero leaks.
- [ ] TextMate and Tree-sitter grammars validate cleanly against `.forseti` test fixtures.
