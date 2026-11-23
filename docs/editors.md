[README](../README.md) · [Docs Hub](README.md) · [Odin API](odin-api.md) · [DSL Reference](dsl-reference.md) · [C99 ABI](c-api.md) · **Editors & LSP** · [Benchmarks](benchmarks.md) · [Agent Rules](../usage-rules.md)

# Editor Integrations, Formatter & Language Server

Forseti ships first-class tooling for `.forseti` policy authoring across editors and CI:

- **Canonical Formatter:** `forseti fmt [--write|-w] [--check] <file.forseti ... | ->`
- **Language Server (LSP):** `forseti lsp` (or standalone `cmd/forseti-lsp`) speaking JSON-RPC 2.0 over stdio
- **Editor Grammars:**
  - TextMate (`source.forseti`): [`editors/textmate/forseti.tmLanguage.json`](../editors/textmate/forseti.tmLanguage.json)
  - Tree-sitter: [`editors/tree-sitter-forseti/grammar.js`](../editors/tree-sitter-forseti/grammar.js) + [`highlights.scm`](../editors/tree-sitter-forseti/queries/highlights.scm)

---

## 1. Building the CLI & LSP Binaries

```bash
odin build cmd/forseti -out:forseti -collection:xitdb=../xitdb/xitdb
odin build cmd/forseti-lsp -out:forseti-lsp -collection:xitdb=../xitdb/xitdb
```

Verify formatting in CI:

```bash
./forseti fmt --check path/to/policy.forseti
```

---

## 2. Neovim (`nvim-lspconfig` + `nvim-treesitter`)

```lua
local lspconfig = require("lspconfig")
local configs = require("lspconfig.configs")

if not configs.forseti then
  configs.forseti = {
    default_config = {
      cmd = { "forseti", "lsp" },
      filetypes = { "forseti" },
      root_dir = lspconfig.util.root_pattern("ols.json", ".git"),
    },
  }
end
lspconfig.forseti.setup({})
```

Point `nvim-treesitter` parser `forseti` at `editors/tree-sitter-forseti/` and copy `queries/highlights.scm` into `queries/forseti/highlights.scm`.

---

## 3. VS Code / TextMate & Zed

- **VS Code:** Register [`editors/textmate/forseti.tmLanguage.json`](../editors/textmate/forseti.tmLanguage.json) under `contributes.grammars` (`language: "forseti"`, `scopeName: "source.forseti"`) and spawn `forseti lsp` via `vscode-languageclient`.
- **Zed:** Register the Tree-sitter grammar in [`editors/tree-sitter-forseti/`](../editors/tree-sitter-forseti/) and configure `language_servers` to launch `forseti lsp`.

---

## 4. Supported LSP Capabilities

- **Live Diagnostics (`publishDiagnostics`):** `E1xxx`–`E4xxx` and `W2xxx`–`W3xxx` with UTF-16 ranges and table witness hints.
- **Hover (`hover`):** Schema field types, `source`/`derived` `xitdb` selector paths, table hit policy/columns, `?var` inferred types, and rule phase/salience/stratum.
- **Go to Definition (`definition`):** Jump from pattern/table/schema/`?var` references to their declarations or binders.
- **Outline (`documentSymbol`):** Schemas, bindings, tables, rules, and queries.
- **Completion (`completion`) & Formatting (`formatting`):** Context keywords/bindings/tables/schemas and full-document `forseti fmt`.
- **Quick-Fixes (`codeAction`):** Prefix unused `W2001` `?var` with `?_var`, and append `r_fallback` rows for `W3001` non-exhaustive tables.
