package main

import "core:fmt"
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

register_scale_rule_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "scale_rules")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000, 100_000, 1_000_000})
	hugi.group_bench(g, "compile_rules", _bench_compile_rules)
	hugi.group_bench(g, "lazy_session_init", _bench_lazy_session_init)
	hugi.group_bench(g, "sparse_alpha_match", _bench_sparse_alpha_match)
	hugi.group_bench(g, "batch_100_alpha_match", _bench_batch_100_alpha_match)
}
