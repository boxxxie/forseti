package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "../../forseti"

Effect_Task :: struct {
	job:       ^forseti.Effect_Job,
	org_id:    string,
	risk_tier: string,
}

worker_proc :: proc(data: rawptr) {
	t := (^Effect_Task)(data)
	for f in t.job.fields {
		if f.name == "org_id" {
			t.org_id = f.str
			break
		}
	}
	t.risk_tier = "verified_low" if t.org_id == "org:1" else "review"
}

run_example :: proc() -> bool {
	src := `module ex05_accum_eff version "1.0"
schema Org { org_id: string }
schema Invoice { org_id: string, amt: i64 }
schema Summary { org_id: string, cnt: i64, total: i64, min_amt: i64, max_amt: i64 }
schema Verified { org_id: string, tier: string }

source OrgSrc : Org at .orgs[?id]
source InvSrc : Invoice at .invoices[?id]
derived Summary : Summary at .summary[?id]
derived Verified : Verified at .verified[?id]

rule summarize {
  when {
    ?_o := OrgSrc(org_id: ?oid)
    ?cnt := count(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?tot := sum(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?mn := min(?a) from InvSrc(org_id: ?oid, amt: ?a)
    ?mx := max(?a) from InvSrc(org_id: ?oid, amt: ?a)
  }
  then { assert Summary(org_id: ?oid, cnt: ?cnt, total: ?tot, min_amt: ?mn, max_amt: ?mx) }
}

rule trigger_verify {
  when { ?_s := Summary(org_id: ?oid, min_amt: ?mn); where ?mn >= 200 }
  effect "verify_org" { org_id: ?oid }
}`

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "05_accum_eff.forseti", &diags)
	if c_err != nil {
		return false
	}
	defer forseti.ir_destroy(&ir)
	if diags.error_count != 0 {
		return false
	}

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
	_, _ = forseti.session_insert_fact(sess, "OrgSrc", "o1", {s_org})
	inv1, _ := forseti.session_insert_fact(sess, "InvSrc", "i1", {s_org, i64(100)})
	inv2, _ := forseti.session_insert_fact(sess, "InvSrc", "i2", {s_org, i64(100)})
	_, _ = forseti.session_insert_fact(sess, "InvSrc", "i3", {s_org, i64(250)})
	_, _ = forseti.session_fire(sess)

	// Retract one tied minimum (100): min stays 100, cnt=2, sum=350; then retract second 100 -> min=250 -> triggers effect!
	_ = forseti.session_retract_fact(sess, inv1)
	_, _ = forseti.session_fire(sess)
	_ = forseti.session_retract_fact(sess, inv2)
	_, _ = forseti.session_fire(sess)

	jobs := forseti.session_prepare_effects(sess)
	defer forseti.effects_jobs_destroy(jobs)
	if len(jobs) != 1 {
		fmt.eprintfln("expected 1 effect job, got %d", len(jobs))
		return false
	}

	task := Effect_Task{job = &jobs[0]}
	th := thread.create_and_start_with_data(&task, worker_proc)
	if th == nil {
		return false
	}
	thread.join(th)
	thread.destroy(th)

	tier_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, task.risk_tier)
	oid_sid, _ := forseti.intern_session_string(&rb.interner, &sess.interner, task.org_id)
	f_slice := [1]forseti.Effect_Result_Fact{{
		binding_name = "Verified",
		key          = "ver:org:1",
		fields       = {oid_sid, tier_sid},
	}}
	res_slice := [1]forseti.Effect_Result{{job_id = jobs[0].job_id, facts = f_slice[:]}}
	applied, app_err := forseti.session_apply_effects(sess, res_slice[:])
	if app_err != .None || len(applied) != 1 {
		return false
	}
	defer delete(applied)

	tree := forseti.explain(sess, applied[0])
	defer forseti.explain_tree_destroy(&tree)
	txt := forseti.explain_format(&tree)
	defer delete(txt)
	if !tree.found || !strings.contains(txt, "trigger_verify") {
		return false
	}

	fmt.println("[ex05] OK tied min retraction -> worker thread effect -> causal lineage verified")
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
