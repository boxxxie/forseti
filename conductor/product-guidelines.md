# Product Guidelines: `forseti`

## 1. Compiler-Grade Diagnostics & Static Safety
- Emit crisp diagnostics with `file:line:col`, byte `Span`, caret source excerpts, structured codes (`E1xxx` lexer/parser, `E2xxx` type/binding, `E3xxx` table soundness, `E4xxx` stratification/effects; `W*` warnings), and human + `--format=json` output.
- Catch real policy bugs at compile time: unbound `?var` range-restriction errors, type mismatches, `U` table overlaps with concrete counterexamples, completeness gaps, dead/shadowed rules, Cartesian joins, self-triggering loops without guard/phase termination, and unstratified negation/aggregation cycles.
- Treat warnings as first-class CI signals via `--warnings-as-errors`.

## 2. Agent-Proof DSL Ergonomics & Documentation
- Keep `.forseti` syntax regular, explicit, and free of implicit coercions or silent fallthroughs: every table row must carry an ID/label; every logical vs. unconditional assertion (`assert` vs. `assert!`) must be unambiguous.
- Whenever grammar, semantics, or diagnostic codes change, update `docs/dsl-reference.md`, `usage-rules.md`, and runnable `examples/` in the same track.
- Every code snippet in `docs/` and `examples/` must be compiled and verified by tests/CI.

## 3. Safe Defaults First; Fast Overrides Explicit
- **Provenance & TMS:** Default to `.Audit_Full` (logical JTMS + causal derivation tracking). Provide `.Support_Only` and `.Fast` modes strictly via explicit opt-in configuration.
- **`xitdb` Compatibility:** Keep standard `xitdb` v2 wire behavior (`SHA-1` HAMT, `CRC-64/XZ` trailers, default allocators) as the unconditional default. Expose fast non-crypto hashing or scratch-RAM bypasses strictly behind explicit opt-in config flags with documented invariants and limitations in `docs/xitdb-fast-mode.md`.

## 4. Data-Oriented Odin Craftsmanship
- Pure Odin (`base:*` and `core:*` + local sibling `xitdb`/`hugi`/`obench`); zero third-party C dependencies in the core library.
- Use `distinct u32` handles (`Node_Id`, `Rule_Id`, `String_Id`, `Fact_Id`), compact `#soa` arrays, `vmem.Arena` phase lifetimes, and ZII structs (`{}`).
- Split immutable shared `Rulebase` from mutable per-run `Session` and allocate per-rule/per-segment session memories lazily so `1,000,000`-rule rulebases do not blow up empty session RAM or init time.
- Zero leaks and zero bad frees enforced on every test run with `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

## 5. Honest Telemetry & Longitudinal Benchmarking
- Bake telemetry counters and phase timers directly into the architecture (compile-time switchable via `#config(FORSETI_TELEMETRY, true)` + zero-cost disabled path).
- Measure performance honestly using `hugi` + `obench`: exclude setup/teardown, unwrap allocators during timed hot loops, verify `@zero_alloc` invariants in dedicated passes, and report memory footprint + hardware perf counters alongside latency across `10` to `1,000,000` rules.
