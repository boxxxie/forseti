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

register_join_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "beta_joins")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "two_way_mdm_join", _bench_two_way_mdm_join)
	hugi.group_bench(g, "phreak_hot_match_zero_alloc", _bench_phreak_hot_match, zero_alloc = true)
	hugi.group_bench(g, "parameterized_query", _bench_parameterized_query)
}
