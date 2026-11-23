package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import actor "actor:."
import xitdb "xitdb:."
import "../../actors"
import "../../forseti"

_seed_snapshot_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	_ = user_data
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	orgs := [3]struct {
		id:  string,
		emp: i64,
	}{
		{"org:1", 80},
		{"org:2", 180},
		{"org:3", 450},
	}
	for o in orgs {
		rwc := xitdb.hash_map_put_cursor(&m, o.id) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "org_id", o.id) or_return
		xitdb.hash_map_put(&rm, "employees", o.emp) or_return
	}
	return nil
}

run_example :: proc() -> bool {
	v1_policy := `module ex08_mdm version "1.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "1.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 100 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule classify {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	v2_policy := `module ex08_mdm version "2.0"
schema RawOrg { org_id: string, employees: i64 }
schema CanonOrg { org_id: string, tier: string }

source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

table tier_gate version "2.0" hit First {
  inputs { employees: i64 }
  outputs { tier: string }
  rows {
    r_ent: >= 300 || "enterprise";
    r_smb: -      || "smb";
  }
}

rule classify {
  when {
    ?_r := Raw(org_id: ?oid, employees: ?emp)
    ?g := decide tier_gate(employees: ?emp)
  }
  then { assert Canon(org_id: ?oid, tier: ?g.tier) }
}

query ent_orgs() {
  Canon(org_id: ?oid, tier: "enterprise")
}`

	// Frozen snapshot store shared safely across concurrent Session rehydrations and Parallel_Diff_Replay
	snap: forseti.Store_Bridge
	if forseti.store_bridge_init_standalone(&snap) != nil {
		return false
	}
	defer forseti.store_bridge_destroy(&snap)
	if _, m_err := forseti.store_bridge_commit_moment(&snap, _seed_snapshot_cb, nil); m_err != nil {
		return false
	}

	sched := actor.scoped_scheduler(num_workers = 4)

	// 1. Single-writer Xitdb_Commit_Actor + Rulebase_Coordinator hot-reload
	writer, w_err := actors.commit_actor_spawn_memory(sched)
	if w_err != nil {
		return false
	}

	coord, c_err := actors.rulebase_coordinator_spawn(sched, v1_policy, "v1.forseti", &snap, {".orgs.raw"})
	if c_err != .None {
		return false
	}
	sa, s_err := actors.rulebase_coordinator_spawn_session(sched, coord)
	if s_err != nil {
		return false
	}

	q1 := actor.call(sched, sa, actors.Session_Msg(actors.Run_Query{query_name = "ent_orgs"}), actors.Session_Query_Reply)
	v1_ent := len(q1.result.rows)
	forseti.query_result_destroy(&q1.result)
	if q1.err != .None || v1_ent != 2 {
		fmt.eprintfln("expected 2 v1 enterprise rows, got %d", v1_ent)
		return false
	}

	c_rep := actor.call(sched, sa, actors.Session_Msg(actors.Commit_Derived_To_Writer{writer = actor.pid(writer)}), actors.Commit_Reply)
	if c_rep.err != nil || c_rep.moment_idx != 0 {
		return false
	}

	// Hot-reload to v2 (>= 300 threshold)
	rel := actor.call(sched, coord, actors.Coordinator_Msg(actors.Reload_Policy{source = v2_policy, filename = "v2.forseti"}), actors.Coordinator_Reload_Reply)
	if !rel.ok || rel.version != 2 {
		return false
	}
	q2 := actor.call(sched, sa, actors.Session_Msg(actors.Run_Query{query_name = "ent_orgs"}), actors.Session_Query_Reply)
	v2_ent := len(q2.result.rows)
	forseti.query_result_destroy(&q2.result)
	if q2.err != .None || v2_ent != 1 {
		fmt.eprintfln("expected 1 v2 enterprise row, got %d", v2_ent)
		return false
	}

	// 2. Partitioned multi-tenant runtime (destroyed before scoped_scheduler exits)
	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	defer forseti.diag_list_destroy(&diags)
	ir_v1, _ := forseti.compile_source(v1_policy, "v1.forseti", &diags)
	defer forseti.ir_destroy(&ir_v1)
	rb_v1, _ := forseti.rulebase_compile(&ir_v1)
	defer forseti.rulebase_destroy(&rb_v1)

	ir_v2, _ := forseti.compile_source(v2_policy, "v2.forseti", &diags)
	defer forseti.ir_destroy(&ir_v2)
	rb_v2, _ := forseti.rulebase_compile(&ir_v2)
	defer forseti.rulebase_destroy(&rb_v2)

	rt: actors.Tenant_Rule_Runtime
	if actors.tenant_runtime_init(&rt, sched, actors.Tenant_Runtime_Config{
		num_partitions  = 4,
		idle_timeout    = 60 * time.Second,
		rb              = &rb_v1,
		rehydrate_store = &snap,
		rehydrate_paths = {".orgs.raw"},
	}) != nil {
		return false
	}
	defer actors.tenant_runtime_destroy(&rt)

	tq, tq_err := actors.tenant_runtime_try_call_name(&rt, "tenant:acme", actors.Session_Msg(actors.Run_Query{query_name = "ent_orgs"}), actors.Session_Query_Reply)
	t_rows := len(tq.result.rows)
	forseti.query_result_destroy(&tq.result)
	if tq_err != .None || tq.err != .None || t_rows != 2 {
		return false
	}

	// 3. Parallel_Diff_Replay over Core_Overlay forks
	diff_res, d_err := actors.parallel_diff_replay(sched, &snap, &rb_v1, {
		{name = "v2", rb = &rb_v2},
		{name = "v1_same", rb = &rb_v1},
	}, {".orgs.raw"})
	defer actors.parallel_diff_results_destroy(diff_res)
	if d_err != nil || len(diff_res) != 2 || len(diff_res[0].report.removed) != 1 || diff_res[1].report.unchanged_count != 3 {
		return false
	}

	fmt.printfln("[ex08] OK v1_ent=%d v2_ent=%d tenant_acme=%d diff_v2_removed=%d",
		v1_ent, v2_ent, t_rows, len(diff_res[0].report.removed))
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
