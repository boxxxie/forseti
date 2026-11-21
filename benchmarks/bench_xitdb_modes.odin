package main

import "core:fmt"
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
_bench_insert_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_insert_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_insert_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_insert_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory, skip_memory_crc = true})
}

@(private = "file")
_bench_lookup_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_lookup_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_lookup_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_lookup_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory, skip_memory_crc = true})
}

@(private = "file")
_bench_diff_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_diff_10_of_10k(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_diff_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_diff_10_of_10k(b, forseti.Xitdb_Config{mode = .Fast_Memory, skip_memory_crc = true})
}

@(private = "file")
_bench_commit_safe_v2 :: proc(b: ^hugi.Bencher) {
	_run_commit_cycle(b, forseti.Xitdb_Config{mode = .Safe_V2})
}

@(private = "file")
_bench_commit_fast_memory :: proc(b: ^hugi.Bencher) {
	_run_commit_cycle(b, forseti.Xitdb_Config{mode = .Fast_Memory, skip_memory_crc = true})
}

register_xitdb_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "xitdb_modes")
	hugi.group_bench(g, "insert_10k_safe_v2", _bench_insert_safe_v2)
	hugi.group_bench(g, "insert_10k_fast_memory", _bench_insert_fast_memory)
	hugi.group_bench(g, "lookup_10k_safe_v2", _bench_lookup_safe_v2, zero_alloc = true)
	hugi.group_bench(g, "lookup_10k_fast_memory", _bench_lookup_fast_memory, zero_alloc = true)
	hugi.group_bench(g, "diff_10_of_10k_safe_v2", _bench_diff_safe_v2)
	hugi.group_bench(g, "diff_10_of_10k_fast_memory", _bench_diff_fast_memory)
	hugi.group_bench(g, "commit_cycle_safe_v2", _bench_commit_safe_v2)
	hugi.group_bench(g, "commit_cycle_fast_memory", _bench_commit_fast_memory)
}
