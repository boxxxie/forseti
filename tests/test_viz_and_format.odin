package forseti_tests

import "core:strings"
import "core:testing"
import "../forseti"

@(test)
test_viz_exports_deterministic_and_escape_safe :: proc(t: ^testing.T) {
	src := `module viz_unit version "1.0"
schema Edge { src: string, dst: string }
schema Reach { src: string, dst: string }
source Edge : Edge at .edges[?k]
derived Reach : Reach at .reach[?k]

table check_edge version "1.0" hit First {
  inputs { src: string }
  outputs { ok: bool }
  rows {
    r_ok: != "ban\"ned" || true;
    r_no: -             || false;
  }
}

rule reach_base {
  when {
    ?_e := Edge(src: ?x, dst: ?y)
    ?g := decide check_edge(src: ?x)
    where ?g.ok == true
  }
  then { assert Reach(src: ?x, dst: ?y) }
}

rule reach_rec {
  when {
    ?_a := Reach(src: ?x, dst: ?y)
    ?_b := Reach(src: ?y, dst: ?z)
  }
  then { assert Reach(src: ?x, dst: ?z) }
}`

	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "viz.forseti", &diags)
	testing.expect_value(t, c_err, nil)
	defer forseti.ir_destroy(&ir)
	testing.expect_value(t, diags.error_count, 0)

	rb, rb_err := forseti.rulebase_compile(&ir)
	testing.expect_value(t, rb_err, forseti.Compile_Error.None)
	defer forseti.rulebase_destroy(&rb)

	dot1, d1_err := forseti.export_rulebase_dot(&rb)
	testing.expect_value(t, d1_err, nil)
	defer delete(dot1)
	dot2, d2_err := forseti.export_rulebase_dot(&rb)
	testing.expect_value(t, d2_err, nil)
	defer delete(dot2)
	testing.expect_value(t, dot1, dot2)
	testing.expect(t, strings.contains(dot1, "reach_base"))
	testing.expect(t, strings.contains(dot1, "check_edge"))

	mmd1, m1_err := forseti.export_rulebase_mermaid(&rb)
	testing.expect_value(t, m1_err, nil)
	defer delete(mmd1)
	testing.expect(t, strings.contains(mmd1, "flowchart LR"))
	testing.expect(t, strings.contains(mmd1, "-. decide .->"))

	sess := new(forseti.Session)
	testing.expect_value(t, forseti.session_init(sess, &rb), forseti.Session_Error.None)
	defer {
		forseti.session_destroy(sess)
		free(sess)
	}

	s_a, _ := forseti.intern_session_string(&rb.interner, &sess.interner, `a"1`)
	s_b, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "b")
	_, _ = forseti.session_insert_fact(sess, "Edge", "e1", {s_a, s_b})
	_, _ = forseti.session_insert_fact(sess, "Edge", "e2", {s_b, s_a})
	_, _ = forseti.session_fire(sess)

	// Cyclic Reach derivations terminate cleanly when focused and full-session exported
	var_focus := forseti.INVALID_FACT
	for &f in sess.facts {
		if f.alive && rb.bindings[f.binding_idx].kind == .Derived {
			var_focus = f.id
			break
		}
	}
	testing.expect(t, var_focus != forseti.INVALID_FACT)

	d_dot1, dd1_err := forseti.export_derivations_dot(sess, var_focus)
	testing.expect_value(t, dd1_err, nil)
	defer delete(d_dot1)
	d_dot2, dd2_err := forseti.export_derivations_dot(sess, var_focus)
	testing.expect_value(t, dd2_err, nil)
	defer delete(d_dot2)
	testing.expect_value(t, d_dot1, d_dot2)
	testing.expect(t, strings.contains(d_dot1, `\"1`))

	d_mmd, dm_err := forseti.export_derivations_mermaid(sess)
	testing.expect_value(t, dm_err, nil)
	defer delete(d_mmd)
	testing.expect(t, strings.contains(d_mmd, "flowchart TD"))
	testing.expect(t, strings.contains(d_mmd, "reach_base"))
}

@(test)
test_format_json_outputs_and_escaping :: proc(t: ^testing.T) {
	// Empty / missing explain & impact & diff_replay format safely without leaks
	empty_tree := forseti.Explain_Tree{found = false}
	ej, ej_err := forseti.explain_format_json(&empty_tree)
	testing.expect_value(t, ej_err, nil)
	defer delete(ej)
	testing.expect_value(t, ej, `{"found":false,"root":null}`)

	ij, ij_err := forseti.impact_format_json(nil, nil)
	testing.expect_value(t, ij_err, nil)
	defer delete(ij)
	testing.expect(t, strings.contains(ij, `"direct_count":0`))

	dj, dj_err := forseti.diff_replay_format_json(nil)
	testing.expect_value(t, dj_err, nil)
	defer delete(dj)
	testing.expect(t, strings.contains(dj, `"unchanged_count":0`))

	b := forseti.rulebase_binding_dot_path(nil, 0, nil)
	testing.expect_value(t, b, "")
}
