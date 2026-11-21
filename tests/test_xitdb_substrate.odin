package forseti_tests

import "core:mem"
import "core:slice"
import "core:testing"
import xitdb "xitdb:."
import "../forseti"

@(test)
test_xitdb_slot_to_value_decoding_and_zero_alloc_scalars :: proc(t: ^testing.T) {
	sb := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb), nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	interner: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&interner), nil)
	defer forseti.interner_destroy(&interner)

	// Pre-intern expected strings so lookup/decoding measures strictly 0 heap allocations.
	_, i_err1 := forseti.intern(&interner, "short6")
	_, i_err2 := forseti.intern(&interner, "organization_long_identifier_value")
	testing.expect_value(t, i_err1, nil)
	testing.expect_value(t, i_err2, nil)

	_Write_Cb_Data :: struct {
		interner: ^forseti.String_Interner,
	}
	cb_data := _Write_Cb_Data{interner = &interner}

	write_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
		_ = (^_Write_Cb_Data)(user_data)
		m := xitdb.write_hash_map_init(moment_wc^) or_return
		xitdb.hash_map_put(&m, "i64_v", i64(-42)) or_return
		xitdb.hash_map_put(&m, "u64_v", u64(9001)) or_return
		xitdb.hash_map_put(&m, "f64_v", f64(3.25)) or_return
		if err := forseti.write_bool_to_hash_map(&m, "bool_t", true); err != nil {
			return .Write_Failed
		}
		if err := forseti.write_bool_to_hash_map(&m, "bool_f", false); err != nil {
			return .Write_Failed
		}
		xitdb.hash_map_put(&m, "short_s", "short6") or_return
		xitdb.hash_map_put(&m, "long_s", "organization_long_identifier_value") or_return
		xitdb.hash_map_put(&m, "time_ns", i64(1700000000)) or_return
		xitdb.hash_map_put(&m, "ent_id", u64(777)) or_return
		return nil
	}

	m_idx, m_err := forseti.store_bridge_commit_moment(sb, write_cb, &cb_data)
	testing.expect_value(t, m_err, nil)
	testing.expect_value(t, m_idx, i64(0))

	m_cur, m_ok, r_err := forseti.store_bridge_moment_cursor(sb, 0)
	testing.expect_value(t, r_err, nil)
	testing.expect(t, m_ok)

	rm, rm_err := xitdb.read_hash_map_init(m_cur)
	testing.expect_value(t, rm_err, nil)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer context.allocator = prev_alloc

	read_checked :: proc(t: ^testing.T, rm: xitdb.Read_Hash_Map, key: string, interner: ^forseti.String_Interner, exp_kind: forseti.Type_Kind = .Unknown) -> forseti.Value {
		cur, err := xitdb.hash_map_get_cursor(rm, key)
		testing.expect_value(t, err, nil)
		c, ok := cur.?
		testing.expect(t, ok)
		v, vok, verr := forseti.cursor_read_value(c, interner, exp_kind)
		testing.expect_value(t, verr, nil)
		testing.expect(t, vok)
		return v
	}

	testing.expect_value(t, read_checked(t, rm, "i64_v", &interner), forseti.Value(i64(-42)))
	testing.expect_value(t, read_checked(t, rm, "u64_v", &interner), forseti.Value(i64(9001)))
	testing.expect_value(t, read_checked(t, rm, "f64_v", &interner), forseti.Value(f64(3.25)))
	testing.expect_value(t, read_checked(t, rm, "bool_t", &interner), forseti.Value(true))
	testing.expect_value(t, read_checked(t, rm, "bool_f", &interner), forseti.Value(false))
	testing.expect_value(t, read_checked(t, rm, "i64_v", &interner, .I32), forseti.Value(i32(-42)))
	testing.expect_value(t, read_checked(t, rm, "time_ns", &interner, .Time), forseti.Value(forseti.Time_Ns(1700000000)))
	testing.expect_value(t, read_checked(t, rm, "ent_id", &interner, .Entity), forseti.Value(forseti.Entity_Id(777)))

	v_short := read_checked(t, rm, "short_s", &interner)
	testing.expect_value(t, forseti.interner_get(&interner, v_short.(forseti.String_Id)), "short6")

	v_long := read_checked(t, rm, "long_s", &interner)
	testing.expect_value(t, forseti.interner_get(&interner, v_long.(forseti.String_Id)), "organization_long_identifier_value")

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
test_xitdb_safe_v2_wire_layout_and_fast_hasher :: proc(t: ^testing.T) {
	// Default Safe_V2 core produces standard v2 57-byte genesis layout (SHA-1, hash_id=0, non-zero CRC-64/XZ).
	sb_safe := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb_safe), nil)
	defer {
		forseti.store_bridge_destroy(sb_safe)
		free(sb_safe)
	}

	raw_safe := xitdb.core_memory_bytes(sb_safe.db.core)
	testing.expect(t, len(raw_safe) >= 57)
	testing.expect(t, slice.equal(raw_safe[0:3], []u8{'x', 'i', 't'}))
	testing.expect_value(t, sb_safe.db.header.version, u16(2))
	testing.expect_value(t, sb_safe.db.header.hash_size, u16(20))
	testing.expect_value(t, sb_safe.db.header.hash_id, u32(0))
	testing.expect(t, !sb_safe.db.skip_memory_crc)

	safe_csz, _ := xitdb.database_committed_size(sb_safe.db)
	safe_trailer, t_err := xitdb.database_read_root_trailer(sb_safe.db, safe_csz)
	testing.expect_value(t, t_err, nil)
	testing.expect(t, safe_trailer.checksum != 0)

	// Opt-in Fast_Memory uses 16-byte fast_hasher ("fh16") and zeroes CRC trailer when requested.
	sb_fast := new(forseti.Store_Bridge)
	testing.expect_value(
		t,
		forseti.store_bridge_init_standalone(
			sb_fast,
			forseti.Xitdb_Config{mode = .Fast_Memory, skip_memory_crc = true},
		),
		nil,
	)
	defer {
		forseti.store_bridge_destroy(sb_fast)
		free(sb_fast)
	}

	testing.expect_value(t, sb_fast.db.header.hash_size, u16(16))
	testing.expect_value(t, sb_fast.db.header.hash_id, xitdb.FAST_HASH_ID)
	testing.expect(t, sb_fast.db.skip_memory_crc)

	fast_csz, _ := xitdb.database_committed_size(sb_fast.db)
	fast_trailer, ft_err := xitdb.database_read_root_trailer(sb_fast.db, fast_csz)
	testing.expect_value(t, ft_err, nil)
	testing.expect_value(t, fast_trailer.checksum, u64(0))

	d1, d2, d3: [16]u8
	xitdb.fast_hash128_sum_into(transmute([]u8)string("org:acme"), d1[:])
	xitdb.fast_hash128_sum_into(transmute([]u8)string("org:acme"), d2[:])
	xitdb.fast_hash128_sum_into(transmute([]u8)string("org:beta"), d3[:])
	testing.expect(t, slice.equal(d1[:], d2[:]))
	testing.expect(t, !slice.equal(d1[:], d3[:]))
}

@(test)
test_xitdb_sorted_diff_with_stats_and_eav_helpers :: proc(t: ^testing.T) {
	core := xitdb.core_memory_init()
	defer _ = xitdb.core_destroy(&core)

	db, d_err := xitdb.database_init(&core, xitdb.fast_hasher())
	testing.expect_value(t, d_err, nil)

	// Wait: database_init works cleanly with custom fast_hasher without skip_memory_crc!
	rc := xitdb.database_root_cursor(&db)
	hist, h_err := xitdb.write_array_list_init(rc)
	testing.expect_value(t, h_err, nil)

	seed_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		sm := xitdb.write_sorted_map_init(m_wc^) or_return
		for i in 0 ..< 250 {
			k := [6]u8{'k', '_', u8('0' + (i / 100) % 10), u8('0' + (i / 10) % 10), u8('0' + i % 10), ' '}
			xitdb.sorted_map_put(&sm, string(k[:5]), i64(i)) or_return
		}
		return nil
	}
	update_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		sm := xitdb.write_sorted_map_init(m_wc^) or_return
		xitdb.sorted_map_put(&sm, "k_125", i64(9999)) or_return
		return nil
	}

	testing.expect_value(t, xitdb.array_list_append_context(&hist, xitdb.Slot{}, seed_cb), nil)
	s0, _ := xitdb.array_list_get_slot(hist.read_array_list, 0)
	testing.expect_value(t, xitdb.array_list_append_context(&hist, s0.?, update_cb), nil)

	c0, _ := xitdb.array_list_get_cursor(hist.read_array_list, 0)
	c1, _ := xitdb.array_list_get_cursor(hist.read_array_list, 1)

	stats: xitdb.Diff_Stats
	changes, diff_err := xitdb.diff_collection_with_stats(c0.?, c1.?, &stats, context.temp_allocator, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, diff_err, nil)
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0].op, xitdb.Collection_Change_Op.Changed)
	testing.expect_value(t, string(changes[0].key), "k_125")
	testing.expect(t, stats.slots_skipped > 10)
}
