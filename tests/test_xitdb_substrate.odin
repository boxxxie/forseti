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
test_xitdb_v2_wire_layout_and_prehashed_keys :: proc(t: ^testing.T) {
	// Default xitdb core produces standard v2 57-byte genesis layout (SHA-1, hash_id=0, non-zero CRC-64/XZ).
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

	safe_csz, _ := xitdb.database_committed_size(sb_safe.db)
	safe_trailer, t_err := xitdb.database_read_root_trailer(sb_safe.db, safe_csz)
	testing.expect_value(t, t_err, nil)
	testing.expect(t, safe_trailer.checksum != 0)

	// Prehashed_Key matches runtime SHA-1 digests identically.
	pk := forseti.prehashed_key_make("org:acme")
	sha1_rt: [20]u8
	xitdb.sha1_sum_into(transmute([]u8)string("org:acme"), sha1_rt[:])
	testing.expect(t, slice.equal(pk.sha1[:], sha1_rt[:]))

	// Custom SHA-256 hasher sets hash_size=32 while keeping CRC-64/XZ trailers.
	sb_sha256 := new(forseti.Store_Bridge)
	testing.expect_value(
		t,
		forseti.store_bridge_init_standalone(
			sb_sha256,
			forseti.Xitdb_Config{custom_hasher = xitdb.sha256_hasher()},
		),
		nil,
	)
	defer {
		forseti.store_bridge_destroy(sb_sha256)
		free(sb_sha256)
	}

	testing.expect_value(t, sb_sha256.db.header.hash_size, u16(32))
	sha256_csz, _ := xitdb.database_committed_size(sb_sha256.db)
	sha256_trailer, st_err := xitdb.database_read_root_trailer(sb_sha256.db, sha256_csz)
	testing.expect_value(t, st_err, nil)
	testing.expect(t, sha256_trailer.checksum != 0)
}

@(test)
test_xitdb_sorted_diff_with_stats_and_eav_helpers :: proc(t: ^testing.T) {
	core := xitdb.core_memory_init()
	defer _ = xitdb.core_destroy(&core)

	db, d_err := xitdb.database_init(&core, xitdb.sha1_hasher())
	testing.expect_value(t, d_err, nil)

	// database_init preserves CRC-64/XZ commit validation with standard SHA-1 hasher.
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

@(test)
test_audit_commit_hashes_each_decision_once_with_custom_hasher :: proc(t: ^testing.T) {
	src := `module test_hash_once version "1.0"

schema RawOrg {
  name: string,
  active: bool
}
schema CanonOrg {
  name: string
}

source RawOrg : RawOrg at .orgs.raw[?id]
derived CanonOrg : CanonOrg at .orgs.canon[?id]

rule canonicalize {
  when { ?_r := RawOrg(name: ?nm, active: true) }
  then { assert CanonOrg(name: ?nm) }
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, cerr := forseti.compile_source(src, "test_hash_once.forseti", &diags)
	testing.expect_value(t, cerr, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, diags.error_count, 0)

	rb, rerr := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rerr, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	Hash_Count_Ctx :: struct {
		dec_key_hashes: int,
		rule_hashes:    int,
	}
	hctx: Hash_Count_Ctx
	counting_sha256 :: proc(data: []u8, out_hash: []u8, user_data: rawptr) {
		xitdb.sha256_sum_into(data, out_hash)
		if user_data != nil {
			cnt := (^Hash_Count_Ctx)(user_data)
			s := string(data)
			if len(s) >= 4 && s[:4] == "dec:" {
				cnt.dec_key_hashes += 1
			} else if s == "canonicalize" {
				cnt.rule_hashes += 1
			}
		}
	}

	cfg := forseti.Xitdb_Config{
		custom_hasher = xitdb.Hasher{
			hash_proc = counting_sha256,
			hash_size = 32,
			user_data = &hctx,
		},
	}
	sb := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb, cfg), nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	s_acme, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "Acme")
	s_beta, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "Beta")
	_, _ = forseti.session_insert_fact(sess, "RawOrg", "org:1", {s_acme, true})
	_, _ = forseti.session_insert_fact(sess, "RawOrg", "org:2", {s_beta, true})
	fired, ferr := forseti.session_fire(sess)
	testing.expect_value(t, ferr, forseti.Session_Error.None)
	testing.expect_value(t, fired, 2)

	hctx = {}
	_, cm_err := forseti.session_commit_derived_and_audit(sess, sb)
	testing.expect_value(t, cm_err, nil)
	testing.expect_value(t, hctx.dec_key_hashes, 2)
	testing.expect_value(t, hctx.rule_hashes, 1)

	m0, m0_ok, m0_err := forseti.store_bridge_moment_cursor(sb, -1)
	testing.expect_value(t, m0_err, nil)
	testing.expect(t, m0_ok)
	dec_cur, has_dec, _ := forseti.store_resolve_path(m0, ".decisions")
	testing.expect(t, has_dec)
	dec1_cur, has_dec1, _ := forseti.store_lookup_record(dec_cur, "dec:1")
	testing.expect(t, has_dec1)
	alive0, a0_ok, _ := forseti.cursor_read_field_path(dec1_cur, {"alive"}, nil, .Bool)
	testing.expect(t, a0_ok)
	testing.expect_value(t, alive0.(bool), true)

	by_rule_cur, has_br, _ := forseti.store_resolve_path(m0, ".idx.decisions_by_rule")
	testing.expect(t, has_br)
	rset_cur, has_rs, _ := forseti.store_lookup_record(by_rule_cur, "canonicalize")
	testing.expect(t, has_rs)
	rset, rs_err := xitdb.read_hash_set_init(rset_cur)
	testing.expect_value(t, rs_err, nil)
	in_set, is_err := xitdb.hash_set_get_cursor(rset, "dec:1")
	testing.expect_value(t, is_err, nil)
	_, has_in_set := in_set.?
	testing.expect(t, has_in_set)

	tx_cur, has_tx, _ := forseti.store_resolve_path(m0, ".__tx")
	testing.expect(t, has_tx)
	rv_cur, has_rv, _ := forseti.store_lookup_record(tx_cur, "rule_versions")
	testing.expect(t, has_rv)
	rver, rv_ok, _ := forseti.cursor_read_field_path(rv_cur, {"canonicalize"}, &sess.interner, .String)
	testing.expect(t, rv_ok)
	testing.expect_value(t, forseti.interner_get(&sess.interner, rver.(forseti.String_Id)), "1.0")

	// Incremental retraction patches dec:<id> alive=false and hashes dec:<id> once.
	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "RawOrg", "org:1"), forseti.Session_Error.None)
	_, _ = forseti.session_fire(sess)
	hctx = {}
	_, cm_err2 := forseti.session_commit_derived_and_audit(sess, sb)
	testing.expect_value(t, cm_err2, nil)
	testing.expect_value(t, hctx.dec_key_hashes, 1)

	m1, m1_ok, m1_err := forseti.store_bridge_moment_cursor(sb, -1)
	testing.expect_value(t, m1_err, nil)
	testing.expect(t, m1_ok)
	dec_cur1, has_dec_1, _ := forseti.store_resolve_path(m1, ".decisions")
	testing.expect(t, has_dec_1)

	false_count := 0
	true_count := 0
	for dec_id in ([2]string{"dec:1", "dec:2"}) {
		dcur, has_d, _ := forseti.store_lookup_record(dec_cur1, dec_id)
		testing.expect(t, has_d)
		av, a_ok, _ := forseti.cursor_read_field_path(dcur, {"alive"}, nil, .Bool)
		testing.expect(t, a_ok)
		wv, w_ok, _ := forseti.cursor_read_field_path(dcur, {"weight"}, nil, .I64)
		testing.expect(t, w_ok)
		if av.(bool) {
			testing.expect_value(t, wv.(i64), i64(1))
			true_count += 1
		} else {
			testing.expect_value(t, wv.(i64), i64(-1))
			false_count += 1
		}
	}
	testing.expect_value(t, true_count, 1)
	testing.expect_value(t, false_count, 1)
}
