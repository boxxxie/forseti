package forseti_tests

import "core:fmt"
import "core:testing"
import "core:thread"
import xitdb "xitdb:."
import "../forseti"

@(private = "file")
_Concurrency_Worker_Ctx :: struct {
	worker_id:     int,
	rb_base:       ^forseti.Rulebase,
	rb_cand:       ^forseti.Rulebase,
	frozen_store:  ^forseti.Store_Bridge,
	tel:           forseti.Telemetry_Sink,
	ok:            bool,
	derived_seen:  int,
	query_rows:    int,
	diff_removed:  int,
	diff_unchanged: int,
	moments_eq:    bool,
	err_msg:       string,
}

@(private = "file")
_seed_concurrent_snapshot_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	_ = user_data
	raw_map, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	for i in 0 ..< 12 {
		key_buf: [32]u8 = ---
		id_str := fmt.bprintf(key_buf[:], "org:%02d", i)
		rec_wc := xitdb.hash_map_put_cursor(&raw_map, id_str) or_return
		rec_map := xitdb.write_hash_map_init(rec_wc) or_return
		xitdb.hash_map_put(&rec_map, "org_id", id_str) or_return
		emp := i64(50) if i < 6 else i64(250)
		xitdb.hash_map_put(&rec_map, "employees", emp) or_return
	}

	blk_map, b_err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.blocked")
	if b_err != nil {
		return .Write_Failed
	}
	bwc := xitdb.hash_map_put_cursor(&blk_map, "org:11") or_return
	brec := xitdb.write_hash_map_init(bwc) or_return
	xitdb.hash_map_put(&brec, "org_id", "org:11") or_return

	edge_map, e_err := forseti.store_write_path_ensure_map(moment_wc, ".graph.edges")
	if e_err != nil {
		return .Write_Failed
	}
	edges := [3][2]string{{"n1", "n2"}, {"n2", "n3"}, {"n3", "n4"}}
	for ep, ei in edges {
		ebuf: [16]u8 = ---
		ekey := fmt.bprintf(ebuf[:], "e:%d", ei)
		ewc := xitdb.hash_map_put_cursor(&edge_map, ekey) or_return
		erec := xitdb.write_hash_map_init(ewc) or_return
		xitdb.hash_map_put(&erec, "src", ep[0]) or_return
		xitdb.hash_map_put(&erec, "dst", ep[1]) or_return
	}
	return nil
}

@(private = "file")
_concurrency_worker_proc :: proc(data: rawptr) {
	w := (^_Concurrency_Worker_Ctx)(data)

	if t_err := forseti.telemetry_init(&w.tel, enabled = true); t_err != nil {
		w.err_msg = "telemetry_init failed"
		return
	}

	for iter in 0 ..< 4 {
		sess := new(forseti.Session)
		if s_err := forseti.session_init(
			sess,
			w.rb_base,
			forseti.Session_Config{provenance_mode = .Audit_Full},
			&w.tel,
		); s_err != .None {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_init failed"
			return
		}

		syncer: forseti.Delta_Syncer
		if d_err := forseti.delta_syncer_init(&syncer, &w.tel); d_err != nil {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "delta_syncer_init failed"
			return
		}
		_ = forseti.delta_syncer_watch(&syncer, ".orgs.raw")
		_ = forseti.delta_syncer_watch(&syncer, ".orgs.blocked")
		_ = forseti.delta_syncer_watch(&syncer, ".graph.edges")

		_, f_err := forseti.session_sync_and_fire(sess, w.frozen_store, &syncer, commit_derived = false)
		forseti.delta_syncer_destroy(&syncer)
		if f_err != nil {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_sync_and_fire failed"
			return
		}

		// Runtime string interning + JTMS retraction per worker session
		dyn_buf: [32]u8 = ---
		dyn_id := fmt.bprintf(dyn_buf[:], "dyn:%d:%d", w.worker_id, iter)
		oid_sid, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, dyn_id)
		_, ins_err := forseti.session_insert_fact(sess, "Raw", dyn_id, []forseti.Value{oid_sid, i64(400)})
		if ins_err != .None {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_insert_fact failed"
			return
		}
		_, fire_err := forseti.session_fire(sess)
		if fire_err != .None {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_fire failed"
			return
		}
		ret_err := forseti.session_retract_fact_by_key(sess, "Raw", dyn_id)
		if ret_err != .None {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_retract_fact_by_key failed"
			return
		}
		_, fire_err2 := forseti.session_fire(sess)
		if fire_err2 != .None {
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_fire post-retract failed"
			return
		}

		// Query & explain checks against shared immutable Rulebase
		qr: forseti.Query_Result
		q_err := forseti.session_query(sess, "ent_tiers", nil, &qr)
		if q_err != .None {
			forseti.query_result_destroy(&qr)
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "session_query failed"
			return
		}
		w.query_rows = len(qr.rows)
		forseti.query_result_destroy(&qr)

		canon_bid, has_c := forseti.session_find_binding(sess, "Canon")
		derived_cnt := 0
		if has_c {
			for &f in sess.facts {
				if f.alive && f.binding_idx == canon_bid {
					derived_cnt += 1
				}
			}
		}
		w.derived_seen = derived_cnt

		rep, dr_err := forseti.diff_replay(
			w.frozen_store,
			w.rb_base,
			w.rb_cand,
			{".orgs.raw", ".orgs.blocked"},
			&w.tel,
		)
		if dr_err != nil {
			forseti.diff_replay_report_destroy(&rep)
			forseti.session_destroy(sess)
			free(sess)
			w.err_msg = "diff_replay failed"
			return
		}
		w.diff_removed = len(rep.removed)
		w.diff_unchanged = rep.unchanged_count
		w.moments_eq = rep.parent_moments_before == 1 && rep.parent_moments_after == 1
		forseti.diff_replay_report_destroy(&rep)

		forseti.session_destroy(sess)
		free(sess)
	}

	w.ok = true
}

@(test)
test_concurrent_rulebase_and_frozen_xitdb_reads :: proc(t: ^testing.T) {
	base_src := `module conc_mdm version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema BlockedOrg { org_id: string }
schema CanonOrg { org_id: string, tier: string }
schema Edge { src: string, dst: string }
schema Reach { src: string, dst: string }

source Raw : RawOrg at .orgs.raw[?id]
source Blocked : BlockedOrg at .orgs.blocked[?id]
source GraphEdge : Edge at .graph.edges[?id]
derived Canon : CanonOrg at .orgs.canon[?id]
derived GraphReach : Reach at .graph.reach[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule canonicalize {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    not Blocked(org_id: ?oid)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

rule reach_base {
  when { GraphEdge(src: ?a, dst: ?b) }
  then { assert GraphReach(src: ?a, dst: ?b) }
}

rule reach_step {
  when {
    GraphReach(src: ?a, dst: ?b)
    GraphEdge(src: ?b, dst: ?c)
  }
  then { assert GraphReach(src: ?a, dst: ?c) }
}

query ent_tiers() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	cand_src := `module conc_mdm version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema BlockedOrg { org_id: string }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
source Blocked : BlockedOrg at .orgs.blocked[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "2.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 300 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule canonicalize {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    not Blocked(org_id: ?oid)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}`

	diags_b, diags_c: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags_b), nil)
	defer forseti.diag_list_destroy(&diags_b)
	testing.expect_value(t, forseti.diag_list_init(&diags_c), nil)
	defer forseti.diag_list_destroy(&diags_c)

	ir_base, err_b := forseti.compile_source(base_src, "base.forseti", &diags_b)
	testing.expect_value(t, err_b, nil)
	defer forseti.ir_destroy(&ir_base)
	testing.expect_value(t, diags_b.error_count, 0)

	ir_cand, err_c := forseti.compile_source(cand_src, "cand.forseti", &diags_c)
	testing.expect_value(t, err_c, nil)
	defer forseti.ir_destroy(&ir_cand)
	testing.expect_value(t, diags_c.error_count, 0)

	// Intentionally pass a compile telemetry sink to verify worker sessions do NOT mutate rb_base.telemetry
	compile_tel: forseti.Telemetry_Sink
	testing.expect_value(t, forseti.telemetry_init(&compile_tel, enabled = true), nil)
	defer forseti.telemetry_destroy(&compile_tel)

	rb_base, rb_b_err := forseti.rulebase_compile(&ir_base, &compile_tel)
	testing.expect_value(t, rb_b_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb_base)

	rb_cand, rb_c_err := forseti.rulebase_compile(&ir_cand, &compile_tel)
	testing.expect_value(t, rb_c_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb_cand)

	compile_events_before := len(compile_tel.events)

	frozen_store := new(forseti.Store_Bridge)
	defer {
		forseti.store_bridge_destroy(frozen_store)
		free(frozen_store)
	}
	testing.expect_value(t, forseti.store_bridge_init_standalone(frozen_store, forseti.Xitdb_Config{}, nil), nil)
	m_idx, m_err := forseti.store_bridge_commit_moment(frozen_store, _seed_concurrent_snapshot_cb, nil)
	testing.expect_value(t, m_err, nil)
	testing.expect_value(t, m_idx, i64(0))

	WORKER_COUNT :: 8
	workers: [WORKER_COUNT]_Concurrency_Worker_Ctx
	threads: [WORKER_COUNT]^thread.Thread
	defer {
		for &wk in workers {
			forseti.telemetry_destroy(&wk.tel)
		}
	}

	for i in 0 ..< WORKER_COUNT {
		workers[i] = _Concurrency_Worker_Ctx{
			worker_id    = i,
			rb_base      = &rb_base,
			rb_cand      = &rb_cand,
			frozen_store = frozen_store,
		}
		threads[i] = thread.create_and_start_with_data(&workers[i], _concurrency_worker_proc)
		testing.expect(t, threads[i] != nil)
	}

	for th in threads {
		if th != nil {
			thread.join(th)
			thread.destroy(th)
		}
	}

	merged_tel: forseti.Telemetry_Sink
	testing.expect_value(t, forseti.telemetry_init(&merged_tel, enabled = true), nil)
	defer forseti.telemetry_destroy(&merged_tel)

	// org:0..10 survive (org:11 blocked) -> 11 Canon facts; org:6..10 are enterprise -> 5 rows;
	// in cand (threshold >= 300) those 5 enterprise Canon facts are removed and 6 smb remain unchanged.
	for &wk, wi in workers {
		testing.expectf(t, wk.ok, "worker %d failed: %s", wi, wk.err_msg)
		testing.expect_value(t, wk.derived_seen, 11)
		testing.expect_value(t, wk.query_rows, 5)
		testing.expect_value(t, wk.diff_removed, 5)
		testing.expect_value(t, wk.diff_unchanged, 6)
		testing.expect(t, wk.moments_eq)
		testing.expect_value(t, forseti.telemetry_merge(&merged_tel, &wk.tel), nil)
	}

	testing.expect_value(t, len(compile_tel.events), compile_events_before)
	testing.expect(t, merged_tel.counters[.Rules_Fired] > 0)
	testing.expect(t, len(merged_tel.events) > 0)
}

@(test)
test_telemetry_merge_preserves_parent_indices_and_watermarks :: proc(t: ^testing.T) {
	dst, src1, src2: forseti.Telemetry_Sink
	testing.expect_value(t, forseti.telemetry_init(&dst, enabled = true), nil)
	defer forseti.telemetry_destroy(&dst)
	testing.expect_value(t, forseti.telemetry_init(&src1, enabled = true), nil)
	defer forseti.telemetry_destroy(&src1)
	testing.expect_value(t, forseti.telemetry_init(&src2, enabled = true), nil)
	defer forseti.telemetry_destroy(&src2)

	s1_outer := forseti.telemetry_span_begin(&src1, .Match, "actor_1_outer")
	s1_inner := forseti.telemetry_span_begin(&src1, .Tms, "actor_1_inner")
	forseti.telemetry_span_end(&src1, s1_inner)
	forseti.telemetry_span_end(&src1, s1_outer)
	forseti.telemetry_count_add(&src1, .Rules_Fired, 3)
	forseti.telemetry_watermark_heap(&src1, 1024)
	src1.watermarks.live_session_memories = 4

	s2_outer := forseti.telemetry_span_begin(&src2, .Sync, "actor_2_outer")
	s2_inner := forseti.telemetry_span_begin(&src2, .Commit, "actor_2_inner")
	forseti.telemetry_span_end(&src2, s2_inner)
	forseti.telemetry_span_end(&src2, s2_outer)
	forseti.telemetry_count_add(&src2, .Rules_Fired, 5)
	forseti.telemetry_watermark_heap(&src2, 4096)
	src2.watermarks.live_session_memories = 7

	testing.expect_value(t, forseti.telemetry_merge(&dst, &src1), nil)
	testing.expect_value(t, forseti.telemetry_merge(&dst, &src2), nil)

	testing.expect_value(t, len(dst.events), 4)
	testing.expect_value(t, dst.events[0].parent_idx, i32(-1))
	testing.expect_value(t, dst.events[1].parent_idx, i32(0))
	testing.expect_value(t, dst.events[2].parent_idx, i32(-1))
	testing.expect_value(t, dst.events[3].parent_idx, i32(2))
	testing.expect_value(t, dst.counters[.Rules_Fired], u64(8))
	testing.expect_value(t, dst.watermarks.peak_heap_bytes, u64(4096))
	testing.expect_value(t, dst.watermarks.live_session_memories, u64(11))
}
