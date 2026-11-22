package forseti_tests

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import xitdb "xitdb:."
import "../forseti"

_reg_compile_source :: proc(
	t: ^testing.T,
	src: string,
	name := "reg.forseti",
	expect_clean := true,
	loc := #caller_location,
) -> (
	ir: forseti.Rulebase_IR,
	diags: forseti.Diagnostic_List,
	ok: bool,
) {
	testing.expect_value(t, forseti.diag_list_init(&diags), nil, loc = loc)
	compiled, c_err := forseti.compile_source(src, name, &diags)
	testing.expect_value(t, c_err, nil, loc = loc)
	if c_err != nil {
		forseti.ir_destroy(&compiled)
		forseti.diag_list_destroy(&diags)
		return {}, {}, false
	}
	a_err := forseti.analyze_ir(&compiled, &diags)
	testing.expect_value(t, a_err, nil, loc = loc)
	if expect_clean {
		testing.expectf(t, diags.error_count == 0, "expected 0 errors in %s, got %d", name, diags.error_count, loc = loc)
	}
	return compiled, diags, true
}

_reg_build_session :: proc(
	t: ^testing.T,
	ir: ^forseti.Rulebase_IR,
	cfg := forseti.Session_Config{},
	loc := #caller_location,
) -> (
	rb: ^forseti.Rulebase,
	sess: ^forseti.Session,
	ok: bool,
) {
	out_rb := new(forseti.Rulebase)
	rb_err: forseti.Compile_Error
	out_rb^, rb_err = forseti.rulebase_compile(ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None, loc = loc)
	if rb_err != .None {
		forseti.rulebase_destroy(out_rb)
		free(out_rb)
		return nil, nil, false
	}
	s := new(forseti.Session)
	s_err := forseti.session_init(s, out_rb, cfg)
	testing.expect_value(t, s_err, forseti.Session_Error.None, loc = loc)
	if s_err != .None {
		forseti.session_destroy(s)
		free(s)
		forseti.rulebase_destroy(out_rb)
		free(out_rb)
		return nil, nil, false
	}
	return out_rb, s, true
}

_reg_has_diag_code :: proc(diags: ^forseti.Diagnostic_List, code: forseti.Diag_Code) -> bool {
	for d in diags.items {
		if d.code == code {
			return true
		}
	}
	return false
}

_reg_str :: proc(s: ^forseti.Session, txt: string) -> forseti.Value {
	sid, _ := forseti.intern_session_string(&s.rb.interner, &s.interner, txt)
	return sid
}

@(test)
test_reg_parser_table_cell_precedence_and_bounds :: proc(t: ^testing.T) {
	// 1. BUG-003: `or` must bind looser than `and` inside table cells ("A" or ("B" and "C"))
	{
		src := `module cell_prec version "1.0"
table gate version "1.0" hit First {
  inputs { code: string cost 1 }
  outputs { tag: string }
  rows {
    r1: "A" or "B" and "C" || "hit";
    r2: -                  || "miss";
  }
}`
		ir, diags, ok := _reg_compile_source(t, src, "cell_prec.forseti")
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		if !ok {
			return
		}
		ct, c_err := forseti.compile_table(&ir, 0)
		testing.expect_value(t, c_err, nil)
		defer forseti.compiled_table_destroy(&ct)

		a_id, has_a := ct.interner.lookup["A"]
		b_id, has_b := ct.interner.lookup["B"]
		testing.expect(t, has_a && has_b)

		res_a := forseti.decide(&ct, {values = {a_id}})
		testing.expect(t, res_a.matched)
		testing.expect(t, res_a.output_set[0])
		out_a, _ := res_a.outputs[0].(forseti.String_Id)
		testing.expect_value(t, forseti.interner_get(&ct.interner, out_a), "hit")

		res_b := forseti.decide(&ct, {values = {b_id}})
		testing.expect(t, res_b.matched)
		out_b, _ := res_b.outputs[0].(forseti.String_Id)
		testing.expect_value(t, forseti.interner_get(&ct.interner, out_b), "miss")
	}

	// 2. BUG-019 + BUG-055: oversized column cost and rule salience emit parse errors instead of truncating
	{
		src := `module overflow_bounds version "1.0"
table t version "1.0" hit First {
  inputs { x: i64 cost 5000000000 }
  outputs { o: i64 }
  rows { r1: 1 || 1; }
}
rule r salience 5000000000 {
  when { ?_g := decide t(x: 1) }
}`
		ir, diags, _ := _reg_compile_source(t, src, "bounds.forseti", expect_clean = false)
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		testing.expect(t, diags.error_count >= 2)
		testing.expect(t, _reg_has_diag_code(&diags, .E1002))
	}

	// 3. BUG-048 + BUG-054: backslash-newline inside string advances line numbers; malformed action is not lowered as .Assert
	{
		src := "module esc_line_and_bad_act version \"1.0\"\nrule r {\n  when { where \"line3\\\nline4\" != \"x\" }\n  then { ??? }\n}\n"
		ir, diags, _ := _reg_compile_source(t, src, "esc.forseti", expect_clean = false)
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		testing.expect(t, diags.error_count >= 2)
		saw_line3_err := false
		saw_line5_err := false
		for d in diags.items {
			if d.line == 3 {
				saw_line3_err = true
			}
			if d.line >= 5 {
				saw_line5_err = true
			}
		}
		testing.expect(t, saw_line3_err)
		testing.expect(t, saw_line5_err)
		testing.expect_value(t, len(ir.rules), 1)
		testing.expect_value(t, len(ir.rules[0].then_actions), 0)
	}
}

@(test)
test_reg_dsl_builder_enum_selector_and_ir_eq :: proc(t: ^testing.T) {
	build_ir :: proc(enum_variant: string) -> (forseti.Rulebase_IR, forseti.Diagnostic_List) {
		b: forseti.Ir_Builder
		_ = forseti.ir_builder_init(&b, "builder_reg", "1.0")
		defer forseti.ir_builder_destroy(&b)

		_ = forseti.ir_schema(&b, "Org", {forseti.field("id", .String)})
		_ = forseti.ir_source(&b, "OrgSrc", "Org", "orgs[?id]")
		_ = forseti.ir_table(&b, forseti.Table_Spec{
			name       = "tier_tbl",
			version    = "1.0",
			hit_policy = .First,
			inputs = {
				{name = "band", type = .Enum, cost = 1, variants = {"low", enum_variant}},
			},
			outputs = {
				{name = "verdict", type = .Enum, variants = {"deny", "allow"}},
			},
			rows = {
				{id = "r1", cells = {forseti.lit("low")}, outputs = {forseti.lit("deny")}},
				{id = "r2", cells = {forseti.wildcard()}, outputs = {forseti.lit("allow")}},
			},
		})
		_ = forseti.ir_rule(&b, forseti.Rule_Spec{
			name = "where_false_keep",
			when_clauses = {
				forseti.pat("o", "OrgSrc", {forseti.field_bind("id", forseti.vref("id"))}),
				forseti.where_clause(forseti.lit(false)),
			},
		})
		_ = forseti.ir_query(&b, forseti.Query_Spec{
			name   = "by_region",
			params = {forseti.field("reg", .Enum, {"us", "eu"})},
			when_clauses = {
				forseti.pat("o", "OrgSrc", {forseti.field_bind("id", forseti.vref("reg"))}),
			},
		})
		diags: forseti.Diagnostic_List
		_ = forseti.diag_list_init(&diags)
		ir, _ := forseti.ir_builder_build(&b, &diags)
		return ir, diags
	}

	ir1, d1 := build_ir("high")
	defer {
		forseti.ir_destroy(&ir1)
		forseti.diag_list_destroy(&d1)
	}
	ir2, d2 := build_ir("critical")
	defer {
		forseti.ir_destroy(&ir2)
		forseti.diag_list_destroy(&d2)
	}

	testing.expect_value(t, d1.error_count, 0)
	// BUG-035: un-dotted leading selector "orgs[?id]" parses both segments
	testing.expect_value(t, len(ir1.bindings[0].segments), 2)
	testing.expect_value(t, ir1.bindings[0].segments[0].kind, forseti.Selector_Seg_Kind.Field)
	testing.expect_value(t, forseti.ir_string(&ir1, ir1.bindings[0].segments[0].text), "orgs")
	testing.expect_value(t, ir1.bindings[0].segments[1].kind, forseti.Selector_Seg_Kind.Var_Key)

	// BUG-009 & BUG-034: table input/output & query param Enum_Def ref_id and variants preserved
	testing.expect_value(t, ir1.tables[0].inputs[0].type.kind, forseti.Type_Kind.Enum)
	in_ref := ir1.tables[0].inputs[0].type.ref_id
	testing.expect(t, int(in_ref) < len(ir1.enums))
	testing.expect_value(t, len(ir1.enums[in_ref].variants), 2)

	out_ref := ir1.tables[0].outputs[0].type.ref_id
	testing.expect(t, int(out_ref) < len(ir1.enums))
	testing.expect_value(t, len(ir1.enums[out_ref].variants), 2)

	q_ref := ir1.queries[0].params[0].type.ref_id
	testing.expect(t, int(q_ref) < len(ir1.enums))
	testing.expect_value(t, len(ir1.enums[q_ref].variants), 2)

	// BUG-052: `where false` preserved as concrete Expr_Id instead of INVALID_EXPR
	testing.expect(t, ir1.rules[0].when_clauses[1].expr != forseti.INVALID_EXPR)

	// BUG-053: enum variant change makes ir_structurally_equal false
	testing.expect(t, forseti.ir_structurally_equal(&ir1, &ir1))
	testing.expect(t, !forseti.ir_structurally_equal(&ir1, &ir2))
}

@(test)
test_reg_sema_i32_symmetry_shadowing_and_w2003 :: proc(t: ^testing.T) {
	// 1. BUG-021, BUG-022, BUG-023, BUG-050 on clean/self-join policy
	src := `module sema_reg version "1.0"
schema Pair { id: string, left: i32, right: i32 }
schema Other { tag: string }
schema Out { v: i32 }

source PSrc : Pair at .pairs[?id]
source OSrc : Other at .others[?id]
derived OutD : Out at .out[?id]

table age_gate version "1.0" hit First {
  inputs { age: i32 cost 1 }
  outputs { ok: bool }
  rows {
    r1: 0..100 || true;
    r2: -      || false;
  }
}

rule sym_and_shadow {
  when {
    ?_p := PSrc(left: ?x)
    where 0 < ?x
    where (10 + ?x) > 10
    not {
      ?_inner := PSrc(left: ?x)
      where ?x == 999
    }
    ?_g := decide age_gate(age: ?x)
  }
  then {
    assert OutD(v: ?x)
  }
}

rule self_join_cartesian {
  when {
    ?_o := OSrc(tag: ?_ot)
    ?_p := PSrc(left: ?dup, right: ?dup)
  }
  then {
    assert OutD(v: ?dup)
  }
}`
	ir, diags, ok := _reg_compile_source(t, src, "sema_reg.forseti")
	defer {
		forseti.ir_destroy(&ir)
		forseti.diag_list_destroy(&diags)
	}
	if !ok {
		return
	}
	testing.expect(t, _reg_has_diag_code(&diags, .W2003))

	// 2. BUG-040 + BUG-039: unknown schema leaves bind.schema_id == INVALID_ID and INVALID_EXPR table output doesn't panic
	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "bad_schema", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)
	_ = forseti.ir_source(&b, "BadSrc", "NoSuchSchema", ".bad[?id]")
	_ = forseti.ir_table(&b, forseti.Table_Spec{
		name       = "tbl",
		version    = "1.0",
		hit_policy = .First,
		inputs     = {{name = "x", type = .I64}},
		outputs    = {{name = "y", type = .I64}},
		rows       = {{id = "r1", cells = {forseti.wildcard()}, outputs = {}}},
	})
	d2: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&d2), nil)
	defer forseti.diag_list_destroy(&d2)
	ir2, ir2_err := forseti.ir_builder_build(&b, &d2)
	testing.expect_value(t, ir2_err, nil)
	defer forseti.ir_destroy(&ir2)

	// Force row.outputs[0] = INVALID_EXPR to exercise BUG-039 guard
	inv_outs := []forseti.Expr_Id{forseti.INVALID_EXPR}
	ir2.tables[0].rows[0].outputs = inv_outs
	testing.expect_value(t, forseti.analyze_ir(&ir2, &d2), nil)
	testing.expect_value(t, ir2.bindings[0].schema_id, forseti.Schema_Id(forseti.INVALID_ID))
	testing.expect(t, _reg_has_diag_code(&d2, .E2001))
}

@(test)
test_reg_residual_pattern_constraints_and_query_params :: proc(t: ^testing.T) {
	// 1. BUG-036: compiling zeroed Rulebase_IR with empty interner does not panic
	{
		empty_ir: forseti.Rulebase_IR
		rb_empty, c_err := forseti.rulebase_compile(&empty_ir)
		testing.expect_value(t, c_err, forseti.Compile_Error.None)
		forseti.rulebase_destroy(&rb_empty)
	}

	// 2. BUG-004: pattern residual constraints (.Cell_Cmp, .Range, .In_List, expr referencing prior var) filter at runtime
	{
		b: forseti.Ir_Builder
		testing.expect_value(t, forseti.ir_builder_init(&b, "res_pat", "1.0"), nil)
		defer forseti.ir_builder_destroy(&b)

		_ = forseti.ir_schema(&b, "Base", {forseti.field("id", .String), forseti.field("b", .I64)})
		_ = forseti.ir_schema(&b, "Item", {forseti.field("id", .String), forseti.field("score", .I64), forseti.field("val", .I64), forseti.field("tag", .String)})
		_ = forseti.ir_schema(&b, "Hit", {forseti.field("id", .String)})
		_ = forseti.ir_source(&b, "BaseSrc", "Base", ".base[?id]")
		_ = forseti.ir_source(&b, "ItemSrc", "Item", ".items[?id]")
		_ = forseti.ir_derived(&b, "HitD", "Hit", ".hits[?id]")

		_ = forseti.ir_rule(&b, forseti.Rule_Spec{
			name = "residual_filter",
			when_clauses = {
				forseti.pat("base", "BaseSrc", {
					forseti.field_bind("id", forseti.vref("id")),
					forseti.field_bind("b", forseti.vref("bv")),
				}),
				forseti.pat("item", "ItemSrc", {
					forseti.field_bind("id", forseti.vref("id")),
					forseti.field_bind("score", forseti.cond(.Add, forseti.vref("bv"), forseti.lit(i64(5)))),
					forseti.field_bind("val", forseti.Expr_Spec{kind = .Range, inclusive = true, children = {forseti.lit(i64(10)), forseti.lit(i64(20))}}),
					forseti.field_bind("tag", forseti.Expr_Spec{kind = .In_List, children = {forseti.lit("A"), forseti.lit("B")}}),
				}),
			},
			then_actions = {
				forseti.assert_fact("HitD", {forseti.field_bind("id", forseti.vref("id"))}),
			},
		})
		_ = forseti.ir_query(&b, forseti.Query_Spec{
			name = "q_res",
			when_clauses = {
				forseti.pat("item", "ItemSrc", {
					forseti.field_bind("id", forseti.vref("id")),
					forseti.field_bind("score", forseti.cond(.Gt, i64(10))),
				}),
			},
		})

		diags: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&diags), nil)
		defer forseti.diag_list_destroy(&diags)
		ir, b_err := forseti.ir_builder_build(&b, &diags)
		testing.expect_value(t, b_err, nil)
		defer forseti.ir_destroy(&ir)

		rb, sess, ok := _reg_build_session(t, &ir)
		defer {
			if sess != nil {
				forseti.session_destroy(sess)
				free(sess)
			}
			if rb != nil {
				forseti.rulebase_destroy(rb)
				free(rb)
			}
		}
		if !ok {
			return
		}

		// Only k_ok satisfies all residual constraints: b+5 == 15, val in 10..=20, tag in ["A","B"]
		_, _ = forseti.session_insert_fact(sess, "BaseSrc", "b_ok", {_reg_str(sess, "k_ok"), i64(10)})
		_, _ = forseti.session_insert_fact(sess, "ItemSrc", "i_ok", {_reg_str(sess, "k_ok"), i64(15), i64(20), _reg_str(sess, "B")})
		// Fails expr (score 14 != 15)
		_, _ = forseti.session_insert_fact(sess, "BaseSrc", "b_bad1", {_reg_str(sess, "k_bad1"), i64(10)})
		_, _ = forseti.session_insert_fact(sess, "ItemSrc", "i_bad1", {_reg_str(sess, "k_bad1"), i64(14), i64(15), _reg_str(sess, "A")})
		// Fails range (val 25 not in 10..=20)
		_, _ = forseti.session_insert_fact(sess, "BaseSrc", "b_bad2", {_reg_str(sess, "k_bad2"), i64(10)})
		_, _ = forseti.session_insert_fact(sess, "ItemSrc", "i_bad2", {_reg_str(sess, "k_bad2"), i64(15), i64(25), _reg_str(sess, "A")})
		// Fails in_list (tag "C")
		_, _ = forseti.session_insert_fact(sess, "BaseSrc", "b_bad3", {_reg_str(sess, "k_bad3"), i64(10)})
		_, _ = forseti.session_insert_fact(sess, "ItemSrc", "i_bad3", {_reg_str(sess, "k_bad3"), i64(15), i64(15), _reg_str(sess, "C")})

		fired, f_err := forseti.session_fire(sess)
		testing.expect_value(t, f_err, forseti.Session_Error.None)
		testing.expect_value(t, fired, u64(1))

		hit_bidx, _ := forseti.session_find_binding(sess, "HitD")
		alive_hits := 0
		for &f in sess.facts {
			if f.alive && f.binding_idx == hit_bidx {
				alive_hits += 1
				sid, _ := f.fields[0].(forseti.String_Id)
				testing.expect_value(t, forseti.session_string(sess, sid), "k_ok")
			}
		}
		testing.expect_value(t, alive_hits, 1)

		qres: forseti.Query_Result
		testing.expect_value(t, forseti.session_query(sess, "q_res", nil, &qres), forseti.Session_Error.None)
		defer forseti.query_result_destroy(&qres)
		testing.expect_value(t, len(qres.rows), 4)
	}

	// 3. BUG-011 + BUG-037: query ?param resolved in rb.interner, and subnetwork tracks outer decide var dependency
	{
		src := `module qparam_and_decide_outer version "1.0"
schema InRec { id: string, tag: string, score: i64 }
schema Blocker { tier: string }
schema Approved { id: string, tier: string }

source In : InRec at .records[?id]
source Block : Blocker at .block[?id]
derived Out : Approved at .out[?id]

table tier_tbl version "1.0" hit First {
  inputs { score: i64 cost 1 }
  outputs { tier: string }
  rows {
    r_hi: >= 80 || "gold";
    r_lo: -     || "silver";
  }
}

rule approve_unblocked {
  when {
    ?_i := In(id: ?id, tag: ?_t, score: ?sc)
    ?d := decide tier_tbl(score: ?sc)
    not {
      ?_b := Block(tier: ?d.tier)
    }
  }
  then {
    assert Out(id: ?id, tier: ?d.tier)
  }
}

query find_in_by_tag(qtag: string) {
  ?_i := In(id: ?id, tag: ?qtag)
}`
		ir, diags, ok := _reg_compile_source(t, src, "qparam.forseti")
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		if !ok {
			return
		}
		rb, sess, ok2 := _reg_build_session(t, &ir)
		defer {
			if sess != nil {
				forseti.session_destroy(sess)
				free(sess)
			}
			if rb != nil {
				forseti.rulebase_destroy(rb)
				free(rb)
			}
		}
		if !ok2 {
			return
		}

		testing.expect(t, len(rb.subnetworks) >= 1)
		testing.expect(t, rb.subnetworks[0].uses_outer_fact)
		testing.expect(t, len(rb.queries) == 1 && len(rb.queries[0].var_names) >= 1)
		saw_qtag := false
		for vn in rb.queries[0].var_names {
			if forseti.interner_get(&rb.interner, vn) == "?qtag" {
				saw_qtag = true
				break
			}
		}
		testing.expect(t, saw_qtag)

		_, _ = forseti.session_insert_fact(sess, "In", "o1", {_reg_str(sess, "o1"), _reg_str(sess, "retail"), i64(90)})
		_, _ = forseti.session_insert_fact(sess, "In", "o2", {_reg_str(sess, "o2"), _reg_str(sess, "retail"), i64(50)})
		_, _ = forseti.session_insert_fact(sess, "Block", "blk", {_reg_str(sess, "gold")})
		fired, f_err := forseti.session_fire(sess)
		testing.expect_value(t, f_err, forseti.Session_Error.None)
		testing.expect_value(t, fired, u64(1))

		qres: forseti.Query_Result
		testing.expect_value(t, forseti.session_query(sess, "find_in_by_tag", {{name = "qtag", value = _reg_str(sess, "retail")}}, &qres), forseti.Session_Error.None)
		defer forseti.query_result_destroy(&qres)
		testing.expect_value(t, len(qres.rows), 2)
		testing.expect(t, len(qres.rows[0].var_names) >= 1)
	}
}

@(test)
test_reg_multi_head_stratification_min_stratum :: proc(t: ^testing.T) {
	// 1. BUG-005: multi-head rule asserting Low (stratum 0) and High (stratum 1) must be placed in stratum 0
	src := `module multi_head version "1.0"
schema Flag { id: string }

source Trig : Flag at .trig[?id]
derived Low : Flag at .low[?id]
derived High : Flag at .high[?id]

rule multi {
  when { ?_t := Trig(id: ?id) }
  then {
    assert Low(id: ?id)
    assert High(id: "from_multi")
  }
}

rule fallback_high {
  when {
    ?_t := Trig(id: ?id)
    not Low(id: ?id)
  }
  then {
    assert High(id: "from_neg")
  }
}`
	ir, diags, ok := _reg_compile_source(t, src, "multi_head.forseti")
	defer {
		forseti.ir_destroy(&ir)
		forseti.diag_list_destroy(&diags)
	}
	if !ok {
		return
	}
	rb, sess, ok2 := _reg_build_session(t, &ir)
	defer {
		if sess != nil {
			forseti.session_destroy(sess)
			free(sess)
		}
		if rb != nil {
			forseti.rulebase_destroy(rb)
			free(rb)
		}
	}
	if !ok2 {
		return
	}
	testing.expect(t, rb.rules[0].stratum < rb.rules[1].stratum)

	_, _ = forseti.session_insert_fact(sess, "Trig", "t1", {_reg_str(sess, "t1")})
	_, f_err := forseti.session_fire(sess)
	testing.expect_value(t, f_err, forseti.Session_Error.None)

	high_bidx, _ := forseti.session_find_binding(sess, "High")
	high_keys := make([dynamic]string, 0, 2, context.temp_allocator)
	for &f in sess.facts {
		if f.alive && f.binding_idx == high_bidx {
			sid, _ := f.fields[0].(forseti.String_Id)
			append(&high_keys, forseti.session_string(sess, sid))
		}
	}
	testing.expect_value(t, len(high_keys), 1)
	if len(high_keys) == 1 {
		testing.expect_value(t, high_keys[0], "from_multi")
	}

	// 2. BUG-025: unstratified cycle returns error cleanly with zero memory leaks
	bad_src := `module bad_cycle version "1.0"
schema S { id: string }
source Trig : S at .trig[?id]
derived A : S at .a[?id]
rule self_neg {
  when {
    ?_t := Trig(id: ?id)
    not A(id: ?id)
  }
  then { assert A(id: ?id) }
}`
	bad_ir, bad_diags, bad_ok := _reg_compile_source(t, bad_src, "bad_cycle.forseti", expect_clean = false)
	defer {
		forseti.ir_destroy(&bad_ir)
		forseti.diag_list_destroy(&bad_diags)
	}
	testing.expect(t, bad_ok)
	testing.expect(t, _reg_has_diag_code(&bad_diags, .E4001))
	bad_rb, bad_comp_err := forseti.rulebase_compile(&bad_ir)
	defer forseti.rulebase_destroy(&bad_rb)
	testing.expect_value(t, bad_comp_err, forseti.Compile_Error.Unstratified_Negation)
}

@(test)
test_reg_decision_table_float_nan_wildcard_and_66_cols :: proc(t: ^testing.T) {
	// 1. BUG-007: decide(nil, {})
	{
		res := forseti.decide(nil, {})
		testing.expect(t, !res.matched)
		testing.expect_value(t, res.trace.winning_row_idx, i32(-1))
	}

	// 2. BUG-006, BUG-013, BUG-026, BUG-041: Float_Interval + String_Set NaN/type-mismatch + wildcard preservation in BOTH First (tree) and Collect (bitset)
	for hit in ([]forseti.Hit_Policy{.First, .Collect}) {
		b: forseti.Ir_Builder
		testing.expect_value(t, forseti.ir_builder_init(&b, "tbl_edge", "1.0"), nil)
		defer forseti.ir_builder_destroy(&b)

		adj_lo := 1.0
		adj_hi := math.nextafter(adj_lo, math.inf_f64(1))
		_ = forseti.ir_table(&b, forseti.Table_Spec{
			name       = "edge_tbl",
			version    = "1.0",
			hit_policy = hit,
			inputs = {
				{name = "x", type = .F64, cost = 1},
				{name = "tag", type = .String, cost = 1},
			},
			outputs = {{name = "label", type = .String}},
			rows = {
				{id = "r_lo", cells = {forseti.cond(.Lt, f64(1.0)), forseti.lit("alpha")}, outputs = {forseti.lit("lo")}},
				{id = "r_eq", cells = {forseti.lit(adj_lo), forseti.wildcard()}, outputs = {forseti.lit("eq1")}},
				{id = "r_hi", cells = {forseti.cond(.Gt, f64(1e308)), forseti.lit("alpha")}, outputs = {forseti.lit("hi")}},
				{id = "r_adj", cells = {forseti.lit(adj_hi), forseti.lit("alpha")}, outputs = {forseti.lit("adj")}},
				{id = "r_wild", cells = {forseti.wildcard(), forseti.wildcard()}, outputs = {forseti.lit("wild")}},
			},
		})
		d: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&d), nil)
		defer forseti.diag_list_destroy(&d)
		ir, b_err := forseti.ir_builder_build(&b, &d)
		testing.expect_value(t, b_err, nil)
		defer forseti.ir_destroy(&ir)

		ct, c_err := forseti.compile_table(&ir, 0)
		testing.expect_value(t, c_err, nil)
		defer forseti.compiled_table_destroy(&ct)

		// Verify float_rep strict monotonicity (BUG-006)
		for i := 0; i + 1 < len(ct.col_domains[0].atoms); i += 1 {
			testing.expect(t, ct.col_domains[0].atoms[i].float_rep < ct.col_domains[0].atoms[i + 1].float_rep)
		}

		alpha_id, _ := ct.interner.lookup["alpha"]
		wild_id, _ := ct.interner.lookup["wild"]

		// NaN on x still hits wildcard row (r_wild = row 4) instead of false match or killing wildcard row
		res_nan := forseti.decide(&ct, {values = {math.nan_f64(), alpha_id}})
		testing.expect(t, res_nan.matched)
		testing.expect_value(t, res_nan.outputs[0], forseti.Value(wild_id))

		// Wrong type (i64 instead of String_Id) on String_Set col still hits wildcard row
		res_bad_str := forseti.decide(&ct, {values = {f64(0.5), i64(42)}})
		testing.expect(t, res_bad_str.matched)
		testing.expect_value(t, res_bad_str.outputs[0], forseti.Value(wild_id))
	}

	// 3. BUG-014: 66-column table evaluates column 65 cleanly without OOB panic
	{
		b: forseti.Ir_Builder
		testing.expect_value(t, forseti.ir_builder_init(&b, "wide66", "1.0"), nil)
		defer forseti.ir_builder_destroy(&b)

		inputs := make([]forseti.Table_Col_Spec, 66, context.temp_allocator)
		cells := make([]forseti.Expr_Spec, 66, context.temp_allocator)
		in_vals := make([]forseti.Value, 66, context.temp_allocator)
		buf: [16]u8 = ---
		for i in 0 ..< 66 {
			inputs[i] = {name = strings.clone(fmt.bprintf(buf[:], "c%d", i), context.temp_allocator), type = .I64, cost = 1}
			cells[i] = forseti.wildcard()
			in_vals[i] = i64(0)
		}
		cells[65] = forseti.lit(i64(99))
		_ = forseti.ir_table(&b, forseti.Table_Spec{
			name       = "wide",
			version    = "1.0",
			hit_policy = .First,
			inputs     = inputs,
			outputs    = {{name = "out", type = .I64}},
			rows       = {{id = "r1", cells = cells, outputs = {forseti.lit(i64(777))}}},
		})
		d: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&d), nil)
		defer forseti.diag_list_destroy(&d)
		ir, b_err := forseti.ir_builder_build(&b, &d)
		testing.expect_value(t, b_err, nil)
		defer forseti.ir_destroy(&ir)

		ct, c_err := forseti.compile_table(&ir, 0)
		testing.expect_value(t, c_err, nil)
		defer forseti.compiled_table_destroy(&ct)

		in_vals[65] = i64(99)
		res_hit := forseti.decide(&ct, {values = in_vals})
		testing.expect(t, res_hit.matched)
		testing.expect_value(t, res_hit.outputs[0], forseti.Value(i64(777)))

		in_vals[65] = i64(1)
		res_miss := forseti.decide(&ct, {values = in_vals})
		testing.expect(t, !res_miss.matched)
	}

	// 4. BUG-042: W3005 is suppressed when domain truncation prevents complete reachability proving
	{
		b: forseti.Ir_Builder
		testing.expect_value(t, forseti.ir_builder_init(&b, "trunc_w3005", "1.0"), nil)
		defer forseti.ir_builder_destroy(&b)

		_ = forseti.ir_table(&b, forseti.Table_Spec{
			name       = "trunc_tbl",
			version    = "1.0",
			hit_policy = .First,
			inputs = {
				{name = "a", type = .I64, cost = 1},
				{name = "b", type = .I64, cost = 1},
			},
			outputs = {{name = "verdict", type = .Enum, variants = {"allow", "deny"}}},
			rows = {
				{id = "r1", cells = {forseti.lit(i64(1)), forseti.wildcard()}, outputs = {forseti.lit("allow")}},
				{id = "r2", cells = {forseti.lit(i64(1)), forseti.lit(i64(1))}, outputs = {forseti.lit("deny")}},
				{id = "r3", cells = {forseti.lit(i64(2)), forseti.lit(i64(2))}, outputs = {forseti.lit("allow")}},
				{id = "r4", cells = {forseti.lit(i64(5)), forseti.lit(i64(5))}, outputs = {forseti.lit("allow")}},
			},
		})
		d: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&d), nil)
		defer forseti.diag_list_destroy(&d)
		ir, b_err := forseti.ir_builder_build(&b, &d)
		testing.expect_value(t, b_err, nil)
		defer forseti.ir_destroy(&ir)

		d2: forseti.Diagnostic_List
		testing.expect_value(t, forseti.diag_list_init(&d2), nil)
		defer forseti.diag_list_destroy(&d2)
		testing.expect_value(t, forseti.verify_decision_table(&ir, 0, &d2, nil, {max_fragments = 3}), nil)
		testing.expect(t, _reg_has_diag_code(&d2, .W3006))
		testing.expect(t, !_reg_has_diag_code(&d2, .W3005))
	}
}

@(test)
test_reg_vm_cmp_type_mismatch_and_oob_loads :: proc(t: ^testing.T) {
	interner: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&interner), nil)
	defer forseti.interner_destroy(&interner)
	sid_abc, _ := forseti.intern(&interner, "abc")

	// 1. BUG-008: i64 vs String_Id, nil vs i64, and bool < bool all return .Type_Mismatch
	{
		consts := []forseti.Value{i64(1), sid_abc}
		code := []forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 1},
			{op = .Eq, dst = 2, lhs = 0, rhs = 1},
			{op = .Halt, dst = 2},
		}
		prog := forseti.Bytecode_Program{code = code, consts = consts}
		_, err := forseti.vm_eval(&prog, nil, nil, nil, &interner)
		testing.expect_value(t, err, forseti.Vm_Error.Type_Mismatch)
	}
	{
		consts := []forseti.Value{nil, i64(5)}
		code := []forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 1},
			{op = .Lt, dst = 2, lhs = 0, rhs = 1},
			{op = .Halt, dst = 2},
		}
		prog := forseti.Bytecode_Program{code = code, consts = consts}
		_, err := forseti.vm_eval(&prog, nil, nil, nil, &interner)
		testing.expect_value(t, err, forseti.Vm_Error.Type_Mismatch)
	}
	{
		consts := []forseti.Value{true, false}
		code := []forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 1},
			{op = .Lt, dst = 2, lhs = 0, rhs = 1},
			{op = .Halt, dst = 2},
		}
		prog := forseti.Bytecode_Program{code = code, consts = consts}
		_, err := forseti.vm_eval(&prog, nil, nil, nil, &interner)
		testing.expect_value(t, err, forseti.Vm_Error.Type_Mismatch)
	}

	// 2. BUG-060: OOB Load_Var and Load_Const return .Missing_Field
	{
		code := []forseti.Instruction{
			{op = .Load_Var, dst = 0, lhs = 3},
			{op = .Halt, dst = 0},
		}
		prog := forseti.Bytecode_Program{code = code}
		_, err := forseti.vm_eval(&prog, nil, nil, nil, &interner)
		testing.expect_value(t, err, forseti.Vm_Error.Missing_Field)
	}
	{
		code := []forseti.Instruction{
			{op = .Load_Const, dst = 0, lhs = 0, rhs = 9},
			{op = .Halt, dst = 0},
		}
		prog := forseti.Bytecode_Program{code = code}
		_, err := forseti.vm_eval(&prog, nil, nil, nil, &interner)
		testing.expect_value(t, err, forseti.Vm_Error.Missing_Field)
	}

	// 3. BUG-027: cursor string field absent from vm.interner when sess_interner == nil does not equal EMPTY_STRING
	{
		bridge: forseti.Store_Bridge
		testing.expect_value(t, forseti.store_bridge_init_standalone(&bridge), nil)
		defer forseti.store_bridge_destroy(&bridge)

		wcb :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
			m := xitdb.write_hash_map_init(wc^) or_return
			return xitdb.hash_map_put(&m, "label", "unseen_val")
		}
		_, cm_err := forseti.store_bridge_commit_moment(&bridge, wcb)
		testing.expect_value(t, cm_err, nil)

		m_cur, m_ok, mc_err := forseti.store_bridge_moment_cursor(&bridge)
		testing.expect(t, mc_err == nil && m_ok)

		segs := []string{"label"}
		hashes := []forseti.Prehashed_Key{forseti.prehashed_key_make("label")}
		frefs := []forseti.Field_Access_Desc{{
			fact_slot     = 0,
			field_idx     = -1,
			segments      = segs,
			seg_hashes    = hashes,
			expected_type = .String,
		}}
		consts := []forseti.Value{forseti.EMPTY_STRING}
		code := []forseti.Instruction{
			{op = .Load_Field, dst = 0, lhs = 0, rhs = 0},
			{op = .Load_Const, dst = 1, lhs = 0, rhs = 0},
			{op = .Eq, dst = 2, lhs = 0, rhs = 1},
			{op = .Halt, dst = 2},
		}
		prog := forseti.Bytecode_Program{code = code, consts = consts, field_refs = frefs}
		fb := []forseti.Vm_Fact_Binding{{cursor = m_cur, has_cursor = true}}
		val, v_err := forseti.vm_eval(&prog, nil, fb, nil, &interner, nil, nil)
		testing.expect_value(t, v_err, forseti.Vm_Error.None)
		testing.expect_value(t, val, forseti.Value(false))
	}
}

@(test)
test_reg_effects_session_validation_phases_and_dirty_cascade :: proc(t: ^testing.T) {
	// 1. BUG-002: session_apply_effects returns nil on error without dangling slice / double-free
	{
		src := `module eff_err version "1.0"
schema Raw { id: string }
schema Res { id: string }
source RawSrc : Raw at .raw[?id]
derived ResD : Res at .res[?id]

rule emit_eff {
  when { ?_r := RawSrc(id: ?id) }
  effect "lookup" { id: ?id }
}`
		ir, diags, ok := _reg_compile_source(t, src, "eff.forseti")
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		if !ok {
			return
		}
		rb, sess, ok2 := _reg_build_session(t, &ir)
		defer {
			if sess != nil {
				forseti.session_destroy(sess)
				free(sess)
			}
			if rb != nil {
				forseti.rulebase_destroy(rb)
				free(rb)
			}
		}
		if !ok2 {
			return
		}
		_, _ = forseti.session_insert_fact(sess, "RawSrc", "r1", {_reg_str(sess, "r1")})
		_, _ = forseti.session_fire(sess)
		jobs := forseti.session_prepare_effects(sess)
		defer {
			for &j in jobs {
				forseti.effect_job_destroy(&j)
			}
			delete(jobs)
		}
		testing.expect_value(t, len(jobs), 1)

		applied1, err1 := forseti.session_apply_effects(sess, {{job_id = 999999}})
		testing.expect(t, applied1 == nil)
		testing.expect_value(t, err1, forseti.Session_Error.Invalid_Arg)

		applied2, err2 := forseti.session_apply_effects(sess, {{
			job_id = jobs[0].job_id,
			facts  = {
				{binding_name = "ResD", key = "k1", fields = {_reg_str(sess, "k1")}},
				{binding_name = "NoSuchBinding", key = "k2", fields = {_reg_str(sess, "k2")}},
			},
		}})
		testing.expect(t, applied2 == nil)
		testing.expect_value(t, err2, forseti.Session_Error.Unknown_Binding)
	}

	// 2. BUG-056, BUG-024, BUG-012, BUG-010: i32 bounds, retract unseen key preserving "", and multi-hop cascade revoke on unlink
	{
		src := `module sess_reg version "1.0"
schema Num { id: string, age: i32 }
schema Mid { id: string }
schema Leaf { id: string }

source NumSrc : Num at .num[?id]
derived MidD : Mid at .mid[?id]
derived LeafD : Leaf at .leaf[?id]

rule hop1 {
  when {
    ?_n := NumSrc(id: ?id, age: ?a)
    where ?a > 0
  }
  then { assert MidD(id: ?id) }
}

rule hop2 {
  when { ?_m := MidD(id: ?id) }
  then { assert LeafD(id: ?id) }
}`
		ir, diags, ok := _reg_compile_source(t, src, "sess_reg.forseti")
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		if !ok {
			return
		}
		rb, sess, ok2 := _reg_build_session(t, &ir, {provenance_mode = .Fast})
		defer {
			if sess != nil {
				forseti.session_destroy(sess)
				free(sess)
			}
			if rb != nil {
				forseti.rulebase_destroy(rb)
				free(rb)
			}
		}
		if !ok2 {
			return
		}

		// Out-of-range i64 for .I32 rejected before insert
		_, oob_err := forseti.session_insert_fact(sess, "NumSrc", "bad", {_reg_str(sess, "bad"), i64(max(i32)) + 1})
		testing.expect_value(t, oob_err, forseti.Session_Error.Invalid_Arg)

		// Empty-key fact stays intact when retracting an unseen key (BUG-024)
		empty_fid, emp_err := forseti.session_insert_fact(sess, "NumSrc", "", {_reg_str(sess, ""), i32(10)})
		testing.expect_value(t, emp_err, forseti.Session_Error.None)
		before_len := forseti.interner_len(&sess.interner)
		testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "NumSrc", "never_seen_key"), forseti.Session_Error.None)
		testing.expect_value(t, forseti.interner_len(&sess.interner), before_len)
		testing.expect(t, sess.facts[empty_fid].alive)

		k1_fid, k1_err := forseti.session_insert_fact(sess, "NumSrc", "k1", {_reg_str(sess, "k1"), i32(25)})
		testing.expect_value(t, k1_err, forseti.Session_Error.None)
		_, _ = forseti.session_fire(sess)

		leaf_bidx, _ := forseti.session_find_binding(sess, "LeafD")
		count_alive :: proc(s: ^forseti.Session, bidx: u16) -> int {
			c := 0
			for &f in s.facts {
				if f.alive && f.binding_idx == bidx {
					c += 1
				}
			}
			return c
		}
		testing.expect_value(t, count_alive(sess, leaf_bidx), 2)

		// Out-of-range modify fails without retracting/corrupting k1
		mod_oob := forseti.session_modify_fact_by_key(sess, "NumSrc", "k1", {_reg_str(sess, "k1"), i64(min(i32)) - 1})
		testing.expect_value(t, mod_oob, forseti.Session_Error.Invalid_Arg)
		testing.expect(t, sess.facts[k1_fid].alive)
		testing.expect_value(t, sess.facts[k1_fid].fields[1], forseti.Value(i32(25)))

		// Retract both NumSrc facts to unlink hop1 -> hop1's jtms_revoke_all_rule_firings dirties hop2 -> LeafD revoked too!
		testing.expect_value(t, forseti.session_retract_fact(sess, empty_fid), forseti.Session_Error.None)
		testing.expect_value(t, forseti.session_retract_fact(sess, k1_fid), forseti.Session_Error.None)
		_, _ = forseti.session_fire(sess)
		testing.expect_value(t, count_alive(sess, leaf_bidx), 0)
	}

	// 3. BUG-031: configured phases are not stripped when unphased rule runs first in stratum 0
	{
		src := `module phase_keep version "1.0"
schema Ev { id: string }
schema Trig { id: string }
schema Fired { id: string }

source EvSrc : Ev at .ev[?id]
derived TrigD : Trig at .trig[?id]
derived FiredD : Fired at .fired[?id]

rule kick_off {
  when { ?_e := EvSrc(id: ?id) }
  then { assert TrigD(id: ?id) }
}

rule run_price phase "price" salience 100 {
  when { ?_t := TrigD(id: ?id) }
  then { assert FiredD(id: "price") }
}

rule run_validate phase "validate" salience 1 {
  when { ?_t := TrigD(id: ?id) }
  then { assert FiredD(id: "validate") }
}`
		ir, diags, ok := _reg_compile_source(t, src, "phases.forseti")
		defer {
			forseti.ir_destroy(&ir)
			forseti.diag_list_destroy(&diags)
		}
		if !ok {
			return
		}
		rb, sess, ok2 := _reg_build_session(t, &ir)
		defer {
			if sess != nil {
				forseti.session_destroy(sess)
				free(sess)
			}
			if rb != nil {
				forseti.rulebase_destroy(rb)
				free(rb)
			}
		}
		if !ok2 {
			return
		}
		testing.expect_value(t, forseti.session_set_phases(sess, {"validate", "price"}), forseti.Session_Error.None)
		_, _ = forseti.session_insert_fact(sess, "EvSrc", "e1", {_reg_str(sess, "e1")})
		fired, f_err := forseti.session_fire(sess)
		testing.expect_value(t, f_err, forseti.Session_Error.None)
		testing.expect_value(t, fired, u64(3))
		testing.expect_value(t, len(sess.fired_trace), 3)
		if len(sess.fired_trace) == 3 {
			testing.expect_value(t, forseti.session_string(sess, sess.fired_trace[0]), "kick_off")
			testing.expect_value(t, forseti.session_string(sess, sess.fired_trace[1]), "run_validate")
			testing.expect_value(t, forseti.session_string(sess, sess.fired_trace[2]), "run_price")
		}
	}
}

@(test)
test_reg_accum_nan_retract_and_min_max_ordering :: proc(t: ^testing.T) {
	// BUG-016: .Sum and .Avg retract NaN cleanly
	for op in ([]forseti.Accum_Op{.Sum, .Avg}) {
		st: forseti.Accum_State
		forseti.accum_init(&st, op)
		defer forseti.accum_destroy(&st)

		forseti.accum_insert(&st, f64(10.0))
		forseti.accum_insert(&st, math.nan_f64())
		forseti.accum_insert(&st, f64(20.0))
		forseti.accum_retract(&st, math.nan_f64())

		val, valid := forseti.accum_finalize(&st)
		testing.expect(t, valid)
		fv, is_f := val.(f64)
		testing.expect(t, is_f && !math.is_nan(fv))
		expected := f64(30.0) if op == .Sum else f64(15.0)
		testing.expect_value(t, fv, expected)
	}

	// BUG-032: .Min and .Max preserve strict weak ordering with NaN + negative + positive floats
	for op in ([]forseti.Accum_Op{.Min, .Max}) {
		st: forseti.Accum_State
		forseti.accum_init(&st, op)
		defer forseti.accum_destroy(&st)

		forseti.accum_insert(&st, f64(-1.0))
		forseti.accum_insert(&st, f64(1.0))
		forseti.accum_insert(&st, math.nan_f64())
		forseti.accum_retract(&st, f64(1.0))
		forseti.accum_retract(&st, math.nan_f64())

		val, valid := forseti.accum_finalize(&st)
		testing.expect(t, valid)
		testing.expect_value(t, val, forseti.Value(f64(-1.0)))
	}
}

@(test)
test_reg_xitdb_sorted_set_lookup_cursor_bounds_and_long_prefix :: proc(t: ^testing.T) {
	bridge: forseti.Store_Bridge
	testing.expect_value(t, forseti.store_bridge_init_standalone(&bridge), nil)
	defer forseti.store_bridge_destroy(&bridge)

	wcb :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		root := xitdb.write_hash_map_init(wc^) or_return
		tags_wc := xitdb.hash_map_put_cursor(&root, "tags") or_return
		tags := xitdb.write_sorted_set_init(tags_wc) or_return
		xitdb.sorted_set_put(&tags, "alpha") or_return

		sm_wc := xitdb.hash_map_put_cursor(&root, "sorted") or_return
		sm := xitdb.write_sorted_map_init(sm_wc) or_return
		pad := strings.repeat("x", 320, context.temp_allocator)
		kbuf: [360]u8 = ---
		for i in 0 ..< 8 {
			k := fmt.bprintf(kbuf[:], "longprefix:%02d:%s", i, pad)
			xitdb.sorted_map_put(&sm, k, i64(i)) or_return
		}
		return nil
	}
	_, cm_err := forseti.store_bridge_commit_moment(&bridge, wcb)
	testing.expect_value(t, cm_err, nil)

	m_cur, m_ok, mc_err := forseti.store_bridge_moment_cursor(&bridge)
	testing.expect(t, mc_err == nil && m_ok)

	// BUG-029: .Sorted_Set lookup returns matched entry cursor, not container cursor
	interner: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&interner), nil)
	defer forseti.interner_destroy(&interner)

	alpha_cur, found_alpha, l_err := forseti.store_resolve_path(m_cur, ".tags.alpha")
	testing.expect_value(t, l_err, nil)
	testing.expect(t, found_alpha)
	alpha_val, val_ok, cv_err := forseti.cursor_read_value(alpha_cur, &interner)
	testing.expect_value(t, cv_err, nil)
	testing.expect(t, val_ok)
	alpha_sid, is_sid := alpha_val.(forseti.String_Id)
	testing.expect(t, is_sid)
	testing.expect_value(t, forseti.interner_get(&interner, alpha_sid), "alpha")

	_, found_nested, nested_err := forseti.store_resolve_path(m_cur, ".tags.alpha.b")
	testing.expect(t, !found_nested)
	testing.expect_value(t, nested_err, forseti.Store_Error(forseti.Store_Bridge_Error.Not_A_Collection))

	// BUG-061: prefix scan over >256-byte keys completes with zero leaks
	sorted_cur, s_ok, s_err := forseti.store_resolve_path(m_cur, ".sorted")
	testing.expect(t, s_err == nil && s_ok)
	visited := 0
	scan_err := forseti.store_sorted_prefix_scan(sorted_cur, transmute([]u8)string("longprefix:"), proc(key: []u8, _: xitdb.Read_Cursor, ud: rawptr) -> bool {
		if len(key) > 256 {
			(^int)(ud)^ += 1
		}
		return true
	}, &visited)
	testing.expect_value(t, scan_err, nil)
	testing.expect_value(t, visited, 8)

	// BUG-044: decode_slot_to_value rejects overflowing .Int -> .I32 and .Uint -> .Time/.I32/.Unknown
	_, _, ovf1 := forseti.decode_slot_to_value(bridge.db, xitdb.Slot{value = max(i64), tag = .Int}, &interner, .I32)
	testing.expect_value(t, ovf1, forseti.Store_Error(forseti.Store_Bridge_Error.Unsupported_Value_Type))
	_, _, ovf2 := forseti.decode_slot_to_value(bridge.db, xitdb.Slot{value = transmute(i64)(u64(max(i64)) + 1), tag = .Uint}, &interner, .Time)
	testing.expect_value(t, ovf2, forseti.Store_Error(forseti.Store_Bridge_Error.Unsupported_Value_Type))
	_, _, ovf3 := forseti.decode_slot_to_value(bridge.db, xitdb.Slot{value = i64(max(i32)) + 1, tag = .Uint}, &interner, .I32)
	testing.expect_value(t, ovf3, forseti.Store_Error(forseti.Store_Bridge_Error.Unsupported_Value_Type))
	_, _, ovf4 := forseti.decode_slot_to_value(bridge.db, xitdb.Slot{value = transmute(i64)(u64(max(i64)) + 1), tag = .Uint}, &interner, .Unknown)
	testing.expect_value(t, ovf4, forseti.Store_Error(forseti.Store_Bridge_Error.Unsupported_Value_Type))
}

@(test)
test_reg_xitdb_provenance_incremental_and_unmapped_derived :: proc(t: ^testing.T) {
	// BUG-015 + BUG-045: incremental commit applies multiple writes & retracts to same map and skips unmapped derived binding
	b: forseti.Ir_Builder
	testing.expect_value(t, forseti.ir_builder_init(&b, "prov_inc", "1.0"), nil)
	defer forseti.ir_builder_destroy(&b)

	_ = forseti.ir_schema(&b, "Rec", {forseti.field("id", .String), forseti.field("v", .I64)})
	_ = forseti.ir_source(&b, "Src", "Rec", ".src[?id]")
	_ = forseti.ir_derived(&b, "Out", "Rec", ".out[?id]")
	_ = forseti.ir_derived(&b, "TempFlag", "Rec", "")

	_ = forseti.ir_rule(&b, forseti.Rule_Spec{
		name = "copy_out",
		when_clauses = {
			forseti.pat("s", "Src", {forseti.field_bind("id", forseti.vref("id")), forseti.field_bind("v", forseti.vref("val"))}),
		},
		then_actions = {
			forseti.assert_fact("Out", {forseti.field_bind("id", forseti.vref("id")), forseti.field_bind("v", forseti.vref("val"))}),
			forseti.assert_fact("TempFlag", {forseti.field_bind("id", forseti.vref("id")), forseti.field_bind("v", forseti.vref("val"))}),
		},
	})

	d: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&d), nil)
	defer forseti.diag_list_destroy(&d)
	ir, b_err := forseti.ir_builder_build(&b, &d)
	testing.expect_value(t, b_err, nil)
	defer forseti.ir_destroy(&ir)

	rb, sess, ok := _reg_build_session(t, &ir)
	defer {
		if sess != nil {
			forseti.session_destroy(sess)
			free(sess)
		}
		if rb != nil {
			forseti.rulebase_destroy(rb)
			free(rb)
		}
	}
	if !ok {
		return
	}

	bridge: forseti.Store_Bridge
	testing.expect_value(t, forseti.store_bridge_init_standalone(&bridge), nil)
	defer forseti.store_bridge_destroy(&bridge)

	// Moment 0 (full commit)
	_, _ = forseti.session_insert_fact(sess, "Src", "k1", {_reg_str(sess, "k1"), i64(10)})
	_, _ = forseti.session_insert_fact(sess, "Src", "k2", {_reg_str(sess, "k2"), i64(20)})
	_, _ = forseti.session_fire(sess)
	_, c1_err := forseti.session_commit_derived_and_audit(sess, &bridge)
	testing.expect_value(t, c1_err, nil)

	// Moment 1 (incremental): retract k1, update k2 -> 200, add k3 -> 300
	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "Src", "k1"), forseti.Session_Error.None)
	_, _ = forseti.session_insert_fact(sess, "Src", "k2", {_reg_str(sess, "k2"), i64(200)})
	_, _ = forseti.session_insert_fact(sess, "Src", "k3", {_reg_str(sess, "k3"), i64(300)})
	_, _ = forseti.session_fire(sess)
	_, c2_err := forseti.session_commit_derived_and_audit(sess, &bridge)
	testing.expect_value(t, c2_err, nil)

	m_cur, m_ok, mc_err := forseti.store_bridge_moment_cursor(&bridge)
	testing.expect(t, mc_err == nil && m_ok)

	// Read committed Out collection (keyed by Rulebase/Session derived keys)
	out_cur, out_ok, out_err := forseti.store_resolve_path(m_cur, ".out")
	testing.expect(t, out_err == nil && out_ok)
	it, it_err := xitdb.cursor_iterator(out_cur)
	testing.expect_value(t, it_err, nil)
	read_int: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&read_int), nil)
	defer forseti.interner_destroy(&read_int)

	derived_vals := make(map[string]i64, 4, context.temp_allocator)
	for {
		entry_m, n_err := xitdb.cursor_iterator_next(&it)
		testing.expect_value(t, n_err, nil)
		entry, has := entry_m.?
		if !has {
			break
		}
		_, vc, kv_err := xitdb.cursor_read_kv_pair_slots(entry)
		testing.expect_value(t, kv_err, nil)
		id_cur, id_ok, _ := forseti.store_lookup_record(vc, "id")
		v_cur, v_ok, _ := forseti.store_lookup_record(vc, "v")
		testing.expect(t, id_ok && v_ok)
		id_val, _, _ := forseti.cursor_read_value(id_cur, &read_int)
		v_val, _, _ := forseti.cursor_read_value(v_cur, &read_int)
		if id_sid, ok_s := id_val.(forseti.String_Id); ok_s {
			if iv, ok_i := v_val.(i64); ok_i {
				derived_vals[forseti.interner_get(&read_int, id_sid)] = iv
			}
		}
	}
	testing.expect_value(t, len(derived_vals), 2)
	testing.expect(t, !("k1" in derived_vals))
	testing.expect_value(t, derived_vals["k2"], i64(200))
	testing.expect_value(t, derived_vals["k3"], i64(300))
}

@(test)
test_reg_xitdb_delta_sync_atomic_on_error :: proc(t: ^testing.T) {
	// BUG-030 + BUG-051: mid-sync failure in col2 must not mutate col1 state or drop deltas on retry
	bridge: forseti.Store_Bridge
	testing.expect_value(t, forseti.store_bridge_init_standalone(&bridge), nil)
	defer forseti.store_bridge_destroy(&bridge)

	syncer: forseti.Delta_Syncer
	testing.expect_value(t, forseti.delta_syncer_init(&syncer), nil)
	defer forseti.delta_syncer_destroy(&syncer)
	testing.expect_value(t, forseti.delta_syncer_watch(&syncer, ".col1"), nil)
	testing.expect_value(t, forseti.delta_syncer_watch(&syncer, ".col2"), nil)

	// Moment 0: clean baseline
	cb0 :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		root := xitdb.write_hash_map_init(wc^) or_return
		c1_wc := xitdb.hash_map_put_cursor(&root, "col1") or_return
		c1 := xitdb.write_hash_map_init(c1_wc) or_return
		xitdb.hash_map_put(&c1, "k1", "v1") or_return
		c2_wc := xitdb.hash_map_put_cursor(&root, "col2") or_return
		c2 := xitdb.write_hash_map_init(c2_wc) or_return
		return xitdb.hash_map_put(&c2, "k2", "v2")
	}
	_, _ = forseti.store_bridge_commit_moment(&bridge, cb0)

	r0: forseti.Sync_Result
	testing.expect_value(t, forseti.delta_syncer_sync(&syncer, &bridge, &r0), nil)
	forseti.sync_result_destroy(&r0)

	// Moment 1: mutate .col1["k1"] = "v1_next", AND write 68-deep nested map in .col2["bad"]
	cb1 :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		root := xitdb.write_hash_map_init(wc^) or_return
		c1_wc := xitdb.hash_map_put_cursor(&root, "col1") or_return
		c1 := xitdb.write_hash_map_init(c1_wc) or_return
		xitdb.hash_map_put(&c1, "k1", "v1_next") or_return

		c2_wc := xitdb.hash_map_put_cursor(&root, "col2") or_return
		c2 := xitdb.write_hash_map_init(c2_wc) or_return
		cur_m := xitdb.write_hash_map_init(xitdb.hash_map_put_cursor(&c2, "bad") or_return) or_return
		for _ in 0 ..< 68 {
			cur_m = xitdb.write_hash_map_init(xitdb.hash_map_put_cursor(&cur_m, "n") or_return) or_return
		}
		return xitdb.hash_map_put(&cur_m, "leaf", "boom")
	}
	_, _ = forseti.store_bridge_commit_moment(&bridge, cb1)

	r1: forseti.Sync_Result
	err1 := forseti.delta_syncer_sync(&syncer, &bridge, &r1)
	forseti.sync_result_destroy(&r1)
	testing.expect_value(t, err1, forseti.Store_Error(xitdb.Xitdb_Error.Key_Offset_Exceeded))

	// Moment 2: fix .col2["bad"] = "repaired" while keeping .col1["k1"] = "v1_next"
	cb2 :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		root := xitdb.write_hash_map_init(wc^) or_return
		c2_wc := xitdb.hash_map_put_cursor(&root, "col2") or_return
		c2 := xitdb.write_hash_map_init(c2_wc) or_return
		return xitdb.hash_map_put(&c2, "bad", "repaired")
	}
	_, _ = forseti.store_bridge_commit_moment(&bridge, cb2)

	r2: forseti.Sync_Result
	err2 := forseti.delta_syncer_sync(&syncer, &bridge, &r2)
	defer forseti.sync_result_destroy(&r2)
	testing.expect_value(t, err2, nil)

	saw_col1_change := false
	for delta in r2.deltas {
		if delta.collection == ".col1" && delta.key == "k1" && delta.kind == .Changed_New {
			saw_col1_change = true
		}
	}
	testing.expect(t, saw_col1_change)
}
