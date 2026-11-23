# Implementation Plan: `.forseti` Language Server (LSP), Canonical Formatter & Editor Tooling

> - **Track ID:** `forseti_lsp_formatter_and_editor_tooling_20261122`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Tracks 1, 2, 7, 8
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/forseti-lsp-formatter-and-editor-tooling` branch, Red-First 4-layer ATDD + TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Canonical `.forseti` Formatter (`forseti fmt` / `--check`)

- [x] Task: Implement trivia/comment-preserving `.forseti` formatter with DMN pipe column alignment (TDD + Pattern D)
    - [x] Write failing Pattern E formatting tests and Pattern D `t.seed` idempotence (`fmt(fmt(src)) == fmt(src)`) + comment-preservation tests in `tests/`
    - [x] Implement `forseti/format.odin` and wire `forseti fmt [--write] [--check]` into `cmd/forseti/main.odin` + `specs/cli_spec_test.odin`
- [x] Task: Conductor - User Manual Verification 'Phase 1: Canonical .forseti Formatter' (Protocol in workflow.md)

---

## Phase 2: JSON-RPC 2.0 Stdio Language Server (`cmd/forseti-lsp` / `forseti lsp`)

- [x] Task: Implement JSON-RPC 2.0 framing, UTF-8-to-UTF-16 position mapping, and live `publishDiagnostics` (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 LSP behavioral specs (`specs/lsp_and_fmt_spec_test.odin`) plus Pattern D UTF-16 position/range tests covering incomplete typing buffers and `E1xxx–E4xxx` / `W2xxx–W3xxx` diagnostics
    - [x] Implement `lsp/` (`transport.odin`, `utf16.odin`, `server.odin`), `cmd/forseti-lsp/`, and `forseti lsp` entrypoint
- [x] Task: Implement `hover`, `definition`, `documentSymbol`, `completion`, `formatting`, and `codeAction` quick-fixes (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 behavioral specs for hover metadata, jump-to-definition (`schema`/`binding`/`table`/`?var`), symbol outline, context completion, and `W2001` (`?var` -> `?_var`) / `W3001` (witness fallback row) quick-fixes
    - [x] Implement semantic index & LSP handlers in `lsp/`, verifying zero leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and `-sanitize:address`
- [x] Task: Conductor - User Manual Verification 'Phase 2: JSON-RPC 2.0 Language Server' (Protocol in workflow.md)

---

## Phase 3: Syntax Highlighting Grammars & Editor Integrations

- [x] Task: Create TextMate and Tree-sitter grammars + editor setup docs
    - [x] Author `editors/textmate/forseti.tmLanguage.json` and `editors/tree-sitter-forseti/{grammar.js,queries/highlights.scm}` covering all `.forseti` keywords, table syntax, selectors, and `?var` sigils
    - [x] Add grammar smoke fixtures, document editor setup in `docs/`, and run full strict check + `tests` + `specs` + `odin doc`
- [x] Task: Conductor - User Manual Verification 'Phase 3: Editor Grammars & Integration Docs' (Protocol in workflow.md)
