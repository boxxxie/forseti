package forseti_actors_specs

import "core:fmt"
import "core:strings"
import "core:testing"
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

Actor_World :: struct {
	t:              ^testing.T,
	arena:          vmem.Arena,
	sched:          ^actor.Scheduler,
	sched_owned:    bool,
	policies:       map[string]Policy_Entry,
	session_actors: map[string]^actors.Session_Actor_Handle,
	commit_actors:  map[string]^actors.Commit_Actor_Handle,
	spsc_boxes:     map[string]^actors.Session_SPSC_Mailbox,
	scratch_facts:  [dynamic][]actors.Actor_Fact_Input,
	scratch_fields: [dynamic][]actors.Actor_Field_Value,
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
	w.scratch_facts = make([dynamic][]actors.Actor_Fact_Input, 0, 8)
	w.scratch_fields = make([dynamic][]actors.Actor_Field_Value, 0, 16)
}

actor_world_destroy :: proc(w: ^Actor_World) {
	if w.sched_owned && w.sched != nil {
		actor.scheduler_scope_end(w.sched)
		w.sched = nil
		w.sched_owned = false
	}
	for _, box in w.spsc_boxes {
		actors.session_spsc_destroy(box)
		free(box)
	}
	delete(w.spsc_boxes)
	delete(w.session_actors)
	delete(w.commit_actors)

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
