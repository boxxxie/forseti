package main

import "core:fmt"
import hugi "hugi:."
import forseti "../forseti"

@(private = "file")
_bench_two_way_mdm_join :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	// Precompute N distinct domain pairs (2 facts per domain => N join fires).
	keys := make([]string, n, context.temp_allocator)
	doms := make([]string, n / 2 + 1, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		keys[i] = fmt.tprintf("o:%06d", i)
	}
	for d := 0; d < len(doms); d += 1 {
		doms[d] = fmt.tprintf("dom%05d.io", d)
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
		for i := 0; i < n; i += 1 {
			id_sid := bench_intern(s, keys[i])
			dom_sid := bench_intern(s, doms[i / 2])
			vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + (i % 50))}
			_, _ = forseti.session_insert_fact(s, "Org", keys[i], vals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
		forseti.session_destroy(s)
		free(s)
	}
}

@(private = "file")
_bench_phreak_hot_match :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	// Seed N background facts across N/2 domains so hot updates hit an indexed join bucket.
	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("seed:%06d", i)
		d := fmt.tprintf("dom%05d.io", i / 2)
		id_sid := bench_intern(s, k)
		dom_sid := bench_intern(s, d)
		vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + (i % 10))}
		_, _ = forseti.session_insert_fact(s, "Org", k, vals[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	hot_id_sid := bench_intern(s, "hot:0")
	hot_dom_sid := bench_intern(s, "dom00000.io")
	hot_vals := [3]forseti.Value{hot_id_sid, hot_dom_sid, i64(500)}
	_, _ = forseti.session_insert_fact(s, "Org", "hot:0", hot_vals[:])
	_, _ = forseti.session_fire(s)

	// Warm up both alternating toggle states so all steady-state buckets/slots are populated.
	for w_emp in ([2]i64{600, 500}) {
		w_vals := [3]forseti.Value{hot_id_sid, hot_dom_sid, w_emp}
		_ = forseti.session_modify_fact_by_key(s, "Org", "hot:0", w_vals[:])
		_, _ = forseti.session_fire(s)
	}
	free_all(context.temp_allocator)

	hugi.set_items(b, 1)
	hugi.expect_zero_allocs(b)
	toggle: i64 = 500
	for hugi.step(b) {
		toggle = 600 if toggle == 500 else 500
		vals := [3]forseti.Value{hot_id_sid, hot_dom_sid, toggle}
		_ = forseti.session_modify_fact_by_key(s, "Org", "hot:0", vals[:])
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_bench_parameterized_query :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	buckets :: 10
	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("q:%06d", i)
		d := fmt.tprintf("dom%d.io", i % buckets)
		id_sid := bench_intern(s, k)
		dom_sid := bench_intern(s, d)
		vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + i)}
		_, _ = forseti.session_insert_fact(s, "Org", k, vals[:])
	}
	free_all(context.temp_allocator)

	target_dom := bench_intern(s, "dom3.io")
	args := [1]forseti.Query_Arg{{name = "d", value = target_dom}}

	hugi.set_items(b, 1)
	for hugi.step(b) {
		res: forseti.Query_Result
		_ = forseti.session_query(s, "orgs_in_domain", args[:], &res)
		_ = hugi.black_box(len(res.rows))
		forseti.query_result_destroy(&res)
	}
}

@(private = "file")
_BENCH_THREE_WAY_SRC :: `module bench_three_way version "1.0"
schema Org { id: string, dom: string }
schema Dept { id: string, dom: string }
schema Contract { id: string, dom: string, val: i64 }
schema Match3 { id: string, dom: string, val: i64 }
source Org : Org at .orgs[?id]
source Dept : Dept at .depts[?id]
source Contract : Contract at .contracts[?id]
derived Match3 : Match3 at .matches[?id]

rule join3 {
  when {
    ?_o := Org(id: ?oid, dom: ?d)
    ?_p := Dept(dom: ?d)
    ?_c := Contract(dom: ?d, val: ?v)
    where ?v >= 10
  }
  then { assert Match3(id: ?oid, dom: ?d, val: ?v) }
}`

@(private = "file")
_BENCH_EXISTS_ACCUM_SRC :: `module bench_exists_accum version "1.0"
schema Root { org_id: string }
schema InvItem { org_id: string, amt: i64 }
schema Flag { org_id: string }
schema Stats { org_id: string, mn: i64, mx: i64, av: f64, dcnt: i64 }
source Root : Root at .root[?org_id]
source InvItem : InvItem at .items[?id]
source Flag : Flag at .flags[?org_id]
derived Stats : Stats at .stats[?org_id]

rule agg_with_exists {
  when {
    ?_r := Root(org_id: ?oid)
    exists Flag(org_id: ?oid)
    ?mn := min(?a) from InvItem(org_id: ?oid, amt: ?a)
    ?mx := max(?a2) from InvItem(org_id: ?oid, amt: ?a2)
    ?av := avg(?a3) from InvItem(org_id: ?oid, amt: ?a3)
    ?dc := distinct(?a4) from InvItem(org_id: ?oid, amt: ?a4)
  }
  then { assert Stats(org_id: ?oid, mn: ?mn, mx: ?mx, av: ?av, dcnt: ?dc) }
}`

@(private = "file")
_bench_three_way_join_cold :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(_BENCH_THREE_WAY_SRC, "bench_three_way.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	keys := make([]string, n, context.temp_allocator)
	doms := make([]string, n, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		keys[i] = fmt.tprintf("k:%06d", i)
		doms[i] = fmt.tprintf("d:%06d", i)
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
		for i := 0; i < n; i += 1 {
			ksid := bench_intern(s, keys[i])
			dsid := bench_intern(s, doms[i])
			ov := [2]forseti.Value{ksid, dsid}
			dv := [2]forseti.Value{ksid, dsid}
			cv := [3]forseti.Value{ksid, dsid, i64(10 + (i % 50))}
			_, _ = forseti.session_insert_fact(s, "Org", keys[i], ov[:])
			_, _ = forseti.session_insert_fact(s, "Dept", keys[i], dv[:])
			_, _ = forseti.session_insert_fact(s, "Contract", keys[i], cv[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
		forseti.session_destroy(s)
		free(s)
	}
}

@(private = "file")
_bench_skewed_fanout_join :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	// Place hub_count facts on dom_hub.io so probing hot:hub hits a high-fanout bucket.
	hub_count := min(max(n / 10, 4), 100)
	hub_dom_sid := bench_intern(s, "dom_hub.io")
	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("sk:%06d", i)
		id_sid := bench_intern(s, k)
		dom_sid := hub_dom_sid if i < hub_count else bench_intern(s, fmt.tprintf("dom%05d.io", i))
		vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + (i % 50))}
		_, _ = forseti.session_insert_fact(s, "Org", k, vals[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	hot_id := bench_intern(s, "hot:hub")
	hugi.set_items(b, u64(hub_count))
	toggle: i64 = 500
	for hugi.step(b) {
		toggle = 600 if toggle == 500 else 500
		vals := [3]forseti.Value{hot_id, hub_dom_sid, toggle}
		_ = forseti.session_modify_fact_by_key(s, "Org", "hot:hub", vals[:])
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_bench_incremental_join_insert_retract :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("seed:%06d", i)
		d := fmt.tprintf("dom%05d.io", i / 2)
		id_sid := bench_intern(s, k)
		dom_sid := bench_intern(s, d)
		vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + (i % 10))}
		_, _ = forseti.session_insert_fact(s, "Org", k, vals[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	probe_id := bench_intern(s, "probe:0")
	probe_dom := bench_intern(s, "dom00000.io")
	probe_vals := [3]forseti.Value{probe_id, probe_dom, i64(500)}

	hugi.set_items(b, 2)
	for hugi.step(b) {
		_, _ = forseti.session_insert_fact(s, "Org", "probe:0", probe_vals[:])
		f1, _ := forseti.session_fire(s)
		_ = forseti.session_retract_fact_by_key(s, "Org", "probe:0")
		f2, _ := forseti.session_fire(s)
		_ = hugi.black_box(f1 + f2)
	}
}

@(private = "file")
_bench_incremental_join_audit_full :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JOIN_POLICY_SRC, "bench_joins.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	for i := 0; i < n; i += 1 {
		k := fmt.tprintf("seed:%06d", i)
		d := fmt.tprintf("dom%05d.io", i / 2)
		id_sid := bench_intern(s, k)
		dom_sid := bench_intern(s, d)
		vals := [3]forseti.Value{id_sid, dom_sid, i64(100 + (i % 10))}
		_, _ = forseti.session_insert_fact(s, "Org", k, vals[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	hot_id := bench_intern(s, "hot:0")
	hot_dom := bench_intern(s, "dom00000.io")
	init_vals := [3]forseti.Value{hot_id, hot_dom, i64(500)}
	_, _ = forseti.session_insert_fact(s, "Org", "hot:0", init_vals[:])
	_, _ = forseti.session_fire(s)

	hugi.set_items(b, 1)
	toggle: i64 = 500
	for hugi.step(b) {
		toggle = 600 if toggle == 500 else 500
		vals := [3]forseti.Value{hot_id, hot_dom, toggle}
		_ = forseti.session_modify_fact_by_key(s, "Org", "hot:0", vals[:])
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_bench_exists_and_accum_variants :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(_BENCH_EXISTS_ACCUM_SRC, "bench_exists_accum.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	root_sid := bench_intern(s, "org:acc")
	rvals := [1]forseti.Value{root_sid}
	_, _ = forseti.session_insert_fact(s, "Root", "org:acc", rvals[:])
	_, _ = forseti.session_insert_fact(s, "Flag", "org:acc", rvals[:])
	for i := 0; i < n; i += 1 {
		ik := fmt.tprintf("inv:%06d", i)
		iv := [2]forseti.Value{root_sid, i64(10 + (i % 50))}
		_, _ = forseti.session_insert_fact(s, "InvItem", ik, iv[:])
	}
	_, _ = forseti.session_fire(s)
	free_all(context.temp_allocator)

	hugi.set_items(b, 1)
	toggle: i64 = 5
	for hugi.step(b) {
		toggle = 99 if toggle == 5 else 5
		iv := [2]forseti.Value{root_sid, toggle}
		_ = forseti.session_modify_fact_by_key(s, "InvItem", "inv:000000", iv[:])
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

register_join_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "beta_joins")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "two_way_mdm_join", _bench_two_way_mdm_join)
	hugi.group_bench(g, "phreak_hot_match_zero_alloc", _bench_phreak_hot_match, zero_alloc = true)
	hugi.group_bench(g, "parameterized_query", _bench_parameterized_query)
	hugi.group_bench(g, "three_way_join_cold", _bench_three_way_join_cold)
	hugi.group_bench(g, "skewed_fanout_join", _bench_skewed_fanout_join)
	hugi.group_bench(g, "incremental_join_insert_retract", _bench_incremental_join_insert_retract)
	hugi.group_bench(g, "incremental_join_audit_full", _bench_incremental_join_audit_full)
	hugi.group_bench(g, "exists_and_accum_variants", _bench_exists_and_accum_variants)
}
