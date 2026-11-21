package forseti_tests

import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import "../forseti"

@(private = "file")
oracle_eval_cell :: proc(ir: ^forseti.Rulebase_IR, eid: forseti.Expr_Id, v: forseti.Value) -> bool {
	e := ir.exprs[eid]
	if e.kind == .Wildcard {
		return true
	}
	if e.kind == .Binary && (e.binary_op == .And || e.binary_op == .Or) {
		l := oracle_eval_cell(ir, e.lhs, v)
		r := oracle_eval_cell(ir, e.rhs, v)
		return (l && r) if e.binary_op == .And else (l || r)
	}
	switch val in v {
	case bool:
		if e.kind == .Lit_Bool {
			return val == e.bool_val
		}
	case i64:
		if e.kind == .Lit_Int {
			return val == e.int_val
		}
		if e.kind == .Cell_Cmp {
			rhs := ir.exprs[e.rhs].int_val
			#partial switch e.binary_op {
			case .Eq:
				return val == rhs
			case .Neq:
				return val != rhs
			case .Lt:
				return val < rhs
			case .Lte:
				return val <= rhs
			case .Gt:
				return val > rhs
			case .Gte:
				return val >= rhs
			}
		}
		if e.kind == .Range {
			lo := ir.exprs[e.lhs].int_val
			hi := ir.exprs[e.rhs].int_val
			return (val >= lo && val <= hi) if e.inclusive else (val >= lo && val < hi)
		}
		if e.kind == .In_List {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				if oracle_eval_cell(ir, ir.extra_exprs[i], v) {
					return true
				}
			}
			return false
		}
	case forseti.String_Id:
		if e.kind == .Lit_String {
			return forseti.ir_string(ir, val) == forseti.ir_string(ir, e.str_id)
		}
		if e.kind == .In_List {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				if oracle_eval_cell(ir, ir.extra_exprs[i], v) {
					return true
				}
			}
			return false
		}
	case i32, f64, forseti.Entity_Id, forseti.Time_Ns, forseti.Enum_Val:
		return false
	}
	return false
}

@(test)
prop_compiled_table_matches_bruteforce_oracle :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 15 * time.Second)
	rng_state := rand.create(t.seed)
	context.random_generator = rand.default_random_generator(&rng_state)

	policies := []forseti.Hit_Policy{
		.First,
		.Collect,
		.Collect_Sum,
		.Collect_Min,
		.Collect_Max,
		.Collect_Count,
		.Merge,
		.Reverse_Merge,
	}

	for iter in 0 ..< 40 {
		defer free_all(context.temp_allocator)

		policy := policies[iter % len(policies)]
		row_count := 5 + rand.int_max(280)

		b: forseti.Ir_Builder
		testing.expect_value(t, forseti.ir_builder_init(&b, "oracle", "1.0"), nil)
		defer forseti.ir_builder_destroy(&b)

		rows := make([]forseti.Table_Row_Spec, row_count, context.temp_allocator)
		str_choices := []string{"alpha", "beta", "gamma", "delta"}

		for r in 0 ..< row_count {
			c0 := forseti.wildcard() if rand.int_max(3) == 0 else forseti.lit(rand.int_max(2) == 1)
			c1_kind := rand.int_max(4)
			c1: forseti.Expr_Spec
			switch c1_kind {
			case 0:
				c1 = forseti.wildcard()
			case 1:
				c1 = forseti.cond(.Gte, i64(rand.int_max(100)))
			case 2:
				c1 = forseti.cond(.Lt, i64(1 + rand.int_max(100)))
			case:
				c1 = forseti.lit(i64(rand.int_max(25)))
			}
			c2 := forseti.wildcard() if rand.int_max(2) == 0 else forseti.lit(str_choices[rand.int_max(len(str_choices))])

			o0: forseti.Expr_Spec
			o1: forseti.Expr_Spec
			if policy == .Merge || policy == .Reverse_Merge {
				o0 = forseti.wildcard() if rand.int_max(3) == 0 else forseti.lit(i64(1 + rand.int_max(500)))
				o1 = forseti.wildcard() if rand.int_max(3) == 0 else forseti.lit(i64(1 + rand.int_max(500)))
			} else {
				o0 = forseti.lit(i64(1 + rand.int_max(500)))
				o1 = forseti.lit(i64(r))
			}

			rows[r] = forseti.Table_Row_Spec{
				id      = fmt.tprintf("r%d", r),
				cells   = {c0, c1, c2},
				outputs = {o0, o1},
			}
		}

		forseti.ir_table(&b, forseti.Table_Spec{
			name       = "tbl",
			version    = "1.0",
			hit_policy = policy,
			inputs     = {
				{name = "b", type = .Bool, cost = 1},
				{name = "n", type = .I64, cost = 5},
				{name = "s", type = .String, cost = 10},
			},
			outputs    = {
				{name = "o0", type = .I64},
				{name = "o1", type = .I64},
			},
			rows       = rows,
		})

		diags: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&diags), nil)
		defer forseti.diag_list_destroy(&diags)

		ir, ir_err := forseti.ir_builder_build(&b, &diags)
		testing.expect_value(t, ir_err, nil)
		defer forseti.ir_destroy(&ir)

		ct, c_err := forseti.compile_table(&ir, 0)
		testing.expect_value(t, c_err, nil)
		defer forseti.compiled_table_destroy(&ct)

		tbl := ir.tables[0]
		probe_strs := []string{"alpha", "beta", "gamma", "delta", "other_unseen"}

		for q in 0 ..< 25 {
			bval := rand.int_max(2) == 1
			nval := i64(rand.int_max(120))
			sstr := probe_strs[rand.int_max(len(probe_strs))]

			in_vals := [3]forseti.Value{
				bval,
				nval,
				forseti.compiled_table_string_value(&ct, sstr),
			}
			// Mirror sstr into ir.interner lookup for oracle comparison
			ir_sid, has_ir_s := ir.interner.lookup[sstr]
			ir_sval := ir_sid if has_ir_s else forseti.String_Id(max(u32))
			oracle_vals := [3]forseti.Value{bval, nval, ir_sval}

			// Verify ZERO heap allocations during decide()
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			prev_alloc := context.allocator
			context.allocator = mem.tracking_allocator(&track)
			res := forseti.decide_values(&ct, in_vals[:])
			context.allocator = prev_alloc
			alloc_count := len(track.allocation_map)
			mem.tracking_allocator_destroy(&track)
			if !testing.expectf(t, alloc_count == 0, "seed=%d iter=%d q=%d decide allocated %d times", t.seed, iter, q, alloc_count) {
				return
			}

			// Brute-force oracle
			matched := make([dynamic]u32, 0, 16, context.temp_allocator)
			for r_idx in 0 ..< len(tbl.rows) {
				row := tbl.rows[r_idx]
				if oracle_eval_cell(&ir, row.cells[0], oracle_vals[0]) &&
					oracle_eval_cell(&ir, row.cells[1], oracle_vals[1]) &&
					oracle_eval_cell(&ir, row.cells[2], oracle_vals[2]) {
					append(&matched, u32(r_idx))
					if policy == .First {
						break
					}
				}
			}

			expected_matched := len(matched) > 0
			if !testing.expectf(t, res.matched == expected_matched, "seed=%d iter=%d q=%d policy=%v matched=%v expected=%v", t.seed, iter, q, policy, res.matched, expected_matched) {
				return
			}
			if !testing.expectf(t, res.matched_row_count == u32(len(matched)), "seed=%d iter=%d q=%d policy=%v count=%d expected=%d", t.seed, iter, q, policy, res.matched_row_count, len(matched)) {
				return
			}
			if !expected_matched {
				continue
			}

			#partial switch policy {
			case .First, .Collect:
				first_row := tbl.rows[matched[0]]
				exp_o0 := ir.exprs[first_row.outputs[0]].int_val
				if !testing.expectf(t, res.outputs[0].(i64) == exp_o0, "seed=%d iter=%d q=%d o0 mismatch", t.seed, iter, q) {
					return
				}
			case .Collect_Count:
				if !testing.expectf(t, res.outputs[0].(i64) == i64(len(matched)), "seed=%d iter=%d q=%d count out mismatch", t.seed, iter, q) {
					return
				}
			case .Collect_Sum:
				sum: i64 = 0
				for r_idx in matched {
					sum += ir.exprs[tbl.rows[r_idx].outputs[0]].int_val
				}
				if !testing.expectf(t, res.outputs[0].(i64) == sum, "seed=%d iter=%d q=%d sum mismatch", t.seed, iter, q) {
					return
				}
			case .Collect_Min:
				mn := ir.exprs[tbl.rows[matched[0]].outputs[0]].int_val
				for r_idx in matched[1:] {
					mn = min(mn, ir.exprs[tbl.rows[r_idx].outputs[0]].int_val)
				}
				if !testing.expectf(t, res.outputs[0].(i64) == mn, "seed=%d iter=%d q=%d min mismatch", t.seed, iter, q) {
					return
				}
			case .Collect_Max:
				mx := ir.exprs[tbl.rows[matched[0]].outputs[0]].int_val
				for r_idx in matched[1:] {
					mx = max(mx, ir.exprs[tbl.rows[r_idx].outputs[0]].int_val)
				}
				if !testing.expectf(t, res.outputs[0].(i64) == mx, "seed=%d iter=%d q=%d max mismatch", t.seed, iter, q) {
					return
				}
			case .Merge, .Reverse_Merge:
				for oc in 0 ..< 2 {
					has_exp := false
					exp_v: i64 = 0
					if policy == .Merge {
						for r_idx in matched {
							oe := ir.exprs[tbl.rows[r_idx].outputs[oc]]
							if oe.kind != .Wildcard {
								has_exp = true
								exp_v = oe.int_val
								break
							}
						}
					} else {
						for mi := len(matched) - 1; mi >= 0; mi -= 1 {
							oe := ir.exprs[tbl.rows[matched[mi]].outputs[oc]]
							if oe.kind != .Wildcard {
								has_exp = true
								exp_v = oe.int_val
								break
							}
						}
					}
					if !testing.expectf(t, res.output_set[oc] == has_exp, "seed=%d iter=%d q=%d merge set mismatch", t.seed, iter, q) {
						return
					}
					if has_exp {
						if !testing.expectf(t, res.outputs[oc].(i64) == exp_v, "seed=%d iter=%d q=%d merge val mismatch", t.seed, iter, q) {
							return
						}
					}
				}
			}
			_ = strings.Builder{}
		}
	}
}
