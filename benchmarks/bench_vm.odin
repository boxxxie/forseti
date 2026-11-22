package main

import hugi "hugi:."
import "../forseti"

@(private = "file")
_BENCH_VM_POLICY_SRC :: `module bench_vm version "1.0"

schema Org {
  id: string,
  domain: string,
  employees: i64,
  score: f64
}
schema Out { id: string }

source Org : Org at .orgs[?id]
derived Out : Out at .outs[?id]

table tier_tbl version "1.0" hit First {
  inputs { employees: i64 cost 1, score: f64 cost 2 }
  outputs { tier: string }
  rows {
    r_ent: >= 200 | >= 0.8 || "ent";
    r_smb: -      | -      || "smb";
  }
}

rule r_arith {
  when {
    ?_o := Org(id: ?id, domain: ?dom, employees: ?emp, score: ?sc)
    where (?emp * 3 + 10) >= 100 and ?dom != "blocked" and ?sc >= 0.5
  }
  then { assert Out(id: ?id) }
}

rule r_decide {
  when {
    ?_o := Org(id: ?id, domain: ?dom, employees: ?emp, score: ?sc)
    ?g := decide tier_tbl(employees: ?emp, score: ?sc)
    where ?g.tier == "ent"
  }
  then { assert Out(id: ?id) }
}

rule r_fields {
  when {
    ?_o := Org(id: ?id, domain: ?dom, employees: ?emp, score: ?sc)
    where ?id != "" and ?dom != "spam" and ?emp > 10 and ?sc <= 1.0
  }
  then { assert Out(id: ?id) }
}`

@(private = "file")
_find_rule_prog :: proc(rb: ^forseti.Rulebase, rule_id: u32, kind: forseti.Beta_Node_Kind) -> (prog_idx: u32, lia: forseti.Beta_Node_Def, ok: bool) {
	if int(rule_id) >= len(rb.rules) {
		return 0, {}, false
	}
	found_lia := false
	for sid in rb.rules[rule_id].segment_ids {
		seg := rb.segments[sid]
		end := seg.node_start + seg.node_count
		for bn in rb.beta_nodes[seg.node_start:end] {
			if bn.kind == .Left_Input_Adapter {
				lia = bn
				found_lia = true
			}
			if bn.kind == kind {
				return bn.prog_idx, lia, found_lia
			}
		}
	}
	return 0, {}, false
}

@(private = "file")
_populate_vars_from_lia :: proc(
	rb: ^forseti.Rulebase,
	lia: forseti.Beta_Node_Def,
	fact_fields: []forseti.Value,
	vars: []forseti.Value,
) {
	_ = rb
	for fb in lia.field_binds {
		if int(fb.var_slot) < len(vars) && int(fb.field_idx) < len(fact_fields) {
			vars[fb.var_slot] = fact_fields[fb.field_idx]
		}
	}
}

@(private = "file")
_bench_vm_arith_cmp_chain :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 100)
	rb, ok := compile_benchmark_source(_BENCH_VM_POLICY_SRC, "bench_vm.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	prog_idx, lia, found := _find_rule_prog(rb, 0, .Filter)
	if !found {
		return
	}

	sess_int: forseti.String_Interner
	_ = forseti.interner_init(&sess_int)
	defer forseti.interner_destroy(&sess_int)

	v_id, _ := forseti.intern_session_string(&rb.interner, &sess_int, "org:1")
	v_dom, _ := forseti.intern_session_string(&rb.interner, &sess_int, "acme.com")
	fact_fields := [4]forseti.Value{v_id, v_dom, i64(150), f64(0.9)}
	vars: [16]forseti.Value
	_populate_vars_from_lia(rb, lia, fact_fields[:], vars[:])

	fslots := [1]forseti.Vm_Fact_Binding{{fields = fact_fields[:]}}
	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	acc := 0
	for hugi.step(b) {
		for i := 0; i < n; i += 1 {
			v, _ := forseti.vm_eval(&rb.programs[prog_idx], vars[:], fslots[:], rb.tables, &rb.interner, nil, &sess_int)
			if v == forseti.Value(true) {
				acc += 1
			}
		}
	}
	_ = hugi.black_box(acc)
}

@(private = "file")
_bench_vm_string_and_decide :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 100)
	rb, ok := compile_benchmark_source(_BENCH_VM_POLICY_SRC, "bench_vm.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	dec_idx, lia, found_dec := _find_rule_prog(rb, 1, .Decide)
	flt_idx, _, found_flt := _find_rule_prog(rb, 1, .Filter)
	if !found_dec || !found_flt {
		return
	}

	sess_int: forseti.String_Interner
	_ = forseti.interner_init(&sess_int)
	defer forseti.interner_destroy(&sess_int)

	v_id, _ := forseti.intern_session_string(&rb.interner, &sess_int, "org:1")
	v_dom, _ := forseti.intern_session_string(&rb.interner, &sess_int, "acme.com")
	fact_fields := [4]forseti.Value{v_id, v_dom, i64(250), f64(0.92)}
	vars: [16]forseti.Value
	_populate_vars_from_lia(rb, lia, fact_fields[:], vars[:])

	fslots := [1]forseti.Vm_Fact_Binding{{fields = fact_fields[:]}}
	dec_outs: [16]forseti.Decision_Result

	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	acc := 0
	for hugi.step(b) {
		for i := 0; i < n; i += 1 {
			_, _ = forseti.vm_eval(&rb.programs[dec_idx], vars[:], fslots[:], rb.tables, &rb.interner, dec_outs[:], &sess_int)
			v, _ := forseti.vm_eval(&rb.programs[flt_idx], vars[:], fslots[:], rb.tables, &rb.interner, dec_outs[:], &sess_int)
			if v == forseti.Value(true) {
				acc += 1
			}
		}
	}
	_ = hugi.black_box(acc)
}

@(private = "file")
_bench_vm_field_access_eval :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 100)
	rb, ok := compile_benchmark_source(_BENCH_VM_POLICY_SRC, "bench_vm.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	prog_idx, lia, found := _find_rule_prog(rb, 2, .Filter)
	if !found {
		return
	}

	sess_int: forseti.String_Interner
	_ = forseti.interner_init(&sess_int)
	defer forseti.interner_destroy(&sess_int)

	v_id, _ := forseti.intern_session_string(&rb.interner, &sess_int, "org:1")
	v_dom, _ := forseti.intern_session_string(&rb.interner, &sess_int, "acme.com")
	fact_fields := [4]forseti.Value{v_id, v_dom, i64(150), f64(0.85)}
	vars: [16]forseti.Value
	_populate_vars_from_lia(rb, lia, fact_fields[:], vars[:])

	fslots := [1]forseti.Vm_Fact_Binding{{fields = fact_fields[:]}}
	hugi.set_items(b, u64(n))
	hugi.expect_zero_allocs(b)

	acc := 0
	for hugi.step(b) {
		for i := 0; i < n; i += 1 {
			v, _ := forseti.vm_eval(&rb.programs[prog_idx], vars[:], fslots[:], rb.tables, &rb.interner, nil, &sess_int)
			if v == forseti.Value(true) {
				acc += 1
			}
		}
	}
	_ = hugi.black_box(acc)
}

register_vm_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "vm_guard_eval")
	hugi.group_params(g, []int{100, 1_000, 10_000})
	hugi.group_bench(g, "vm_arith_cmp_chain", _bench_vm_arith_cmp_chain, zero_alloc = true)
	hugi.group_bench(g, "vm_string_and_decide", _bench_vm_string_and_decide, zero_alloc = true)
	hugi.group_bench(g, "vm_field_access_eval", _bench_vm_field_access_eval, zero_alloc = true)
}
