package forseti_actors_specs

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import vmem "core:mem/virtual"
import actor "actor:."
import xitdb "xitdb:."
import "../actors"
import "../forseti"

Policy_Entry :: struct {
	ir:    forseti.Rulebase_IR,
	diags: forseti.Diagnostic_List,
	rb:    ^forseti.Rulebase,
}

Snapshot_Org_Seed :: struct {
	org_id:    string,
	employees: i64,
}

Parallel_Cand_Spec :: struct {
	name:         string,
	policy_label: string,
}

Tenant_Runtime_Slot :: struct {
	rt:               ^actors.Tenant_Rule_Runtime,
	clock_ns:         i64,
	panic_tenant_id:  u64,
	panicked_once:    bool,
	evicted_seen:     int,
}

Effect_Disp_Slot :: struct {
	disp:             ^actors.Effect_Dispatcher,
	last_jobs:        int,
	last_applied:     int,
	last_failed:      int,
}

Actor_World :: struct {
	t:               ^testing.T,
	arena:           vmem.Arena,
	sched:           ^actor.Scheduler,
	sched_owned:     bool,
	policies:        map[string]Policy_Entry,
	session_actors:  map[string]^actors.Session_Actor_Handle,
	commit_actors:   map[string]^actors.Commit_Actor_Handle,
	spsc_boxes:      map[string]^actors.Session_SPSC_Mailbox,
	snap_stores:     map[string]^forseti.Store_Bridge,
	tenant_runtimes: map[string]^Tenant_Runtime_Slot,
	effect_disps:    map[string]^Effect_Disp_Slot,
	coordinators:    map[string]^actors.Rulebase_Coordinator_Handle,
	diff_runs:       map[string][]actors.Parallel_Diff_Candidate_Result,
	scratch_facts:   [dynamic][]actors.Actor_Fact_Input,
	scratch_fields:  [dynamic][]actors.Actor_Field_Value,
}

actor_world_init :: proc(w: ^Actor_World, t: ^testing.T, num_workers := 4, loc := #caller_location) {
	w^ = {}
	w.t = t
	err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, err, nil, loc = loc)

	w.sched = new(actor.Scheduler)
	sched_err := actor.scheduler_init_workers(w.sched, num_workers)
	testing.expect_value(t, sched_err, nil, loc = loc)
	actor.scheduler_start(w.sched)
	w.sched_owned = true

	w.policies = make(map[string]Policy_Entry, 8)
	w.session_actors = make(map[string]^actors.Session_Actor_Handle, 8)
	w.commit_actors = make(map[string]^actors.Commit_Actor_Handle, 8)
	w.spsc_boxes = make(map[string]^actors.Session_SPSC_Mailbox, 8)
	w.snap_stores = make(map[string]^forseti.Store_Bridge, 8)
	w.tenant_runtimes = make(map[string]^Tenant_Runtime_Slot, 8)
	w.effect_disps = make(map[string]^Effect_Disp_Slot, 8)
	w.coordinators = make(map[string]^actors.Rulebase_Coordinator_Handle, 8)
	w.diff_runs = make(map[string][]actors.Parallel_Diff_Candidate_Result, 8)
	w.scratch_facts = make([dynamic][]actors.Actor_Fact_Input, 0, 8)
	w.scratch_fields = make([dynamic][]actors.Actor_Field_Value, 0, 16)
}

actor_world_destroy :: proc(w: ^Actor_World) {
	if w.sched != nil {
		actor.scheduler_wait_idle(w.sched)
	}
	for _, slot in w.tenant_runtimes {
		actors.tenant_runtime_destroy(slot.rt)
		free(slot.rt)
		free(slot)
	}
	delete(w.tenant_runtimes)
	for _, eslot in w.effect_disps {
		actors.effect_dispatcher_destroy(eslot.disp)
		free(eslot.disp)
		free(eslot)
	}
	delete(w.effect_disps)
	if w.sched_owned && w.sched != nil {
		actor.scheduler_scope_end(w.sched)
		w.sched = nil
		w.sched_owned = false
	}
	for _, res in w.diff_runs {
		actors.parallel_diff_results_destroy(res)
	}
	delete(w.diff_runs)
	for _, sb in w.snap_stores {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
	delete(w.snap_stores)
	for _, box in w.spsc_boxes {
		actors.session_spsc_destroy(box)
		free(box)
	}
	delete(w.spsc_boxes)
	delete(w.session_actors)
	delete(w.commit_actors)
	delete(w.coordinators)

	for _, &p in w.policies {
		if p.rb != nil {
			forseti.rulebase_destroy(p.rb)
			free(p.rb)
		}
		forseti.ir_destroy(&p.ir)
		forseti.diag_list_destroy(&p.diags)
	}
	delete(w.policies)

	for s in w.scratch_facts {
		delete(s)
	}
	delete(w.scratch_facts)
	for f in w.scratch_fields {
		delete(f)
	}
	delete(w.scratch_fields)

	vmem.arena_check_temp(&w.arena)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

given_actor_policy :: proc(w: ^Actor_World, label: string, src: string, loc := #caller_location) {
	entry, ok, msg := driver_compile_policy(src)
	if !testing.expectf(w.t, ok, "compile failed for %q: %s", label, msg, loc = loc) {
		return
	}
	if prev, has := &w.policies[label]; has {
		if prev.rb != nil {
			forseti.rulebase_destroy(prev.rb)
			free(prev.rb)
		}
		forseti.ir_destroy(&prev.ir)
		forseti.diag_list_destroy(&prev.diags)
	}
	w.policies[label] = entry
}

given_session_actor :: proc(w: ^Actor_World, actor_label: string, policy_label: string, loc := #caller_location) {
	pol, has := &w.policies[policy_label]
	if !testing.expectf(w.t, has && pol.rb != nil, "unknown policy %q", policy_label, loc = loc) {
		return
	}
	h, err := actors.session_actor_spawn(w.sched, pol.rb)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	w.session_actors[actor_label] = h
}

given_commit_actor :: proc(w: ^Actor_World, label: string, loc := #caller_location) {
	h, err := actors.commit_actor_spawn_memory(w.sched)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	w.commit_actors[label] = h
}

given_spsc_ingest_mailbox :: proc(w: ^Actor_World, label: string, num_producers: int, loc := #caller_location) {
	box := new(actors.Session_SPSC_Mailbox)
	err := actors.session_spsc_init(box, num_producers)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		free(box)
		return
	}
	w.spsc_boxes[label] = box
}

upon_pushing_spsc_fact :: proc(
	w: ^Actor_World,
	spsc_label: string,
	producer_id: int,
	fact: actors.Actor_Fact_Input,
	loc := #caller_location,
) {
	box, has := w.spsc_boxes[spsc_label]
	if !testing.expectf(w.t, has, "unknown spsc mailbox %q", spsc_label, loc = loc) {
		return
	}
	cloned_fields := make([]actors.Actor_Field_Value, len(fact.fields))
	copy(cloned_fields, fact.fields)
	append(&w.scratch_fields, cloned_fields)
	cloned := fact
	cloned.fields = cloned_fields
	actors.session_spsc_push(box, producer_id, cloned)
}

upon_draining_spsc_on_actor :: proc(
	w: ^Actor_World,
	actor_label: string,
	spsc_label: string,
	auto_fire: bool,
	loc := #caller_location,
) {
	sa, has_a := w.session_actors[actor_label]
	box, has_b := w.spsc_boxes[spsc_label]
	if !testing.expectf(w.t, has_a && has_b, "unknown actor %q or spsc %q", actor_label, spsc_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Drain_SPSC{
		mailbox        = box,
		quota_per_lane = 64,
		auto_fire      = auto_fire,
	}), actors.Session_Batch_Reply)
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
}

upon_sending_fact :: proc(
	w: ^Actor_World,
	actor_label: string,
	binding_name: string,
	key: string,
	fields: []actors.Actor_Field_Value,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	cloned_fields := make([]actors.Actor_Field_Value, len(fields))
	copy(cloned_fields, fields)
	append(&w.scratch_fields, cloned_fields)
	actor.send(w.sched, sa, actors.Session_Msg(actors.Insert_Fact{
		fact = actors.Actor_Fact_Input{
			binding_name = binding_name,
			key          = key,
			fields       = cloned_fields,
		},
	}))
}

upon_sending_fact_batch :: proc(
	w: ^Actor_World,
	actor_label: string,
	facts: []actors.Actor_Fact_Input,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	cloned := make([]actors.Actor_Fact_Input, len(facts))
	for f, i in facts {
		cf := make([]actors.Actor_Field_Value, len(f.fields))
		copy(cf, f.fields)
		append(&w.scratch_fields, cf)
		cloned[i] = f
		cloned[i].fields = cf
	}
	append(&w.scratch_facts, cloned)

	// Emit K separate Insert_Fact messages via sleipnir Chain=K batch splicing!
	msgs := make([]actors.Session_Msg, len(cloned), context.temp_allocator)
	for f, i in cloned {
		msgs[i] = actors.Insert_Fact{fact = f}
	}
	actor.send(w.sched, sa, msgs)
}

upon_retracting_fact_on_actor :: proc(
	w: ^Actor_World,
	actor_label: string,
	binding_name: string,
	key: string,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Retract_Fact{
		binding_name = binding_name,
		key          = key,
	}), actors.Session_Op_Reply)
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
}

upon_firing_session_actor :: proc(w: ^Actor_World, actor_label: string, loc := #caller_location) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Fire_Session{}), actors.Session_Fire_Reply)
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
}

upon_subscribing_session_to_commits :: proc(
	w: ^Actor_World,
	actor_label: string,
	commit_label: string,
	loc := #caller_location,
) {
	sa, has_s := w.session_actors[actor_label]
	ca, has_c := w.commit_actors[commit_label]
	if !testing.expectf(w.t, has_s && has_c, "unknown session %q or commit actor %q", actor_label, commit_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ca, actors.Commit_Msg(actors.Subscribe_Commits{
		pid = actor.pid(sa),
	}), actors.Commit_Op_Reply)
	testing.expect_value(w.t, rep.err, nil, loc = loc)
}

upon_committing_session_derived_to_writer :: proc(
	w: ^Actor_World,
	actor_label: string,
	commit_label: string,
	loc := #caller_location,
) {
	sa, has_s := w.session_actors[actor_label]
	ca, has_c := w.commit_actors[commit_label]
	if !testing.expectf(w.t, has_s && has_c, "unknown session %q or commit actor %q", actor_label, commit_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Commit_Derived_To_Writer{
		writer = actor.pid(ca),
	}), actors.Commit_Reply)
	testing.expect_value(w.t, rep.err, nil, loc = loc)
}

upon_waiting_actor_scheduler_idle :: proc(w: ^Actor_World) {
	actor.scheduler_wait_idle(w.sched)
}

then_session_actor_query_returns_count :: proc(
	w: ^Actor_World,
	actor_label: string,
	query_name: string,
	args: []actors.Actor_Query_Arg,
	expected_count: int,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Run_Query{
		query_name = query_name,
		args       = args,
	}), actors.Session_Query_Reply)
	defer forseti.query_result_destroy(&rep.result)
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
	testing.expect_value(w.t, len(rep.result.rows), expected_count, loc = loc)
}

then_session_actor_explain_contains :: proc(
	w: ^Actor_World,
	actor_label: string,
	binding_name: string,
	fields: []actors.Actor_Field_Value,
	needles: []string,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Explain_Fact{
		binding_name = binding_name,
		fields       = fields,
	}), actors.Session_Text_Reply)
	defer if len(rep.text) > 0 {
		delete(rep.text)
	}
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
	testing.expect(w.t, rep.found, loc = loc)
	for needle in needles {
		testing.expectf(w.t, strings.contains(rep.text, needle), "explain text missing %q in:\n%s", needle, rep.text, loc = loc)
	}
}

then_commit_actor_moment_count_is :: proc(
	w: ^Actor_World,
	commit_label: string,
	expected_moments: i64,
	loc := #caller_location,
) {
	ca, has := w.commit_actors[commit_label]
	if !testing.expectf(w.t, has, "unknown commit actor %q", commit_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ca, actors.Commit_Msg(actors.Get_Moment_Count{}), actors.Commit_Count_Reply)
	testing.expect_value(w.t, rep.err, nil, loc = loc)
	testing.expect_value(w.t, rep.count, expected_moments, loc = loc)
}

then_commit_actor_has_derived_record :: proc(
	w: ^Actor_World,
	commit_label: string,
	dot_path: string,
	match_field: string,
	match_str: string,
	field_name: string,
	expected_str: string,
	loc := #caller_location,
) {
	ca, has := w.commit_actors[commit_label]
	if !testing.expectf(w.t, has, "unknown commit actor %q", commit_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ca, actors.Commit_Msg(actors.Snapshot_Lookup_Field{
		dot_path    = dot_path,
		match_field = match_field,
		match_str   = match_str,
		field_name  = field_name,
	}), actors.Snapshot_Field_Reply)
	defer if len(rep.str_val) > 0 {
		delete(rep.str_val)
	}
	testing.expect_value(w.t, rep.err, nil, loc = loc)
	testing.expect(w.t, rep.found, loc = loc)
	testing.expect_value(w.t, rep.str_val, expected_str, loc = loc)
}

then_session_actor_received_commit_notifications :: proc(
	w: ^Actor_World,
	actor_label: string,
	expected_count: int,
	last_moment: i64,
	loc := #caller_location,
) {
	sa, has := w.session_actors[actor_label]
	if !testing.expectf(w.t, has, "unknown session actor %q", actor_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, sa, actors.Session_Msg(actors.Get_Session_Stats{}), actors.Session_Stats_Reply)
	testing.expect_value(w.t, rep.commit_notifications, expected_count, loc = loc)
	testing.expect_value(w.t, rep.last_commit_moment, last_moment, loc = loc)
	_ = fmt.tprintf
	_ = xitdb.Xitdb_Error.None
}

@(private = "file")
_tenant_clock_proc :: proc(user_data: rawptr) -> time.Tick {
	slot := (^Tenant_Runtime_Slot)(user_data)
	return time.Tick{_nsec = intrinsics.atomic_load_explicit(&slot.clock_ns, .Acquire)}
}

@(private = "file")
_tenant_panic_hook :: proc(state: ^actors.Session_Actor_State) {
	if state.rb == nil {
		return
	}
	slot := (^Tenant_Runtime_Slot)(state.retired_rb_ctx)
	if slot == nil {
		return
	}
	if slot.panic_tenant_id != 0 && u64(state.sess.rb != nil ? 1 : 0) == 1 {
		// Trigger panic once for the designated tenant via actor_seq/id stored on actor
		if !slot.panicked_once && state.cfg.max_activations == 777 {
			slot.panicked_once = true
			panic("simulated tenant policy panic")
		}
	}
}

given_frozen_snapshot_store :: proc(
	w: ^Actor_World,
	label: string,
	orgs: []Snapshot_Org_Seed,
	loc := #caller_location,
) {
	sb, ok, msg := driver_create_frozen_org_store(orgs)
	if !testing.expectf(w.t, ok, "frozen snapshot store %q failed: %s", label, msg, loc = loc) {
		return
	}
	if prev, has := w.snap_stores[label]; has {
		forseti.store_bridge_destroy(prev)
		free(prev)
	}
	w.snap_stores[label] = sb
}

given_tenant_rule_runtime :: proc(
	w: ^Actor_World,
	label: string,
	policy_label: string,
	snap_label: string,
	watched_paths: []string,
	idle_timeout: time.Duration,
	panic_first_fire_for_tenant: string = "",
	loc := #caller_location,
) {
	pol, has_p := &w.policies[policy_label]
	snap, has_s := w.snap_stores[snap_label]
	if !testing.expectf(w.t, has_p && pol.rb != nil && has_s, "missing policy %q or snap %q", policy_label, snap_label, loc = loc) {
		return
	}

	slot := new(Tenant_Runtime_Slot)
	slot.clock_ns = i64(time.Second)

	rt := new(actors.Tenant_Rule_Runtime)
	cfg := actors.Tenant_Runtime_Config{
		num_partitions  = 8,
		idle_timeout    = idle_timeout,
		rb              = pol.rb,
		rehydrate_store = snap,
		rehydrate_paths = watched_paths,
		now_proc        = _tenant_clock_proc,
		clock_data      = slot,
		user_data       = slot,
	}
	if len(panic_first_fire_for_tenant) > 0 {
		cfg.panic_on_first_tenant = panic_first_fire_for_tenant
	}
	err := actors.tenant_runtime_init(rt, w.sched, cfg)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		free(rt)
		free(slot)
		return
	}
	slot.rt = rt
	w.tenant_runtimes[label] = slot
	_ = sync.Mutex{}
	_ = _tenant_panic_hook
}

upon_tenant_inserting_and_firing :: proc(
	w: ^Actor_World,
	rt_label: string,
	tenant_name: string,
	binding_name: string,
	key: string,
	fields: []actors.Actor_Field_Value,
	expect_crash: bool,
	loc := #caller_location,
) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	cloned := make([]actors.Actor_Field_Value, len(fields))
	copy(cloned, fields)
	append(&w.scratch_fields, cloned)

	rep, err := actors.tenant_runtime_try_call_name(
		slot.rt,
		tenant_name,
		actors.Session_Msg(actors.Insert_Fact{
			fact = actors.Actor_Fact_Input{
				binding_name = binding_name,
				key          = key,
				fields       = cloned,
			},
			auto_fire = true,
		}),
		actors.Session_Op_Reply,
	)
	if expect_crash {
		testing.expect_value(w.t, err, actor.Call_Error.Call_Target_Crashed, loc = loc)
	} else {
		testing.expect_value(w.t, err, actor.Call_Error.None, loc = loc)
		testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
	}
}

upon_waiting_for_tenant_recovery :: proc(
	w: ^Actor_World,
	rt_label: string,
	tenant_name: string,
	min_gen: u32,
	loc := #caller_location,
) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	recovered := false
	for _ in 0 ..< 500 {
		actor.scheduler_wait_idle(w.sched)
		st, err := actors.tenant_runtime_try_call_name(
			slot.rt,
			tenant_name,
			actors.Session_Msg(actors.Get_Session_Stats{}),
			actors.Session_Stats_Reply,
		)
		if err == .None && st.generation >= min_gen {
			recovered = true
			break
		}
		time.sleep(200 * time.Microsecond)
	}
	testing.expectf(w.t, recovered, "tenant %q did not recover to generation >= %d", tenant_name, min_gen, loc = loc)
}

then_tenant_generation_is :: proc(
	w: ^Actor_World,
	rt_label: string,
	tenant_name: string,
	expected_gen: u32,
	loc := #caller_location,
) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	st, err := actors.tenant_runtime_try_call_name(
		slot.rt,
		tenant_name,
		actors.Session_Msg(actors.Get_Session_Stats{}),
		actors.Session_Stats_Reply,
	)
	testing.expect_value(w.t, err, actor.Call_Error.None, loc = loc)
	testing.expect_value(w.t, st.generation, expected_gen, loc = loc)
}

then_tenant_query_returns_count :: proc(
	w: ^Actor_World,
	rt_label: string,
	tenant_name: string,
	query_name: string,
	expected_count: int,
	loc := #caller_location,
) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	rep, err := actors.tenant_runtime_try_call_name(
		slot.rt,
		tenant_name,
		actors.Session_Msg(actors.Run_Query{query_name = query_name}),
		actors.Session_Query_Reply,
	)
	defer forseti.query_result_destroy(&rep.result)
	testing.expect_value(w.t, err, actor.Call_Error.None, loc = loc)
	testing.expect_value(w.t, rep.err, forseti.Session_Error.None, loc = loc)
	testing.expect_value(w.t, len(rep.result.rows), expected_count, loc = loc)
}

upon_advancing_tenant_clock :: proc(w: ^Actor_World, rt_label: string, delta: time.Duration, loc := #caller_location) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	intrinsics.atomic_add_explicit(&slot.clock_ns, i64(delta), .Acq_Rel)
}

upon_sweeping_idle_tenants :: proc(w: ^Actor_World, rt_label: string, expected_evicted: int, loc := #caller_location) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	evicted := actors.tenant_runtime_sweep_idle(slot.rt)
	testing.expect_value(w.t, evicted, expected_evicted, loc = loc)
}

then_tenant_runtime_active_count_is :: proc(w: ^Actor_World, rt_label: string, expected: int, loc := #caller_location) {
	slot, has := w.tenant_runtimes[rt_label]
	if !testing.expectf(w.t, has, "unknown tenant runtime %q", rt_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, actors.tenant_runtime_count(slot.rt), expected, loc = loc)
}

@(private = "file")
_test_enrich_effect_handler :: proc(
	job: ^forseti.Effect_Job,
	user_data: rawptr,
	alloc: mem.Allocator,
) -> (facts: []actors.Actor_Fact_Input, ok: bool, err_msg: string) {
	crash_bad := (^bool)(user_data)^
	org_id := ""
	for f in job.fields {
		if f.name == "org_id" {
			org_id = f.str
			break
		}
	}
	if crash_bad && org_id == "org:bad" {
		panic("simulated effect worker crash")
	}
	out := make([]actors.Actor_Fact_Input, 1, alloc)
	fields := make([]actors.Actor_Field_Value, 2, alloc)
	fields[0] = strings.clone(org_id, alloc)
	fields[1] = strings.clone("DE" if org_id == "org:1" else "US", alloc)
	out[0] = actors.Actor_Fact_Input{
		binding_name = "Enriched",
		key          = fmt.aprintf("enr:%s", org_id, allocator = alloc),
		fields       = fields,
	}
	return out, true, ""
}

@(private = "file")
_crash_bad_org_flag: bool = true

given_effect_dispatcher :: proc(
	w: ^Actor_World,
	label: string,
	crash_on_bad_org: bool,
	loc := #caller_location,
) {
	_crash_bad_org_flag = crash_on_bad_org
	disp := new(actors.Effect_Dispatcher)
	err := actors.effect_dispatcher_init(disp, w.sched)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		free(disp)
		return
	}
	r_err := actors.effect_dispatcher_register(disp, "enrich", _test_enrich_effect_handler, &_crash_bad_org_flag)
	if !testing.expect_value(w.t, r_err, nil, loc = loc) {
		actors.effect_dispatcher_destroy(disp)
		free(disp)
		return
	}
	slot := new(Effect_Disp_Slot)
	slot.disp = disp
	w.effect_disps[label] = slot
}

upon_dispatching_and_applying_effects :: proc(
	w: ^Actor_World,
	disp_label: string,
	actor_label: string,
	expected_jobs: int,
	expected_applied: int,
	expected_failed: int,
	loc := #caller_location,
) {
	slot, has_d := w.effect_disps[disp_label]
	sa, has_s := w.session_actors[actor_label]
	if !testing.expectf(w.t, has_d && has_s, "unknown dispatcher %q or actor %q", disp_label, actor_label, loc = loc) {
		return
	}
	summary := actors.effect_dispatcher_run_session(slot.disp, actor.pid(sa))
	testing.expect_value(w.t, summary.total_jobs, expected_jobs, loc = loc)
	testing.expect_value(w.t, summary.applied_count, expected_applied, loc = loc)
	testing.expect_value(w.t, summary.failed_count, expected_failed, loc = loc)
}

upon_running_parallel_diff_replay :: proc(
	w: ^Actor_World,
	run_label: string,
	snap_label: string,
	baseline_label: string,
	cands: []Parallel_Cand_Spec,
	watched_paths: []string,
	loc := #caller_location,
) {
	snap, has_s := w.snap_stores[snap_label]
	base_pol, has_b := &w.policies[baseline_label]
	if !testing.expectf(w.t, has_s && has_b && base_pol.rb != nil, "missing snap %q or baseline %q", snap_label, baseline_label, loc = loc) {
		return
	}
	cand_defs := make([]actors.Parallel_Diff_Candidate, len(cands), context.temp_allocator)
	for c, i in cands {
		cp, has_c := &w.policies[c.policy_label]
		if !testing.expectf(w.t, has_c && cp.rb != nil, "missing candidate %q", c.policy_label, loc = loc) {
			return
		}
		cand_defs[i] = actors.Parallel_Diff_Candidate{
			name = c.name,
			rb   = cp.rb,
		}
	}

	results, err := actors.parallel_diff_replay(w.sched, snap, base_pol.rb, cand_defs, watched_paths)
	testing.expect_value(w.t, err, nil, loc = loc)
	if prev, has := w.diff_runs[run_label]; has {
		actors.parallel_diff_results_destroy(prev)
	}
	w.diff_runs[run_label] = results
}

then_parallel_diff_candidate_matches :: proc(
	w: ^Actor_World,
	run_label: string,
	cand_name: string,
	expected_added: int,
	expected_removed: int,
	expected_unchanged: int,
	expected_moments: i64,
	loc := #caller_location,
) {
	results, has := w.diff_runs[run_label]
	if !testing.expectf(w.t, has, "unknown diff run %q", run_label, loc = loc) {
		return
	}
	for &r in results {
		if r.name == cand_name {
			testing.expect_value(w.t, r.err, nil, loc = loc)
			testing.expect_value(w.t, len(r.report.added), expected_added, loc = loc)
			testing.expect_value(w.t, len(r.report.removed), expected_removed, loc = loc)
			testing.expect_value(w.t, r.report.unchanged_count, expected_unchanged, loc = loc)
			testing.expect_value(w.t, r.report.parent_moments_before, expected_moments, loc = loc)
			testing.expect_value(w.t, r.report.parent_moments_after, expected_moments, loc = loc)
			return
		}
	}
	testing.expectf(w.t, false, "candidate %q not found in diff run %q", cand_name, run_label, loc = loc)
}

given_rulebase_coordinator :: proc(
	w: ^Actor_World,
	coord_label: string,
	initial_source: string,
	rehyd_snap_label: string,
	watched_paths: []string,
	loc := #caller_location,
) {
	snap, has_s := w.snap_stores[rehyd_snap_label]
	if !testing.expectf(w.t, has_s, "unknown snapshot store %q", rehyd_snap_label, loc = loc) {
		return
	}
	ch, err := actors.rulebase_coordinator_spawn(w.sched, initial_source, "v1.forseti", snap, watched_paths)
	if !testing.expect_value(w.t, err, forseti.Compile_Error.None, loc = loc) {
		return
	}
	w.coordinators[coord_label] = ch
}

given_coordinated_session_actor :: proc(
	w: ^Actor_World,
	coord_label: string,
	actor_label: string,
	loc := #caller_location,
) {
	ch, has := w.coordinators[coord_label]
	if !testing.expectf(w.t, has, "unknown coordinator %q", coord_label, loc = loc) {
		return
	}
	sa, err := actors.rulebase_coordinator_spawn_session(w.sched, ch)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	w.session_actors[actor_label] = sa
}

upon_reloading_coordinator_policy :: proc(
	w: ^Actor_World,
	coord_label: string,
	new_source: string,
	expect_ok: bool,
	loc := #caller_location,
) {
	ch, has := w.coordinators[coord_label]
	if !testing.expectf(w.t, has, "unknown coordinator %q", coord_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ch, actors.Coordinator_Msg(actors.Reload_Policy{
		source   = new_source,
		filename = "reload.forseti",
	}), actors.Coordinator_Reload_Reply)
	testing.expect_value(w.t, rep.ok, expect_ok, loc = loc)
}

then_coordinator_version_is :: proc(
	w: ^Actor_World,
	coord_label: string,
	expected_version: u64,
	loc := #caller_location,
) {
	ch, has := w.coordinators[coord_label]
	if !testing.expectf(w.t, has, "unknown coordinator %q", coord_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ch, actors.Coordinator_Msg(actors.Get_Coordinator_Stats{}), actors.Coordinator_Stats_Reply)
	testing.expect_value(w.t, rep.version, expected_version, loc = loc)
}

then_coordinator_retired_count_is :: proc(
	w: ^Actor_World,
	coord_label: string,
	expected_retired: u64,
	loc := #caller_location,
) {
	ch, has := w.coordinators[coord_label]
	if !testing.expectf(w.t, has, "unknown coordinator %q", coord_label, loc = loc) {
		return
	}
	rep := actor.call(w.sched, ch, actors.Coordinator_Msg(actors.Get_Coordinator_Stats{}), actors.Coordinator_Stats_Reply)
	testing.expect_value(w.t, rep.retired_freed, expected_retired, loc = loc)
}
