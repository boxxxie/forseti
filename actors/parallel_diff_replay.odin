package forseti_actors

import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import actor "actor:."
import "../forseti"

Parallel_Diff_Candidate :: struct {
	name: string,
	rb:   ^forseti.Rulebase,
}

Parallel_Diff_Candidate_Result :: struct {
	name:      string,
	report:    forseti.Diff_Replay_Report,
	err:       forseti.Store_Error,
	allocator: mem.Allocator,
}

@(private)
_Diff_Task_Req :: struct {
	idx:           int,
	name:          string,
	parent_bridge: ^forseti.Store_Bridge,
	baseline_rb:   ^forseti.Rulebase,
	candidate_rb:  ^forseti.Rulebase,
	watched_paths: []string,
	alloc:         mem.Allocator,
}

@(private)
_Diff_Task_Done :: struct {
	idx:    int,
	name:   string,
	report: forseti.Diff_Replay_Report,
	err:    forseti.Store_Error,
	tel:    forseti.Telemetry_Sink,
}

@(private)
_Diff_Worker_State :: struct {
	alloc: mem.Allocator,
}

@(private)
_diff_worker_receive :: proc(ctx: ^actor.Context, self: ^actor.Actor(_Diff_Worker_State, _Diff_Task_Req), msg: ^_Diff_Task_Req) {
	_ = self
	tel: forseti.Telemetry_Sink
	_ = forseti.telemetry_init(&tel, enabled = true, allocator = msg.alloc)
	rep, err := forseti.diff_replay(
		msg.parent_bridge,
		msg.baseline_rb,
		msg.candidate_rb,
		msg.watched_paths,
		&tel,
		msg.alloc,
	)
	actor.reply(ctx, _Diff_Task_Done{
		idx    = msg.idx,
		name   = msg.name,
		report = rep,
		err    = err,
		tel    = tel,
	})
}

@(private)
_Diff_Collect_Wait :: struct {
	expected: int,
}

@(private)
_Diff_Collector_Msg :: union {
	_Diff_Task_Done,
	_Diff_Collect_Wait,
}

@(private)
_Diff_Collector_State :: struct {
	alloc:       mem.Allocator,
	expected:    int,
	received:    int,
	results:     []Parallel_Diff_Candidate_Result,
	telemetry:   ^forseti.Telemetry_Sink,
	waiting:     bool,
	wait_ctx_ok: bool,
	reply_slot:  rawptr,
	reply_flags: u16,
}

@(private)
_diff_collector_receive :: proc(ctx: ^actor.Context, self: ^actor.Actor(_Diff_Collector_State, _Diff_Collector_Msg), msg: ^_Diff_Collector_Msg) {
	st := &self.state
	switch &m in msg^ {
	case _Diff_Task_Done:
		if m.idx >= 0 && m.idx < len(st.results) {
			st.results[m.idx] = Parallel_Diff_Candidate_Result{
				name      = strings.clone(m.name, st.alloc),
				report    = m.report,
				err       = m.err,
				allocator = st.alloc,
			}
		} else {
			forseti.diff_replay_report_destroy(&m.report)
		}
		if st.telemetry != nil {
			_ = forseti.telemetry_merge(st.telemetry, &m.tel)
		}
		forseti.telemetry_destroy(&m.tel)
		st.received += 1
		if st.waiting && st.received >= st.expected {
			ctx.current_reply_slot = st.reply_slot
			ctx.current_flags = st.reply_flags
			st.waiting = false
			actor.reply(ctx, true)
		}

	case _Diff_Collect_Wait:
		st.expected = m.expected
		if st.received >= st.expected {
			actor.reply(ctx, true)
		} else {
			st.waiting = true
			st.reply_slot = ctx.current_reply_slot
			st.reply_flags = ctx.current_flags
			ctx.current_reply_slot = nil
			ctx.current_flags = 0
		}
	}
}

parallel_diff_results_destroy :: proc(results: []Parallel_Diff_Candidate_Result) {
	if len(results) == 0 {
		return
	}
	alloc := results[0].allocator
	for &r in results {
		if alloc.procedure == nil && r.allocator.procedure != nil {
			alloc = r.allocator
		}
		if len(r.name) > 0 && alloc.procedure != nil {
			delete(r.name, alloc)
		}
		forseti.diff_replay_report_destroy(&r.report)
	}
	if alloc.procedure != nil {
		delete(results, alloc)
	}
}

// Fans out concurrent Core_Overlay diff_replay workers over a frozen parent Store_Bridge snapshot.
parallel_diff_replay :: proc(
	sched: ^actor.Scheduler,
	frozen_store: ^forseti.Store_Bridge,
	baseline_rb: ^forseti.Rulebase,
	candidates: []Parallel_Diff_Candidate,
	watched_paths: []string,
	telemetry_out: ^forseti.Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (results: []Parallel_Diff_Candidate_Result, err: forseti.Store_Error) {
	if sched == nil || frozen_store == nil || baseline_rb == nil {
		return nil, .Invalid_Config
	}
	if len(candidates) == 0 {
		return nil, nil
	}

	results = make([]Parallel_Diff_Candidate_Result, len(candidates), allocator)
	collector, c_err := actor.spawn(sched, _Diff_Collector_State{
		alloc     = allocator,
		expected  = len(candidates),
		results   = results,
		telemetry = telemetry_out,
	}, _diff_collector_receive, allocator = allocator)
	if c_err != nil {
		delete(results, allocator)
		return nil, c_err
	}

	collector_pid := actor.pid(collector)
	// Wrap _Diff_Task_Done into _Diff_Collector_Msg via per-worker direct send, OR spawn worker calling collector!
	// Even cleaner: spawn a worker per candidate that sends _Diff_Collector_Msg(_Diff_Task_Done) to collector!
	_ = collector_pid

	Worker_Task :: struct {
		req:       _Diff_Task_Req,
		collector: actor.PID(_Diff_Collector_Msg),
	}
	for cand, i in candidates {
		w_actor, w_err := actor.spawn(sched, _Diff_Worker_State{alloc = allocator}, proc(ctx: ^actor.Context, self: ^actor.Actor(_Diff_Worker_State, Worker_Task), msg: ^Worker_Task) {
			_ = self
			local_temp: vmem.Arena
			prev_temp := context.temp_allocator
			if vmem.arena_init_growing(&local_temp) == nil {
				context.temp_allocator = vmem.arena_allocator(&local_temp)
			}
			defer {
				context.temp_allocator = prev_temp
				vmem.arena_destroy(&local_temp)
			}
			tel: forseti.Telemetry_Sink
			_ = forseti.telemetry_init(&tel, enabled = true, allocator = msg.req.alloc)
			rep, r_err := forseti.diff_replay(
				msg.req.parent_bridge,
				msg.req.baseline_rb,
				msg.req.candidate_rb,
				msg.req.watched_paths,
				&tel,
				msg.req.alloc,
			)
			actor.send(ctx.sched, msg.collector, _Diff_Collector_Msg(_Diff_Task_Done{
				idx    = msg.req.idx,
				name   = msg.req.name,
				report = rep,
				err    = r_err,
				tel    = tel,
			}))
		}, allocator = allocator)
		if w_err != nil {
			parallel_diff_results_destroy(results)
			return nil, w_err
		}
		actor.send(sched, w_actor, Worker_Task{
			req = _Diff_Task_Req{
				idx           = i,
				name          = cand.name,
				parent_bridge = frozen_store,
				baseline_rb   = baseline_rb,
				candidate_rb  = cand.rb,
				watched_paths = watched_paths,
				alloc         = allocator,
			},
			collector = collector_pid,
		})
	}

	_ = actor.call(sched, collector, _Diff_Collector_Msg(_Diff_Collect_Wait{expected = len(candidates)}), bool)
	_ = _diff_worker_receive
	return results, nil
}
