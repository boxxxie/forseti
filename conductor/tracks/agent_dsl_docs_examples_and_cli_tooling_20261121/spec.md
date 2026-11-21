# Specification: Agent-Proof DSL Reference (`docs/` & `usage-rules.md`), CI-Verified Examples, Full CLI (`cmd/forseti`), and 4-Layer ATDD Specs

> - **Track ID:** `agent_dsl_docs_examples_and_cli_tooling_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** All prior tracks (`1`–`6`; `docs/dsl-reference.md` is updated incrementally along the way and finalized/audited here)

---

## 1. Problem Statement & Motivation

Even the cleanest rules engine fails in practice if AI coding agents or domain engineers guess syntax, hit confusing Rete/Datalog edge cases, or lack runnable references. This track delivers:
1. **Unambiguous, Agent-Proof Documentation (`docs/dsl-reference.md` + `usage-rules.md` + `AGENTS.md`):** Exact grammar, complete `E`/`W` diagnostic catalog with *Broken -> Fixed* examples, and clear decision trees (`table` vs `rule` vs recursive rule vs `effect` vs AOT codegen).
2. **CI-Verified Runnable Examples (`examples/`):** 7 self-contained examples compiled and executed in tests so documentation never rots.
3. **Full Operational `cmd/forseti` CLI + 4-Layer ATDD Suite (`specs/`):** Complete inspection, audit, counterfactual replay, graph visualization, and behavioral specification coverage.

---

## 2. Architecture

- **`docs/dsl-reference.md`:** Complete EBNF grammar, type system, `xitdb` path binding rules, decision table hit-policy semantics, stratification rules, provenance/semiring guide, and full `E1xxx–E4xxx` / `W1xxx–W4xxx` error/warning catalog with *Broken* -> *Diagnostic* -> *Fixed* triplets.
- **`usage-rules.md`:** Concise, LLM-optimized quick reference (matching the `usage-rules.md` convention in `../xitdb`) covering syntax rules, top 12 agent pitfalls, Odin embedding & allocator lifetimes, and opt-in `.Fast` / `Fast_Memory` guardrails.
- **`examples/` (7 Standalone Verified Examples):**
  1. `01_decision_tables`: DMN tables (`F`/`U`/`C`/`M`), gap/overlap diagnostics, lazy thunks, Tier 3 AOT codegen.
  2. `02_mdm_xitdb_pipeline`: End-to-end `Core_Memory` + `Core_Buffered_File` MDM survivorship, routing, and persisted `decisions` / `idx.decisions_*` audits.
  3. `03_jtms_steward_overrides`: Source corrections & steward locks triggering automatic cascading retractions.
  4. `04_cyclic_hierarchies`: Stratified semi-naive recursion on cyclic org/event hierarchies with finite proof trees.
  5. `05_accumulators_and_effects`: Retractable `count`/`min`/`max` + 3-phase `Prepare -> Execute -> Apply` parallel effects.
  6. `06_internal_odin_dsl_and_aot`: Tier 2 internal Odin DSL + Tier 3 `forseti gen` `"contextless"` output.
  7. `07_telemetry_and_diff_replay`: Telemetry JSONL/Chrome Trace capture + `Core_Overlay` counterfactual `diff_replay`.
- **`cmd/forseti` Complete CLI:** `check`, `verify-tables`, `ast`, `ir`, `gen`, `run`, `explain`, `impact`, `diff-replay`, `telemetry`, `export-dot` / `export-mermaid`.
- **`specs/` 4-Layer ATDD Suite:** Domain specs -> `&World` DSL (`given_*`, `upon_*`, `then_*`, `#caller_location`) -> Protocol Drivers -> `forseti` SUT.

---

## 3. Functional Requirements

### FR-1: Agent-Proof DSL Reference & `usage-rules.md`
- Complete `docs/dsl-reference.md` and `usage-rules.md` with zero undocumented keywords, flags, or error codes.
- Include an automated test extracting every `.forseti` fence from `docs/` and `usage-rules.md` (except explicitly tagged `// expect-error: E...` snippets, which must fail with that exact diagnostic code!).

### FR-2: 7 CI-Checked Runnable Examples (`examples/`)
- Build all 7 runnable examples (`01`..`07`) and add an automated test runner checking compilation (`odin check -vet ...`) and execution (`0` leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

### FR-3: Full `cmd/forseti` CLI & Visual Exporters
- Implement `run`, `explain`, `impact`, `diff-replay`, `telemetry`, and Mermaid/DOT exporters for Rete/Segment topology and Derivation DAGs.

### FR-4: 4-Layer ATDD Executable Specifications (`specs/`)
- Write end-to-end MDM behavioral specs using clean 4-layer separation (`specs/spec_*.odin`, `specs/dsl_*.odin`, `specs/driver_*.odin`).

---

## 4. Non-Functional & Verification Requirements

- Every code snippet in `docs/dsl-reference.md` and `usage-rules.md` is verified automatically (valid snippets pass; `expect-error` snippets match their documented code).
- All 7 examples, `cmd/forseti`, `tests/`, and `specs/` pass strict `odin check` and `odin test -all-packages -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.

---

## 5. Out of Scope

- Elixir NIF wrapper inside CAASA Connect (future downstream integration once Forseti C ABI / library stabilizes).

---

## 6. Acceptance Criteria

- [ ] `docs/dsl-reference.md`, `usage-rules.md`, and `AGENTS.md` cover 100% of `.forseti` constructs, Odin APIs, `E`/`W` codes, and opt-in `Fast_Memory` / `.Fast` tradeoffs.
- [ ] Automated doc-snippet test verifies every `.forseti` block in `docs/` and `usage-rules.md` (including negative `expect-error` tests).
- [ ] All 7 runnable examples compile cleanly under `-vet -vet-tabs -strict-style -disallow-do -warnings-as-errors` and execute with zero leaks.
- [ ] `cmd/forseti` supports all subcommands (`check`, `verify-tables`, `ast`, `ir`, `gen`, `run`, `explain`, `impact`, `diff-replay`, `telemetry`, `export-dot`/`export-mermaid`).
- [ ] Full 4-layer `specs/` ATDD suite passes under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
