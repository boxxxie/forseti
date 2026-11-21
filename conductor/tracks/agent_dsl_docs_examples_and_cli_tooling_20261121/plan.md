# Implementation Plan: Agent-Proof DSL Reference (`docs/` & `usage-rules.md`), CI-Verified Examples, Full CLI (`cmd/forseti`), and 4-Layer ATDD Specs

> - **Track ID:** `agent_dsl_docs_examples_and_cli_tooling_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Tracks 1–6
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/agent-dsl-docs-examples-and-cli-tooling` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Full `cmd/forseti` CLI, Visual Exporters & 4-Layer ATDD Suite (`specs/`)

- [ ] Task: Complete `cmd/forseti` operational subcommands (`run`, `explain`, `impact`, `diff-replay`, `telemetry`, Mermaid/DOT export) (TDD)
    - [ ] Write failing CLI integration tests covering JSON/human `explain`, `impact`, `diff-replay`, `telemetry`, and graph exports
    - [ ] Implement remaining subcommands in `cmd/forseti/` and `forseti/viz_export.odin`
- [ ] Task: Build 4-layer ATDD executable specification suite under `specs/` (TDD)
    - [ ] Create `specs/dsl_mdm.odin` (`World` + `#caller_location`) and `specs/driver_mdm.odin`
    - [ ] Implement end-to-end MDM feature specs (`specs/spec_mdm_rules.odin`) passing under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Full CLI & 4-Layer ATDD Suite' (Protocol in workflow.md)

---

## Phase 2: Agent-Proof Documentation (`docs/dsl-reference.md`, `usage-rules.md`) & 7 CI-Verified Examples

- [ ] Task: Author complete `docs/dsl-reference.md`, `usage-rules.md`, and automated doc-snippet verifier test (TDD)
    - [ ] Write failing test `tests/test_doc_snippets.odin` extracting every `.forseti` code fence from `docs/dsl-reference.md` and `usage-rules.md` (validating clean compilation or exact expected `E`/`W` diagnostic codes)
    - [ ] Author full `docs/dsl-reference.md` and `usage-rules.md` (including agent cheat sheet, Broken -> Fixed diagnostics catalog, and allocator/mode rules) and make `test_doc_snippets` pass 100%
- [ ] Task: Create and CI-verify all 7 runnable examples under `examples/`
    - [ ] Implement `examples/01_decision_tables` through `examples/07_telemetry_and_diff_replay`
    - [ ] Run strict `odin check`, execution under leak-checked tracking, `odin test tests -all-packages`, and `odin test specs -all-packages`, updating `AGENTS.md` / `README.md` links
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Agent DSL Docs, Usage Rules & Verified Examples' (Protocol in workflow.md)
