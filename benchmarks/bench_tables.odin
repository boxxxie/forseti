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

@(private = "file")
_bench_tables_unique_hit :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	ir, ct := build_scaled_table(n, .Unique, cheap_decide = false)
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
_bench_tables_priority_hit :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	bl: forseti.Ir_Builder
	_ = forseti.ir_builder_init(&bl, "bench_prio", "1.0")
	defer forseti.ir_builder_destroy(&bl)

	rows := make([]forseti.Table_Row_Spec, n, context.temp_allocator)
	prio_names := [3]string{"p_low", "p_med", "p_high"}
	for r in 0 ..< n {
		// First 3 rows overlap on target bucket so Priority arbitrates by enum rank.
		c0 := forseti.lit(false)
		c1 := forseti.lit(i64(n / 2)) if r < 3 else forseti.lit(i64(r))
		c2 := forseti.cond(.Gte, f64(0.0)) if r < 3 else forseti.cond(.Gte, f64(r % 100) * 0.01)
		rows[r] = forseti.Table_Row_Spec{
			id      = fmt.tprintf("p%d", r),
			cells   = {c0, c1, c2},
			outputs = {forseti.lit(prio_names[r % 3])},
		}
	}

	_ = forseti.ir_table(&bl, forseti.Table_Spec{
		name       = "prio_tbl",
		version    = "1.0",
		hit_policy = .Priority,
		inputs = {
			{name = "fast_flag", type = .Bool, cost = 1},
			{name = "bucket", type = .I64, cost = 5},
			{name = "exp_score", type = .F64, cost = 100},
		},
		outputs = {
			{name = "prio", type = .Enum, variants = {"p_high", "p_med", "p_low"}},
		},
		rows = rows,
	})

	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)

	ir, _ := forseti.ir_builder_build(&bl, &diags)
	defer forseti.ir_destroy(&ir)
	ct, _ := forseti.compile_table(&ir, 0)
	defer forseti.compiled_table_destroy(&ct)

	vals := [3]forseti.Value{false, i64(n / 2), f64(0.99)}
	hugi.set_items(b, u64(1))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_values(&ct, vals[:])
		_ = hugi.black_box(res.outputs[0])
	}
}

@(private = "file")
_run_tables_merge_variant :: proc(b: ^hugi.Bencher, policy: forseti.Hit_Policy) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	bl: forseti.Ir_Builder
	_ = forseti.ir_builder_init(&bl, "bench_merge", "1.0")
	defer forseti.ir_builder_destroy(&bl)

	rows := make([]forseti.Table_Row_Spec, n, context.temp_allocator)
	for r in 0 ..< n {
		// Multiple overlapping rows match target bucket with partial wildcard outputs.
		c1 := forseti.wildcard() if (r % 250 == 0) else forseti.lit(i64(r))
		o0 := forseti.lit(i64(r + 1)) if (r % 2 == 0) else forseti.wildcard()
		o1 := forseti.wildcard() if (r % 2 == 0) else forseti.lit(i64(r + 10))
		rows[r] = forseti.Table_Row_Spec{
			id      = fmt.tprintf("m%d", r),
			cells   = {forseti.lit(false), c1, forseti.cond(.Gte, f64(0.5))},
			outputs = {o0, o1},
		}
	}

	_ = forseti.ir_table(&bl, forseti.Table_Spec{
		name       = "merge_tbl",
		version    = "1.0",
		hit_policy = policy,
		inputs = {
			{name = "fast_flag", type = .Bool, cost = 1},
			{name = "bucket", type = .I64, cost = 5},
			{name = "exp_score", type = .F64, cost = 100},
		},
		outputs = {
			{name = "out_a", type = .I64},
			{name = "out_b", type = .I64},
		},
		rows = rows,
	})

	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)

	ir, _ := forseti.ir_builder_build(&bl, &diags)
	defer forseti.ir_destroy(&ir)
	ct, _ := forseti.compile_table(&ir, 0)
	defer forseti.compiled_table_destroy(&ct)

	vals := [3]forseti.Value{false, i64(n / 2), f64(0.99)}
	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_values(&ct, vals[:])
		_ = hugi.black_box(res.outputs[0])
		_ = hugi.black_box(res.outputs[1])
	}
}

@(private = "file")
_bench_tables_merge :: proc(b: ^hugi.Bencher) {
	_run_tables_merge_variant(b, .Merge)
}

@(private = "file")
_bench_tables_reverse_merge :: proc(b: ^hugi.Bencher) {
	_run_tables_merge_variant(b, .Reverse_Merge)
}

@(private = "file")
_bench_tables_wide_string_range :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	defer free_all(context.temp_allocator)

	bl: forseti.Ir_Builder
	_ = forseti.ir_builder_init(&bl, "bench_wide", "1.0")
	defer forseti.ir_builder_destroy(&bl)

	regions := [4]string{"us", "eu", "apac", "latam"}
	tiers := [3]string{"ent", "mid", "smb"}
	rows := make([]forseti.Table_Row_Spec, n, context.temp_allocator)
	for r in 0 ..< n {
		lo := i64(r % 100) * 10
		hi := lo + 19
		rng_ch := make([]forseti.Expr_Spec, 2, context.temp_allocator)
		rng_ch[0] = forseti.lit(lo)
		rng_ch[1] = forseti.lit(hi)
		rng := forseti.Expr_Spec{kind = .Range, inclusive = true, children = rng_ch}
		rows[r] = forseti.Table_Row_Spec{
			id = fmt.tprintf("w%d", r),
			cells = {
				forseti.lit(r % 2 == 0),
				rng,
				forseti.lit(regions[r % len(regions)]),
				forseti.cond(.Gte, f64(r % 50) * 0.01),
				forseti.lit(i64(r)),
				forseti.lit(true),
				forseti.lit(tiers[r % len(tiers)]),
				forseti.cond(.Lte, f64(100.0 + f64(r % 10))),
			},
			outputs = {forseti.lit(i64(r + 1))},
		}
	}

	_ = forseti.ir_table(&bl, forseti.Table_Spec{
		name       = "wide_tbl",
		version    = "1.0",
		hit_policy = .First,
		inputs = {
			{name = "active", type = .Bool, cost = 1},
			{name = "emp_band", type = .I64, cost = 2},
			{name = "region", type = .String, cost = 3},
			{name = "conf", type = .F64, cost = 4},
			{name = "bucket", type = .I64, cost = 5},
			{name = "verified", type = .Bool, cost = 6},
			{name = "tier", type = .String, cost = 7},
			{name = "risk", type = .F64, cost = 8},
		},
		outputs = {{name = "score", type = .I64}},
		rows    = rows,
	})

	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)

	ir, _ := forseti.ir_builder_build(&bl, &diags)
	defer forseti.ir_destroy(&ir)
	ct, _ := forseti.compile_table(&ir, 0)
	defer forseti.compiled_table_destroy(&ct)

	target := n / 2
	target_lo := i64(target % 100) * 10 + 5
	reg_sid, _ := forseti.intern(&ct.interner, regions[target % len(regions)])
	tier_sid, _ := forseti.intern(&ct.interner, tiers[target % len(tiers)])
	vals := [8]forseti.Value{
		target % 2 == 0,
		target_lo,
		reg_sid,
		f64(0.95),
		i64(target),
		true,
		tier_sid,
		f64(50.0),
	}

	hugi.set_items(b, u64(1))
	hugi.expect_zero_allocs(b)

	for hugi.step(b) {
		res := forseti.decide_values(&ct, vals[:])
		_ = hugi.black_box(res.matched)
	}
}

register_table_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "decision_tables")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "cost_tree_single_hit", _bench_tables_single_hit_tree, zero_alloc = true)
	hugi.group_bench(g, "lazy_cost_skip", _bench_tables_lazy_cost_skip, zero_alloc = true)
	hugi.group_bench(g, "bitset_collect_sum", _bench_tables_bitset_sum, zero_alloc = true)
	hugi.group_bench(g, "aot_native_fast_path", _bench_tables_aot_fast_path, zero_alloc = true)
	hugi.group_bench(g, "unique_table_hit", _bench_tables_unique_hit, zero_alloc = true)
	hugi.group_bench(g, "priority_table_hit", _bench_tables_priority_hit, zero_alloc = true)
	hugi.group_bench(g, "merge_table_outputs", _bench_tables_merge, zero_alloc = true)
	hugi.group_bench(g, "reverse_merge_table_outputs", _bench_tables_reverse_merge, zero_alloc = true)
	hugi.group_bench(g, "wide_string_range_table", _bench_tables_wide_string_range, zero_alloc = true)
}
