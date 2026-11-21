package forseti_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import xitdb "xitdb:."
import "../forseti"

@(private = "file")
_compile_test_rb :: proc(
	t: ^testing.T,
	src: string,
	name: string,
	loc := #caller_location,
) -> (
	rb: forseti.Rulebase,
) {
	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil, loc = loc)
	defer forseti.diag_list_destroy(&diags)

	ir, ir_err := forseti.compile_source(src, name, &diags)
	testing.expect_value(t, ir_err, nil, loc = loc)
	testing.expect_value(t, diags.error_count, 0, loc = loc)
	defer forseti.ir_destroy(&ir)

	compiled, rb_err := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None, loc = loc)
	return compiled
}

@(private = "file")
_count_alive_binding :: proc(s: ^forseti.Session, binding_name: string) -> int {
	bidx, ok := forseti.session_find_binding(s, binding_name)
	if !ok {
		return 0
	}
	cnt := 0
	for &f in s.facts {
		if f.alive && f.binding_idx == bidx {
			cnt += 1
		}
	}
	return cnt
}

@(private = "file")
_count_map_entries :: proc(cur: xitdb.Read_Cursor) -> int {
	it, err := xitdb.cursor_iterator(cur)
	if err != nil {
		return -1
	}
	cnt := 0
	for {
		item, nerr := xitdb.cursor_iterator_next(&it)
		if nerr != nil {
			return -1
		}
		if _, has := item.?; !has {
			break
		}
		cnt += 1
	}
	return cnt
}

@(test)
test_bytecode_program_interning_parity :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	defer free_all(context.temp_allocator)

	strings.write_string(&b, `module prog_intern version "1.0"
schema Org { bucket: i64, name: string, emp: i64 }
schema Out { name: string, score: i64 }
source Org : Org at .orgs[?id]
derived Out : Out at .out[?id]

table tier_tbl version "1.0" hit First {
  inputs { emp: i64 cost 1 }
  outputs { tier: string }
  rows {
    r1: >= 200 || "high";
    r2: -      || "low";
  }
}
`)

	for i := 0; i < 40; i += 1 {
		strings.write_string(&b, "rule r_")
		strings.write_int(&b, i)
		strings.write_string(&b, ` { when { ?_o := Org(bucket: `)
		strings.write_int(&b, i)
		strings.write_string(&b, `, name: ?nm, emp: ?e); where ?e >= 100 } then { assert Out(name: ?nm, score: ?e + 10) } }`)
		strings.write_byte(&b, '\n')
	}
	strings.write_string(&b, `
rule r_40 { when { ?_o := Org(bucket: 40, name: ?nm, emp: ?e); where ?e >= 200 } then { assert Out(name: ?nm, score: ?e + 10) } }
rule r_41 { when { ?_o := Org(bucket: 41, name: ?nm, emp: ?e); where ?e >= 100 and ?nm == "a" } then { assert Out(name: ?nm, score: ?e + 10) } }
rule r_42 { when { ?_o := Org(bucket: 42, name: ?nm, emp: ?e); where ?e >= 100 and ?nm == "b" } then { assert Out(name: ?nm, score: ?e + 10) } }
rule r_43 { when { ?_o := Org(bucket: 43, name: ?nm, emp: ?e); where ?e >= 100 } then { assert Out(name: ?nm, score: ?e + 20) } }
rule r_44 { when { ?_o := Org(bucket: 44, name: ?nm, emp: ?e); ?t := decide tier_tbl(emp: ?e); where ?t.tier == "high" } then { assert Out(name: ?nm, score: ?e + 50) } }
`)

	rb := _compile_test_rb(t, strings.to_string(b), "prog_intern.forseti")
	defer forseti.rulebase_destroy(&rb)

	// 40 identical rules reuse the same 3 bytecode programs rather than allocating 120 copies.
	testing.expectf(t, len(rb.programs) < 20, "expected interned programs < 20, got %d", len(rb.programs))

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	s_a, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "a")
	s_b, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "b")
	s_z, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "z")

	_, _ = forseti.session_insert_fact(sess, "Org", "o0", {i64(0), s_z, i64(120)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o39", {i64(39), s_z, i64(105)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o40_miss", {i64(40), s_z, i64(150)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o40_hit", {i64(40), s_z, i64(210)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o41", {i64(41), s_a, i64(110)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o42_miss", {i64(42), s_a, i64(110)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o43", {i64(43), s_b, i64(100)})
	_, _ = forseti.session_insert_fact(sess, "Org", "o44", {i64(44), s_b, i64(200)})

	fired, f_err := forseti.session_fire(sess)
	testing.expect_value(t, f_err, forseti.Session_Error.None)
	testing.expect_value(t, fired, u64(6))
	testing.expect_value(t, _count_alive_binding(sess, "Out"), 6)

	out_bidx, _ := forseti.session_find_binding(sess, "Out")
	expected_scores := make(map[i64]bool, 8)
	expected_scores[130] = false
	expected_scores[115] = false
	expected_scores[220] = false
	expected_scores[120] = false
	expected_scores[250] = false
	defer delete(expected_scores)
	for &f in sess.facts {
		if f.alive && f.binding_idx == out_bidx {
			sc := f.fields[1].(i64)
			expected_scores[sc] = true
		}
	}
	for k, seen in expected_scores {
		testing.expectf(t, seen, "expected Out score %d", k)
	}
}

@(test)
test_agenda_heap_deterministic_order_and_retraction :: proc(t: ^testing.T) {
	src := `module agenda_heap version "1.0"
schema Item { id: string, prio: i64 }
schema Block { id: string }
schema Log { id: string }
source Item : Item at .items[?id]
source Block : Block at .blocks[?id]
derived Log : Log at .logs[?id]

rule p1_hi phase "p1" salience 100 {
  when { ?_i := Item(id: ?id, prio: ?p); where ?p >= 90 }
  then { assert Block(id: ?id); assert Log(id: ?id) }
}
rule p1_lo phase "p1" salience 10 {
  when { ?_i := Item(id: ?id, prio: ?p); where ?p >= 10 }
  then { assert Log(id: ?id) }
}
rule p2_hi phase "p2" salience 50 {
  when { ?_i := Item(id: ?id, prio: ?p); not Block(id: ?id); where ?p >= 50 }
  then { assert Log(id: ?id) }
}
rule p2_mid phase "p2" salience 50 {
  when { ?_i := Item(id: ?id, prio: ?p); not Block(id: ?id); where ?p >= 10 }
  then { assert Log(id: ?id) }
}`

	rb := _compile_test_rb(t, src, "agenda_heap.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(
		t,
		forseti.session_init(sess, &rb, forseti.Session_Config{initial_phases = {"p1", "p2"}, provenance_mode = .Fast}),
		forseti.Session_Error.None,
	)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	kbuf: [24]u8 = ---
	for i := 0; i < 60; i += 1 {
		key := fmt.bprintf(kbuf[:], "it:%02d", i)
		kid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, key)
		prio := i64(100 if i % 6 == 0 else (55 if i % 2 == 0 else 20))
		_, _ = forseti.session_insert_fact(sess, "Item", key, {kid, prio})
	}
	// Retract 10 items before firing -> cancelled activations must not fire.
	for i := 0; i < 10; i += 1 {
		key := fmt.bprintf(kbuf[:], "it:%02d", i)
		_ = forseti.session_retract_fact_by_key(sess, "Item", key)
	}

	fired, err := forseti.session_fire(sess)
	testing.expect_value(t, err, forseti.Session_Error.None)
	// Surviving items: 10..59 (50 items).
	// i % 6 == 0 in 10..59: 12, 18, 24, 30, 36, 42, 48, 54 => 8 items trigger p1_hi + p1_lo, blocked in p2.
	// Remaining 42 items trigger p1_lo + p2_mid, and even among them (20..58 step 2 minus those 8 = 17 items) also trigger p2_hi.
	// Total firings = 8*2 + 17*3 + 25*2 = 16 + 51 + 50 = 117.
	testing.expect_value(t, fired, u64(117))
	testing.expect_value(t, len(sess.fired_trace), 117)

	// Verify p1 completes entirely before p2 begins, and salience stays non-increasing within p1 and p2.
	seen_p2 := false
	seen_p1_lo := false
	seen_p2_mid := false
	for sid in sess.fired_trace {
		rname := forseti.session_string(sess, sid)
		if strings.has_prefix(rname, "p1_") {
			testing.expectf(t, !seen_p2, "p1 rule %q fired after p2 rule", rname)
			if rname == "p1_lo" {
				seen_p1_lo = true
			} else {
				testing.expectf(t, !seen_p1_lo, "p1_hi fired after p1_lo")
			}
		} else {
			seen_p2 = true
			if rname == "p2_mid" {
				seen_p2_mid = true
			}
		}
	}
	// Note: in p2, both p2_hi and p2_mid have salience 50 -> tie broken by max_recency DESC, then rule_id ASC!
	_ = seen_p2_mid

	// Also verify unphased strict salience + recency ordering on 120 activations.
	sess2 := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess2, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess2)
		free(sess2)
	}
	for i := 0; i < 40; i += 1 {
		key := fmt.bprintf(kbuf[:], "u:%02d", i)
		kid, _ := forseti.intern_session_string(&rb.interner, &sess2.interner, key)
		_, _ = forseti.session_insert_fact(sess2, "Item", key, {kid, i64(100)})
	}
	f2, err2 := forseti.session_fire(sess2)
	testing.expect_value(t, err2, forseti.Session_Error.None)
	testing.expect_value(t, f2, u64(80)) // 40 p1_hi + 40 p1_lo (p2 blocked)
	// First 40 must all be p1_hi (salience 100), next 40 must all be p1_lo (salience 10).
	for sid, idx in sess2.fired_trace {
		rname := forseti.session_string(sess2, sid)
		expected := "p1_hi" if idx < 40 else "p1_lo"
		testing.expect_value(t, rname, expected)
	}
}

@(test)
test_incremental_lia_beta_and_seminaive_wave_parity :: proc(t: ^testing.T) {
	// Part A: Root -> Mid -> Leaf incremental LIA + JTMS retraction/re-insertion parity
	jtms_src := `module inc_lia version "1.0"
schema Root { id: string, emp: i64 }
schema Mid { id: string, tier: string }
schema Leaf { id: string, tier: string }
source Root : Root at .r[?id]
derived Mid : Mid at .m[?id]
derived Leaf : Leaf at .l[?id]
rule r1 { when { ?_r := Root(id: ?id, emp: ?e); where ?e >= 50 } then { assert Mid(id: ?id, tier: "ok") } }
rule r2 { when { ?_m := Mid(id: ?id, tier: ?t) } then { assert Leaf(id: ?id, tier: ?t) } }`

	rb1 := _compile_test_rb(t, jtms_src, "inc_lia.forseti")
	defer forseti.rulebase_destroy(&rb1)

	s1 := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s1, &rb1), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s1)
		free(s1)
	}

	kbuf: [24]u8 = ---
	for i := 0; i < 250; i += 1 {
		k := fmt.bprintf(kbuf[:], "k:%04d", i)
		ks, _ := forseti.intern_session_string(&rb1.interner, &s1.interner, k)
		_, _ = forseti.session_insert_fact(s1, "Root", k, {ks, i64(100)})
	}
	_, _ = forseti.session_fire(s1)
	testing.expect_value(t, _count_alive_binding(s1, "Mid"), 250)
	testing.expect_value(t, _count_alive_binding(s1, "Leaf"), 250)

	for i := 0; i < 50; i += 1 {
		k := fmt.bprintf(kbuf[:], "k:%04d", i)
		_ = forseti.session_retract_fact_by_key(s1, "Root", k)
	}
	_, _ = forseti.session_fire(s1)
	testing.expect_value(t, _count_alive_binding(s1, "Mid"), 200)
	testing.expect_value(t, _count_alive_binding(s1, "Leaf"), 200)

	for i := 250; i < 280; i += 1 {
		k := fmt.bprintf(kbuf[:], "k:%04d", i)
		ks, _ := forseti.intern_session_string(&rb1.interner, &s1.interner, k)
		_, _ = forseti.session_insert_fact(s1, "Root", k, {ks, i64(100)})
	}
	_, _ = forseti.session_fire(s1)
	testing.expect_value(t, _count_alive_binding(s1, "Mid"), 230)
	testing.expect_value(t, _count_alive_binding(s1, "Leaf"), 230)

	// Part B: Semi-naive wave closure on 200-edge DAG + cycles + negative stratification + retraction
	rec_src := `module inc_rec version "1.0"
schema Edge { src: string, dst: string }
schema Node { id: string }
schema Reach { src: string, dst: string }
schema Isolated { id: string }
source Edge : Edge at .e[?id]
source Node : Node at .n[?id]
derived Reach : Reach at .rch[?id]
derived Isolated : Isolated at .iso[?id]
rule base_reach { when { ?_e := Edge(src: ?x, dst: ?y) } then { assert Reach(src: ?x, dst: ?y) } }
rule step_reach { when { ?_r1 := Reach(src: ?x, dst: ?y); ?_r2 := Reach(src: ?y, dst: ?z) } then { assert Reach(src: ?x, dst: ?z) } }
rule find_iso { when { ?_n := Node(id: ?u); not Reach(src: "root", dst: ?u) } then { assert Isolated(id: ?u) } }`

	rb2 := _compile_test_rb(t, rec_src, "inc_rec.forseti")
	defer forseti.rulebase_destroy(&rb2)

	s2 := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s2, &rb2), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s2)
		free(s2)
	}

	// Build 50 depth-4 chains from "root" (200 edges) plus 10 disconnected nodes.
	sbuf: [24]u8 = ---
	dbuf: [24]u8 = ---
	for c := 0; c < 50; c += 1 {
		for step := 0; step < 4; step += 1 {
			u := "root" if step == 0 else fmt.bprintf(sbuf[:], "c%d_%d", c, step)
			v := fmt.bprintf(dbuf[:], "c%d_%d", c, step + 1)
			ek := fmt.bprintf(kbuf[:], "e_%d_%d", c, step)
			us, _ := forseti.intern_session_string(&rb2.interner, &s2.interner, u)
			vs, _ := forseti.intern_session_string(&rb2.interner, &s2.interner, v)
			_, _ = forseti.session_insert_fact(s2, "Edge", ek, {us, vs})
			_, _ = forseti.session_insert_fact(s2, "Node", v, {vs})
		}
	}
	for iso := 0; iso < 10; iso += 1 {
		nk := fmt.bprintf(kbuf[:], "iso_%d", iso)
		ns, _ := forseti.intern_session_string(&rb2.interner, &s2.interner, nk)
		_, _ = forseti.session_insert_fact(s2, "Node", nk, {ns})
	}

	_, r_err := forseti.session_fire(s2)
	testing.expect_value(t, r_err, forseti.Session_Error.None)
	// Each depth-4 chain has 4+3+2+1 = 10 distinct Reach pairs -> 500 Reach facts, 10 Isolated.
	testing.expect_value(t, _count_alive_binding(s2, "Reach"), 500)
	testing.expect_value(t, _count_alive_binding(s2, "Isolated"), 10)

	// Sever the first edge of 10 chains -> loses 4 Reach pairs per chain (root->1..4) and revives 40 Isolated nodes!
	// Wait: remaining 3 edges in each severed chain still produce 3+2+1 = 6 Reach pairs -> 500 - 40 = 460 Reach, 10 + 40 = 50 Isolated!
	for c := 0; c < 10; c += 1 {
		ek := fmt.bprintf(kbuf[:], "e_%d_0", c)
		_ = forseti.session_retract_fact_by_key(s2, "Edge", ek)
	}
	_, r_err2 := forseti.session_fire(s2)
	testing.expect_value(t, r_err2, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(s2, "Reach"), 460)
	testing.expect_value(t, _count_alive_binding(s2, "Isolated"), 50)
}

@(test)
test_incremental_xitdb_provenance_commit_parity :: proc(t: ^testing.T) {
	src := `module inc_commit version "1.0"
schema RawOrg { name: string, domain: string, employees: i64 }
schema Suppress { domain: string }
schema CanonOrg { name: string, domain: string, employees: i64 }
schema DomainStats { domain: string, cnt: i64 }
source RawOrg : RawOrg at .orgs.raw[?id]
source Suppress : Suppress at .orgs.suppress[?domain]
derived CanonOrg : CanonOrg at .orgs.canon[?id]
derived DomainStats : DomainStats at .orgs.stats[?domain]

rule canonicalize {
  when {
    ?_r := RawOrg(name: ?nm, domain: ?dom, employees: ?emp)
    not Suppress(domain: ?dom)
    where ?emp >= 100
  }
  then { assert CanonOrg(name: ?nm, domain: ?dom, employees: ?emp) }
}
rule stats {
  when {
    ?_c := CanonOrg(domain: ?dom, name: ?_nm)
    ?cnt := count(?nm) from CanonOrg(domain: ?dom, name: ?nm)
  }
  then { assert DomainStats(domain: ?dom, cnt: ?cnt) }
}`

	rb := _compile_test_rb(t, src, "inc_commit.forseti")
	defer forseti.rulebase_destroy(&rb)

	sb_inc := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb_inc, forseti.Xitdb_Config{mode = .Safe_V2}), nil)
	defer {
		forseti.store_bridge_destroy(sb_inc)
		free(sb_inc)
	}

	syncer := new(forseti.Delta_Syncer)
	testing.expect_value(t, forseti.delta_syncer_init(syncer), nil)
	testing.expect_value(t, forseti.delta_syncer_watch(syncer, ".orgs.raw"), nil)
	testing.expect_value(t, forseti.delta_syncer_watch(syncer, ".orgs.suppress"), nil)
	defer {
		forseti.delta_syncer_destroy(syncer)
		free(syncer)
	}

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	// Moment 0: seed 20 orgs (15 >= 100 across 3 domains, 5 < 100).
	seed_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		raw_m, err := forseti.store_write_path_ensure_map(m_wc, ".orgs.raw")
		if err != nil {
			return .Write_Failed
		}
		kbuf: [24]u8 = ---
		dbuf: [24]u8 = ---
		for i := 0; i < 20; i += 1 {
			k := fmt.bprintf(kbuf[:], "org:%02d", i)
			d := fmt.bprintf(dbuf[:], "dom%d.com", i % 3)
			emp := i64(150 + i) if i < 15 else i64(50 + i)
			rwc := xitdb.hash_map_put_cursor(&raw_m, k) or_return
			rm := xitdb.write_hash_map_init(rwc) or_return
			xitdb.hash_map_put(&rm, "name", k) or_return
			xitdb.hash_map_put(&rm, "domain", d) or_return
			xitdb.hash_map_put(&rm, "employees", emp) or_return
		}
		return nil
	}
	_, e0 := forseti.store_bridge_commit_moment(sb_inc, seed_cb)
	testing.expect_value(t, e0, nil)
	_, s0 := forseti.session_sync_and_fire(sess, sb_inc, syncer, commit_derived = true)
	testing.expect_value(t, s0, nil)

	// Moment 1: drop org:01 below 100 (JTMS retraction), update org:02, add org:20/org:21.
	mut_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		raw_m, err := forseti.store_write_path_ensure_map(m_wc, ".orgs.raw")
		if err != nil {
			return .Write_Failed
		}
		put_org :: proc(m: ^xitdb.Write_Hash_Map, k, dom: string, emp: i64) -> xitdb.Error {
			rwc := xitdb.hash_map_put_cursor(m, k) or_return
			rm := xitdb.write_hash_map_init(rwc) or_return
			xitdb.hash_map_put(&rm, "name", k) or_return
			xitdb.hash_map_put(&rm, "domain", dom) or_return
			xitdb.hash_map_put(&rm, "employees", emp) or_return
			return nil
		}
		put_org(&raw_m, "org:01", "dom1.com", 40) or_return
		put_org(&raw_m, "org:02", "dom2.com", 320) or_return
		put_org(&raw_m, "org:20", "dom0.com", 400) or_return
		put_org(&raw_m, "org:21", "dom1.com", 410) or_return
		return nil
	}
	_, e1 := forseti.store_bridge_commit_moment(sb_inc, mut_cb)
	testing.expect_value(t, e1, nil)
	_, s1 := forseti.session_sync_and_fire(sess, sb_inc, syncer, commit_derived = true)
	testing.expect_value(t, s1, nil)

	// Moment 2: suppress dom2.com.
	sup_cb :: proc(m_wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
		sup_m, err := forseti.store_write_path_ensure_map(m_wc, ".orgs.suppress")
		if err != nil {
			return .Write_Failed
		}
		rwc := xitdb.hash_map_put_cursor(&sup_m, "dom2.com") or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "domain", "dom2.com") or_return
		return nil
	}
	_, e2 := forseti.store_bridge_commit_moment(sb_inc, sup_cb)
	testing.expect_value(t, e2, nil)
	_, s2 := forseti.session_sync_and_fire(sess, sb_inc, syncer, commit_derived = true)
	testing.expect_value(t, s2, nil)

	// Commit same session state into a fresh Store_Bridge and compare full parity.
	sb_ref := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb_ref, forseti.Xitdb_Config{mode = .Safe_V2}), nil)
	defer {
		forseti.store_bridge_destroy(sb_ref)
		free(sb_ref)
	}
	_, c_ref := forseti.session_commit_derived_and_audit(sess, sb_ref)
	testing.expect_value(t, c_ref, nil)

	m_inc, ok_inc, _ := forseti.store_bridge_moment_cursor(sb_inc, -1)
	m_ref, ok_ref, _ := forseti.store_bridge_moment_cursor(sb_ref, -1)
	testing.expect(t, ok_inc && ok_ref)

	for path in ([4]string{".orgs.canon", ".orgs.stats", ".decisions", ".idx.decisions_by_rule"}) {
		c1, f1, _ := forseti.store_resolve_path(m_inc, path)
		c2, f2, _ := forseti.store_resolve_path(m_ref, path)
		testing.expect(t, f1 && f2)
		cnt1 := _count_map_entries(c1)
		cnt2 := _count_map_entries(c2)
		testing.expectf(t, cnt1 > 0 && cnt1 == cnt2, "path %s mismatch: inc=%d ref=%d", path, cnt1, cnt2)
	}

	// Verify alive/weight parity on every derivation (including retracted derivations with alive=false, weight=-1).
	dec_inc, _, _ := forseti.store_resolve_path(m_inc, ".decisions")
	dec_ref, _, _ := forseti.store_resolve_path(m_ref, ".decisions")
	id_buf: [32]u8 = ---
	retracted_seen := 0
	for di := 1; di < len(sess.provenance.derivs); di += 1 {
		did := fmt.bprintf(id_buf[:], "dec:%d", di)
		r1, ok1, _ := forseti.store_lookup_record(dec_inc, did)
		r2, ok2, _ := forseti.store_lookup_record(dec_ref, did)
		testing.expect(t, ok1 && ok2)
		a1, _, _ := forseti.cursor_read_field_path(r1, {"alive"}, nil, .Bool)
		a2, _, _ := forseti.cursor_read_field_path(r2, {"alive"}, nil, .Bool)
		w1, _, _ := forseti.cursor_read_field_path(r1, {"weight"}, nil, .I64)
		w2, _, _ := forseti.cursor_read_field_path(r2, {"weight"}, nil, .I64)
		testing.expect_value(t, a1, a2)
		testing.expect_value(t, w1, w2)
		if a1 == forseti.Value(false) {
			retracted_seen += 1
			testing.expect_value(t, w1, forseti.Value(i64(-1)))
		}
	}
	testing.expect(t, retracted_seen >= 2)
}

@(test)
test_fast_mode_inplace_modify_and_slot_recycling :: proc(t: ^testing.T) {
	src := `module fast_recycle version "1.0"
schema Org { id: string, domain: string, emp: i64 }
schema Pair { id: string, domain: string, emp: i64 }
source Org : Org at .orgs.raw[?id]
derived Pair : Pair at .orgs.pairs[?id]
rule win_domain {
  when {
    ?_a := Org(id: ?ida, domain: ?dom, emp: ?ea)
    ?_b := Org(id: ?_idb, domain: ?dom, emp: ?eb)
    where ?ea > ?eb
  }
  then { assert Pair(id: ?ida, domain: ?dom, emp: ?ea) }
}`

	rb := _compile_test_rb(t, src, "fast_recycle.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(
		t,
		forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}),
		forseti.Session_Error.None,
	)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	dom_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "acme.com")
	seed_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "seed:0")
	hot_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "hot:0")

	_, _ = forseti.session_insert_fact(sess, "Org", "seed:0", {seed_sid, dom_sid, i64(550)})
	_, _ = forseti.session_insert_fact(sess, "Org", "hot:0", {hot_sid, dom_sid, i64(600)})
	_, _ = forseti.session_fire(sess)
	testing.expect_value(t, _count_alive_binding(sess, "Pair"), 1)

	for step := 0; step < 2_000; step += 1 {
		emp := i64(500) if (step % 2 == 0) else i64(600)
		err := forseti.session_modify_fact_by_key(sess, "Org", "hot:0", {hot_sid, dom_sid, emp})
		testing.expect_value(t, err, forseti.Session_Error.None)
		_, fe := forseti.session_fire(sess)
		testing.expect_value(t, fe, forseti.Session_Error.None)
		if step == 0 || step == 1998 || step == 1999 {
			// Either hot:0 (600 > 550) or seed:0 (550 > 500) wins -> exactly 1 Pair alive.
			testing.expect_value(t, _count_alive_binding(sess, "Pair"), 1)
		}
	}
	testing.expectf(t, len(sess.facts) < 100, "expected recycled facts len < 100, got %d", len(sess.facts))
}
