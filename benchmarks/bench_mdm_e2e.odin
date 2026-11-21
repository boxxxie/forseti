package main

import "core:fmt"
import hugi "hugi:."
import xitdb "xitdb:."
import forseti "../forseti"

@(private = "file")
_Mdm_Seed_Ctx :: struct {
	n: int,
}

@(private = "file")
_bench_mdm_seed_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Mdm_Seed_Ctx)(user_data)
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	k_name := forseti.prehashed_key_make("name")
	k_ctry := forseti.prehashed_key_make("country")
	k_dom := forseti.prehashed_key_make("domain")
	k_emp := forseti.prehashed_key_make("employees")
	k_act := forseti.prehashed_key_make("active")

	kbuf: [32]u8 = ---
	dbuf: [32]u8 = ---
	for i := 0; i < ctx.n; i += 1 {
		key := fmt.bprintf(kbuf[:], "org:%06d", i)
		dom := fmt.bprintf(dbuf[:], "dom%04d.com", i % 50)
		rwc := xitdb.hash_map_put_cursor(&m, key) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		forseti.hash_map_put_prehashed(&rm, &k_name, key) or_return
		forseti.hash_map_put_prehashed(&rm, &k_ctry, "US") or_return
		forseti.hash_map_put_prehashed(&rm, &k_dom, dom) or_return
		forseti.hash_map_put_prehashed(&rm, &k_emp, i64(150 + (i % 100))) or_return
		if forseti.write_bool_to_hash_map_prehashed(&rm, &k_act, true) != nil {
			return .Write_Failed
		}
	}
	return nil
}

@(private = "file")
_bench_mdm_delta_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	seq := (^i64)(user_data)^
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	k_name := forseti.prehashed_key_make("name")
	k_ctry := forseti.prehashed_key_make("country")
	k_dom := forseti.prehashed_key_make("domain")
	k_emp := forseti.prehashed_key_make("employees")
	k_act := forseti.prehashed_key_make("active")

	kbuf: [32]u8 = ---
	// Mutate 10 existing/hot records in a single atomic transaction while keeping N-10 unchanged.
	for j := 0; j < 10; j += 1 {
		key := fmt.bprintf(kbuf[:], "hot:%02d", j)
		rwc := xitdb.hash_map_put_cursor(&m, key) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		forseti.hash_map_put_prehashed(&rm, &k_name, key) or_return
		forseti.hash_map_put_prehashed(&rm, &k_ctry, "DE") or_return
		forseti.hash_map_put_prehashed(&rm, &k_dom, "hot.acme.com") or_return
		forseti.hash_map_put_prehashed(&rm, &k_emp, i64(200 + ((seq + i64(j)) % 100))) or_return
		if forseti.write_bool_to_hash_map_prehashed(&rm, &k_act, true) != nil {
			return .Write_Failed
		}
	}
	return nil
}

@(private = "file")
_run_mdm_e2e_incremental :: proc(
	b: ^hugi.Bencher,
	xcfg: forseti.Xitdb_Config,
	pmode: forseti.Provenance_Mode,
	commit_derived: bool,
) {
	n := max(hugi.param(b), 10)
	rb, ok := compile_benchmark_source(BENCH_MDM_E2E_POLICY_SRC, "bench_mdm_e2e.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, xcfg)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	seed_ctx := _Mdm_Seed_Ctx{n = n}
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_mdm_seed_cb, &seed_ctx)

	syncer := new(forseti.Delta_Syncer)
	_ = forseti.delta_syncer_init(syncer)
	_ = forseti.delta_syncer_watch(syncer, ".orgs.raw")
	defer {
		forseti.delta_syncer_destroy(syncer)
		free(syncer)
	}

	s := new(forseti.Session)
	_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = pmode})
	defer {
		forseti.session_destroy(s)
		free(s)
	}

	// Initial full load & firing outside the incremental measurement loop.
	_, _ = forseti.session_sync_and_fire(s, sb, syncer, commit_derived = commit_derived)

	hugi.set_items(b, 10)
	seq: i64 = 0
	for hugi.step(b) {
		seq += 1
		_, _ = forseti.store_bridge_commit_moment(sb, _bench_mdm_delta_cb, &seq)
		fired, _ := forseti.session_sync_and_fire(s, sb, syncer, commit_derived = commit_derived)
		_ = hugi.black_box(fired)
	}
}

@(private = "file")
_bench_mdm_audit_full_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_mdm_e2e_incremental(b, forseti.Xitdb_Config{mode = .Safe_V2}, .Audit_Full, true)
}

@(private = "file")
_bench_mdm_fast_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_mdm_e2e_incremental(b, forseti.Xitdb_Config{mode = .Safe_V2}, .Fast, false)
}

@(private = "file")
_bench_mdm_audit_full_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_mdm_e2e_incremental(b, forseti.Xitdb_Config{mode = .Fast_Memory}, .Audit_Full, true)
}

register_mdm_e2e_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "mdm_e2e")
	hugi.group_params(g, []int{10, 100, 1_000, 10_000})
	hugi.group_bench(g, "incremental_sync_fire_audit_full_safe_v2", _bench_mdm_audit_full_safe_v2)
	hugi.group_bench(g, "incremental_sync_fire_fast_safe_v2", _bench_mdm_fast_safe_v2)
	hugi.group_bench(g, "incremental_sync_fire_audit_full_fast_memory", _bench_mdm_audit_full_fast_memory)
}
