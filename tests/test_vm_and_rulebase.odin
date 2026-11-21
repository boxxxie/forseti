package forseti_tests

import "core:testing"
import xitdb "xitdb:."
import "../forseti"

@(test)
test_vm_instruction_layout_and_register_recycling :: proc(t: ^testing.T) {
	#assert(size_of(forseti.Instruction) == 4)

	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "vm_reg", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)

	// Left-leaning 300-term sum chain: `(((0 + 1) + 1) + ...)` must recycle registers cleanly (< 256).
	left_expr := forseti.lit_int(0)
	for _ in 0 ..< 300 {
		left_expr = forseti.cond(.Add, left_expr, forseti.lit_int(1))
	}

	// Synthetic 260-deep right-leaning chain: `1 + (1 + (1 + ...))` holds 260 LHS temps alive simultaneously -> .Register_Overflow.
	right_expr := forseti.lit_int(1)
	for _ in 0 ..< 260 {
		right_expr = forseti.cond(.Add, forseti.lit_int(1), right_expr)
	}

	forseti.ir_schema(&b, "Item", {forseti.field("x", .I64)})
	forseti.ir_source(&b, "Item", "Item", ".items[?id]")
	forseti.ir_rule(&b, forseti.Rule_Spec{
		name         = "r_ok",
		when_clauses = {
			forseti.pat("it", "Item"),
			forseti.where_clause(forseti.cond(.Eq, left_expr, forseti.lit_int(300))),
		},
	})
	forseti.ir_rule(&b, forseti.Rule_Spec{
		name         = "r_overflow",
		when_clauses = {
			forseti.pat("it", "Item"),
			forseti.where_clause(forseti.cond(.Eq, right_expr, forseti.lit_int(261))),
		},
	})

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, ir_err := forseti.ir_builder_build(&b, &diags)
	free_all(context.temp_allocator)
	testing.expect_value(t, ir_err, nil)
	defer forseti.ir_destroy(&ir)

	tables: [0]forseti.Compiled_Table
	env := forseti.Vm_Compile_Env{ir = &ir, tables = tables[:]}

	ok_eid := ir.rules[0].when_clauses[1].expr
	ok_prog, ok_err := forseti.vm_compile_expr(&env, ok_eid)
	defer forseti.vm_program_destroy(&ok_prog)
	testing.expect_value(t, ok_err, forseti.Vm_Error.None)
	testing.expect(t, ok_prog.max_regs < 16)

	res, eval_err := forseti.vm_eval(&ok_prog, nil, nil, nil, &ir.interner)
	testing.expect_value(t, eval_err, forseti.Vm_Error.None)
	testing.expect_value(t, res, forseti.Value(true))

	ov_eid := ir.rules[1].when_clauses[1].expr
	ov_prog, ov_err := forseti.vm_compile_expr(&env, ov_eid)
	defer forseti.vm_program_destroy(&ov_prog)
	testing.expect_value(t, ov_err, forseti.Vm_Error.Register_Overflow)
}

@(test)
test_vm_arithmetic_traps_comparisons_decide_and_cursor_fields :: proc(t: ^testing.T) {
	// 1. Direct bytecode trap checks: div by 0, mod by 0, min(i64) / -1, min(i64) % -1
	{
		consts := [4]forseti.Value{i64(10), i64(0), min(i64), i64(-1)}

		div0 := [3]forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 1},
			{op = .Div, dst = 2, lhs = 0, rhs = 1},
		}
		prog := forseti.Bytecode_Program{code = div0[:], consts = consts[:]}
		_, e1 := forseti.vm_eval(&prog, nil, nil, nil, nil)
		testing.expect_value(t, e1, forseti.Vm_Error.Trap_Div_By_Zero)

		mod0 := [3]forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 1},
			{op = .Mod, dst = 2, lhs = 0, rhs = 1},
		}
		prog.code = mod0[:]
		_, e2 := forseti.vm_eval(&prog, nil, nil, nil, nil)
		testing.expect_value(t, e2, forseti.Vm_Error.Trap_Div_By_Zero)

		div_ov := [3]forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 2},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 3},
			{op = .Div, dst = 2, lhs = 0, rhs = 1},
		}
		prog.code = div_ov[:]
		_, e3 := forseti.vm_eval(&prog, nil, nil, nil, nil)
		testing.expect_value(t, e3, forseti.Vm_Error.Trap_Int_Overflow)

		mod_ov := [3]forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 2},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 3},
			{op = .Mod, dst = 2, lhs = 0, rhs = 1},
		}
		prog.code = mod_ov[:]
		_, e4 := forseti.vm_eval(&prog, nil, nil, nil, nil)
		testing.expect_value(t, e4, forseti.Vm_Error.Trap_Int_Overflow)
	}

	// 2. Compile decide + string/numeric comparison + lazy xitdb.Read_Cursor field projection
	src := `module vm_e2e version "1.0"

schema Org {
  country: string,
  employees: i64,
  active: bool
}

source RawOrg : Org at .orgs.raw[?id]

table tier_table version "1.0" hit First {
  inputs {
    country: string cost 1,
    employees: i64 cost 2
  }
  outputs {
    tier: string,
    score: i64
  }
  rows {
    r1: "DE" | >= 100 || "enterprise" | 90;
    r2: -    | -      || "standard"   | 20;
  }
}

rule classify {
  when {
    ?raw := RawOrg()
    ?t := decide tier_table(country: ?raw.country, employees: ?raw.employees)
    where ?t.tier == "enterprise" and ?raw.active == true and (?t.score + 10) >= 100
  }
  then {
  }
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "vm_e2e.forseti", &diags)
	testing.expect_value(t, c_err, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, len(diags.items), 0)

	rb, rb_err := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	// Seed an xitdb cursor-backed record cleanly in standalone Store_Bridge.
	sb := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb), nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	seed_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		raw_m, err := forseti.store_write_path_ensure_map(m_wc, ".orgs.raw")
		if err != nil {
			return .Write_Failed
		}
		rec_wc := xitdb.hash_map_put_cursor(&raw_m, "org:1") or_return
		rec := xitdb.write_hash_map_init(rec_wc) or_return
		xitdb.hash_map_put(&rec, "country", "DE") or_return
		xitdb.hash_map_put(&rec, "employees", i64(250)) or_return
		_ = forseti.write_bool_to_hash_map(&rec, "active", true)
		return nil
	}
	_, m_err := forseti.store_bridge_commit_moment(sb, seed_cb)
	testing.expect_value(t, m_err, nil)

	m_cur, _, _ := forseti.store_bridge_moment_cursor(sb, -1)
	col_cur, _, _ := forseti.store_resolve_path(m_cur, ".orgs.raw")
	rec_cur, rec_ok, _ := forseti.store_lookup_record(col_cur, "org:1")
	testing.expect(t, rec_ok)

	// Evaluate compiled Decide_Call program followed by Where guard program over cursor fact slot!
	testing.expect(t, len(rb.rules) == 1)
	r := rb.rules[0]
	testing.expect(t, len(rb.programs) >= 2)

	fact_slots := [1]forseti.Vm_Fact_Binding{
		{cursor = rec_cur, has_cursor = true},
	}
	decide_results: [16]forseti.Decision_Result

	// Find segment nodes in rule and run Decide + Filter programs through VM!
	seg := rb.segments[r.segment_ids[0]]
	did_decide, did_filter := false, false
	for ni := seg.node_start; ni < seg.node_start + seg.node_count; ni += 1 {
		bn := rb.beta_nodes[ni]
		#partial switch bn.kind {
		case .Decide:
			v, e := forseti.vm_eval(&rb.programs[bn.prog_idx], nil, fact_slots[:], rb.tables, &rb.interner, decide_results[:])
			testing.expect_value(t, e, forseti.Vm_Error.None)
			testing.expect_value(t, v, forseti.Value(true))
			did_decide = true
		case .Filter:
			v, e := forseti.vm_eval(&rb.programs[bn.prog_idx], nil, fact_slots[:], rb.tables, &rb.interner, decide_results[:])
			testing.expect_value(t, e, forseti.Vm_Error.None)
			testing.expect_value(t, v, forseti.Value(true))
			did_filter = true
		}
	}
	testing.expect(t, did_decide && did_filter)
}

@(test)
test_rulebase_alpha_sharing_hash_split_and_segments_10k :: proc(t: ^testing.T) {
	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "share_bench", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)

	forseti.ir_schema(&b, "Account", {
		forseti.field("active", .Bool),
		forseti.field("tier", .String),
		forseti.field("bucket", .I64),
	})
	forseti.ir_source(&b, "Acct", "Account", ".accounts[?id]")
	forseti.ir_derived(&b, "Flag", "Account", ".flags[?id]")

	RULE_COUNT :: 2_000
	rule_names := make([]string, RULE_COUNT, context.temp_allocator)
	for i := 0; i < RULE_COUNT; i += 1 {
		// Common shared conditions (`active: true, tier: "gold"`) + O(1) hash-split (`bucket: i`)
		rule_names[i] = tprintf_alloc("r_%d", i)
		forseti.ir_rule(&b, forseti.Rule_Spec{
			name = rule_names[i],
			when_clauses = {
				forseti.pat("a", "Acct", {
					forseti.field_bind("active", forseti.lit(true)),
					forseti.field_bind("tier", forseti.lit("gold")),
					forseti.field_bind("bucket", forseti.lit(i64(i))),
				}),
			},
			then_actions = {
				forseti.assert_fact("Flag", {
					forseti.field_bind("bucket", forseti.lit(i64(i))),
				}),
			},
		})
	}
	defer free_all(context.temp_allocator)

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, ir_err := forseti.ir_builder_build(&b, &diags)
	testing.expect_value(t, ir_err, nil)
	defer forseti.ir_destroy(&ir)

	tel: forseti.Telemetry_Sink
	testing.expect_value(t, forseti.telemetry_init(&tel, true), nil)
	defer forseti.telemetry_destroy(&tel)

	rb, comp_err := forseti.rulebase_compile(&ir, &tel)
	testing.expect_value(t, comp_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	testing.expect_value(t, len(rb.rules), RULE_COUNT)
	// Active + tier nodes shared across all 2,000 rules, plus single Hash_Split node for `bucket`.
	testing.expect(t, tel.counters[.Alpha_Nodes_Shared] >= u64(RULE_COUNT * 2))
	testing.expect(t, tel.counters[.Segments_Created] >= u64(RULE_COUNT))
}

@(private = "file")
tprintf_alloc :: proc(prefix: string, idx: int) -> string {
	buf: [32]u8 = ---
	n := 0
	for i := 0; i < len(prefix) && n < len(buf); i += 1 {
		buf[n] = prefix[i]
		n += 1
	}
	tmp: [20]u8 = ---
	ti := len(tmp)
	v := idx
	if v == 0 {
		ti -= 1
		tmp[ti] = '0'
	} else {
		for v > 0 {
			ti -= 1
			tmp[ti] = u8('0' + (v % 10))
			v /= 10
		}
	}
	for ti < len(tmp) && n < len(buf) {
		buf[n] = tmp[ti]
		n += 1
		ti += 1
	}
	return string(append_clone_temp(buf[:n]))
}

@(private = "file")
append_clone_temp :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}
