package forseti_actors

import "base:intrinsics"
import "core:mem"
import actor "actor:."
import "../forseti"

Rulebase_Ref :: struct {
	rb:        ^forseti.Rulebase,
	ref_count: i64,
	alloc:     mem.Allocator,
	version:   u64,
}

rulebase_ref_acquire :: proc(ref: ^Rulebase_Ref) {
	if ref == nil {
		return
	}
	_ = intrinsics.atomic_add_explicit(&ref.ref_count, 1, .Acq_Rel)
}

rulebase_ref_release :: proc(ref: ^Rulebase_Ref) -> bool {
	if ref == nil {
		return false
	}
	prev := intrinsics.atomic_sub_explicit(&ref.ref_count, 1, .Acq_Rel)
	if prev == 1 {
		alloc := ref.alloc
		if ref.rb != nil {
			forseti.rulebase_destroy(ref.rb)
			free(ref.rb, alloc)
		}
		free(ref, alloc)
		return true
	}
	return false
}

@(private)
_coord_release_rb_cb :: proc(old_rb: ^forseti.Rulebase, user_data: rawptr) {
	_ = old_rb
	ref := (^Rulebase_Ref)(user_data)
	_ = rulebase_ref_release(ref)
}

Reload_Policy :: struct {
	source:   string,
	filename: string,
}

Spawn_Coordinated_Session :: struct {
	cfg: Session_Actor_Config,
}

Get_Coordinator_Stats :: struct {}

Coordinator_Msg :: union {
	Reload_Policy,
	Spawn_Coordinated_Session,
	Get_Coordinator_Stats,
}

Coordinator_Reload_Reply :: struct {
	ok:          bool,
	version:     u64,
	error_count: int,
	compile_err: forseti.Compile_Error,
}

Coordinator_Spawn_Reply :: struct {
	handle: ^Session_Actor_Handle,
	err:    mem.Allocator_Error,
}

Coordinator_Stats_Reply :: struct {
	version:       u64,
	subscribers:   int,
	retired_freed: u64,
}

Rulebase_Coordinator_State :: struct {
	alloc:             mem.Allocator,
	active_ref:        ^Rulebase_Ref,
	rehydrate_store:   ^forseti.Store_Bridge,
	rehydrate_paths:   []string,
	subscribers:       [dynamic]actor.PID(Session_Msg),
	version_seq:       u64,
	retired_freed:     u64,
	prev_destroy_proc: proc(base: ^actor.Actor_Base),
}

Rulebase_Coordinator_Handle :: actor.Actor(Rulebase_Coordinator_State, Coordinator_Msg)

@(private)
_compile_validated_rulebase :: proc(
	src: string,
	filename: string,
	alloc: mem.Allocator,
) -> (rb: ^forseti.Rulebase, err_cnt: int, cerr: forseti.Compile_Error) {
	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags, alloc) != nil {
		return nil, 1, .Alloc_Failed
	}
	defer forseti.diag_list_destroy(&diags)

	ir, comp_err := forseti.compile_source(src, filename, &diags, nil, alloc)
	defer forseti.ir_destroy(&ir)
	if comp_err != nil || diags.error_count > 0 {
		return nil, diags.error_count if diags.error_count > 0 else 1, .Vm_Compile_Failed
	}

	if v_err := forseti.verify_all_tables(&ir, &diags, nil); v_err != nil || diags.error_count > 0 {
		return nil, diags.error_count if diags.error_count > 0 else 1, .Vm_Compile_Failed
	}

	rb_ptr := new(forseti.Rulebase, alloc)
	rb_val, rb_err := forseti.rulebase_compile(&ir, nil, alloc)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb_val)
		free(rb_ptr, alloc)
		return nil, 1, rb_err
	}
	rb_ptr^ = rb_val
	return rb_ptr, 0, .None
}

@(private)
_coordinator_destroy_hook :: proc(base: ^actor.Actor_Base) {
	self := cast(^Rulebase_Coordinator_Handle)base
	st := &self.state
	prev := st.prev_destroy_proc
	if st.active_ref != nil {
		_ = rulebase_ref_release(st.active_ref)
		st.active_ref = nil
	}
	if st.subscribers != nil {
		delete(st.subscribers)
		st.subscribers = nil
	}
	if prev != nil {
		prev(base)
	}
}

rulebase_coordinator_receive :: proc(
	ctx: ^actor.Context,
	self: ^Rulebase_Coordinator_Handle,
	msg: ^Coordinator_Msg,
) {
	st := &self.state
	switch &m in msg^ {
	case Reload_Policy:
		fname := m.filename if len(m.filename) > 0 else "policy.forseti"
		new_rb, err_cnt, cerr := _compile_validated_rulebase(m.source, fname, st.alloc)
		if cerr != .None || err_cnt > 0 || new_rb == nil {
			actor.reply(ctx, Coordinator_Reload_Reply{
				ok          = false,
				version     = st.version_seq,
				error_count = err_cnt,
				compile_err = cerr,
			})
			return
		}

		st.version_seq += 1
		new_ref := new(Rulebase_Ref, st.alloc)
		new_ref^ = Rulebase_Ref{
			rb        = new_rb,
			ref_count = 1,
			alloc     = st.alloc,
			version   = st.version_seq,
		}
		old_ref := st.active_ref
		st.active_ref = new_ref

		kept := 0
		for sub in st.subscribers {
			if sub.ref == nil {
				continue
			}
			rulebase_ref_acquire(new_ref)
			_, call_err := actor.try_call(ctx.sched, sub, Session_Msg(Swap_Rulebase{
				rb               = new_ref.rb,
				rehydrate_store  = st.rehydrate_store,
				watched_paths    = st.rehydrate_paths,
				on_retired       = _coord_release_rb_cb,
				retired_ctx      = old_ref,
				next_on_retired  = _coord_release_rb_cb,
				next_retired_ctx = new_ref,
			}), Session_Op_Reply)
			if call_err == .Target_Stopped || call_err == .Stale_Generation {
				_ = rulebase_ref_release(new_ref)
				continue
			}
			st.subscribers[kept] = sub
			kept += 1
		}
		resize(&st.subscribers, kept)

		if old_ref != nil && rulebase_ref_release(old_ref) {
			st.retired_freed += 1
		}
		actor.reply(ctx, Coordinator_Reload_Reply{
			ok      = true,
			version = st.version_seq,
		})

	case Spawn_Coordinated_Session:
		if st.active_ref == nil {
			actor.reply(ctx, Coordinator_Spawn_Reply{err = .Invalid_Pointer})
			return
		}
		scfg := m.cfg
		scfg.rehydrate_store = st.rehydrate_store
		scfg.rehydrate_paths = st.rehydrate_paths
		scfg.on_retired_rb = _coord_release_rb_cb
		scfg.retired_rb_ctx = st.active_ref
		rulebase_ref_acquire(st.active_ref)

		sa, err := session_actor_spawn(ctx.sched, st.active_ref.rb, scfg, u32(len(st.subscribers) + 1), st.alloc)
		if err != nil {
			_ = rulebase_ref_release(st.active_ref)
			actor.reply(ctx, Coordinator_Spawn_Reply{err = err})
			return
		}
		append(&st.subscribers, actor.pid(sa))
		actor.reply(ctx, Coordinator_Spawn_Reply{handle = sa, err = .None})

	case Get_Coordinator_Stats:
		actor.reply(ctx, Coordinator_Stats_Reply{
			version       = st.version_seq,
			subscribers   = len(st.subscribers),
			retired_freed = st.retired_freed,
		})
	}
}

rulebase_coordinator_spawn :: proc(
	sched: ^actor.Scheduler,
	initial_source: string,
	filename: string = "policy.forseti",
	rehydrate_store: ^forseti.Store_Bridge = nil,
	rehydrate_paths: []string = nil,
	allocator := context.allocator,
) -> (h: ^Rulebase_Coordinator_Handle, err: forseti.Compile_Error) {
	rb, err_cnt, cerr := _compile_validated_rulebase(initial_source, filename, allocator)
	if cerr != .None || err_cnt > 0 || rb == nil {
		return nil, cerr if cerr != .None else .Vm_Compile_Failed
	}
	ref := new(Rulebase_Ref, allocator)
	ref^ = Rulebase_Ref{
		rb        = rb,
		ref_count = 1,
		alloc     = allocator,
		version   = 1,
	}
	subs, s_err := make([dynamic]actor.PID(Session_Msg), 0, 8, allocator)
	if s_err != nil {
		_ = rulebase_ref_release(ref)
		return nil, .Alloc_Failed
	}
	state := Rulebase_Coordinator_State{
		alloc           = allocator,
		active_ref      = ref,
		rehydrate_store = rehydrate_store,
		rehydrate_paths = rehydrate_paths,
		subscribers     = subs,
		version_seq     = 1,
	}
	ch, a_err := actor.spawn(sched, state, rulebase_coordinator_receive, allocator = allocator)
	if a_err != nil {
		delete(subs)
		_ = rulebase_ref_release(ref)
		return nil, .Alloc_Failed
	}
	ch.state.prev_destroy_proc = ch.base.destroy_proc
	ch.base.destroy_proc = _coordinator_destroy_hook
	return ch, .None
}

rulebase_coordinator_spawn_session :: proc(
	sched: ^actor.Scheduler,
	coord: ^Rulebase_Coordinator_Handle,
	cfg: Session_Actor_Config = {},
) -> (^Session_Actor_Handle, mem.Allocator_Error) {
	rep := actor.call(sched, coord, Coordinator_Msg(Spawn_Coordinated_Session{cfg = cfg}), Coordinator_Spawn_Reply)
	return rep.handle, rep.err
}
