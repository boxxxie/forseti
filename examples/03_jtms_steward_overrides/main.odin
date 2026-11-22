package main

import "core:fmt"
import "core:mem"
import "core:os"
import "../../forseti"

count_alive :: proc(s: ^forseti.Session, binding_name: string) -> int {
	bidx, ok := forseti.session_find_binding(s, binding_name)
	if !ok {
		return 0
	}
	n := 0
	for &f in s.facts {
		if f.alive && f.binding_idx == bidx {
			n += 1
		}
	}
	return n
}

run_example :: proc() -> bool {
	src := `module ex03_jtms version "1.0"
schema OrgRef { org_id: string }
source RawOrg : OrgRef at .raw[?id]
source AltOrg : OrgRef at .alt[?id]
derived Canon : OrgRef at .canon[?id]
derived Alert : OrgRef at .alert[?id]
derived Audit : OrgRef at .audit[?id]

rule from_raw {
  when { ?_r := RawOrg(org_id: ?oid) }
  then {
    assert Canon(org_id: ?oid)
    assert! Audit(org_id: ?oid) unconditional
  }
}
rule from_alt {
  when { ?_a := AltOrg(org_id: ?oid) }
  then { assert Canon(org_id: ?oid) }
}
rule escalate {
  when { ?_c := Canon(org_id: ?oid) }
  then { assert Alert(org_id: ?oid) }
}`

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "03_jtms.forseti", &diags)
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

	s_org, _ := forseti.intern_session_string(&rb.interner, &sess.interner, "org:1")
	f_raw, _ := forseti.session_insert_fact(sess, "RawOrg", "r:1", {s_org})
	f_alt, _ := forseti.session_insert_fact(sess, "AltOrg", "a:1", {s_org})
	_, _ = forseti.session_fire(sess)

	if count_alive(sess, "Canon") != 1 || count_alive(sess, "Alert") != 1 || count_alive(sess, "Audit") != 1 {
		return false
	}

	// Retract first diamond leg -> Canon & Alert survive on AltOrg leg!
	_ = forseti.session_retract_fact(sess, f_raw)
	if count_alive(sess, "Canon") != 1 || count_alive(sess, "Alert") != 1 {
		return false
	}

	// Retract remaining leg -> Canon & Alert cascade out, while assert! Audit survives!
	_ = forseti.session_retract_fact(sess, f_alt)
	if count_alive(sess, "Canon") != 0 || count_alive(sess, "Alert") != 0 || count_alive(sess, "Audit") != 1 {
		return false
	}

	fmt.println("[ex03] OK JTMS diamond survival, cascade retraction & unconditional Audit preserved")
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
