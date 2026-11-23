# Implementation Plan: External Consumer Integration, Stable C ABI (`libforseti`) & DSL v1.1 Ergonomics

> - **Track ID:** `c_abi_external_integration_and_dsl_v1_1_20261122`
> - **Specification:** [`./spec.md`](./spec.md)
> - **Dependencies:** Tracks 7, 8, 9
> - **Workflow:** Follow [`../../workflow.md`](../../workflow.md) (`track/c-abi-external-integration-and-dsl-v1-1` branch, Red-First 4-layer ATDD + TDD, `-vet` + `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`).

---

## Phase 1: Stable C ABI (`capi/` -> `libforseti` + `include/forseti.h`)

- [x] Task: Design and implement C99 header `include/forseti.h` and `capi/` shared library exports (TDD + C FFI Harness)
    - [x] Write failing C99 FFI harness test (`tests/capi_smoke.c` + Odin runner) exercising rulebase compile, session lifecycle, fact CRUD, fire, JSON `explain`/`diff_replay`, and string reclamation
    - [x] Implement `include/forseti.h` and `capi/*.odin` (`-build-mode:shared`), verifying clean compilation and zero leaks under ASan/LSan
- [x] Task: Conductor - User Manual Verification 'Phase 1: Stable C ABI (libforseti)' (Protocol in workflow.md)

---

## Phase 2: Typed Odin Host Ergonomics

- [x] Task: Implement `forseti:"..."` struct reflection helpers for fact insertion, table evaluation, and query unmarshaling (Red-First 4-Layer ATDD)
    - [x] Write failing Layer 1 behavioral specs (`specs/typed_embed_spec_test.odin`) verifying typed struct MDM ingestion, `decide_struct`, and `query_unmarshal` with leak checks
    - [x] Implement `forseti/typed_api.odin`, document in `docs/odin-api.md`, and verify under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`
- [x] Task: Conductor - User Manual Verification 'Phase 2: Typed Odin Host Ergonomics' (Protocol in workflow.md)

---

## Phase 3: DSL v1.1 Multi-File `import` & Pure Built-In Scalar Functions

- [ ] Task: Implement multi-file `.forseti` `import` resolution with diamond deduplication and cycle diagnostics (Red-First 4-Layer ATDD)
    - [ ] Write failing Layer 1 specs covering shared schema/table imports, diamond deduplication, and `E2006` import-cycle diagnostics
    - [ ] Implement `forseti/import_resolver.odin`, CLI `--include` search paths, and multi-file span reporting
- [ ] Task: Implement pure built-in scalar VM functions (`lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, `max`) and update docs (Red-First 4-Layer ATDD)
    - [ ] Write failing Layer 1 behavioral specs + VM Pattern E tests covering type checking (`E2002`), execution, and zero-leak string temp scoping
    - [ ] Implement built-in typecheck rules in `forseti/sema.odin` and VM opcodes in `forseti/vm_bytecode.odin` / `forseti/vm_eval.odin`, updating `docs/dsl-reference.md`, `usage-rules.md`, and `tests/test_doc_snippets.odin`
- [ ] Task: Conductor - User Manual Verification 'Phase 3: DSL v1.1 Imports & Pure Built-Ins' (Protocol in workflow.md)
