package forseti_actors

import "base:intrinsics"
import "core:mem"
import "core:strings"
import "core:time"
import actor "actor:."
import "../forseti"

Effect_Handler_Proc :: #type proc(
	job: ^forseti.Effect_Job,
	user_data: rawptr,
	alloc: mem.Allocator,
) -> (facts: []Actor_Fact_Input, ok: bool, err_msg: string)

Effect_Work_Msg :: struct {
	job: ^forseti.Effect_Job,
}

Effect_Work_Reply :: struct {
	job_id:  u64,
	facts:   []Actor_Fact_Input,
	ok:      bool,
	err_msg: string,
}

Effect_Worker_State :: struct {
	alloc:     mem.Allocator,
	handler:   Effect_Handler_Proc,
	user_data: rawptr,
}

Effect_Worker_Actor :: actor.Actor(Effect_Worker_State, Effect_Work_Msg)

Effect_Dispatcher :: struct {
	sched:   ^actor.Scheduler,
	alloc:   mem.Allocator,
	sup:     ^actor.Supervisor,
	workers: map[string]^Effect_Worker_Actor,
}

Effect_Dispatch_Summary :: struct {
	total_jobs:    int,
	applied_count: int,
	failed_count:  int,
	fired:         u64,
	err:           forseti.Session_Error,
}

@(private)
_effect_worker_receive :: proc(ctx: ^actor.Context, self: ^Effect_Worker_Actor, msg: ^Effect_Work_Msg) {
	s := &self.state
	if s.handler == nil || msg.job == nil {
		actor.reply(ctx, Effect_Work_Reply{job_id = msg.job.job_id if msg.job != nil else 0, ok = false, err_msg = "missing handler"})
		return
	}
	facts, ok, err_msg := s.handler(msg.job, s.user_data, s.alloc)
	actor.reply(ctx, Effect_Work_Reply{
		job_id  = msg.job.job_id,
		facts   = facts,
		ok      = ok,
		err_msg = err_msg,
	})
}

effect_dispatcher_init :: proc(
	d: ^Effect_Dispatcher,
	sched: ^actor.Scheduler,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	if d == nil || sched == nil {
		return .Invalid_Pointer
	}
	d^ = {}
	d.sched = sched
	d.alloc = allocator
	d.workers = make(map[string]^Effect_Worker_Actor, 8, allocator) or_return
	d.sup = actor.spawn_supervisor(sched, actor.Supervisor_Config{
		strategy      = .One_For_One,
		max_restarts  = 16,
		within_window = 10 * time.Second,
	}, allocator)
	return .None
}

effect_dispatcher_destroy :: proc(d: ^Effect_Dispatcher) {
	if d == nil {
		return
	}
	if d.sup != nil {
		actor.stop_supervisor(d.sup)
		d.sup = nil
	}
	for k in d.workers {
		delete(k, d.alloc)
	}
	delete(d.workers)
	d^ = {}
}

effect_dispatcher_register :: proc(
	d: ^Effect_Dispatcher,
	kind: string,
	handler: Effect_Handler_Proc,
	user_data: rawptr = nil,
) -> mem.Allocator_Error {
	if d == nil || handler == nil || len(kind) == 0 {
		return .Invalid_Pointer
	}
	if kind in d.workers {
		d.workers[kind].state.handler = handler
		d.workers[kind].state.user_data = user_data
		return .None
	}
	init_state := Effect_Worker_State{
		alloc     = d.alloc,
		handler   = handler,
		user_data = user_data,
	}
	w, err := actor.spawn(d.sched, init_state, _effect_worker_receive, id = u32(len(d.workers) + 1), allocator = d.alloc)
	if err != nil {
		return err
	}
	hooks := actor.Child_Hooks(Effect_Worker_State){
		use_arena    = false,
		keep_mailbox = false,
	}
	_ = actor.supervise(d.sup, w, init_state, .Permanent, hooks, u64(len(d.workers) + 1))
	cloned_kind := strings.clone(kind, d.alloc) or_return
	d.workers[cloned_kind] = w
	return .None
}

@(private)
_destroy_actor_effect_facts :: proc(facts: []Actor_Fact_Input, alloc: mem.Allocator) {
	for f in facts {
		if len(f.key) > 0 {
			delete(f.key, alloc)
		}
		for fv in f.fields {
			if s, ok := fv.(string); ok && len(s) > 0 {
				delete(s, alloc)
			}
		}
		if f.fields != nil {
			delete(f.fields, alloc)
		}
	}
	if facts != nil {
		delete(facts, alloc)
	}
}

effect_dispatcher_run_session :: proc(
	d: ^Effect_Dispatcher,
	sess_pid: actor.PID(Session_Msg),
) -> Effect_Dispatch_Summary {
	if d == nil || d.sched == nil || sess_pid.ref == nil {
		return {err = .Invalid_Arg}
	}
	prep := actor.call(d.sched, sess_pid, Session_Msg(Prepare_Effects{}), Session_Prepared_Effects_Reply)
	if prep.err != .None {
		return {err = prep.err}
	}
	defer forseti.effects_jobs_destroy(prep.jobs)

	summary := Effect_Dispatch_Summary{
		total_jobs = len(prep.jobs),
	}
	if len(prep.jobs) == 0 {
		return summary
	}

	results := make([dynamic]Actor_Effect_Result, 0, len(prep.jobs), d.alloc)
	defer {
		for r in results {
			_destroy_actor_effect_facts(r.facts, d.alloc)
		}
		delete(results)
	}

	for &job in prep.jobs {
		w, has_w := d.workers[job.kind]
		if !has_w {
			summary.failed_count += 1
			continue
		}
		rep, call_err := actor.try_call(d.sched, w, Effect_Work_Msg{job = &job}, Effect_Work_Reply)
		if call_err != .None || !rep.ok {
			if rep.facts != nil {
				_destroy_actor_effect_facts(rep.facts, d.alloc)
			}
			summary.failed_count += 1
			if call_err == .Call_Target_Crashed {
				for _ in 0 ..< 500 {
					actor.scheduler_wait_idle(d.sched)
					if intrinsics.atomic_load_explicit(&w.base.status, .Acquire) == u32(actor.Actor_Status.Running) {
						break
					}
					time.sleep(200 * time.Microsecond)
				}
			}
			continue
		}
		append(&results, Actor_Effect_Result{
			job_id = rep.job_id,
			facts  = rep.facts,
		})
	}

	if len(results) > 0 {
		app := actor.call(d.sched, sess_pid, Session_Msg(Apply_Actor_Effects{
			results   = results[:],
			auto_fire = true,
		}), Session_Apply_Reply)
		summary.applied_count = len(app.applied)
		summary.fired = app.fired
		summary.err = app.err
		if app.applied != nil {
			del_alloc := app.alloc if app.alloc.procedure != nil else d.alloc
			delete(app.applied, del_alloc)
		}
	}
	return summary
}
