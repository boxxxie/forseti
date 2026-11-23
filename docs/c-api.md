[README](../README.md) · [Docs Hub](README.md) · [Odin API](odin-api.md) · [DSL Reference](dsl-reference.md) · **C99 ABI** · [Editors & LSP](editors.md) · [Benchmarks](benchmarks.md) · [Agent Rules](../usage-rules.md)

# Forseti C99 ABI & Polyglot FFI Guide

Forseti exposes a stable, opaque-handle C99 binary interface in [`include/forseti.h`](../include/forseti.h) implemented by [`capi/capi.odin`](../capi/capi.odin). Use it to embed `.forseti` rulebases, incremental PHREAK sessions, `xitdb` stores, causal `explain`/`impact`, and counterfactual `diff_replay` from **C, C++, Rust, Python, Elixir, Go, or Zig** with zero Odin runtime boilerplate in the caller.

## Contents

- [1. Building `libforseti` Across Platforms](#1-building-libforseti-across-platforms)
- [2. Ownership, Lifetimes & Thread-Safety Contract](#2-ownership-lifetimes--thread-safety-contract)
- [3. Status Codes, Provenance Modes & Tagged Values](#3-status-codes-provenance-modes--tagged-values)
- [4. Complete C99 Walkthrough](#4-complete-c99-walkthrough)
- [5. C99 API Reference Summary](#5-c99-api-reference-summary)
- [6. Polyglot FFI Tips (Rust, Python, Elixir, Go)](#6-polyglot-ffi-tips-rust-python-elixir-go)

---

## 1. Building `libforseti` Across Platforms

Build the shared library from the repository root (requiring only Odin and `-collection:xitdb=../xitdb/xitdb`):

```bash
XITDB="-collection:xitdb=../xitdb/xitdb"

# Linux
odin build capi -build-mode:shared $XITDB -out:libforseti.so

# macOS
odin build capi -build-mode:shared $XITDB -out:libforseti.dylib

# Windows (pass -linker:lld so an import .lib is generated alongside forseti.dll for MSVC)
odin build capi -build-mode:shared -linker:lld $XITDB -out:forseti.dll
```

Link a C99 caller on Linux:

```bash
cc -std=c99 -O2 -Iinclude app.c -L. -lforseti -Wl,-rpath,'$ORIGIN' -o app
```

You can also inspect the live smoke test and ASan verification harness in [`tests/capi_smoke.c`](../tests/capi_smoke.c) and [`tests/test_capi.odin`](../tests/test_capi.odin).

---

## 2. Ownership, Lifetimes & Thread-Safety Contract

| Rule | Contract |
| :--- | :--- |
| **Opaque Handles** | Never dereference `forseti_rulebase_t`, `forseti_session_t`, or `forseti_store_t`. Pass pointers exclusively to `forseti_*` functions and destroy in LIFO order (`session` before parent `rulebase`). |
| **Thread Safety** | A compiled `forseti_rulebase_t` is immutable and safe to share concurrently across threads (creating one `forseti_session_t` per worker thread). A single `forseti_session_t` or `forseti_store_t` is **not** internally mutex-locked—serialize access to each instance on one owning thread. |
| **Heap String Cleanup** | Every JSON / JSONL string written to `out_diags_json`, `out_json`, or `out_jsonl` is allocated by Odin and **must be freed with `forseti_free_string(ptr)`**—never call standard C `free(ptr)` (`forseti_free_string(NULL)` is a safe no-op). `forseti_abi_version()` returns a static constant string (`"0.1.0"`) and must **not** be freed. |
| **Store Modes** | `forseti_store_open(NULL, &store)` (or `""`) opens an in-memory `xitdb` `Core_Memory` store. Passing a file path (e.g. `"mdm.xit"`) opens a durable `Core_Buffered_File` store. |
| **Input & JSON Edge Safety** | `Fact_Id` arguments (`forseti_session_retract_fact_id`, `forseti_session_explain_json`) exceeding `UINT32_MAX` fail cleanly with `FORSETI_ERR_INVALID_ARG` instead of truncating. Non-finite `f64` values (`NaN`, `+Inf`, `-Inf`) serialize as JSON `null` in query outputs. |

---

## 3. Status Codes, Provenance Modes & Tagged Values

### Status Codes (`forseti_status_t`)

| Code | Meaning |
| :--- | :--- |
| `FORSETI_OK` (`0`) | Operation succeeded. |
| `FORSETI_ERR_INVALID_ARG` (`1`) | `NULL` pointer, unknown `kind`, field arity mismatch, or out-of-range `fact_id`. |
| `FORSETI_ERR_COMPILE` (`2`) | `.forseti` compilation failed (or warnings present when `warnings_as_errors = true`). Inspect `out_diags_json`. |
| `FORSETI_ERR_ALLOC` (`3`) | Memory allocation failed. |
| `FORSETI_ERR_UNKNOWN_BINDING` (`4`) | Referenced `binding` name does not exist in the compiled `Rulebase`. |
| `FORSETI_ERR_UNKNOWN_QUERY` (`5`) | Referenced `query_name` does not exist in the compiled `Rulebase`. |
| `FORSETI_ERR_UNKNOWN_RULE` (`6`) | Referenced `rule_name` (or version) does not exist in the `Rulebase`. |
| `FORSETI_ERR_STORE` (`7`) | Underlying `xitdb` open, write, or delta-sync failure. |
| `FORSETI_ERR_LIMIT` (`8`) | `session_fire` exceeded `max_activations`. |
| `FORSETI_ERR_INTERNAL` (`9`) | Unexpected VM or internal state failure. |

### Provenance Modes (`forseti_provenance_mode_t`)

- `FORSETI_PROV_AUDIT_FULL` (`0`) — Default: Z-set JTMS cascading retractions + full `#soa` derivation proof DAGs (`explain`, `impact`, `diff_replay`, `.decisions`).
- `FORSETI_PROV_SUPPORT_ONLY` (`1`) — Logical JTMS retractions without retaining full proof DAGs.
- `FORSETI_PROV_FAST` (`2`) — Zero-audit high-throughput matching (`session_modify_fact` updates slots in place). Pass `max_activations = 0` in `forseti_session_create` to use Forseti's default safety cap.

### Tagged Values (`forseti_value_t`)

| `kind` (`forseti_val_kind_t`) | Union Member (`v.as.*`) | C Type | Notes |
| :--- | :--- | :--- | :--- |
| `FORSETI_VAL_NIL` | — | — | Sentinel / empty value |
| `FORSETI_VAL_BOOL` | `.b` | `bool` | Boolean |
| `FORSETI_VAL_I32` | `.i32` | `int32_t` | Signed 32-bit integer |
| `FORSETI_VAL_I64` | `.i64` | `int64_t` | Signed 64-bit integer |
| `FORSETI_VAL_F64` | `.f64` | `double` | IEEE-754 64-bit float (`NaN`/`Inf` -> JSON `null`) |
| `FORSETI_VAL_STRING` | `.str` | `const char *` | Null-terminated UTF-8 string (interned on ingestion) |
| `FORSETI_VAL_ENTITY` | `.entity` | `uint64_t` | `Entity_Id` |
| `FORSETI_VAL_TIME_NS` | `.time_ns` | `int64_t` | Nanosecond timestamp (`Time_Ns`) |
| `FORSETI_VAL_ENUM` | `.enum_val` | `{ uint32_t enum_id; uint32_t variant; }` | Closed schema enum value |

---

## 4. Complete C99 Walkthrough

```c
#include "forseti.h"

#include <assert.h>
#include <stdio.h>

static forseti_value_t make_str(const char *s) {
	forseti_value_t v = { .kind = FORSETI_VAL_STRING };
	v.as.str = s;
	return v;
}

static forseti_value_t make_i64(int64_t n) {
	forseti_value_t v = { .kind = FORSETI_VAL_I64 };
	v.as.i64 = n;
	return v;
}

int main(void) {
	const char *policy_v1 =
		"module orders_v1 version \"1.0\"\n"
		"schema Order { id: string, amount: i64 }\n"
		"schema Flag  { id: string, reason: string }\n"
		"source orders: Order at .orders[?id]\n"
		"derived flags: Flag at .flags[?id]\n"
		"rule high_value {\n"
		"  when { orders(id: ?id, amount: ?amt); where ?amt >= 100 }\n"
		"  then { assert flags(id: ?id, reason: \"high_value\") }\n"
		"}\n"
		"query flagged() { flags(id: ?id, reason: ?reason) }\n";

	const char *policy_v2 =
		"module orders_v2 version \"2.0\"\n"
		"schema Order { id: string, amount: i64 }\n"
		"schema Flag  { id: string, reason: string }\n"
		"source orders: Order at .orders[?id]\n"
		"derived flags: Flag at .flags[?id]\n"
		"rule high_value {\n"
		"  when { orders(id: ?id, amount: ?amt); where ?amt >= 50 }\n"
		"  then { assert flags(id: ?id, reason: \"high_value\") }\n"
		"}\n"
		"query flagged() { flags(id: ?id, reason: ?reason) }\n";

	forseti_rulebase_t *rb1 = NULL, *rb2 = NULL;
	char *diags_json = NULL;
	assert(forseti_rulebase_compile(policy_v1, "v1.forseti", true, &rb1, &diags_json) == FORSETI_OK);
	forseti_free_string(diags_json);
	assert(forseti_rulebase_compile(policy_v2, "v2.forseti", true, &rb2, NULL) == FORSETI_OK);

	/* 1. In-session CRUD, JTMS fire, query, explain & impact */
	forseti_session_t *sess = NULL;
	assert(forseti_session_create(rb1, FORSETI_PROV_AUDIT_FULL, 0, &sess) == FORSETI_OK);

	forseti_value_t row1[] = { make_str("o1"), make_i64(150) };
	uint64_t o1_fid = 0;
	assert(forseti_session_insert_fact(sess, "orders", "o1", row1, 2, &o1_fid) == FORSETI_OK);

	uint64_t fired = 0;
	assert(forseti_session_fire(sess, &fired) == FORSETI_OK && fired == 1);

	char *q_json = NULL;
	assert(forseti_session_query_json(sess, "flagged", NULL, NULL, 0, &q_json) == FORSETI_OK);
	printf("Query JSON: %s\n", q_json);
	forseti_free_string(q_json);

	char *imp_json = NULL;
	assert(forseti_session_impact_json(sess, "high_value", NULL, &imp_json) == FORSETI_OK);
	printf("Impact JSON: %s\n", imp_json);
	forseti_free_string(imp_json);

	/* 2. Store persistence + zero-copy counterfactual diff_replay */
	forseti_store_t *store = NULL;
	assert(forseti_store_open(NULL, &store) == FORSETI_OK); /* NULL -> Core_Memory */

	const char *f_names[] = { "id", "amount" };
	forseti_value_t row2[] = { make_str("o2"), make_i64(75) };
	assert(forseti_store_put_record(store, ".orders", "o2", f_names, row2, 2) == FORSETI_OK);

	const char *watched[] = { ".orders" };
	char *diff_json = NULL;
	assert(forseti_diff_replay_json(store, rb1, rb2, watched, 1, &diff_json) == FORSETI_OK);
	printf("Counterfactual v1->v2 diff: %s\n", diff_json);
	forseti_free_string(diff_json);

	/* 3. LIFO teardown */
	forseti_store_destroy(store);
	forseti_session_destroy(sess);
	forseti_rulebase_destroy(rb2);
	forseti_rulebase_destroy(rb1);
	return 0;
}
```

---

## 5. C99 API Reference Summary

| Function | Purpose |
| :--- | :--- |
| `forseti_abi_version()` | Returns static ABI version string (`"0.1.0"`). Do not free. |
| `forseti_free_string(str)` | Frees any string allocated by Forseti (`NULL`-safe). |
| `forseti_rulebase_compile(src, name, werror, &rb, &diags_json)` | Compiles `.forseti` source into an immutable `forseti_rulebase_t` and optional JSON diagnostics. |
| `forseti_rulebase_destroy(rb)` | Destroys a compiled rulebase (call after all child sessions are destroyed). |
| `forseti_session_create(rb, prov_mode, max_activations, &sess)` | Allocates a pinned `forseti_session_t` with `O(1)` lazy sparse memory. |
| `forseti_session_destroy(sess)` | Destroys a session and all working-memory / JTMS state. |
| `forseti_session_insert_fact(sess, binding, key, fields, n, &fid)` | Inserts a fact row matching `binding`'s schema field order. |
| `forseti_session_modify_fact(sess, binding, key, fields, n)` | Updates an existing fact by `(binding, key)` (`O(1)` slot reuse in `.Fast` mode). |
| `forseti_session_retract_fact(sess, binding, key)` / `..._fact_id` | Retracts a fact and triggers JTMS cascades. |
| `forseti_session_fire(sess, &fired)` | Fires PHREAK matching, agenda dispatch, and JTMS cascades until fixpoint. |
| `forseti_session_query_json(sess, name, args, vals, n, &json)` | Runs a compiled parameterized query and returns JSON rows (`row_count`, `rows`). |
| `forseti_store_open(path_or_null, &store)` / `forseti_store_destroy` | Opens a `Core_Memory` (`NULL`/`""`) or durable `Core_Buffered_File` `xitdb` store. |
| `forseti_store_put_record(store, dot_path, key, names, vals, n)` | Commits a record under `dot_path[key]` inside an `xitdb` moment. |
| `forseti_session_sync_and_fire(sess, store, paths, n, commit, &fired)` | Diffs watched `xitdb` collections (`O(delta)`), fires rules, and optionally commits derived + audit state. |
| `forseti_diff_replay_json(store, base_rb, cand_rb, paths, n, &json)` | Stateless counterfactual comparison over a `Core_Overlay` fork. |
| `forseti_session_diff_replay_json(sess, store, cand_rb, paths, n, &json)` | Compares `sess`'s live rulebase against `cand_rb` over a `Core_Overlay` fork. |
| `forseti_session_explain_json(sess, fact_id, &json)` | Returns the minimal acyclic causal proof tree as JSON. |
| `forseti_session_impact_json(sess, rule_name, rule_ver, &json)` | Returns direct and transitive rule blast radius as JSON. |
| `forseti_session_telemetry_jsonl(sess, &jsonl)` | Exports session telemetry spans and counters as JSONL. |

---

## 6. Polyglot FFI Tips (Rust, Python, Elixir, Go)

- **Bind directly against [`include/forseti.h`](../include/forseti.h):** Run `bindgen` (Rust), `cffi` / `ctypes` (Python), `cgo` (Go), or an Erlang NIF/C-Node wrapper (Elixir) targeting `forseti.h`.
- **Wrap strings in RAII / `defer` helpers:** Copy `const char *` output JSON into your host language's `String` / `str` / binary immediately and release the C pointer with `forseti_free_string` in a destructor or `defer`.
- **Match `forseti_value_t` field order:** Pass `fields` arrays in the exact declaration order of the schema fields in your `.forseti` module when calling `forseti_session_insert_fact` or `forseti_session_modify_fact`.
- **Share rulebases, pin sessions:** Wrap `forseti_rulebase_t*` behind an `Arc` (Rust) or read-only shared resource after compilation, and keep each `forseti_session_t*` owned by a single thread, actor, or GenServer.
