# Specification: External Consumer Integration, Stable C ABI (`libforseti`) & DSL v1.1 Ergonomics

> - **Track ID:** `c_abi_external_integration_and_dsl_v1_1_20261122`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** Tracks 7, 8, 9 (`sleipnir_actor_multithreaded_runtime_20261122`)

---

## 1. Problem Statement & Motivation

As Forseti moves from standalone engine to production embedding inside external hosts—both pure-Odin systems (such as B2B/MDM applications) and non-Odin runtimes (Elixir NIFs, Rust, Python, Go)—three high-leverage gaps emerge:
1. **Non-Odin Consumers (`capi/`):** Track 7 deferred an Elixir NIF / C ABI boundary until core types stabilized. External languages need an opaque-handle C99 shared/static library (`libforseti` + `include/forseti.h`) with explicit ownership rules and zero-leak C string/buffer reclamation.
2. **Typed Odin Consumer Ergonomics (`session_insert_struct`, typed query mapping):** Pure-Odin hosts currently construct `[]Value` slices manually and call `intern_session_string` per string field. Struct-tag marshaling and typed query projections dramatically cut embedding boilerplate.
3. **DSL v1.1 Modularity & Pure Built-Ins:** Larger enterprise policy suites need multi-file `import` (sharing `schema` and `table` definitions cleanly across files) and pure scalar helpers in `where` / `let` clauses (`lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, `max`).

---

## 2. Architecture

- **C99 ABI Package (`capi/` + `include/forseti.h`):**
  - Builds as a shared or static library (`odin build capi -build-mode:shared -out:libforseti.so` / `.dylib` / `.dll`) without altering core `forseti/` pure-Odin semantics.
  - Exposes opaque pointers (`forseti_rulebase_t*`, `forseti_session_t*`, `forseti_store_t*`), deterministic `forseti_status_t` enum codes, `forseti_free_string(const char*)`, and JSON output endpoints for diagnostics, query rows, `explain`, `impact`, `diff_replay`, and telemetry.
- **Typed Odin Consumer Helpers (`forseti/typed_api.odin`):**
  - Uses Odin compile-time RTTI (`type_info_of`, struct tags `forseti:"field_name"`) to insert/update facts directly from Odin structs (`session_insert_struct`, `session_modify_struct`) and project `Query_Result` rows into typed Odin structs (`query_unmarshal`).
- **DSL v1.1 (`forseti/import_resolver.odin` + VM built-in opcodes):**
  - Pre-lowering module resolver for `import "path.forseti"` with canonical path deduplication, circular import detection (`E2006`), and merged source spans for accurate diagnostics.
  - Deterministic, side-effect-free built-in VM opcodes for `lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, and `max` checked statically by `sema.odin`.

---

## 3. Functional Requirements

### FR-1: Stable C99 ABI (`capi/` + `include/forseti.h`)
- Implement opaque C99 lifecycle, compilation, fact insertion/retraction, `session_fire`, `store` sync/overlay `diff_replay`, `explain`/`impact` JSON serialization, and `forseti_free_string` memory reclamation.
- Verify with an automated C test harness compiled via `cc` / `clang` linking against `libforseti` (checking clean header compilation, error reporting, and ASan/LSan zero-leak guarantees).

### FR-2: Typed Odin Host Ergonomics
- Implement `session_insert_struct`, `session_modify_struct`, `query_unmarshal`, and typed `decide_struct` helpers using `forseti:"..."` struct tags.
- Provide an end-to-end consumer integration guide and runnable example demonstrating `forseti` + `xitdb` struct-driven MDM workflows.

### FR-3: DSL v1.1 Multi-File `import` & Pure Built-In Scalar Functions
- Support `import "shared/schemas.forseti"` (deduplicated diamond imports, explicit cycle error with import trace, clean multi-file diagnostic source paths).
- Add pure, deterministic built-ins (`lower`, `upper`, `len`, `starts_with`, `contains`, `abs`, `min`, `max`) validated by `sema.odin` and executed inside `#must_tail` guard VM with `0` extra session corruption.
- Update `docs/dsl-reference.md`, `usage-rules.md`, and `tests/test_doc_snippets.odin` in the same track.

---

## 4. Non-Functional & Verification Requirements

- Core `forseti/` remains zero external C dependencies; `capi/` wraps `forseti/` cleanly at the outer boundary.
- Zero leaks across C FFI calls (`ODIN_TEST_FAIL_ON_BAD_MEMORY=true` + C ASan test harness) and Odin typed helpers.
- All new DSL v1.1 diagnostic codes and syntax snippets covered by `test_doc_snippets.odin`, `test_doc_diagnostic_catalog_covers_all_codes`, and 4-layer ATDD specs in `specs/`.

---

## 5. Out of Scope

- Impure I/O built-ins inside `when`/`where` clauses (external I/O stays inside 3-phase `effect "..." { ... }`).
- Publishing language-specific package wrappers (Hex/PyPI/Crates.io) beyond the core `libforseti` + `forseti.h` boundary.

---

## 6. Acceptance Criteria

- [ ] `capi/` builds `libforseti` + `include/forseti.h` cleanly and passes the C99 FFI verification suite with zero leaks.
- [ ] Typed Odin struct helpers pass 4-layer ATDD specs (`specs/`) with `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`.
- [ ] DSL v1.1 multi-file `import` and pure built-ins pass 4-layer ATDD specs, `test_doc_snippets.odin`, `test_doc_diagnostic_catalog_covers_all_codes`, and strict `odin check`.
