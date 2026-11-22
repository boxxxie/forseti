package main

import "core:fmt"
import "core:mem"
import "core:os"
import "../../forseti"

run_example :: proc() -> bool {
	src := `module ex04_cyclic version "1.0"
schema Edge { parent: string, child: string }
source OrgEdge : Edge at .edges[?id]
derived Ancestor : Edge at .anc[?id]

rule anc_base phase "recurse" {
  when { ?_e := OrgEdge(parent: ?p, child: ?c) }
  then { assert Ancestor(parent: ?p, child: ?c) }
}
rule anc_step phase "recurse" {
  when {
    ?_a := Ancestor(parent: ?p, child: ?mid)
    ?_b := Ancestor(parent: ?mid, child: ?c)
  }
  then { assert Ancestor(parent: ?p, child: ?c) }
}`

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "04_cyclic.forseti", &diags)
	if c_err != nil || diags.error_count != 0 {
		return false
	}
	defer forseti.ir_destroy(&ir)

	rb, rb_err := forseti.rulebase_compile(&ir)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb)
		return false
	}
	defer forseti.rulebase_destroy(&rb)

	sess := new(forseti.Session)
	if forseti.session_init(sess, &rb) != .None {
		forseti.session_destroy(sess)
		free(sess)
		return false
	}
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	a_s, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "A")
	b_s, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "B")
	c_s, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "C")

	_, _ = forseti.session_insert_fact(sess, "OrgEdge", "e1", {a_s, b_s})
	_, _ = forseti.session_insert_fact(sess, "OrgEdge", "e2", {b_s, c_s})
	e3_fid, _ := forseti.session_insert_fact(sess, "OrgEdge", "e3", {c_s, a_s})
	_, _ = forseti.session_fire(sess)

	anc_bidx, _ := forseti.session_find_binding(sess, "Ancestor")
	alive_cnt := 0
	sample_fid := forseti.INVALID_FACT
	for &f in sess.facts {
		if f.alive && f.binding_idx == anc_bidx {
			alive_cnt += 1
			if sample_fid == forseti.INVALID_FACT {
				sample_fid = f.id
			}
		}
	}
	// Full 3-node cycle closure: all 9 (parent, child) pairs
	if alive_cnt != 9 || sample_fid == forseti.INVALID_FACT {
		fmt.eprintfln("expected 9 Ancestor facts in 3-cycle, got %d", alive_cnt)
		return false
	}

	tree := forseti.explain(sess, sample_fid)
	defer forseti.explain_tree_destroy(&tree)
	if !tree.found {
		return false
	}

	// Break cycle edge C->A -> remaining DAG is A->B, B->C, A->C (3 edges)
	_ = forseti.session_retract_fact(sess, e3_fid)
	rem_cnt := 0
	for &f in sess.facts {
		if f.alive && f.binding_idx == anc_bidx {
			rem_cnt += 1
		}
	}
	if rem_cnt != 3 {
		fmt.eprintfln("expected 3 Ancestor facts after breaking cycle, got %d", rem_cnt)
		return false
	}

	fmt.printfln("[ex04] OK cyclic closure=9 facts -> break cycle -> %d facts", rem_cnt)
	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	ok := run_example()
	free_all(context.temp_allocator)

	leaks := len(track.allocation_map)
	bad_frees := len(track.bad_free_array)
	for _, entry in track.allocation_map {
		fmt.eprintfln("%v leaked %m", entry.location, entry.size)
	}
	mem.tracking_allocator_destroy(&track)
	if !ok || leaks > 0 || bad_frees > 0 {
		os.exit(1)
	}
}
