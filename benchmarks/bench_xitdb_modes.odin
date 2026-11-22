package main

import "core:fmt"
import "core:os"
import vmem "core:mem/virtual"
import hugi "hugi:."
import xitdb "xitdb:."
import "../forseti"

@(private = "file")
_SEED_COUNT :: 10_000

@(private = "file")
_bench_seed_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	n := (^int)(user_data)^
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	kbuf: [32]u8 = ---
	for i := 0; i < n; i += 1 {
		k := fmt.bprintf(kbuf[:], "org:%06d", i)
		xitdb.hash_map_put(&m, k, i64(i)) or_return
	}
	return nil
}

@(private = "file")
_bench_mutate_10_cb :: proc(moment_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	kbuf: [32]u8 = ---
	for i := 0; i < 4; i += 1 {
		k := fmt.bprintf(kbuf[:], "org:%06d", i * 2000 + 17)
		xitdb.hash_map_put(&m, k, i64(900_000 + i)) or_return
	}
	for i := 0; i < 3; i += 1 {
		k := fmt.bprintf(kbuf[:], "org:%06d", i * 2000 + 99)
		_, _ = xitdb.hash_map_remove(&m, k)
	}
	for i := 0; i < 3; i += 1 {
		k := fmt.bprintf(kbuf[:], "org:%06d", _SEED_COUNT + i)
		xitdb.hash_map_put(&m, k, i64(_SEED_COUNT + i)) or_return
	}
	return nil
}

@(private = "file")
_bench_single_put_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	seq := (^i64)(user_data)^
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	kbuf: [32]u8 = ---
	k := fmt.bprintf(kbuf[:], "org:%06d", int(seq % _SEED_COUNT))
	xitdb.hash_map_put(&m, k, seq) or_return
	return nil
}

@(private = "file")
_run_insert_10k :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	count := _SEED_COUNT
	hugi.set_items(b, u64(count))

	for hugi.step(b) {
		sb := new(forseti.Store_Bridge)
		_ = forseti.store_bridge_init_standalone(sb, cfg)
		_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &count)
		_ = hugi.black_box(sb.db.header.file_id)
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
}

@(private = "file")
_run_lookup_10k :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, cfg)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	count := _SEED_COUNT
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &count)

	m_cur, _, _ := forseti.store_bridge_moment_cursor(sb, -1)
	col_cur, _, _ := forseti.store_resolve_path(m_cur, ".orgs.raw")

	keys := make([]string, count, context.temp_allocator)
	for i := 0; i < count; i += 1 {
		keys[i] = fmt.tprintf("org:%06d", i)
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(count))
	hugi.expect_zero_allocs(b)

	sum: i64 = 0
	for hugi.step(b) {
		for k in keys {
			rec, ok, _ := forseti.store_lookup_record(col_cur, k)
			if ok {
				v, _, _ := forseti.cursor_read_value(rec, nil)
				if iv, is_i := v.(i64); is_i {
					sum += iv
				}
			}
		}
	}
	_ = hugi.black_box(sum)
}

@(private = "file")
_run_diff_10_of_10k :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, cfg)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	count := _SEED_COUNT
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &count)
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_mutate_10_cb, nil)

	m0, _, _ := forseti.store_bridge_moment_cursor(sb, 0)
	m1, _, _ := forseti.store_bridge_moment_cursor(sb, 1)
	col0, _, _ := forseti.store_resolve_path(m0, ".orgs.raw")
	col1, _, _ := forseti.store_resolve_path(m1, ".orgs.raw")

	scratch: vmem.Arena
	_ = vmem.arena_init_growing(&scratch)
	defer vmem.arena_destroy(&scratch)
	s_alloc := vmem.arena_allocator(&scratch)

	hugi.set_items(b, u64(10))

	total_skipped: u64 = 0
	for hugi.step(b) {
		vmem.arena_free_all(&scratch)
		stats: xitdb.Diff_Stats
		changes, _ := xitdb.diff_collection_with_stats(col0, col1, &stats, s_alloc, s_alloc)
		total_skipped += stats.slots_skipped + u64(len(changes))
	}
	_ = hugi.black_box(total_skipped)
}

@(private = "file")
_run_commit_cycle :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, cfg)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	base := 1_000
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &base)

	hugi.set_items(b, u64(1))
	seq: i64 = 0
	for hugi.step(b) {
		seq += 1
		m_idx, _ := forseti.store_bridge_commit_moment(sb, _bench_single_put_cb, &seq)
		_ = hugi.black_box(m_idx)
	}
}

@(private = "file")
_run_lookup_10k_prehashed :: proc(b: ^hugi.Bencher, cfg: forseti.Xitdb_Config) {
	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, cfg)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	count := _SEED_COUNT
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &count)

	m_cur, _, _ := forseti.store_bridge_moment_cursor(sb, -1)
	col_cur, _, _ := forseti.store_resolve_path(m_cur, ".orgs.raw")
	rm, _ := xitdb.read_hash_map_init(col_cur)

	pkeys := make([]forseti.Prehashed_Key, count, context.temp_allocator)
	for i := 0; i < count; i += 1 {
		pkeys[i] = forseti.prehashed_key_make(fmt.tprintf("org:%06d", i))
	}
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(count))
	hugi.expect_zero_allocs(b)

	sum: i64 = 0
	for hugi.step(b) {
		for &pk in pkeys {
			ms, _ := forseti.hash_map_get_slot_prehashed(rm, &pk)
			if slot, ok := ms.?; ok {
				v, _, _ := forseti.decode_slot_to_value(sb.db, slot, nil)
				if iv, is_i := v.(i64); is_i {
					sum += iv
				}
			}
		}
	}
	_ = hugi.black_box(sum)
}

@(private = "file")
_bench_seed_records_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	n := (^int)(user_data)^
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	k_emp := forseti.prehashed_key_make("employees")
	kbuf: [32]u8 = ---
	for i := 0; i < n; i += 1 {
		k := fmt.bprintf(kbuf[:], "org:%06d", i)
		rwc := xitdb.hash_map_put_cursor(&m, k) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		forseti.hash_map_put_prehashed(&rm, &k_emp, i64(i)) or_return
	}
	return nil
}

@(private = "file")
_run_field_read_10k :: proc(b: ^hugi.Bencher, prehashed: bool) {
	sb := new(forseti.Store_Bridge)
	_ = forseti.store_bridge_init_standalone(sb, forseti.Xitdb_Config{mode = .Safe_V2})
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	count := _SEED_COUNT
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_records_cb, &count)

	m_cur, _, _ := forseti.store_bridge_moment_cursor(sb, -1)
	col_cur, _, _ := forseti.store_resolve_path(m_cur, ".orgs.raw")

	rec_curs := make([]xitdb.Read_Cursor, count, context.temp_allocator)
	for i := 0; i < count; i += 1 {
		rc, _, _ := forseti.store_lookup_record(col_cur, fmt.tprintf("org:%06d", i))
		rec_curs[i] = rc
	}
	defer free_all(context.temp_allocator)

	str_path := [1]string{"employees"}
	pre_path := [1]forseti.Prehashed_Key{forseti.prehashed_key_make("employees")}

	hugi.set_items(b, u64(count))
	hugi.expect_zero_allocs(b)

	sum: i64 = 0
	for hugi.step(b) {
		if prehashed {
			for rc in rec_curs {
				v, ok, _ := forseti.cursor_read_field_path_prehashed(rc, pre_path[:], nil, .I64)
				if ok {
					if iv, is_i := v.(i64); is_i {
						sum += iv
					}
				}
			}
		} else {
			for rc in rec_curs {
				v, ok, _ := forseti.cursor_read_field_path(rc, str_path[:], nil, .I64)
				if ok {
					if iv, is_i := v.(i64); is_i {
						sum += iv
					}
				}
			}
		}
	}
	_ = hugi.black_box(sum)
}

@(private = "file")
_bench_batch_1k_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	n := (^int)(user_data)^
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	kbuf: [32]u8 = ---
	for i := 0; i < n; i += 1 {
		k := fmt.bprintf(kbuf[:], "batch:%06d", i)
		xitdb.hash_map_put(&m, k, i64(i)) or_return
	}
	return nil
}

@(private = "file")
_run_batch_vs_separate_1k :: proc(b: ^hugi.Bencher, single_tx: bool) {
	n :: 1_000
	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		sb := new(forseti.Store_Bridge)
		_ = forseti.store_bridge_init_standalone(sb, forseti.Xitdb_Config{mode = .Safe_V2})
		if single_tx {
			cnt := n
			_, _ = forseti.store_bridge_commit_moment(sb, _bench_batch_1k_cb, &cnt)
		} else {
			for i := 0; i < n; i += 1 {
				seq := i64(i)
				_, _ = forseti.store_bridge_commit_moment(sb, _bench_single_put_cb, &seq)
			}
		}
		_ = hugi.black_box(sb.db.header.file_id)
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
}

@(private = "file")
_bench_insert_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_insert_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_insert_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_insert_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory})
}

@(private = "file")
_bench_lookup_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_lookup_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_lookup_safe_v2_prehashed_cursor :: proc(b: ^hugi.Bencher) {
	_run_lookup_10k_prehashed(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_lookup_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_lookup_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory})
}

@(private = "file")
_bench_field_read_10k_safe_v2_string :: proc(b: ^hugi.Bencher) {
	_run_field_read_10k(b, prehashed = false)
}

@(private = "file")
_bench_field_read_10k_safe_v2_prehashed :: proc(b: ^hugi.Bencher) {
	_run_field_read_10k(b, prehashed = true)
}

@(private = "file")
_bench_diff_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_diff_10_of_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_diff_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_diff_10_of_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory})
}

@(private = "file")
_bench_commit_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_commit_cycle(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_commit_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_commit_cycle(b, forseti.Xitdb_Config{mode = .Fast_Memory})
}

@(private = "file")
_bench_batch_write_1k_single_tx_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_batch_vs_separate_1k(b, single_tx = true)
}

@(private = "file")
_bench_single_write_1k_separate_tx_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_batch_vs_separate_1k(b, single_tx = false)
}

@(private = "file")
_bench_file_buffered_write_1k_single_tx_safe_v2 :: proc(b: ^hugi.Bencher) {
	n :: 1_000
	dir, d_err := os.make_directory_temp("", "forseti_xit_w1k_*", context.allocator)
	if d_err != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	pbuf: [256]u8 = ---
	hugi.set_items(b, u64(n))
	iter := 0
	for hugi.step(b) {
		iter += 1
		db_path := fmt.bprintf(pbuf[:], "%s/w_%d.xit", dir, iter)
		sb := new(forseti.Store_Bridge)
		if forseti.store_bridge_open_file(sb, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
			free(sb)
			break
		}
		cnt := n
		_, _ = forseti.store_bridge_commit_moment(sb, _bench_batch_1k_cb, &cnt)
		_ = hugi.black_box(sb.db.header.file_id)
		forseti.store_bridge_destroy(sb)
		free(sb)
		_ = os.remove(db_path)
	}
}

@(private = "file")
_bench_file_buffered_commit_cycle_safe_v2 :: proc(b: ^hugi.Bencher) {
	dir, d_err := os.make_directory_temp("", "forseti_xit_cyc_*", context.allocator)
	if d_err != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	pbuf: [256]u8 = ---
	db_path := fmt.bprintf(pbuf[:], "%s/cycle.xit", dir)
	sb := new(forseti.Store_Bridge)
	if forseti.store_bridge_open_file(sb, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
		free(sb)
		return
	}
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	base := 1_000
	_, _ = forseti.store_bridge_commit_moment(sb, _bench_seed_cb, &base)

	hugi.set_items(b, 1)
	seq: i64 = 0
	for hugi.step(b) {
		seq += 1
		m_idx, _ := forseti.store_bridge_commit_moment(sb, _bench_single_put_cb, &seq)
		_ = hugi.black_box(m_idx)
	}
}

@(private = "file")
_bench_file_reopen_hydrate_session_1k :: proc(b: ^hugi.Bencher) {
	n :: 1_000
	rb, ok := compile_benchmark_source(BENCH_MDM_E2E_POLICY_SRC, "bench_hydrate.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}

	dir, d_err := os.make_directory_temp("", "forseti_xit_hyd_*", context.allocator)
	if d_err != nil {
		return
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}

	pbuf: [256]u8 = ---
	db_path := fmt.bprintf(pbuf[:], "%s/hydrate.xit", dir)
	{
		sb := new(forseti.Store_Bridge)
		if forseti.store_bridge_open_file(sb, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
			free(sb)
			return
		}
		seed_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
			cnt := (^int)(user_data)^
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
			for i := 0; i < cnt; i += 1 {
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
		cnt := n
		_, _ = forseti.store_bridge_commit_moment(sb, seed_cb, &cnt)
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		sb := new(forseti.Store_Bridge)
		if forseti.store_bridge_open_file(sb, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
			free(sb)
			break
		}
		syncer := new(forseti.Delta_Syncer)
		_ = forseti.delta_syncer_init(syncer)
		_ = forseti.delta_syncer_watch(syncer, ".orgs.raw")
		s := new(forseti.Session)
		_ = forseti.session_init(s, rb, forseti.Session_Config{provenance_mode = .Audit_Full})
		fired, _ := forseti.session_sync_and_fire(s, sb, syncer, commit_derived = false)
		_ = hugi.black_box(fired)
		forseti.session_destroy(s)
		free(s)
		forseti.delta_syncer_destroy(syncer)
		free(syncer)
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
}

register_xitdb_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "xitdb_modes")
	hugi.group_bench(g, "insert_10k_safe_v2", _bench_insert_safe_v2)
	hugi.group_bench(g, "insert_10k_fast_memory", _bench_insert_fast_memory)
	hugi.group_bench(g, "lookup_10k_safe_v2", _bench_lookup_safe_v2, zero_alloc = true)
	hugi.group_bench(g, "lookup_10k_safe_v2_prehashed_cursor", _bench_lookup_safe_v2_prehashed_cursor, zero_alloc = true)
	hugi.group_bench(g, "lookup_10k_fast_memory", _bench_lookup_fast_memory, zero_alloc = true)
	hugi.group_bench(g, "field_read_10k_safe_v2_string", _bench_field_read_10k_safe_v2_string, zero_alloc = true)
	hugi.group_bench(g, "field_read_10k_safe_v2_prehashed", _bench_field_read_10k_safe_v2_prehashed, zero_alloc = true)
	hugi.group_bench(g, "diff_10_of_10k_safe_v2", _bench_diff_safe_v2)
	hugi.group_bench(g, "diff_10_of_10k_fast_memory", _bench_diff_fast_memory)
	hugi.group_bench(g, "commit_cycle_safe_v2", _bench_commit_safe_v2)
	hugi.group_bench(g, "commit_cycle_fast_memory", _bench_commit_fast_memory)
	hugi.group_bench(g, "batch_write_1k_single_tx_safe_v2", _bench_batch_write_1k_single_tx_safe_v2)
	hugi.group_bench(g, "single_write_1k_separate_tx_safe_v2", _bench_single_write_1k_separate_tx_safe_v2)
	hugi.group_bench(g, "file_buffered_write_1k_single_tx_safe_v2", _bench_file_buffered_write_1k_single_tx_safe_v2)
	hugi.group_bench(g, "file_buffered_commit_cycle_safe_v2", _bench_file_buffered_commit_cycle_safe_v2)
	hugi.group_bench(g, "file_reopen_hydrate_session_1k", _bench_file_reopen_hydrate_session_1k)
}
