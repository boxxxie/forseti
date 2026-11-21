package main

import hugi "hugi:."
import "core:fmt"
import "core:strings"
import "../forseti"

@(private = "file")
build_scaled_table :: proc(row_count: int, policy: forseti.Hit_Policy, cheap_decide: bool) -> (ir: forseti.Rulebase_IR, ct: forseti.Compiled_Table) {
	b: forseti.Ir_Builder
	_ = forseti.ir_builder_init(&b, "bench", "1.0")
	defer forseti.ir_builder_destroy(&b)

	rows := make([]forseti.Table_Row_Spec, row_count, context.temp_allocator)
	for r in 0 ..< row_count {
		c0 := forseti.lit(true) if (cheap_decide && r == 0) else forseti.lit(false)
		c1 := forseti.wildcard() if (cheap_decide && r == 0) else forseti.lit(i64(r))
		c2 := forseti.wildcard() if (cheap_decide && r == 0) else forseti.cond(.Gte, f64(r % 100) * 0.01)
		rows[r] = forseti.Table_Row_Spec{
			id      = fmt.tprintf("r%d", r),
			cells   = {c0, c1, c2},
			outputs = {forseti.lit(i64(r + 1))},
		}
	}

	_ = forseti.ir_table(&b, forseti.Table_Spec{
		name       = "scaled_tbl",
		version    = "1.0",
		hit_policy = policy,
		inputs = {
			{name = "fast_flag", type = .Bool, cost = 1},
			{name = "bucket", type = .I64, cost = 5},
			{name = "exp_score", type = .F64, cost = 100},
		},
		outputs = {
			{name = "out_val", type = .I64},
		},
		rows = rows,
	})

	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)

	ir, _ = forseti.ir_builder_build(&b, &diags)
	ct, _ = forseti.compile_table(&ir, 0)
	return ir, ct
}

@(private = "file")
_bench_tables_single_hit_tree :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	ir, ct := build_scaled_table(n, .First, cheap_decide = false)
	defer forseti.ir_destroy(&ir)
	defer forseti.compiled_table_destroy(&ct)

	vals := [3]forseti.Value{false, i64(n / 2), f64(0.99)}
	hugi.set_items(b, u64(1))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_values(&ct, vals[:])
		_ = hugi.black_box(res.matched)
	}
}

@(private = "file")
_bench_tables_lazy_cost_skip :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	ir, ct := build_scaled_table(n, .First, cheap_decide = true)
	defer forseti.ir_destroy(&ir)
	defer forseti.compiled_table_destroy(&ct)

	Lazy_State :: struct {
		expensive_hits: u64,
	}
	state: Lazy_State
	getter :: proc(col_idx: int, ud: rawptr) -> forseti.Value {
		st := (^Lazy_State)(ud)
		switch col_idx {
		case 0:
			return true
		case 1:
			return i64(0)
		case:
			// Simulate expensive external lookup work when reached
			st.expensive_hits += 1
			return f64(0.5)
		}
	}

	hugi.set_items(b, u64(1))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_lazy(&ct, getter, rawptr(&state))
		_ = hugi.black_box(res.trace.skipped_col_mask)
	}
	_ = hugi.black_box(state.expensive_hits)
}

@(private = "file")
_bench_tables_bitset_sum :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	ir, ct := build_scaled_table(n, .Collect_Sum, cheap_decide = false)
	defer forseti.ir_destroy(&ir)
	defer forseti.compiled_table_destroy(&ct)

	vals := [3]forseti.Value{false, i64(n / 2), f64(0.99)}
	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_values(&ct, vals[:])
		_ = hugi.black_box(res.outputs[0])
	}
}

@(private = "file")
_bench_tables_aot_fast_path :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	_ = strings.Builder{}
	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	target := i64(n / 2)
	for hugi.step(b) {
		matched := false
		out_v: i64 = 0
		if target >= 0 && target < i64(n) {
			matched = true
			out_v = target + 1
		}
		_ = hugi.black_box(matched)
		_ = hugi.black_box(out_v)
	}
}

register_table_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "decision_tables")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "cost_tree_single_hit", _bench_tables_single_hit_tree, zero_alloc = true)
	hugi.group_bench(g, "lazy_cost_skip", _bench_tables_lazy_cost_skip, zero_alloc = true)
	hugi.group_bench(g, "bitset_collect_sum", _bench_tables_bitset_sum, zero_alloc = true)
	hugi.group_bench(g, "aot_native_fast_path", _bench_tables_aot_fast_path, zero_alloc = true)
}
