# AGENTS.md — Forseti Repository Guide

Guidelines and architecture invariants for coding agents developing **Forseti** in Odin.

---

## Planned Repository Structure

- **`forseti/`** — Core rules engine library (`package forseti`): `.forseti` lexer/parser/IR, compile-time diagnostics, compiled DMN decision tables, `xitdb` delta substrate, lazy PHREAK / Rete-UL matcher, 32-bit `#must_tail` guard VM, Z-set JTMS, accumulators, Tarjan SCC semi-naive Datalog, compact `#soa` provenance/semirings, 3-phase async effects, and built-in telemetry.
- **`cmd/forseti/`** — CLI (`check`, `verify-tables`, `ast`, `ir`, `gen`, `explain`, `impact`, `diff-replay`, `telemetry`).
- **`tests/`** — Direct `@(test)` unit, parser fuzz-recovery, and differential oracle suites.
- **`specs/`** — 4-layer ATDD executable specifications (`World` DSL + Protocol Drivers).
- **`benchmarks/`** — `hugi` + `obench` benchmark suite scaling `10` to `1,000,000` rules (`benchmarks/history.hugidb`).
- **`examples/`** — CI-verified standalone runnable examples demonstrating the `.forseti` DSL, internal Odin DSL, AOT codegen, `xitdb` integration, and telemetry.
- **`docs/`** — Deep technical architecture, DSL reference (`docs/dsl-reference.md`), `xitdb` fast-mode tradeoffs (`docs/xitdb-fast-mode.md`), and scaling benchmarks (`docs/benchmarks.md`).
- **`conductor/`** — Conductor project context and sequenced implementation tracks ([`conductor/tracks.md`](conductor/tracks.md)).
- **`reference/`** — Gitignored upstream reference engines indexed in [`reference/README.md`](reference/README.md) (populate with `./scripts/clone_references.sh`).

---

## Canonical Build, Check, Test & Benchmark Commands

Always pass the sibling collection flags when invoking `odin`:

```bash
COLS="-collection:xitdb=../xitdb/xitdb -collection:hugi=../hugi/hugi -collection:obench=../hugi/deps/obench/obench"
VET="-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors"

# 1. Strict compiler check
odin check forseti -no-entry-point $COLS $VET
odin check cmd/forseti $COLS $VET

# 2. Leak-checked tests (always enable ODIN_TEST_FAIL_ON_BAD_MEMORY=true)
odin test tests -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test specs -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# 3. ASan differential / fuzz checks
odin test tests -sanitize:address $COLS -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# 4. Longitudinal scaling benchmarks via hugi
hugi run
```

---

## Core Architectural Invariants

1. **Preserve Safe `xitdb` v2 Defaults:** Never alter default `xitdb` wire compatibility (`SLOT_LENGTH = 9`, big-endian encoding, CRC-64/XZ trailers, SHA-1 HAMT hashing). Any fast-memory adaptation for trusted in-memory Forseti workloads (e.g., non-crypto `Hasher`, optional CRC skip in pure scratch RAM, preallocated diff scratch) MUST live behind explicit opt-in configuration with documented limitations in `docs/xitdb-fast-mode.md`.
2. **Audit Trails On by Default (`.Audit_Full`):** Default session mode enables Z-set JTMS (`assert` is logical) and `#soa[dynamic]Derivation` causal lineage. Opt-out `.Fast` / `.Support_Only` modes must be explicitly requested.
3. **Zero Hot-Path Crypto Hashing:** Never run SHA-1/SHA-256 per fact inside matching or derivation recording. Record compact `u32`-indexed derivations in RAM and compute content digests lazily only when exporting or committing checkpoints.
4. **Lazy Session Memory for `1,000,000`-Rule Scalability:** Immutable `Rulebase` holds network topology shared across threads; per-`Session` segment and Beta memories allocate lazily on first activation so initializing a session over `1,000,000` rules stays O(active) rather than preallocating O(rules) empty containers.
5. **Telemetry & Diagnostics First:** Instrument compilation, sync, alpha/beta matching, JTMS cascades, stratification, and provenance commits from Track 1, and keep compile-time `E`/`W` diagnostics deterministic with `file:line:col` spans and counterexample witnesses.
6. **Conductor & Documentation Discipline:** Track all work under [`conductor/tracks.md`](conductor/tracks.md) on dedicated `track/<track_id>` branches. Whenever `.forseti` syntax, semantics, or diagnostic codes change, update `docs/dsl-reference.md`, `usage-rules.md`, and affected `examples/` in the same track.
