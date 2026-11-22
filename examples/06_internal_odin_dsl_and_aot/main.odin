package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../forseti"

run_example :: proc() -> bool {
	b: forseti.Ir_Builder
	if forseti.ir_builder_init(&b, "ex06_internal", "1.0") != nil {
		return false
	}
	defer forseti.ir_builder_destroy(&b)

	_ = forseti.ir_schema(&b, "Account", {
		forseti.field("id", .String),
		forseti.field("employees", .I64),
		forseti.field("active", .Bool),
	})
	_ = forseti.ir_schema(&b, "DecisionOut", {
		forseti.field("id", .String),
		forseti.field("tier", .String),
	})
	_ = forseti.ir_source(&b, "RawAcct", "Account", ".acct.raw[?id]")
	_ = forseti.ir_derived(&b, "GoldenAcct", "DecisionOut", ".acct.golden[?id]")

	_ = forseti.ir_table(&b, forseti.Table_Spec{
		name       = "tier_table",
		version    = "1.0",
		hit_policy = .First,
		inputs     = {
			{name = "employees", type = .I64, cost = 1},
			{name = "active", type = .Bool, cost = 1},
		},
		outputs = {{name = "tier", type = .String}},
		rows = {
			{id = "r_ent", cells = {forseti.cond(.Gte, i64(200)), forseti.lit(true)}, outputs = {forseti.lit("enterprise")}},
			{id = "r_smb", cells = {forseti.wildcard(), forseti.lit(true)}, outputs = {forseti.lit("smb")}},
			{id = "r_off", cells = {forseti.wildcard(), forseti.wildcard()}, outputs = {forseti.lit("inactive")}},
		},
	})

	_ = forseti.ir_rule(&b, forseti.Rule_Spec{
		name     = "classify_acct",
		phase    = "survive",
		salience = 50,
		when_clauses = {
			forseti.pat("?_r", "RawAcct", {
				forseti.field_bind("id", forseti.vref("?id")),
				forseti.field_bind("employees", forseti.vref("?emp")),
				forseti.field_bind("active", forseti.vref("?act")),
			}),
			forseti.decide_clause("?g", "tier_table", {
				forseti.field_bind("employees", forseti.vref("?emp")),
				forseti.field_bind("active", forseti.vref("?act")),
			}),
			forseti.let_clause("?keep", forseti.cond(.Neq, forseti.fget("?g", "tier"), forseti.lit("inactive"))),
			forseti.where_clause(forseti.vref("?keep")),
		},
		then_actions = {
			forseti.assert_fact("GoldenAcct", {
				forseti.field_bind("id", forseti.vref("?id")),
				forseti.field_bind("tier", forseti.fget("?g", "tier")),
			}),
		},
	})

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, b_err := forseti.ir_builder_build(&b, &diags)
	if b_err != nil || diags.error_count != 0 {
		return false
	}
	defer forseti.ir_destroy(&ir)

	rb, rb_err := forseti.rulebase_compile(&ir)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb)
		return false
	}
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	if forseti.session_init(sess, &rb) != .None {
		forseti.session_destroy(sess)
		free(sess)
		return false
	}
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	a1, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "acct:1")
	a2, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "acct:2")
	_, _ = forseti.session_insert_fact(sess, "RawAcct", "acct:1", {a1, i64(500), true})
	_, _ = forseti.session_insert_fact(sess, "RawAcct", "acct:2", {a2, i64(500), false})
	fired, f_err := forseti.session_fire(sess)
	if f_err != .None || fired != 1 {
		fmt.eprintfln("expected 1 rule firing, got %d", fired)
		return false
	}

	aot_src, aot_err := forseti.codegen_odin_module(&ir, "ex06_aot")
	if aot_err != nil || !strings.contains(aot_src, "decide_tier_table") {
		delete(aot_src)
		return false
	}
	defer delete(aot_src)

	fmt.printfln("[ex06] OK internal Odin DSL fired=%d aot_bytes=%d", fired, len(aot_src))
	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	ok := run_example()
	free_all(context.temp_allocator)

	leaks := len(track.allocation_map)
	bad_frees := len(track.bad_free_array)
	for _, entry in track.allocation_map {
		fmt.eprintfln("%v leaked %m", entry.location, entry.size)
	}
	mem.tracking_allocator_destroy(&track)
	if !ok || leaks > 0 || bad_frees > 0 {
		os.exit(1)
	}
}
