# Changelog

All notable changes to **Forseti** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-23

Initial pure-Odin release of **Forseti**: a data-oriented rules engine, statically verified DMN decision-table compiler, and stratified Datalog runtime with causal audit trails backed by `xitdb`.

### Added

- **Core DSL, Canonical IR & Diagnostics (`forseti/`):**
  - External `.forseti` lexer, parser, semantic analyzer, and canonical `Rulebase_IR` (`schema`, `source`, `derived`, `table`, `rule`, `query`).
  - Internal Odin DSL (`Ir_Builder`) lowering to the exact same `Rulebase_IR`.
  - Compile-time `E`/`W` diagnostics with `file:line:col` source spans, hints, and JSON/human formatting.
  - Built-in profiler and telemetry sink (`Telemetry_Sink`) with JSONL and Chrome Trace Event Format export.
- **Verified DMN Decision Tables & Tier 3 AOT Codegen:**
  - Hit policies `First`, `Unique`, `Any`, `Priority`, `Collect` (`_Sum`, `_Min`, `_Max`, `_Count`), `Merge`, and `Reverse_Merge`.
  - Static domain partitioning proving coverage completeness, overlaps, dead/shadowed rows, and unsatisfiable predicates with concrete counterexample witnesses.
  - Dual compilers: cost-ordered lazy decision trees (`decide_lazy`) and branchless `u64` bitset matrices, plus `"contextless"` AOT Odin code generation (`forseti gen`).
- **`xitdb` v2 Substrate & CoW Overlays:**
  - `Store_Bridge` supporting in-memory `Core_Memory`, durable `Core_Buffered_File`, and attached caller databases with `xitdb` v2 SHA-1 HAMT + CRC-64/XZ integrity.
  - Incremental `Delta_Syncer` (`diff_collection`) with `Prehashed_Key` lookups, nested path/B+Tree/set/EAV extraction, and zero-copy `Core_Overlay` counterfactual forks.
- **Lazy PHREAK Matcher, `#must_tail` Guard VM & 1M-Rule Scaling:**
  - Shared alpha DAG with equality hash-splitting, `u64` segment bitmasks, Left/Right unlinking, hash-indexed beta joins, and binary max-heap `Agenda`.
  - 32-bit `#must_tail` bytecode guard/action VM with structural program interning.
  - `O(1)` sparse per-`Session` memory allocation scaling cleanly from `10` to `1,000,000` rules.
- **Z-Set JTMS, Accumulators, Stratified Datalog & Causal Provenance:**
  - Default `.Audit_Full` truth maintenance with cascading retractions, `unconditional` audit assertions, `not`/`exists` negation, and incremental retractable accumulators (`count`, `sum`, `min`, `max`, `avg`, `distinct`).
  - Tarjan SCC stratification with Soufflé-style `proof_height` semi-naive recursion.
  - Compact `#soa` derivation DAG committed atomically to `.decisions`, `.idx.*`, and `.__tx`, plus `explain`, `impact`, `diff_replay`, algebraic semiring evaluators (`Boolean`, `Why`, `How`, `Viterbi`), and 3-phase async effects (`Prepare -> Execute -> Apply`).
- **CLI, Benchmarks, Examples, Docs & Cross-OS CI:**
  - `cmd/forseti` CLI (`check`, `verify-tables`, `ast`, `ir`, `gen`, `run`, `explain`, `impact`, `diff-replay`, `telemetry`, `export-dot`, `export-mermaid`, `fmt`, `lsp`, and `-I` / `--include` import search paths).
  - `hugi` + `obench` benchmark suite (`benchmarks/`, recorded in `benchmarks/history.hugidb`) scaling `10` to `1,000,000` rules, plus 8 CI-verified runnable examples (`examples/01..08`), `README.md`, `usage-rules.md`, and `docs/`.
  - 4-layer ATDD specs (`specs/` and `specs_actors/`) and unit/property tests (`tests/`) verified with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`, Linux `-sanitize:address`, and a 3-OS GitHub Actions matrix (`ubuntu-latest`, `macos-latest`, `windows-latest`) using `boxxxie/odin-xitdb@v2.2.0`, `boxxxie/hugi@v0.2.0`, and `boxxxie/sleipnir@v1.1.3`.
- **Sleipnir Multi-Threaded Actor Runtime (`actors/` — Track 9):**
  - Zero-actor core isolation (`forseti/` stays free of `actor` dependencies) with sibling `package forseti_actors` (`actors/`).
  - `Session_Actor` pinning `^Session` per actor with `Chain=K` batching and `Session_SPSC_Mailbox` ingest, single-writer `Xitdb_Commit_Actor` with `Commit_Notification` broadcasts, `Tenant_Rule_Runtime` (`Partitioned_Supervisor` + TTL eviction + crash re-hydration), supervised `Effect_Dispatcher`, `Parallel_Diff_Replay` over concurrent `Core_Overlay` forks, and `Rulebase_Coordinator` hot-reload.
- **Canonical Formatter, Language Server & Editor Grammars (`lsp/`, `editors/` — Track 10):**
  - Trivia-preserving `.forseti` formatter (`forseti fmt`, `--write`, `--check`, aligned `|` / `||` decision-table columns).
  - Pure-Odin JSON-RPC 2.0 stdio LSP (`lsp/`, `cmd/forseti-lsp`, `forseti lsp`) with UTF-16 range mapping, live diagnostics, hover, definition, document symbols, completions, formatting, and quick-fix code actions.
  - TextMate (`editors/textmate/forseti.tmLanguage.json`) and Tree-sitter (`editors/tree-sitter-forseti/`) grammars with fixture tests.
- **C99 ABI, Typed Odin Helpers & DSL v1.1 (`capi/`, `include/forseti.h` — Track 11):**
  - Stable C99 shared/static library boundary (`capi/capi.odin`, `include/forseti.h`) exposing opaque handles (`forseti_rulebase_t`, `forseti_session_t`, `forseti_store_t`), `forseti_free_string`, and JSON query/explain/impact/diff-replay/telemetry endpoints verified under ASan/LSan.
  - Typed Odin host helpers (`forseti/typed_api.odin`): `session_insert_struct`, `session_modify_struct`, `decide_table_struct`, `decide_struct`, and `query_unmarshal` with `forseti:"..."` struct tags.
  - DSL v1.1 multi-file `import` resolution (`forseti/import_resolver.odin`, diamond deduplication, `E2006` cycle diagnostics) and pure scalar VM built-ins (`lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, `max`).
