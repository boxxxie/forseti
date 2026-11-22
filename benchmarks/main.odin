package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import hugi "hugi:."
import forseti "../forseti"

g_bench_root_allocator: mem.Allocator

run_profile_1m :: proc() -> int {
	scales := [6]int{10, 100, 1_000, 10_000, 100_000, 1_000_000}
	fmt.println("scale_rules,compile_ms,rb_arena_bytes,sess_init_us,fire_1_us,fire_100_us,live_mems,alpha_shared,segs_linked,segs_skipped,peak_arena_bytes,trace_ok")

	for n in scales {
		tel: forseti.Telemetry_Sink
		if err := forseti.telemetry_init(&tel, enabled = true); err != nil {
			fmt.eprintfln("telemetry_init failed: %v", err)
			return 1
		}

		ir := gen_scaled_rule_ir(n, &tel)

		t0 := time.tick_now()
		rb := new(forseti.Rulebase)
		compiled, c_err := forseti.rulebase_compile(&ir, &tel)
		compile_ns := time.duration_nanoseconds(time.tick_diff(t0, time.tick_now()))
		forseti.ir_destroy(&ir)
		if c_err != .None {
			forseti.telemetry_destroy(&tel)
			free(rb)
			fmt.eprintfln("rulebase_compile(%d) failed: %v", n, c_err)
			return 1
		}
		rb^ = compiled
		rb_bytes := rb.arena.total_used

		// Measure lazy session init over N rules.
		s1 := new(forseti.Session)
		ti0 := time.tick_now()
		s_err := forseti.session_init(s1, rb, forseti.Session_Config{provenance_mode = .Fast}, &tel)
		init_ns := time.duration_nanoseconds(time.tick_diff(ti0, time.tick_now()))
		if s_err != .None {
			forseti.session_destroy(s1)
			free(s1)
			forseti.rulebase_destroy(rb)
			free(rb)
			forseti.telemetry_destroy(&tel)
			return 1
		}

		saas_sid := bench_intern(s1, "saas")
		hot_sid := bench_intern(s1, "org:0")
		tf1 := time.tick_now()
		v1 := [3]forseti.Value{hot_sid, saas_sid, i64(n / 2)}
		_, _ = forseti.session_insert_fact(s1, "Org", "org:0", v1[:])
		fired1, _ := forseti.session_fire(s1)
		fire1_ns := time.duration_nanoseconds(time.tick_diff(tf1, time.tick_now()))
		if fired1 != 1 {
			fmt.eprintfln("scale %d expected 1 fire, got %d", n, fired1)
			return 1
		}

		// Measure 100-fact sparse fire on a fresh session to capture active-vs-unlinked ratios.
		s100 := new(forseti.Session)
		_ = forseti.session_init(s100, rb, forseti.Session_Config{provenance_mode = .Fast}, &tel)
		saas2 := bench_intern(s100, "saas")
		kbuf: [24]u8 = ---
		tf100 := time.tick_now()
		for i := 0; i < 100; i += 1 {
			k := fmt.bprintf(kbuf[:], "org:%d", i)
			ksid := bench_intern(s100, k)
			bucket := i64((i * 7919) % n)
			vi := [3]forseti.Value{ksid, saas2, bucket}
			_, _ = forseti.session_insert_fact(s100, "Org", k, vi[:])
		}
		_, _ = forseti.session_fire(s100)
		fire100_ns := time.duration_nanoseconds(time.tick_diff(tf100, time.tick_now()))

		live_mems := s100.live_memories_count
		alpha_shared := tel.counters[.Alpha_Nodes_Shared]
		segs_linked := tel.counters[.Segments_Linked]
		segs_skipped := tel.counters[.Segments_Skipped_Unlinked]
		peak_arena := tel.watermarks.peak_arena_bytes

		trace_json, j_err := forseti.telemetry_export_chrome_trace(&tel)
		trace_ok := j_err == nil &&
			strings.contains(trace_json, `"traceEvents"`) &&
			strings.contains(trace_json, `"cat":"compile"`) &&
			strings.contains(trace_json, `"cat":"match"`)
		delete(trace_json)

		fmt.printfln(
			"%d,%.2f,%d,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%v",
			n,
			f64(compile_ns) / 1e6,
			rb_bytes,
			f64(init_ns) / 1e3,
			f64(fire1_ns) / 1e3,
			f64(fire100_ns) / 1e3,
			live_mems,
			alpha_shared,
			segs_linked,
			segs_skipped,
			peak_arena,
			trace_ok,
		)

		forseti.session_destroy(s100)
		free(s100)
		forseti.session_destroy(s1)
		free(s1)
		forseti.rulebase_destroy(rb)
		free(rb)
		forseti.telemetry_destroy(&tel)
		free_all(context.temp_allocator)
		if !trace_ok {
			return 1
		}
	}
	return 0
}

main :: proc() {
	g_bench_root_allocator = context.allocator
	for arg in os.args[1:] {
		if arg == "--profile-1m" {
			code := run_profile_1m()
			if code != 0 {
				os.exit(code)
			}
			return
		}
	}

	suite := hugi.suite_create("forseti_benchmarks")
	defer {
		scale_bench_cache_destroy()
		hugi.suite_destroy(&suite)
	}

	register_table_benchmarks(&suite)
	register_frontend_benchmarks(&suite)
	register_vm_benchmarks(&suite)
	register_xitdb_benchmarks(&suite)
	register_scale_rule_benchmarks(&suite)
	register_scale_join_benchmarks(&suite)
	register_join_benchmarks(&suite)
	register_jtms_benchmarks(&suite)
	register_recursive_benchmarks(&suite)
	register_provenance_replay_benchmarks(&suite)
	register_mdm_e2e_benchmarks(&suite)

	if !hugi.suite_run(&suite) {
		fmt.eprintln("forseti benchmarks failed")
		os.exit(1)
	}
}
