# AGENTS.md — Forseti Repository Guide

Guidelines and architecture invariants for coding agents developing **Forseti** in Odin.

---

## Repository Structure

- **`forseti/`** — Core rules engine library (`package forseti`): `.forseti` lexer/parser/IR, compile-time diagnostics, compiled DMN decision tables, `xitdb` delta substrate, lazy PHREAK / Rete-UL matcher, 32-bit `#must_tail` guard VM, Z-set JTMS, accumulators, Tarjan SCC semi-naive Datalog, compact `#soa` provenance/semirings, 3-phase async effects, DOT/Mermaid visual exporters, and built-in telemetry. Internal structs/helpers are marked `@(private)` or `#+private`.
- **`specs/`** — Black-box 4-Layer ATDD executable specifications (`package forseti_specs`, importing `../forseti`):
  - **Layer 1 (`*_spec_test.odin`):** Behavioral specifications in pure problem-domain vocabulary (Patterns A/B/C + `#caller_location` row-constructor decision tables). Zero allocator, cursor, or internal struct details.
  - **Layer 2 (`dsl_test.odin`):** Domain verbs (`given_*`, `upon_*`, `then_*`, `viewing_*`, `proc{...}` overloads) operating on `&World` (initialized in-place with `world_init(&w, t)` + `defer world_destroy(&w)`), forwarding `loc := #caller_location` to every `testing.expect*` call.
  - **Layer 3 (`driver_test.odin`):** Composable protocol drivers bridging Layer 2 to `forseti` / `xitdb` / CLI APIs. SUT allocations stay on `context.allocator` (never hidden in `w.arena`) so `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` catches real production leaks; expected negative paths scope `context.logger = log.nil_logger()`, and OS resources register `testing.cleanup`.
- **`tests/`** — Direct Pattern E unit tests and Pattern D `prop_*` (`t.seed` + `testing.set_fail_timeout`) property / differential oracle tests for low-level infrastructure, plus doc-snippet (`test_doc_snippets.odin`) and example (`test_examples_verify.odin`) verifiers.
- **`cmd/forseti/`** — CLI (`check`, `verify-tables`, `ast`, `ir`, `gen`, `run`, `explain`, `impact`, `diff-replay`, `telemetry`, `export-dot` / `export-mermaid`).
- **`benchmarks/`** — `hugi` + `obench` benchmark suite scaling `10` to `1,000,000` rules (`benchmarks/history.hugidb`).
- **`examples/`** — CI-verified standalone runnable examples (`01_decision_tables` .. `07_telemetry_and_diff_replay`) demonstrating the `.forseti` DSL, internal Odin DSL, AOT codegen, `xitdb` integration, and telemetry.
- **`docs/` & `usage-rules.md`** — Documentation hub ([`docs/README.md`](docs/README.md)), Odin embedding guide ([`docs/odin-api.md`](docs/odin-api.md)), concise LLM quick reference ([`usage-rules.md`](usage-rules.md)), complete DSL reference ([`docs/dsl-reference.md`](docs/dsl-reference.md)), `xitdb` fast-mode tradeoffs ([`docs/xitdb-fast-mode.md`](docs/xitdb-fast-mode.md)), and scaling benchmarks ([`docs/benchmarks.md`](docs/benchmarks.md)).
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

# 2. Full leak-checked ATDD specs + transitive unit/property tests (always enable ODIN_TEST_FAIL_ON_BAD_MEMORY=true)
odin test specs -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
odin test tests -all-packages $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# 3. Single Red-First ATDD scenario execution
odin test specs $COLS $VET -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true -define:ODIN_TEST_NAMES=forseti_specs.<spec_name> -define:ODIN_TEST_FANCY=false

# 4. ASan differential / fuzz checks
odin test tests -sanitize:address $COLS -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true

# 5. Longitudinal scaling benchmarks via hugi
hugi run
```

---

## 4-Layer ATDD & Pattern A–E Testing Rules

- **Patterns A/B/C in `specs/` for Behavioral Capabilities:** Multi-step MDM workflows, policy/diagnostic behavior, incremental `xitdb` sync, JTMS cascades, and CLI/audit contracts must be driven Red-First from `specs/*_spec_test.odin`.
- **Pattern D (`prop_*`) & Pattern E Direct Tests for Low-Level Infrastructure:** Never wrap lexers, AST pools, bytecode opcodes, or binary slot/hasher codecs in ceremonial Given/Upon/Then steps—keep them as direct Pattern E unit tests + Pattern D stack-local `rand.create(t.seed)` property tests.
- **No DSL Theater or Vacuous Assertions:** Every `given_*` / `upon_*` / `then_*` step must accept the domain parameters determining the outcome (never zero-argument mega-steps hiding inputs/assertions in `driver_test.odin`), never use shape-only assertions (`len >= 0`), and keep per-test `World` label maps isolated so specs run concurrently without shared globals.

---

## Core Architectural Invariants

1. **Preserve Safe `xitdb` v2 Defaults:** Never alter default `xitdb` wire compatibility (`SLOT_LENGTH = 9`, big-endian encoding, CRC-64/XZ trailers, SHA-1 HAMT hashing). Any fast-memory adaptation for trusted in-memory Forseti workloads (e.g., non-crypto `Hasher`, optional CRC skip in pure scratch RAM, preallocated diff scratch) MUST live behind explicit opt-in configuration with documented limitations in `docs/xitdb-fast-mode.md`.
2. **Audit Trails On by Default (`.Audit_Full`):** Default session mode enables Z-set JTMS (`assert` is logical) and `#soa[dynamic]Derivation` causal lineage. Opt-out `.Fast` / `.Support_Only` modes must be explicitly requested.
3. **Zero Hot-Path Crypto Hashing:** Never run SHA-1/SHA-256 per fact inside matching or derivation recording. Record compact `u32`-indexed derivations in RAM and compute content digests lazily only when exporting or committing checkpoints.
4. **Lazy Session Memory for `1,000,000`-Rule Scalability:** Immutable `Rulebase` holds network topology shared across threads; per-`Session` segment and Beta memories allocate lazily on first activation so initializing a session over `1,000,000` rules stays O(active) rather than preallocating O(rules) empty containers.
5. **Telemetry & Diagnostics First:** Instrument compilation, sync, alpha/beta matching, JTMS cascades, stratification, and provenance commits from Track 1, and keep compile-time `E`/`W` diagnostics deterministic with `file:line:col` spans and counterexample witnesses.
6. **Conductor & Documentation Discipline:** Track all work under [`conductor/tracks.md`](conductor/tracks.md) on dedicated `track/<track_id>` branches. Whenever `.forseti` syntax, semantics, or diagnostic codes change, update `docs/dsl-reference.md`, `usage-rules.md`, and affected `examples/` in the same track.
