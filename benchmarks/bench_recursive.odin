package main

import "core:fmt"
import hugi "hugi:."
import forseti "../forseti"

@(private = "file")
_bench_seminaive_dag_closure :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_RECURSIVE_POLICY_SRC, "bench_recursive.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	// Build a bounded-depth forest/DAG (depth <= 5 per root chain) so transitive closure stays O(N).
	edge_keys := make([]string, n, context.temp_allocator)
	src_names := make([]string, n, context.temp_allocator)
	dst_names := make([]string, n, context.temp_allocator)
	for i := 0; i < n; i += 1 {
		chain_step := i % 4
		base := (i / 4) * 5
		u := "root" if chain_step == 0 else fmt.tprintf("n%d", base + chain_step)
		v := fmt.tprintf("n%d", base + chain_step + 1)
		edge_keys[i] = fmt.tprintf("e%d", i)
		src_names[i] = u
		dst_names[i] = v
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Fast})
		for i := 0; i < n; i += 1 {
			usid := bench_intern(s, src_names[i])
			vsid := bench_intern(s, dst_names[i])
			vals := [2]forseti.Value{usid, vsid}
			_, _ = forseti.session_insert_fact(s, "Edge", edge_keys[i], vals[:])
		}
		fired, _ := forseti.session_fire(s)
		_ = hugi.black_box(fired)
		forseti.session_destroy(s)
		free(s)
	}
}

register_recursive_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "recursive_strata")
	hugi.group_params(g, []int{10, 100, 1_000, 5_000})
	hugi.group_bench(g, "seminaive_dag_closure", _bench_seminaive_dag_closure)
}
