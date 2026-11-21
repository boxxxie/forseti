# Specification: Lazy PHREAK + Rete/UL Matcher, 32-bit `#must_tail` Guard VM, Deterministic Agenda, and `1M`-Rule Sparse Session Memory

> - **Track ID:** `phreak_rete_ul_matcher_and_guard_vm_20261121`
> - **Type:** `feature`
> - **Status:** `new`
> - **Dependencies:** `dsl_ir_diagnostics_and_telemetry_foundation_20261121`, `decision_tables_verifier_and_aot_codegen_20261121`, `xitdb_substrate_and_optin_fast_memory_20261121`

---

## 1. Problem Statement & Motivation

Scaling Forseti cleanly from `10` rules up to `1,000,000` rules requires avoiding two fatal bottlenecks of classic Rete engines:
1. **Eager Beta Propagation & Churn Thrashing:** Classic Rete (Clara/CLIPS) pushes single tuples through every join node even when partner inputs are empty.
2. **O(rules) Session Preallocation:** Allocating a Beta memory hash map for every rule or node at `session_init` would consume gigabytes and hundreds of milliseconds at `1,000,000` rules when a single sync batch only touches `0.1%` of rules.

Drawing on Soar's Rete/UL (`reference/soar/.../rete.cpp`) and Drools PHREAK (`reference/drools/.../RuleNetworkEvaluatorImpl.java`, `BuildtimeSegmentUtilities.java`), Forseti builds an immutable shared `Rulebase` paired with **lazily allocated** `Session` segment/beta memories, `u64` linking bitmasks, and a 32-bit `#must_tail` bytecode VM.

---

## 2. Architecture

- **Immutable `Rulebase`:**
  - `O(1)` `[Source_Id]Alpha_Root` dispatch -> structural node-shared Alpha DAG with hash-indexed equality split tables (so 1M rules sharing prefixes share nodes and fan out in `O(1)`).
  - Build-time PHREAK segment decomposition (`Segment_Def`, `Segment_Bit` masks) grouping linear chains of Beta nodes shared by the same rule set.
  - Lowered 32-bit packed register bytecode (`Instruction{op: Opcode, dst, lhs, rhs: u8}`, `#assert(size_of(Instruction) == 4)`) for `where` expressions, arithmetic/string checks, `decide` calls, and lazy `xitdb.Read_Cursor` field reads.
- **Lazy Sparse `Session`:**
  - `seg_memories` and `beta_memories` use sparse hash/page-index tables (`map` or two-level `u32` page directory) allocated **on first touch** so `session_init` over `1,000,000` rules stays `O(1)` / tiny RAM.
  - PHREAK `u64` bitmask linking (`seg_linked`, `rule_linked`) + Left/Right unlinking: rules with any unsatisfied pattern stay unlinked with zero Beta join work.
  - Non-recursive explicit `Eval_Stack` (`[dynamic]Eval_Frame`) for segment evaluation, pause/resume subnetworks, and batched Z-set tuple staging.
  - Hash-indexed Beta join memories (`Join_Bucket`) avoiding nested-loop scans.
- **Deterministic Agenda:** Salience (`i16`), Focus Phase stacks (e.g., `"clean" -> "match" -> "route" -> "survive"`), refraction, and deterministic `(salience, recency, rule_id)` ordering.

---

## 3. Functional Requirements

### FR-1: Immutable `Rulebase` Compiler (Alpha Sharing + Segment Partitioning)
- Compile `Rulebase_IR` into shared Alpha nodes (`Hash_Split`, `Range_Split`, `Guard_Node`, `Alpha_Terminal`) and segmented Beta graph (`Join`, `Filter`, `Decide_Call`, `Rule_Terminal`).
- Support compiling `1,000,000` structured rules within bounded compile RAM and report sharing ratio in telemetry (`alpha_nodes_shared`, `segments_created`).

### FR-2: 32-bit `#must_tail` Guard & Expression VM
- Lower `Expr_IR` into register-recycled 4-byte `Instruction` streams terminated by `.Halt`.
- Implement `proc "preserve/none"` `#must_tail` threaded dispatch table (`vm.dispatch[next](vm, pc + 1)`) with `div == 0` / `min(i64)/-1` guards and lazy `xitdb.Read_Cursor` field fetch opcodes.

### FR-3: Lazy Sparse PHREAK / Rete-UL `Session` & Deterministic Agenda
- Implement lazy segment/beta memory allocation on first alpha activation.
- Implement Left/Right bitmask unlinking, hash-indexed Beta joins, non-recursive `Eval_Stack`, batched Z-set staging (`+1`/`-1`), `assert`/`retract`/`modify`, and `query` result cursors.
- Implement Phase Focus Stack + Salience Agenda with refraction and loop detection counters (`max_activations` guard + telemetry).

### FR-4: Full Matcher Telemetry Instrumentation
- Record `alpha_tests`, `alpha_hits`, `beta_joins`, `beta_tuples_staged`, `segments_linked`, `segments_skipped_unlinked`, `rules_fired`, and `session_live_memories` in `Telemetry_Sink`.

---

## 4. Non-Functional & Verification Requirements

- `session_init` on a `1,000,000`-rule `Rulebase` must remain sub-millisecond and avoid preallocating per-rule Beta containers.
- Zero leaks/bad frees under `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` and `-sanitize:address`.

---

## 5. Out of Scope

- Logical JTMS retraction cascades, accumulators, `not`/`exists` subnetworks, Tarjan SCC recursion, and `decisions` persistence (Track 5).

---

## 6. Acceptance Criteria

- [ ] Alpha sharing merges common conditions across rules; hash-split Alpha dispatch routes equality predicates in `O(1)`.
- [ ] Lazy `Session` allocates segment/beta memory only for activated segments, verified via memory watermark telemetry on `100,000` and `1,000,000` rule fixtures.
- [ ] Unlinked rules perform `0` Beta joins when partner inputs are empty (verified via `segments_skipped_unlinked` telemetry).
- [ ] `#must_tail` Guard VM evaluates arithmetic, comparisons, strings, `decide`, and `xitdb` cursor field reads cleanly with zero stack overflow or leaks.
- [ ] Multi-way Beta joins, Salience/Phase Focus Agenda, and parameterized `query` lookups match a brute-force oracle on randomized workloads.
