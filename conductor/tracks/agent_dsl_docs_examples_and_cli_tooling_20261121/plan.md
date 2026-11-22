# Implementation Plan: Agent-Proof DSL Reference (`docs/` & `usage-rules.md`), CI-Verified Examples, Full CLI (`cmd/forseti`), and 4-Layer ATDD Specs

> - **Track ID:** `agent_dsl_docs_examples_and_cli_tooling_20261121`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Tracks 1–6
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/agent-dsl-docs-examples-and-cli-tooling` branch, strict TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Full `cmd/forseti` CLI, Visual Exporters & E2E 4-Layer ATDD Expansion / Audit

- [x] Task: Complete `cmd/forseti` operational subcommands (`run`, `explain`, `impact`, `diff-replay`, `telemetry`, Mermaid/DOT export) (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 CLI behavioral scenarios in `specs/cli_spec_test.odin` covering JSON/human `explain`, `impact`, `diff-replay`, `telemetry`, and graph exports
    - [x] Implement remaining subcommands in `cmd/forseti/` and `forseti/viz_export.odin`
- [x] Task: Expand cross-track E2E MDM specs and run full 4-layer ATDD hygiene audit across `specs/` (Red-First ATDD)
    - [x] Implement cross-track E2E behavioral scenarios (`specs/mdm_e2e_spec_test.odin` with Pattern B `viewing_*` scoped entity audit blocks) integrating Tracks 1–6
    - [x] Audit all `specs/*_spec_test.odin`, `specs/dsl_test.odin`, and `specs/driver_test.odin` for zero DSL theater, complete `#caller_location` forwarding, SUT `@(private)` encapsulation, parallel safety, and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [ ] Task: Conductor - User Manual Verification 'Phase 1: Full CLI & E2E 4-Layer ATDD Audit' (Protocol in workflow.md)

---

## Phase 2: Agent-Proof Documentation (`docs/dsl-reference.md`, `usage-rules.md`) & 7 CI-Verified Examples

- [x] Task: Author complete `docs/dsl-reference.md`, `usage-rules.md`, and automated doc-snippet verifier test (TDD)
    - [x] Write failing test `tests/test_doc_snippets.odin` extracting every `.forseti` code fence from `docs/dsl-reference.md` and `usage-rules.md` (validating clean compilation or exact expected `E`/`W` diagnostic codes)
    - [x] Author full `docs/dsl-reference.md` and `usage-rules.md` (including agent cheat sheet, Broken -> Fixed diagnostics catalog, and allocator/mode rules) and make `test_doc_snippets` pass 100%
- [x] Task: Create and CI-verify all 7 runnable examples under `examples/`
    - [x] Implement `examples/01_decision_tables` through `examples/07_telemetry_and_diff_replay`
    - [x] Run strict `odin check`, execution under leak-checked tracking, `odin test tests -all-packages`, and `odin test specs -all-packages`, updating `AGENTS.md` / `README.md` links
- [ ] Task: Conductor - User Manual Verification 'Phase 2: Agent DSL Docs, Usage Rules & Verified Examples' (Protocol in workflow.md)
