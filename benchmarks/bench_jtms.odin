package main

import "core:fmt"
import hugi "hugi:."
import forseti "../forseti"

@(private = "file")
_run_jtms_cascade :: proc(b: ^hugi.Bencher, mode: forseti.Provenance_Mode) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JTMS_POLICY_SRC, "bench_jtms.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	keys := make([]string, n, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		keys[i] = fmt.tprintf("org:%06d", i)
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = mode})
		for k in keys {
			sid := bench_intern(s, k)
			vals := [2]forseti.Value{sid, i64(100)}
			_, _ = forseti.session_insert_fact(s, "Root", k, vals[:])
		}
		_, _ = forseti.session_fire(s)
		for k in keys {
			_ = forseti.session_retract_fact_by_key(s, "Root", k)
		}
		_, _ = forseti.session_fire(s)
		_ = hugi.black_box(len(s.provenance.derivs))
		forseti.session_destroy(s)
		free(s)
	}
}

@(private = "file")
_bench_jtms_audit_full :: proc(b: ^hugi.Bencher) {
	_run_jtms_cascade(b, .Audit_Full)
}

@(private = "file")
_bench_jtms_fast_mode :: proc(b: ^hugi.Bencher) {
	_run_jtms_cascade(b, .Fast)
}

@(private = "file")
_bench_retractable_accum :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_JTMS_POLICY_SRC, "bench_jtms.forseti")
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
	rvals := [2]forseti.Value{root_sid, i64(250)}
	_, _ = forseti.session_insert_fact(s, "Root", "org:acc", rvals[:])

	item_keys := make([]string, n, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		item_keys[i] = fmt.tprintf("inv:%06d", i)
		ivals := [2]forseti.Value{root_sid, i64(i + 1)}
		_, _ = forseti.session_insert_fact(s, "InvItem", item_keys[i], ivals[:])
	}
	_, _ = forseti.session_fire(s)
	defer free_all(context.temp_allocator)

	hugi.set_items(b, 2)
	toggle: i64 = 10
	for hugi.step(b) {
		toggle = 20 if toggle == 10 else 10
		ivals := [2]forseti.Value{root_sid, toggle}
		_ = forseti.session_modify_fact_by_key(s, "InvItem", "inv:000000", ivals[:])
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
	}
}

register_jtms_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "jtms_churn")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "cascade_retract_audit_full", _bench_jtms_audit_full)
	hugi.group_bench(g, "cascade_retract_fast_mode", _bench_jtms_fast_mode)
	hugi.group_bench(g, "retractable_accum_sum", _bench_retractable_accum)
}
