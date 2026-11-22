package main

import "core:fmt"
import vmem "core:mem/virtual"
import hugi "hugi:."
import forseti "../forseti"

@(private = "file")
_Scale_Fixture_Cache :: struct {
	cached_n: int,
	has_ir:   bool,
	ir:       forseti.Rulebase_IR,
	has_rb:   bool,
	rb:       ^forseti.Rulebase,
}

@(private = "file")
_g_scale_cache: _Scale_Fixture_Cache

scale_bench_cache_destroy :: proc() {
	saved := context.allocator
	if g_bench_root_allocator.procedure != nil {
		context.allocator = g_bench_root_allocator
	}
	defer context.allocator = saved

	if _g_scale_cache.has_rb && _g_scale_cache.rb != nil {
		forseti.rulebase_destroy(_g_scale_cache.rb)
		free(_g_scale_cache.rb)
	}
	if _g_scale_cache.has_ir {
		forseti.ir_destroy(&_g_scale_cache.ir)
	}
	_g_scale_cache = {}
}

@(private = "file")
_get_scale_ir :: proc(n: int) -> ^forseti.Rulebase_IR {
	if !_g_scale_cache.has_ir || _g_scale_cache.cached_n != n {
		scale_bench_cache_destroy()
		saved := context.allocator
		if g_bench_root_allocator.procedure != nil {
			context.allocator = g_bench_root_allocator
		}
		defer context.allocator = saved

		_g_scale_cache.ir = gen_scaled_rule_ir(n)
		_g_scale_cache.has_ir = true
		_g_scale_cache.cached_n = n
		free_all(context.temp_allocator)
	}
	return &_g_scale_cache.ir
}

@(private = "file")
_get_scale_rb :: proc(n: int) -> ^forseti.Rulebase {
	_ = _get_scale_ir(n)
	if !_g_scale_cache.has_rb {
		saved := context.allocator
		if g_bench_root_allocator.procedure != nil {
			context.allocator = g_bench_root_allocator
		}
		defer context.allocator = saved

		rb := new(forseti.Rulebase)
		compiled, c_err := forseti.rulebase_compile(&_g_scale_cache.ir)
		if c_err != .None {
			free(rb)
			return nil
		}
		rb^ = compiled
		_g_scale_cache.rb = rb
		_g_scale_cache.has_rb = true
		free_all(context.temp_allocator)
	}
	return _g_scale_cache.rb
}

@(private = "file")
_bench_compile_rules :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	ir := _get_scale_ir(n)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		rb, err := forseti.rulebase_compile(ir)
		if err != .None {
			break
		}
		_ = hugi.black_box(len(rb.rules))
		forseti.rulebase_destroy(&rb)
	}
}

@(private = "file")
_bench_lazy_session_init :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb := _get_scale_rb(n)
	if rb == nil {
		return
	}

	hugi.set_items(b, 1)
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
		_ = hugi.black_box(s.live_memories_count)
		forseti.session_destroy(s)
		free(s)
	}
}

@(private = "file")
_bench_sparse_alpha_match :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb := _get_scale_rb(n)
	if rb == nil {
		return
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	saas_sid := bench_intern(s, "saas")
	id_sid := bench_intern(s, "org:hot")

	hugi.set_items(b, 1)
	seq: i64 = 0
	for hugi.step(b) {
		bucket := i64(seq % i64(n))
		seq += 1
		vals := [3]forseti.Value{id_sid, saas_sid, bucket}
		if seq == 1 {
			_, _ = forseti.session_insert_fact(s, "Org", "org:hot", vals[:])
		} else {
			_ = forseti.session_modify_fact_by_key(s, "Org", "org:hot", vals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_bench_batch_100_alpha_match :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	batch :: 100
	rb := _get_scale_rb(n)
	if rb == nil {
		return
	}

	keys := make([]string, batch, context.temp_allocator)
	for i := 0; i < batch; i += 1 {
		keys[i] = fmt.tprintf("org:%03d", i)
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(batch))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
		saas_sid := bench_intern(s, "saas")
		for i := 0; i < batch; i += 1 {
			id_sid := bench_intern(s, keys[i])
			bucket := i64((i * 7919) % n)
			vals := [3]forseti.Value{id_sid, saas_sid, bucket}
			_, _ = forseti.session_insert_fact(s, "Org", keys[i], vals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
		forseti.session_destroy(s)
		free(s)
	}
}

@(private = "file")
_bench_audit_full_sparse_match :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb := _get_scale_rb(n)
	if rb == nil {
		return
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	saas_sid := bench_intern(s, "saas")
	id_sid := bench_intern(s, "org:hot")

	hugi.set_items(b, 1)
	seq: i64 = 0
	for hugi.step(b) {
		bucket := i64(seq % i64(n))
		seq += 1
		vals := [3]forseti.Value{id_sid, saas_sid, bucket}
		if seq == 1 {
			_, _ = forseti.session_insert_fact(s, "Org", "org:hot", vals[:])
		} else {
			_ = forseti.session_modify_fact_by_key(s, "Org", "org:hot", vals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_gen_scaled_join_ir :: proc(rule_count: int) -> forseti.Rulebase_IR {
	ir: forseti.Rulebase_IR
	_ = vmem.arena_init_growing(&ir.arena)
	_ = forseti.interner_init(&ir.interner)
	a := vmem.arena_allocator(&ir.arena)

	ir.module_name, _ = forseti.intern(&ir.interner, "scale_join_bench")
	ir.module_version, _ = forseti.intern(&ir.interner, "1.0")

	sid_org, _ := forseti.intern(&ir.interner, "Org")
	sid_dept, _ := forseti.intern(&ir.interner, "Dept")
	sid_flag, _ := forseti.intern(&ir.interner, "Flag")
	sid_id, _ := forseti.intern(&ir.interner, "id")
	sid_dom, _ := forseti.intern(&ir.interner, "dom")
	sid_bucket, _ := forseti.intern(&ir.interner, "bucket")
	sid_orgs_seg, _ := forseti.intern(&ir.interner, "orgs")
	sid_raw_seg, _ := forseti.intern(&ir.interner, "raw")
	sid_depts_seg, _ := forseti.intern(&ir.interner, "depts")
	sid_flags_seg, _ := forseti.intern(&ir.interner, "flags")
	sid_var_id, _ := forseti.intern(&ir.interner, "?id")
	sid_var_dom, _ := forseti.intern(&ir.interner, "?dom")
	sid_bind_o, _ := forseti.intern(&ir.interner, "?_o")
	sid_bind_d, _ := forseti.intern(&ir.interner, "?_d")

	ir.schemas = make([]forseti.Schema_Def, 3, a)
	org_fields := make([]forseti.Field_Def, 3, a)
	org_fields[0] = {name = sid_id, type = {kind = .String}}
	org_fields[1] = {name = sid_dom, type = {kind = .String}}
	org_fields[2] = {name = sid_bucket, type = {kind = .I64}}
	ir.schemas[0] = {name = sid_org, fields = org_fields}

	dept_fields := make([]forseti.Field_Def, 2, a)
	dept_fields[0] = {name = sid_dom, type = {kind = .String}}
	dept_fields[1] = {name = sid_bucket, type = {kind = .I64}}
	ir.schemas[1] = {name = sid_dept, fields = dept_fields}

	flag_fields := make([]forseti.Field_Def, 2, a)
	flag_fields[0] = {name = sid_id, type = {kind = .String}}
	flag_fields[1] = {name = sid_bucket, type = {kind = .I64}}
	ir.schemas[2] = {name = sid_flag, fields = flag_fields}

	ir.bindings = make([]forseti.Binding_Def, 3, a)
	s0 := make([]forseti.Selector_Segment, 3, a)
	s0[0] = {kind = .Field, text = sid_orgs_seg}
	s0[1] = {kind = .Field, text = sid_raw_seg}
	s0[2] = {kind = .Var_Key, text = sid_var_id}
	ir.bindings[0] = {kind = .Source, name = sid_org, schema_name = sid_org, schema_id = forseti.Schema_Id(forseti.INVALID_ID), segments = s0}

	s1 := make([]forseti.Selector_Segment, 3, a)
	s1[0] = {kind = .Field, text = sid_orgs_seg}
	s1[1] = {kind = .Field, text = sid_depts_seg}
	s1[2] = {kind = .Var_Key, text = sid_var_dom}
	ir.bindings[1] = {kind = .Source, name = sid_dept, schema_name = sid_dept, schema_id = forseti.Schema_Id(forseti.INVALID_ID), segments = s1}

	s2 := make([]forseti.Selector_Segment, 3, a)
	s2[0] = {kind = .Field, text = sid_orgs_seg}
	s2[1] = {kind = .Field, text = sid_flags_seg}
	s2[2] = {kind = .Var_Key, text = sid_var_id}
	ir.bindings[2] = {kind = .Derived, name = sid_flag, schema_name = sid_flag, schema_id = forseti.Schema_Id(forseti.INVALID_ID), segments = s2}

	ir.exprs = make([]forseti.Expr_IR, 3 + rule_count, a)
	ir.exprs[0] = {kind = .Invalid}
	ir.exprs[1] = {kind = .Var, str_id = sid_var_id}
	ir.exprs[2] = {kind = .Var, str_id = sid_var_dom}
	for i := 0; i < rule_count; i += 1 {
		ir.exprs[3 + i] = {kind = .Lit_Int, int_val = i64(i)}
	}

	all_when_fbs := make([]forseti.Field_Binding_IR, rule_count * 5, a)
	all_clauses := make([]forseti.Clause_IR, rule_count * 2, a)
	all_then_fbs := make([]forseti.Field_Binding_IR, rule_count * 2, a)
	all_actions := make([]forseti.Action_IR, rule_count, a)
	ir.rules = make([]forseti.Rule_Def, rule_count, a)

	nbuf: [32]u8 = ---
	for i := 0; i < rule_count; i += 1 {
		fb_off := i * 5
		all_when_fbs[fb_off + 0] = {name = sid_id, expr = forseti.Expr_Id(1)}
		all_when_fbs[fb_off + 1] = {name = sid_dom, expr = forseti.Expr_Id(2)}
		all_when_fbs[fb_off + 2] = {name = sid_bucket, expr = forseti.Expr_Id(3 + i)}
		all_when_fbs[fb_off + 3] = {name = sid_dom, expr = forseti.Expr_Id(2)}
		all_when_fbs[fb_off + 4] = {name = sid_bucket, expr = forseti.Expr_Id(3 + i)}

		cl_off := i * 2
		all_clauses[cl_off + 0] = {
			kind     = .Pattern,
			bind_var = sid_bind_o,
			target   = sid_org,
			fields   = all_when_fbs[fb_off:fb_off + 3],
		}
		all_clauses[cl_off + 1] = {
			kind     = .Pattern,
			bind_var = sid_bind_d,
			target   = sid_dept,
			fields   = all_when_fbs[fb_off + 3:fb_off + 5],
		}

		tf_off := i * 2
		all_then_fbs[tf_off + 0] = {name = sid_id, expr = forseti.Expr_Id(1)}
		all_then_fbs[tf_off + 1] = {name = sid_bucket, expr = forseti.Expr_Id(3 + i)}
		all_actions[i] = {
			kind   = .Assert,
			target = sid_flag,
			fields = all_then_fbs[tf_off:tf_off + 2],
		}

		rname := fmt.bprintf(nbuf[:], "jr%d", i)
		rname_id, _ := forseti.intern(&ir.interner, rname)
		ir.rules[i] = {
			name         = rname_id,
			when_clauses = all_clauses[cl_off:cl_off + 2],
			then_actions = all_actions[i:i + 1],
		}
	}

	_ = forseti.analyze_ir(&ir, nil)
	return ir
}

@(private = "file")
_bench_compile_join_rules :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	ir := _gen_scaled_join_ir(n)
	defer forseti.ir_destroy(&ir)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		rb, err := forseti.rulebase_compile(&ir)
		if err != .None {
			break
		}
		_ = hugi.black_box(len(rb.rules))
		forseti.rulebase_destroy(&rb)
	}
}

@(private = "file")
_bench_sparse_join_match_1k_facts :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	ir := _gen_scaled_join_ir(n)
	rb, err := forseti.rulebase_compile(&ir)
	forseti.ir_destroy(&ir)
	if err != .None {
		forseti.rulebase_destroy(&rb)
		return
	}
	defer forseti.rulebase_destroy(&rb)

	s := new(forseti.Session)
	_ = forseti.session_init(s, &rb, forseti.Session_Config{provenance_mode = .Audit_Full})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	// Seed 1,000 Org + Dept pairs spread across rules, then toggle 1 hot join probe.
	bg_count :: 1_000
	for i := 0; i < bg_count; i += 1 {
		ok := fmt.tprintf("o:%04d", i)
		dk := fmt.tprintf("d:%04d", i)
		osid := bench_intern(s, ok)
		dsid := bench_intern(s, dk)
		bkt := i64(i % n)
		ovals := [3]forseti.Value{osid, dsid, bkt}
		dvals := [2]forseti.Value{dsid, bkt}
		_, _ = forseti.session_insert_fact(s, "Org", ok, ovals[:])
		_, _ = forseti.session_insert_fact(s, "Dept", dk, dvals[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	hot_id := bench_intern(s, "o:hot")
	hot_dom := bench_intern(s, "d:0000")
	hugi.set_items(b, 1)
	seq: i64 = 0
	for hugi.step(b) {
		bkt := i64(seq % i64(n))
		seq += 1
		ovals := [3]forseti.Value{hot_id, hot_dom, bkt}
		dvals := [2]forseti.Value{hot_dom, bkt}
		if seq == 1 {
			_, _ = forseti.session_insert_fact(s, "Org", "o:hot", ovals[:])
			_, _ = forseti.session_insert_fact(s, "Dept", "d:hot", dvals[:])
		} else {
			_ = forseti.session_modify_fact_by_key(s, "Org", "o:hot", ovals[:])
			_ = forseti.session_modify_fact_by_key(s, "Dept", "d:hot", dvals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

register_scale_rule_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "scale_rules")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000, 100_000, 1_000_000})
	hugi.group_bench(g, "compile_rules", _bench_compile_rules)
	hugi.group_bench(g, "lazy_session_init", _bench_lazy_session_init)
	hugi.group_bench(g, "sparse_alpha_match", _bench_sparse_alpha_match)
	hugi.group_bench(g, "audit_full_sparse_match", _bench_audit_full_sparse_match)
	hugi.group_bench(g, "batch_100_alpha_match", _bench_batch_100_alpha_match)
}

register_scale_join_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "scale_join_rules")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "compile_join_rules", _bench_compile_join_rules)
	hugi.group_bench(g, "sparse_join_match_1k_facts", _bench_sparse_join_match_1k_facts)
}
