package forseti_tests

import "core:fmt"
import "core:math"
import "core:mem"
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
	if diags.error_count > 0 {
		for d in diags.items {
			if d.severity == .Error {
				testing.expectf(t, false, "diag %s: %s", d.code, d.message, loc = loc)
			}
		}
	}
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
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb_inc, forseti.Xitdb_Config{}), nil)
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
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb_ref, forseti.Xitdb_Config{}), nil)
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

@(test)
test_fast_mode_jtms_cascade_scratch_growth :: proc(t: ^testing.T) {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	defer free_all(context.temp_allocator)

	strings.write_string(&b, `module fast_jtms_growth version "1.0"
schema Root { group: i64 }
schema Fan { group: i64, k: i64 }
schema LeafFan { m: i64 }
schema Block { group: i64 }
schema Mid { group: i64, k: i64 }
schema Leaf { group: i64, k: i64, m: i64 }
source Root : Root at .r[?id]
source Fan : Fan at .fan[?id]
source LeafFan : LeafFan at .lf[?id]
source Block : Block at .blk[?id]
derived Mid : Mid at .m[?id]
derived Leaf : Leaf at .l[?id]

rule make_mid {
  when { ?_r := Root(group: ?g); ?_f := Fan(group: ?g, k: ?k) }
  then { assert Mid(group: ?g, k: ?k) }
}
rule make_leaf {
  when { ?_m := Mid(group: ?g, k: ?k); ?_lf := LeafFan(m: ?m) }
  then { assert Leaf(group: ?g, k: ?k, m: ?m) }
}
rule revoke_many {
  when { ?_r := Root(group: ?g); not Block(group: ?g); where ?g == 2 }
  then {
`)
	for i := 0; i < 22; i += 1 {
		fmt.sbprintf(&b, "    assert Mid(group: ?g, k: %d)\n", 100 + i)
	}
	strings.write_string(&b, "  }\n}\n")

	rb := _compile_test_rb(t, strings.to_string(b), "fast_jtms_growth.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	kbuf: [24]u8 = ---
	for k := 0; k < 26; k += 1 {
		fk := fmt.bprintf(kbuf[:], "f:%d", k)
		_, _ = forseti.session_insert_fact(sess, "Fan", fk, {i64(1), i64(k)})
	}
	for m := 0; m < 2; m += 1 {
		lk := fmt.bprintf(kbuf[:], "lf:%d", m)
		_, _ = forseti.session_insert_fact(sess, "LeafFan", lk, {i64(m)})
	}

	// Wave 1: 26 direct Mid children and 52 Leaf grandchildren exceed 16-entry scratch_dead_justs in both functions.
	_, _ = forseti.session_insert_fact(sess, "Root", "r1", {i64(1)})
	_, ferr := forseti.session_fire(sess)
	testing.expect_value(t, ferr, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 26)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 52)

	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "Root", "r1"), forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 0)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 0)

	// Wave 2: reuse scratch_dead_justs cleanly across another full cascade.
	_, _ = forseti.session_insert_fact(sess, "Root", "r1", {i64(1)})
	_, ferr2 := forseti.session_fire(sess)
	testing.expect_value(t, ferr2, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 26)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 52)

	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "Root", "r1"), forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 0)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 0)

	// Exercise jtms_revoke_firing via `not Block` blocking a rule firing with 22 logical assertions -> 44 Leaves.
	_, _ = forseti.session_insert_fact(sess, "Root", "r2", {i64(2)})
	_, ferr3 := forseti.session_fire(sess)
	testing.expect_value(t, ferr3, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 22)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 44)

	_, _ = forseti.session_insert_fact(sess, "Block", "b2", {i64(2)})
	_, ferr4 := forseti.session_fire(sess)
	testing.expect_value(t, ferr4, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Mid"), 0)
	testing.expect_value(t, _count_alive_binding(sess, "Leaf"), 0)
}

@(test)
test_fast_mode_accum_inplace_modify_and_logical_recycling :: proc(t: ^testing.T) {
	src := `module fast_accum_recycle version "1.0"
schema Item { id: string, grp: string, val: i64 }
schema Trigger { grp: string, mult: i64 }
schema DerivedItem { grp: string, val: i64 }
schema QueryGrp { grp: string }
schema ExtAgg { grp: string, s: i64, c: i64, mn: i64, mx: i64 }
schema DerAgg { grp: string, s: i64, c: i64 }
source Item : Item at .items[?id]
source Trigger : Trigger at .trig[?id]
derived DerivedItem : DerivedItem at .d_items[?id]
source QueryGrp : QueryGrp at .q[?id]
derived ExtAgg : ExtAgg at .ext_agg[?id]
derived DerAgg : DerAgg at .der_agg[?id]

rule ext_stats {
  when {
    ?_q := QueryGrp(grp: ?g)
    ?s := sum(?v) from Item(grp: ?g, val: ?v)
    ?c := count(?v) from Item(grp: ?g, val: ?v)
    ?mn := min(?v) from Item(grp: ?g, val: ?v)
    ?mx := max(?v) from Item(grp: ?g, val: ?v)
  }
  then { assert ExtAgg(grp: ?g, s: ?s, c: ?c, mn: ?mn, mx: ?mx) }
}

rule make_derived {
  when { ?_t := Trigger(grp: ?g, mult: ?m) }
  then { assert DerivedItem(grp: ?g, val: ?m * 10) }
}

rule der_stats {
  when {
    ?_q := QueryGrp(grp: ?g)
    ?s := sum(?v) from DerivedItem(grp: ?g, val: ?v)
    ?c := count(?v) from DerivedItem(grp: ?g, val: ?v)
  }
  then { assert DerAgg(grp: ?g, s: ?s, c: ?c) }
}`

	rb := _compile_test_rb(t, src, "fast_accum_recycle.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	g1, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "g1")
	g2, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "g2")
	i1, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "i1")
	i2, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "i2")
	i3, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "i3")

	_, _ = forseti.session_insert_fact(sess, "QueryGrp", "qg1", {g1})
	_, _ = forseti.session_insert_fact(sess, "QueryGrp", "qg2", {g2})
	_, _ = forseti.session_insert_fact(sess, "Item", "i1", {i1, g1, i64(10)})
	_, _ = forseti.session_insert_fact(sess, "Item", "i2", {i2, g1, i64(30)})
	_, _ = forseti.session_insert_fact(sess, "Item", "i3", {i3, g2, i64(5)})
	_, _ = forseti.session_insert_fact(sess, "Trigger", "t1", {g1, i64(2)})

	_, fe1 := forseti.session_fire(sess)
	testing.expect_value(t, fe1, forseti.Session_Error.None)

	find_ext :: proc(s: ^forseti.Session, grp: forseti.String_Id) -> (res: [4]i64, ok: bool) {
		bidx, _ := forseti.session_find_binding(s, "ExtAgg")
		for &f in s.facts {
			if f.alive && f.binding_idx == bidx && f.fields[0] == forseti.Value(grp) {
				return {f.fields[1].(i64), f.fields[2].(i64), f.fields[3].(i64), f.fields[4].(i64)}, true
			}
		}
		return {}, false
	}
	find_der :: proc(s: ^forseti.Session, grp: forseti.String_Id) -> (s_val: i64, c_val: i64, ok: bool) {
		bidx, _ := forseti.session_find_binding(s, "DerAgg")
		for &f in s.facts {
			if f.alive && f.binding_idx == bidx && f.fields[0] == forseti.Value(grp) {
				return f.fields[1].(i64), f.fields[2].(i64), true
			}
		}
		return 0, 0, false
	}

	e1, e1_ok := find_ext(sess, g1)
	testing.expect(t, e1_ok)
	testing.expect_value(t, e1, [4]i64{40, 2, 10, 30})
	ds1, dc1, dok1 := find_der(sess, g1)
	testing.expect(t, dok1)
	testing.expect_value(t, ds1, i64(20))
	testing.expect_value(t, dc1, i64(1))

	// In-place modify value (keeping same group).
	testing.expect_value(t, forseti.session_modify_fact_by_key(sess, "Item", "i2", {i2, g1, i64(50)}), forseti.Session_Error.None)
	_, fe2 := forseti.session_fire(sess)
	testing.expect_value(t, fe2, forseti.Session_Error.None)
	e2, e2_ok := find_ext(sess, g1)
	testing.expect(t, e2_ok)
	testing.expect_value(t, e2, [4]i64{60, 2, 10, 50})

	// In-place modify changing group key from g1 -> g2.
	testing.expect_value(t, forseti.session_modify_fact_by_key(sess, "Item", "i2", {i2, g2, i64(15)}), forseti.Session_Error.None)
	_, fe3 := forseti.session_fire(sess)
	testing.expect_value(t, fe3, forseti.Session_Error.None)
	e3a, _ := find_ext(sess, g1)
	e3b, _ := find_ext(sess, g2)
	testing.expect_value(t, e3a, [4]i64{10, 1, 10, 10})
	testing.expect_value(t, e3b, [4]i64{20, 2, 5, 15})

	// Logical Fact_Id recycling in stratum 0 before stratum 1 accumulator re-evaluates.
	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "Trigger", "t1"), forseti.Session_Error.None)
	_, _ = forseti.session_insert_fact(sess, "Trigger", "t2", {g1, i64(7)})
	_, fe4 := forseti.session_fire(sess)
	testing.expect_value(t, fe4, forseti.Session_Error.None)
	ds4, dc4, dok4 := find_der(sess, g1)
	testing.expect(t, dok4)
	testing.expect_value(t, ds4, i64(70))
	testing.expect_value(t, dc4, i64(1))
}

@(test)
test_fast_mode_derived_modify_and_nil_field_commit :: proc(t: ^testing.T) {
	src := `module fast_derived_commit version "1.0"
schema Trig1 { score: i64 }
schema Trig2 { score: i64 }
schema Out { score: i64, note: string }
schema ExtOut { id: string, score: i64, note: string }
source Trig1 : Trig1 at .trig1[?id]
source Trig2 : Trig2 at .trig2[?id]
derived Out : Out at .out[?id]
derived ExtOut : ExtOut at .ext_out[?id]

rule from_t1 {
  when { ?_t := Trig1(score: ?s) }
  then { assert Out(score: ?s, note: "present") }
}
rule from_t2 {
  when { ?_t := Trig2(score: ?s) }
  then { assert Out(score: ?s, note: "replaced") }
}`

	rb := _compile_test_rb(t, src, "fast_derived_commit.forseti")
	defer forseti.rulebase_destroy(&rb)

	sb := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb, forseti.Xitdb_Config{}), nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	// Moment 0: logical Out("Out:1") with note="present", plus ExtOut("e1") with note="initial".
	e1_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "e1")
	init_note_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "initial")
	_, _ = forseti.session_insert_fact(sess, "Trig1", "t1", {i64(100)})
	_, _ = forseti.session_insert_fact(sess, "ExtOut", "e1", {e1_sid, i64(10), init_note_sid}, .External)
	_, fe0 := forseti.session_fire(sess)
	testing.expect_value(t, fe0, forseti.Session_Error.None)

	_, ce0 := forseti.session_commit_derived_and_audit(sess, sb)
	testing.expect_value(t, ce0, nil)

	// Verify Moment 0 Out("Out:1").note=="present" and ExtOut("e1").note=="initial" in xitdb.
	m0, ok0, _ := forseti.store_bridge_moment_cursor(sb, -1)
	testing.expect(t, ok0)
	out0_c, has_out0, _ := forseti.store_resolve_path(m0, ".out")
	testing.expect(t, has_out0)
	rec0, has_r0, _ := forseti.store_lookup_record(out0_c, "Out:1")
	testing.expect(t, has_r0)
	note0, has_n0, _ := forseti.cursor_read_field_path(rec0, {"note"}, &sess.interner, .String)
	testing.expect(t, has_n0)
	testing.expect_value(t, forseti.interner_get(&sess.interner, note0.(forseti.String_Id)), "present")

	ext0_c, has_ext0, _ := forseti.store_resolve_path(m0, ".ext_out")
	testing.expect(t, has_ext0)
	erec0, has_er0, _ := forseti.store_lookup_record(ext0_c, "e1")
	testing.expect(t, has_er0)
	enote0, has_en0, _ := forseti.cursor_read_field_path(erec0, {"note"}, &sess.interner, .String)
	testing.expect(t, has_en0)
	testing.expect_value(t, forseti.interner_get(&sess.interner, enote0.(forseti.String_Id)), "initial")

	// Moment 1: recycle Out("Out:1") and in-place modify ExtOut("e1") clearing optional `note` to nil.
	testing.expect_value(t, forseti.session_retract_fact_by_key(sess, "Trig1", "t1"), forseti.Session_Error.None)
	_, _ = forseti.session_insert_fact(sess, "Trig2", "t2", {i64(250)})
	testing.expect_value(t, forseti.session_modify_fact_by_key(sess, "ExtOut", "e1", {e1_sid, i64(999), nil}), forseti.Session_Error.None)
	_, fe1 := forseti.session_fire(sess)
	testing.expect_value(t, fe1, forseti.Session_Error.None)

	_, ce1 := forseti.session_commit_derived_and_audit(sess, sb)
	testing.expect_value(t, ce1, nil)

	m1, ok1, _ := forseti.store_bridge_moment_cursor(sb, -1)
	testing.expect(t, ok1)
	out1_c, has_out1, _ := forseti.store_resolve_path(m1, ".out")
	testing.expect(t, has_out1)
	rec1, has_r1, _ := forseti.store_lookup_record(out1_c, "Out:1")
	testing.expect(t, has_r1)
	score1, has_s1, _ := forseti.cursor_read_field_path(rec1, {"score"}, &sess.interner, .I64)
	testing.expect(t, has_s1)
	testing.expect_value(t, score1, forseti.Value(i64(250)))
	note1, has_n1, _ := forseti.cursor_read_field_path(rec1, {"note"}, &sess.interner, .String)
	testing.expect(t, has_n1)
	testing.expect_value(t, forseti.interner_get(&sess.interner, note1.(forseti.String_Id)), "replaced")

	ext1_c, has_ext1, _ := forseti.store_resolve_path(m1, ".ext_out")
	testing.expect(t, has_ext1)
	erec1, has_er1, _ := forseti.store_lookup_record(ext1_c, "e1")
	testing.expect(t, has_er1)
	escore1, has_es1, _ := forseti.cursor_read_field_path(erec1, {"score"}, &sess.interner, .I64)
	testing.expect(t, has_es1)
	testing.expect_value(t, escore1, forseti.Value(i64(999)))
	_, still_has_note, _ := forseti.cursor_read_field_path(erec1, {"note"}, &sess.interner, .String)
	testing.expect(t, !still_has_note)
}

@(test)
test_agenda_phase_and_stratum_heap_bounded_growth :: proc(t: ^testing.T) {
	src := `module agenda_bounds version "1.0"
schema Tick { id: string, v: i64 }
schema Out { id: string }
source Tick : Tick at .t[?id]
derived Out : Out at .o[?id]

rule p1 phase "p1" salience 10 {
  when { ?_t := Tick(id: ?id, v: ?v); where ?v >= 1 }
  then { assert Out(id: ?id) }
}
rule p2 phase "p2" salience 50 {
  when { ?_t := Tick(id: ?id, v: ?v); where ?v >= 1 }
  then { assert Out(id: ?id) }
}`

	rb := _compile_test_rb(t, src, "agenda_bounds.forseti")
	defer forseti.rulebase_destroy(&rb)

	// 1. Default unphased execution (len(phases) == 0) must not populate phase_heaps.
	s_no_phase := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s_no_phase, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s_no_phase)
		free(s_no_phase)
	}

	kbuf: [24]u8 = ---
	for i := 0; i < 500; i += 1 {
		key := fmt.bprintf(kbuf[:], "n:%d", i)
		ks, _ := forseti.intern_session_string(&rb.interner, &s_no_phase.interner, key)
		_, _ = forseti.session_insert_fact(s_no_phase, "Tick", key, {ks, i64(1)})
		_, _ = forseti.session_fire(s_no_phase)
		_ = forseti.session_retract_fact_by_key(s_no_phase, "Tick", key)
	}
	testing.expect_value(t, len(s_no_phase.agenda.phase_heaps), 0)

	// 2. Staging activations before session_set_phases preserves strict p1-before-p2 order,
	//    and repeated churn keeps stratum_heaps and phase_heaps compacted.
	s_phased := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s_phased, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s_phased)
		free(s_phased)
	}

	k0, _ := forseti.intern_session_string(&rb.interner, &s_phased.interner, "pre:0")
	_, _ = forseti.session_insert_fact(s_phased, "Tick", "pre:0", {k0, i64(1)})
	testing.expect_value(t, forseti.phreak_evaluate_linked_rules(s_phased), forseti.Session_Error.None)
	testing.expect_value(t, forseti.session_set_phases(s_phased, {"p1", "p2"}), forseti.Session_Error.None)
	fired0, fe0 := forseti.session_fire(s_phased)
	testing.expect_value(t, fe0, forseti.Session_Error.None)
	testing.expect_value(t, fired0, u64(2))
	testing.expect_value(t, forseti.session_string(s_phased, s_phased.fired_trace[0]), "p1")
	testing.expect_value(t, forseti.session_string(s_phased, s_phased.fired_trace[1]), "p2")
	_ = forseti.session_retract_fact_by_key(s_phased, "Tick", "pre:0")

	for i := 0; i < 500; i += 1 {
		testing.expect_value(t, forseti.session_set_phases(s_phased, {"p1", "p2"}), forseti.Session_Error.None)
		key := fmt.bprintf(kbuf[:], "p:%d", i)
		ks, _ := forseti.intern_session_string(&rb.interner, &s_phased.interner, key)
		_, _ = forseti.session_insert_fact(s_phased, "Tick", key, {ks, i64(1)})
		_, _ = forseti.session_fire(s_phased)
		_ = forseti.session_retract_fact_by_key(s_phased, "Tick", key)
	}
	sh_total := 0
	for _, h in s_phased.agenda.stratum_heaps {
		sh_total += len(h)
	}
	ph_total := 0
	for _, h in s_phased.agenda.phase_heaps {
		ph_total += len(h)
	}
	testing.expectf(t, sh_total <= 256, "expected bounded stratum_heaps <= 256, got %d", sh_total)
	testing.expectf(t, ph_total <= 256, "expected bounded phase_heaps <= 256, got %d", ph_total)
}

@(test)
test_prehashed_key_custom_20byte_hasher_id0 :: proc(t: ^testing.T) {
	inv_sha1 :: proc(data: []u8, out_hash: []u8, _: rawptr) {
		xitdb.sha1_sum_into(data, out_hash)
		for i := 0; i < 20; i += 1 {
			out_hash[i] = ~out_hash[i]
		}
	}

	cfg := forseti.Xitdb_Config{
		custom_hasher = xitdb.Hasher{
			hash_proc = inv_sha1,
			hash_size = 20,
			id        = 0,
		},
	}

	sb := new(forseti.Store_Bridge)
	testing.expect_value(t, forseti.store_bridge_init_standalone(sb, cfg), nil)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}

	pk_std := forseti.prehashed_key_make("k_std")
	pk_pre := forseti.prehashed_key_make("k_pre")

	Commit_Ctx :: struct {
		pk_pre: ^forseti.Prehashed_Key,
	}
	cctx := Commit_Ctx{pk_pre = &pk_pre}
	cb :: proc(m_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
		ctx := (^Commit_Ctx)(user_data)
		m := xitdb.write_hash_map_init(m_wc^) or_return
		xitdb.hash_map_put(&m, "k_std", i64(111)) or_return
		forseti.hash_map_put_prehashed(&m, ctx.pk_pre, i64(222)) or_return
		return nil
	}
	_, cerr := forseti.store_bridge_commit_moment(sb, cb, &cctx)
	testing.expect_value(t, cerr, nil)

	mcur, mok, merr := forseti.store_bridge_moment_cursor(sb, -1)
	testing.expect_value(t, merr, nil)
	testing.expect(t, mok)

	rm := xitdb.Read_Hash_Map{cursor = mcur}
	c1, g1 := forseti.hash_map_get_cursor_prehashed(rm, &pk_std)
	testing.expect_value(t, g1, nil)
	rc1, ok1 := c1.?
	testing.expect(t, ok1)
	v1, r1 := xitdb.cursor_read_int(rc1)
	testing.expect_value(t, r1, nil)
	testing.expect_value(t, v1, i64(111))

	c2, g2 := xitdb.hash_map_get_cursor(rm, "k_pre")
	testing.expect_value(t, g2, nil)
	rc2, ok2 := c2.?
	testing.expect(t, ok2)
	v2, r2 := xitdb.cursor_read_int(rc2)
	testing.expect_value(t, r2, nil)
	testing.expect_value(t, v2, i64(222))
}

@(test)
test_interner_geometric_growth_10k :: proc(t: ^testing.T) {
	si: forseti.String_Interner
	testing.expect_value(t, forseti.interner_init(&si), nil)
	defer forseti.interner_destroy(&si)

	buf: [32]u8 = ---
	for i := 0; i < 10_000; i += 1 {
		txt := fmt.bprintf(buf[:], "str:%06d", i)
		sid, err := forseti.intern(&si, txt)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, forseti.interner_get(&si, sid), txt)
	}
	testing.expect_value(t, len(si.strings), 10_001) // slot 0 = EMPTY_STRING
	sid_dup, err_dup := forseti.intern(&si, "str:004242")
	testing.expect_value(t, err_dup, nil)
	testing.expect_value(t, forseti.interner_get(&si, sid_dup), "str:004242")
	testing.expect_value(t, len(si.strings), 10_001)
}

@(test)
test_beta_token_size_and_multi_decide_isolation :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		size_of(forseti.Beta_Token) <= 768,
		"expected compact Beta_Token <= 768 B, got %d B",
		size_of(forseti.Beta_Token),
	)

	src := `module six_decide version "1.0"
schema In { id: string, k: i64 }
schema Out { id: string, score: i64, tag: string }
source In : In at .req_in[?id]
derived Out : Out at .req_out[?id]

table d1 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { s: i64 } rows { r1: == 1 || 10; r2: - || 20; } }
table d2 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { s: i64 } rows { r1: == 1 || 100; r2: - || 200; } }
table d3 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { t: string } rows { r1: == 1 || "k1"; r2: - || "k2"; } }
table d4 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { s: i64 } rows { r1: == 1 || 1; r2: - || 2; } }
table d5 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { t: string } rows { r1: == 1 || "ok"; r2: - || "alt"; } }
table d6 version "1.0" hit First { inputs { k: i64 cost 1 } outputs { t: string } rows { r1: == 1 || "p1"; r2: - || "p2"; } }

rule six_steps {
  when {
    ?_x := In(id: ?id, k: ?k)
    ?a1 := decide d1(k: ?k)
    ?a2 := decide d2(k: ?k)
    ?a3 := decide d3(k: ?k)
    ?a4 := decide d4(k: ?k)
    ?a5 := decide d5(k: ?k)
    ?a6 := decide d6(k: ?k)
    where ?a3.t == "k1" or ?a5.t == "alt"
  }
  then {
    assert Out(id: ?id, score: ?a1.s + ?a2.s + ?a4.s, tag: ?a6.t)
  }
}`

	rb := _compile_test_rb(t, src, "six_decide.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	for i := 1; i <= 4; i += 1 {
		key := fmt.tprintf("i:%d", i)
		ks, _ := forseti.intern_session_string(&rb.interner, &sess.interner, key)
		kv := i64(1 if i % 2 == 1 else 2)
		_, _ = forseti.session_insert_fact(sess, "In", key, {ks, kv})
	}
	defer free_all(context.temp_allocator)

	fired, fe := forseti.session_fire(sess)
	testing.expect_value(t, fe, forseti.Session_Error.None)
	testing.expect_value(t, fired, u64(4))
	testing.expect_value(t, _count_alive_binding(sess, "Out"), 4)

	bidx, _ := forseti.session_find_binding(sess, "Out")
	for &f in sess.facts {
		if !f.alive || f.binding_idx != bidx {
			continue
		}
		id_s := forseti.session_string(sess, f.fields[0].(forseti.String_Id))
		sc := f.fields[1].(i64)
		tg := forseti.session_string(sess, f.fields[2].(forseti.String_Id))
		if id_s == "i:1" || id_s == "i:3" {
			testing.expect_value(t, sc, i64(111))
			testing.expect_value(t, tg, "p1")
		} else {
			testing.expect_value(t, sc, i64(222))
			testing.expect_value(t, tg, "p2")
		}
	}
}

@(test)
test_accum_f64_cancellation_nonfinite_and_heap_compaction :: proc(t: ^testing.T) {
	// 1. Float cancellation + nonfinite recovery
	sum_st: forseti.Accum_State
	forseti.accum_init(&sum_st, .Sum)
	defer forseti.accum_destroy(&sum_st)

	forseti.accum_insert(&sum_st, f64(1e16))
	forseti.accum_insert(&sum_st, f64(1.0))
	forseti.accum_insert(&sum_st, f64(-1e16))
	v_c, ok_c := forseti.accum_finalize(&sum_st)
	testing.expect(t, ok_c)
	testing.expect(t, math.abs(v_c.(f64) - 1.0) < 1e-6)

	pos_inf := math.inf_f64(1)
	neg_inf := math.inf_f64(-1)
	nan_v := math.nan_f64()

	forseti.accum_insert(&sum_st, f64(41.5))
	forseti.accum_insert(&sum_st, pos_inf)
	v_inf, _ := forseti.accum_finalize(&sum_st)
	testing.expect(t, math.is_inf(v_inf.(f64), 1))

	forseti.accum_insert(&sum_st, neg_inf)
	v_nan1, _ := forseti.accum_finalize(&sum_st)
	testing.expect(t, math.is_nan(v_nan1.(f64)))

	forseti.accum_retract(&sum_st, pos_inf)
	forseti.accum_retract(&sum_st, neg_inf)
	forseti.accum_insert(&sum_st, nan_v)
	v_nan2, _ := forseti.accum_finalize(&sum_st)
	testing.expect(t, math.is_nan(v_nan2.(f64)))

	forseti.accum_retract(&sum_st, nan_v)
	v_rec, ok_rec := forseti.accum_finalize(&sum_st)
	testing.expect(t, ok_rec)
	testing.expect(t, math.abs(v_rec.(f64) - 42.5) < 1e-6)

	// 2. Min/Max lazy heap compaction across heavy insert/retract churn
	for op in ([2]forseti.Accum_Op{.Min, .Max}) {
		st: forseti.Accum_State
		forseti.accum_init(&st, op)
		defer forseti.accum_destroy(&st)

		for i := i64(1); i <= 300; i += 1 {
			forseti.accum_insert(&st, i)
		}
		for i := i64(1); i <= 250; i += 1 {
			forseti.accum_retract(&st, i)
		}
		got, ok := forseti.accum_finalize(&st)
		testing.expect(t, ok)
		expected := i64(251) if op == .Min else i64(300)
		testing.expect_value(t, got.(i64), expected)
		testing.expectf(
			t,
			len(st.bag_heap) <= max(len(st.bag_counts) * 2, 64),
			"expected compacted heap <= max(2*U, 64), got %d for U=%d",
			len(st.bag_heap),
			len(st.bag_counts),
		)
	}
}

@(test)
test_accum_overflow_64_delta_fallback_and_fast_modify :: proc(t: ^testing.T) {
	src := `module accum_overflow version "1.0"
schema Bucket { grp: i64 }
schema Item { grp: i64, amt: i64 }
schema Out { grp: i64, s: i64 }
source Bucket : Bucket at .b[?id]
source Item : Item at .it[?id]
derived Out : Out at .out[?id]

rule sum_grp {
  when {
    ?_b := Bucket(grp: ?g)
    ?s := sum(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert Out(grp: ?g, s: ?s) }
}`

	rb := _compile_test_rb(t, src, "accum_overflow.forseti")
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	_, _ = forseti.session_insert_fact(sess, "Bucket", "b0", {i64(0)})
	_, _ = forseti.session_insert_fact(sess, "Bucket", "b1", {i64(1)})
	_, _ = forseti.session_fire(sess)

	// Burst > 64 inserts in one tx (75 items) overflows MAX_ALPHA_DELTA_LOG and falls back cleanly.
	kbuf: [24]u8 = ---
	for i := 0; i < 75; i += 1 {
		key := fmt.bprintf(kbuf[:], "it:%d", i)
		grp := i64(i % 2)
		_, _ = forseti.session_insert_fact(sess, "Item", key, {grp, i64(10)})
	}
	_, fe1 := forseti.session_fire(sess)
	testing.expect_value(t, fe1, forseti.Session_Error.None)

	find_sum :: proc(s: ^forseti.Session, grp: i64) -> (val: i64, ok: bool) {
		bidx, _ := forseti.session_find_binding(s, "Out")
		for &f in s.facts {
			if f.alive && f.binding_idx == bidx && f.fields[0] == forseti.Value(grp) {
				return f.fields[1].(i64), true
			}
		}
		return 0, false
	}

	s0, ok0 := find_sum(sess, 0)
	s1, ok1 := find_sum(sess, 1)
	testing.expect(t, ok0 && ok1)
	testing.expect_value(t, s0, i64(380)) // 38 even indices * 10
	testing.expect_value(t, s1, i64(370)) // 37 odd indices * 10

	// Burst > 64 retracts in one tx.
	for i := 0; i < 70; i += 1 {
		key := fmt.bprintf(kbuf[:], "it:%d", i)
		_ = forseti.session_retract_fact_by_key(sess, "Item", key)
	}
	_, fe2 := forseti.session_fire(sess)
	testing.expect_value(t, fe2, forseti.Session_Error.None)
	s0b, _ := find_sum(sess, 0)
	s1b, _ := find_sum(sess, 1)
	testing.expect_value(t, s0b, i64(30)) // 70, 72, 74
	testing.expect_value(t, s1b, i64(20)) // 71, 73

	// In-place fast modify on Bucket moving outer key 1 -> 0.
	_ = forseti.session_modify_fact_by_key(sess, "Bucket", "b1", {i64(0)})
	_, fe3 := forseti.session_fire(sess)
	testing.expect_value(t, fe3, forseti.Session_Error.None)
	testing.expect_value(t, _count_alive_binding(sess, "Out"), 1)
	s0c, _ := find_sum(sess, 0)
	testing.expect_value(t, s0c, i64(30))
}

@(test)
test_jtms_pooled_recycle_and_provenance_fifo_order :: proc(t: ^testing.T) {
	src := `module hub_fifo version "1.0"
schema Hub { x: i64 }
schema Leaf { id: i64, x: i64 }
schema Alt { id: i64 }
schema Out { id: i64 }
source Hub : Hub at .hub[?id]
source Leaf : Leaf at .leaf[?id]
source Alt : Alt at .alt[?id]
derived Out : Out at .out[?id]

rule r_hub {
  when {
    ?_h := Hub(x: ?x)
    ?_l := Leaf(id: ?id, x: ?x)
  }
  then { assert Out(id: ?id) }
}
rule r_alt {
  when { ?_a := Alt(id: ?id) }
  then { assert Out(id: ?id) }
}`

	rb := _compile_test_rb(t, src, "hub_fifo.forseti")
	defer forseti.rulebase_destroy(&rb)

	// 1. Audit_Full preserves exact FIFO derivation order in intrusive Provenance lists.
	s_audit := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s_audit, &rb, forseti.Session_Config{provenance_mode = .Audit_Full}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s_audit)
		free(s_audit)
	}
	_, _ = forseti.session_insert_fact(s_audit, "Hub", "h1", {i64(7)})
	_, _ = forseti.session_insert_fact(s_audit, "Leaf", "l1", {i64(1), i64(7)})
	_, _ = forseti.session_fire(s_audit)
	_, _ = forseti.session_insert_fact(s_audit, "Alt", "a1", {i64(1)})
	_, _ = forseti.session_fire(s_audit)

	out_bidx, _ := forseti.session_find_binding(s_audit, "Out")
	out_fid := forseti.INVALID_FACT
	for &f in s_audit.facts {
		if f.alive && f.binding_idx == out_bidx {
			out_fid = f.id
			break
		}
	}
	testing.expect(t, out_fid != forseti.INVALID_FACT)
	testing.expect(t, int(out_fid) < len(s_audit.provenance.fact_deriv_lists))
	d0 := s_audit.provenance.fact_deriv_lists[out_fid].head
	testing.expect(t, d0 != forseti.INVALID_DERIVATION)
	d1 := s_audit.provenance.deriv_next_for_fact[d0]
	testing.expect(t, d1 != forseti.INVALID_DERIVATION)
	testing.expect_value(t, s_audit.provenance.deriv_next_for_fact[d1], forseti.INVALID_DERIVATION)
	testing.expect_value(t, forseti.interner_get(&rb.interner, rb.rules[s_audit.provenance.derivs[d0].rule_id].name), "r_hub")
	testing.expect_value(t, forseti.interner_get(&rb.interner, rb.rules[s_audit.provenance.derivs[d1].rule_id].name), "r_alt")

	// 2. Fast mode hub retract + recycle handles 64+ dependents cleanly across multiple cycles.
	s_fast := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(s_fast, &rb, forseti.Session_Config{provenance_mode = .Fast}), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s_fast)
		free(s_fast)
	}
	kbuf: [24]u8 = ---
	for i := i64(0); i < 64; i += 1 {
		_, _ = forseti.session_insert_fact(s_fast, "Leaf", fmt.bprintf(kbuf[:], "l:%d", i), {i, i64(9)})
	}
	for cycle := 0; cycle < 3; cycle += 1 {
		_, _ = forseti.session_insert_fact(s_fast, "Hub", "h", {i64(9)})
		_, _ = forseti.session_fire(s_fast)
		testing.expect_value(t, _count_alive_binding(s_fast, "Out"), 64)
		_ = forseti.session_retract_fact_by_key(s_fast, "Hub", "h")
		_, _ = forseti.session_fire(s_fast)
		testing.expect_value(t, _count_alive_binding(s_fast, "Out"), 0)
	}
	testing.expect(t, len(s_fast.jtms.free_justs) >= 64)
}

@(test)
test_flat_pool_steady_state_alloc_budget :: proc(t: ^testing.T) {
	src := `module pool_budget version "1.0"
schema Org { id: string, dom: string }
schema Dept { id: string, dom: string }
schema Contract { id: string, dom: string, v: i64 }
schema Out { id: string }
source Org : Org at .o[?id]
source Dept : Dept at .d[?id]
source Contract : Contract at .c[?id]
derived Out : Out at .out[?id]

rule join3 {
  when {
    ?_o := Org(id: ?id, dom: ?dom)
    ?_p := Dept(dom: ?dom)
    ?_c := Contract(dom: ?dom, v: ?v)
    where ?v >= 10
  }
  then { assert Out(id: ?id) }
}`

	rb := _compile_test_rb(t, src, "pool_budget.forseti")
	defer forseti.rulebase_destroy(&rb)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	talloc := mem.tracking_allocator(&track)

	sess := new(forseti.Session, talloc)
	testing.expect_value(t, forseti.session_init(sess, &rb, forseti.Session_Config{provenance_mode = .Fast}, nil, talloc), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess, talloc)
	}

	kbuf: [24]u8 = ---
	dbuf: [24]u8 = ---
	for i := 0; i < 200; i += 1 {
		k := fmt.bprintf(kbuf[:], "k:%d", i)
		d := fmt.bprintf(dbuf[:], "d:%d", i)
		ks, _ := forseti.intern_session_string(&rb.interner, &sess.interner, k)
		ds, _ := forseti.intern_session_string(&rb.interner, &sess.interner, d)
		_, _ = forseti.session_insert_fact(sess, "Org", k, {ks, ds})
		_, _ = forseti.session_insert_fact(sess, "Dept", k, {ks, ds})
		_, _ = forseti.session_insert_fact(sess, "Contract", k, {ks, ds, i64(20)})
	}
	_, _ = forseti.session_fire(sess)

	k0_s, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "k:0")
	d0_s, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "d:0")
	// Warm up both alternating toggle states across 3-way join cleanly.
	for toggle_val in ([2]i64{30, 5}) {
		_ = forseti.session_modify_fact_by_key(sess, "Contract", "k:0", {k0_s, d0_s, toggle_val})
		_, _ = forseti.session_fire(sess)
	}
	free_all(context.temp_allocator)

	before_allocs := track.total_allocation_count
	for i := 0; i < 10; i += 1 {
		v := i64(30 if i % 2 == 0 else 5)
		_ = forseti.session_modify_fact_by_key(sess, "Contract", "k:0", {k0_s, d0_s, v})
		_, _ = forseti.session_fire(sess)
		free_all(context.temp_allocator)
	}
	after_allocs := track.total_allocation_count
	delta_allocs := after_allocs - before_allocs
	testing.expectf(t, delta_allocs <= 4, "expected steady-state 3-way flat-pool allocs <= 4 across 10 modify cycles, got %d", delta_allocs)
}

@(test)
test_audit_full_geometric_growth_alloc_budget :: proc(t: ^testing.T) {
	// 1. Audit_Full 3-stage Root -> Mid -> Leaf with decide table over 2,000 roots (4,000 derived facts)
	//    + full retraction cascade must grow geometrically (O(log N) slice reallocs, not O(N)).
	chain_src := `module audit_geom version "1.0"
schema Root { id: string, emp: i64 }
schema Mid { id: string, tier: string }
schema Leaf { id: string, tier: string }
source Root : Root at .groot[?id]
derived Mid : Mid at .gmid[?id]
derived Leaf : Leaf at .gleaf[?id]

table tier_tbl version "1.0" hit First {
  inputs { emp: i64 cost 1 }
  outputs { tier: string }
  rows { r1: >= 50 || "ok"; r2: - || "low"; }
}

rule r_mid {
  when {
    ?_r := Root(id: ?id, emp: ?e)
    ?t := decide tier_tbl(emp: ?e)
    where ?t.tier == "ok"
  }
  then { assert Mid(id: ?id, tier: ?t.tier) }
}
rule r_leaf {
  when { ?_m := Mid(id: ?id, tier: ?t) }
  then { assert Leaf(id: ?id, tier: ?t) }
}`

	rb1 := _compile_test_rb(t, chain_src, "audit_geom.forseti")
	defer forseti.rulebase_destroy(&rb1)

	track1: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track1, context.allocator)
	defer mem.tracking_allocator_destroy(&track1)
	ta1 := mem.tracking_allocator(&track1)

	s1 := new(forseti.Session, ta1)
	testing.expect_value(t, forseti.session_init(s1, &rb1, forseti.Session_Config{provenance_mode = .Audit_Full}, nil, ta1), forseti.Session_Error.None)
	{
		defer {
			forseti.session_destroy(s1)
			free(s1, ta1)
		}
		n :: 2_000
		kbuf: [24]u8 = ---
		for i := 0; i < n; i += 1 {
			key := fmt.bprintf(kbuf[:], "r:%04d", i)
			ks, _ := forseti.intern_session_string(&rb1.interner, &s1.interner, key)
			_, _ = forseti.session_insert_fact(s1, "Root", key, {ks, i64(100)})
		}
		_, fe1 := forseti.session_fire(s1)
		testing.expect_value(t, fe1, forseti.Session_Error.None)
		testing.expect_value(t, _count_alive_binding(s1, "Leaf"), n)

		for i := 0; i < n; i += 1 {
			key := fmt.bprintf(kbuf[:], "r:%04d", i)
			_ = forseti.session_retract_fact_by_key(s1, "Root", key)
		}
		_, fe2 := forseti.session_fire(s1)
		testing.expect_value(t, fe2, forseti.Session_Error.None)
		testing.expect_value(t, _count_alive_binding(s1, "Leaf"), 0)
	}
	// Previously > 8,000 due to exact-cap resize(&p.fact_deriv_lists), jtms scratch arrays, and per-activation decide_blocks.
	testing.expectf(t, track1.total_allocation_count <= 700, "expected Audit_Full 2k cascade allocs <= 700, got %d", track1.total_allocation_count)

	// 2. Steady-state Audit_Full single-item modify over grouped sum accumulator must not reallocate scratch/deriv lists on every edit.
	acc_src := `module audit_acc_geom version "1.0"
schema Bucket { grp: string }
schema Item { grp: string, amt: i64 }
schema Out { grp: string, total: i64 }
source Bucket : Bucket at .ab[?id]
source Item : Item at .ai[?id]
derived Out : Out at .ao[?id]

rule sum_grp {
  when {
    ?_b := Bucket(grp: ?g)
    ?s := sum(?a) from Item(grp: ?g, amt: ?a)
  }
  then { assert Out(grp: ?g, total: ?s) }
}`

	rb2 := _compile_test_rb(t, acc_src, "audit_acc_geom.forseti")
	defer forseti.rulebase_destroy(&rb2)

	track2: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track2, context.allocator)
	defer mem.tracking_allocator_destroy(&track2)
	ta2 := mem.tracking_allocator(&track2)

	s2 := new(forseti.Session, ta2)
	testing.expect_value(t, forseti.session_init(s2, &rb2, forseti.Session_Config{provenance_mode = .Audit_Full}, nil, ta2), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(s2)
		free(s2, ta2)
	}
	grp_s, _ := forseti.intern_session_string(&rb2.interner, &s2.interner, "g0")
	_, _ = forseti.session_insert_fact(s2, "Bucket", "g0", {grp_s})
	ibuf: [24]u8 = ---
	for i := 0; i < 500; i += 1 {
		key := fmt.bprintf(ibuf[:], "it:%04d", i)
		_, _ = forseti.session_insert_fact(s2, "Item", key, {grp_s, i64(i + 1)})
	}
	_, _ = forseti.session_fire(s2)
	for tv in ([2]i64{10, 20}) {
		_ = forseti.session_modify_fact_by_key(s2, "Item", "it:0000", {grp_s, tv})
		_, _ = forseti.session_fire(s2)
	}
	free_all(context.temp_allocator)

	before := track2.total_allocation_count
	for i := 0; i < 500; i += 1 {
		v := i64(10 if i % 2 == 0 else 20)
		_ = forseti.session_modify_fact_by_key(s2, "Item", "it:0000", {grp_s, v})
		_, _ = forseti.session_fire(s2)
		free_all(context.temp_allocator)
	}
	delta := track2.total_allocation_count - before
	testing.expectf(t, delta <= 120, "expected Audit_Full warm accum modify O(log N) allocs <= 120 across 500 cycles, got %d", delta)
}
