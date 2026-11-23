package main

import "core:fmt"
import "core:mem"
import "core:time"
import actor "actor:."
import hugi "hugi:."
import xitdb "xitdb:."
import actors "../actors"
import forseti "../forseti"

@(private = "file")
_ACTOR_BENCH_POLICY :: `module bench_actors version "1.0"
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
}`

@(private = "file")
_ACTOR_BENCH_CAND_POLICY :: `module bench_actors version "2.0"
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
}`

@(private = "file")
_bench_actor_seed_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	_ = user_data
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	kbuf: [24]u8 = ---
	for i in 0 ..< 32 {
		key := fmt.bprintf(kbuf[:], "org:%02d", i)
		rwc := xitdb.hash_map_put_cursor(&m, key) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "org_id", key) or_return
		xitdb.hash_map_put(&rm, "employees", i64(50 + i * 20)) or_return
	}
	return nil
}

@(private = "file")
_bench_session_actor_chain_k :: proc(b: ^hugi.Bencher) {
	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	if g_bench_root_allocator.procedure != nil {
		context.allocator = g_bench_root_allocator
	}
	defer {
		context.allocator = prev_alloc
		context.temp_allocator = prev_temp
	}
	workers := max(hugi.param(b), 1)
	rb, ok := compile_benchmark_source(_ACTOR_BENCH_POLICY, "actor_chain.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	context.temp_allocator = mem.nil_allocator()

	sched := actor.scoped_scheduler(num_workers = workers)
	NUM_ACTORS :: 8
	CHAIN_K :: 32
	handles: [NUM_ACTORS]^actors.Session_Actor_Handle
	for i in 0 ..< NUM_ACTORS {
		h, s_err := actors.session_actor_spawn(sched, rb, actors.Session_Actor_Config{
			session_cfg = forseti.Session_Config{provenance_mode = .Fast},
		}, u32(i + 1))
		if s_err != nil {
			return
		}
		handles[i] = h
	}

	fields_pool: [CHAIN_K][2]actors.Actor_Field_Value
	msgs: [CHAIN_K]actors.Session_Msg
	keys: [CHAIN_K]string
	kbuf: [CHAIN_K][24]u8
	for k in 0 ..< CHAIN_K {
		keys[k] = fmt.bprintf(kbuf[k][:], "k:%02d", k)
		fields_pool[k] = {keys[k], i64(100 + k * 10)}
		msgs[k] = actors.Insert_Fact{
			fact = actors.Actor_Fact_Input{
				binding_name = "Raw",
				key          = keys[k],
				fields       = fields_pool[k][:],
			},
		}
	}

	hugi.set_items(b, NUM_ACTORS * CHAIN_K)
	for hugi.step(b) {
		for h in handles {
			actor.send(sched, h, msgs[:])
		}
		for h in handles {
			rep := actor.call(sched, h, actors.Session_Msg(actors.Fire_Session{}), actors.Session_Fire_Reply)
			_ = hugi.black_box(rep.fired)
		}
	}
}

@(private = "file")
_bench_tenant_runtime_fanout :: proc(b: ^hugi.Bencher) {
	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	if g_bench_root_allocator.procedure != nil {
		context.allocator = g_bench_root_allocator
	}
	defer {
		context.allocator = prev_alloc
		context.temp_allocator = prev_temp
	}
	workers := max(hugi.param(b), 1)
	rb, ok := compile_benchmark_source(_ACTOR_BENCH_POLICY, "tenant_fanout.forseti")
	if !ok {
		return
	}
	defer {
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	context.temp_allocator = mem.nil_allocator()

	sched := actor.scoped_scheduler(num_workers = workers)
	rt: actors.Tenant_Rule_Runtime
	if actors.tenant_runtime_init(&rt, sched, actors.Tenant_Runtime_Config{
		num_partitions = 16,
		idle_timeout   = 60 * time.Second,
		rb             = rb,
		session_cfg    = forseti.Session_Config{provenance_mode = .Fast},
	}) != nil {
		return
	}
	defer {
		actor.scheduler_wait_idle(sched)
		actors.tenant_runtime_destroy(&rt)
	}

	TENANTS :: 16
	fields := [2]actors.Actor_Field_Value{"org:hot", i64(250)}
	msg := actors.Session_Msg(actors.Insert_Fact{
		fact = actors.Actor_Fact_Input{
			binding_name = "Raw",
			key          = "org:hot",
			fields       = fields[:],
		},
		auto_fire = true,
	})

	// Pre-warm all 16 tenants outside the measured loop
	for ti in 1 ..= TENANTS {
		_, _ = actors.tenant_runtime_try_call(&rt, u64(ti), msg, actors.Session_Op_Reply)
	}

	hugi.set_items(b, TENANTS)
	for hugi.step(b) {
		for ti in 1 ..= TENANTS {
			rep, _ := actors.tenant_runtime_try_call(&rt, u64(ti), msg, actors.Session_Op_Reply)
			_ = hugi.black_box(rep.fact_id)
		}
	}
}

@(private = "file")
_bench_parallel_diff_replay :: proc(b: ^hugi.Bencher) {
	prev_alloc := context.allocator
	prev_temp := context.temp_allocator
	if g_bench_root_allocator.procedure != nil {
		context.allocator = g_bench_root_allocator
	}
	defer {
		context.allocator = prev_alloc
		context.temp_allocator = prev_temp
	}
	workers := max(hugi.param(b), 1)
	rb_base, ok1 := compile_benchmark_source(_ACTOR_BENCH_POLICY, "diff_base.forseti")
	if !ok1 {
		return
	}
	defer {
		forseti.rulebase_destroy(rb_base)
		free(rb_base)
	}
	rb_cand, ok2 := compile_benchmark_source(_ACTOR_BENCH_CAND_POLICY, "diff_cand.forseti")
	if !ok2 {
		return
	}
	defer {
		forseti.rulebase_destroy(rb_cand)
		free(rb_cand)
	}
	context.temp_allocator = mem.nil_allocator()

	snap: forseti.Store_Bridge
	_ = forseti.store_bridge_init_standalone(&snap)
	defer forseti.store_bridge_destroy(&snap)
	_, _ = forseti.store_bridge_commit_moment(&snap, _bench_actor_seed_cb, nil)

	sched := actor.scoped_scheduler(num_workers = workers)
	cands := [4]actors.Parallel_Diff_Candidate{
		{name = "c0", rb = rb_cand},
		{name = "c1", rb = rb_cand},
		{name = "c2", rb = rb_base},
		{name = "c3", rb = rb_cand},
	}

	hugi.set_items(b, 4)
	for hugi.step(b) {
		res, err := actors.parallel_diff_replay(sched, &snap, rb_base, cands[:], {".orgs.raw"})
		_ = hugi.black_box(err)
		actors.parallel_diff_results_destroy(res)
	}
}

register_sleipnir_actor_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "sleipnir_actors")
	hugi.group_params(g, []int{1, 2, 4, 8})
	hugi.group_bench(g, "session_actor_chain_k_batch", _bench_session_actor_chain_k)
	hugi.group_bench(g, "tenant_runtime_fanout", _bench_tenant_runtime_fanout)
	hugi.group_bench(g, "parallel_diff_replay_4_cands", _bench_parallel_diff_replay)
}
