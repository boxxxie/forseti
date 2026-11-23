package forseti_actors

import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import actor "actor:."
import "../forseti"

Tenant_Runtime_Config :: struct {
	num_partitions:        int,
	idle_timeout:          time.Duration,
	max_tenants:           int,
	rb:                    ^forseti.Rulebase,
	session_cfg:           forseti.Session_Config,
	rehydrate_store:       ^forseti.Store_Bridge,
	rehydrate_paths:       []string,
	now_proc:              actor.Clock_Proc,
	clock_data:            rawptr,
	user_data:             rawptr,
	on_evict:              proc(tenant_id: u64, user_data: rawptr),
	panic_on_first_tenant: string,
}

Tenant_Rule_Runtime :: struct {
	sched:              ^actor.Scheduler,
	alloc:              mem.Allocator,
	cfg:                Tenant_Runtime_Config,
	ps:                 actor.Partitioned_Supervisor,
	reg_u64:            actor.Registry(u64),
	id_mu:              sync.Mutex,
	str_to_id:          map[string]u64,
	next_id:            u64,
	panic_tenant_id:    u64,
	panic_fired_once:   bool,
}

@(private)
_tenant_pre_fire_panic_check :: proc(state: ^Session_Actor_State) {
	rt := (^Tenant_Rule_Runtime)(state.retired_rb_ctx)
	if rt == nil {
		return
	}
	sync.mutex_lock(&rt.id_mu)
	should_panic := !rt.panic_fired_once
	if should_panic {
		rt.panic_fired_once = true
	}
	sync.mutex_unlock(&rt.id_mu)
	if should_panic {
		panic("simulated tenant session fire fault")
	}
}

@(private)
_tenant_factory :: proc(sched: ^actor.Scheduler, org_id: u64, user_data: rawptr) -> actor.Tenant_Subtree {
	rt := (^Tenant_Rule_Runtime)(user_data)
	sup := actor.spawn_supervisor(sched, actor.Supervisor_Config{
		strategy      = .One_For_One,
		max_restarts  = 5,
		within_window = 10 * time.Second,
		now_proc      = rt.cfg.now_proc,
		clock_data    = rt.cfg.clock_data,
	}, rt.alloc)

	scfg := Session_Actor_Config{
		session_cfg     = rt.cfg.session_cfg,
		rehydrate_store = rt.cfg.rehydrate_store,
		rehydrate_paths = rt.cfg.rehydrate_paths,
	}
	if rt.panic_tenant_id != 0 && rt.panic_tenant_id == org_id {
		scfg.pre_fire_hook = _tenant_pre_fire_panic_check
		scfg.retired_rb_ctx = rt
	}

	init_state := session_actor_make_init_state(rt.cfg.rb, scfg, rt.alloc)
	sa, err := actor.spawn(sched, init_state, session_actor_receive, id = u32(org_id), allocator = rt.alloc)
	assert(err == .None, "failed to spawn tenant Session_Actor")
	session_actor_attach_cleanup(sa)

	hooks := actor.Child_Hooks(Session_Actor_State){
		on_reinit    = session_actor_on_reinit,
		on_stop      = session_actor_on_stop,
		use_arena    = false,
		keep_mailbox = false,
	}
	sup_err := actor.supervise(sup, sa, sa.state, .Permanent, hooks, org_id)
	assert(sup_err == .None, "failed to supervise tenant Session_Actor")

	// Eagerly initialize session on first spawn so queries before insert see rehydrated state
	subtree := actor.Tenant_Subtree{
		sup      = sup,
		router   = &sa.base,
		msg_type = typeid_of(Session_Msg),
		user_ctx = rt,
	}
	append(&subtree.children, &sa.base)
	return subtree
}

@(private)
_tenant_on_evict :: proc(org_id: u64, subtree: ^actor.Tenant_Subtree, user_data: rawptr) {
	_ = subtree
	rt := (^Tenant_Rule_Runtime)(user_data)
	if rt != nil && rt.cfg.on_evict != nil {
		rt.cfg.on_evict(org_id, rt.cfg.user_data)
	}
}

tenant_runtime_init :: proc(
	rt: ^Tenant_Rule_Runtime,
	sched: ^actor.Scheduler,
	cfg: Tenant_Runtime_Config,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	if rt == nil || sched == nil || cfg.rb == nil {
		return .Invalid_Pointer
	}
	rt^ = {}
	rt.sched = sched
	rt.alloc = allocator
	rt.cfg = cfg
	rt.next_id = 1
	rt.str_to_id = make(map[string]u64, 16, allocator) or_return

	actor.registry_init(&rt.reg_u64, allocator)
	if len(cfg.panic_on_first_tenant) > 0 {
		rt.panic_tenant_id = tenant_runtime_id(rt, cfg.panic_on_first_tenant)
	}

	ps_cfg := actor.Partitioned_Supervisor_Config{
		num_partitions = cfg.num_partitions if cfg.num_partitions > 0 else 16,
		idle_timeout   = cfg.idle_timeout,
		max_children   = cfg.max_tenants,
		factory        = _tenant_factory,
		on_evict       = _tenant_on_evict,
		user_data      = rt,
		registry       = &rt.reg_u64,
		now_proc       = cfg.now_proc,
		clock_data     = cfg.clock_data,
	}
	actor.partitioned_supervisor_init(&rt.ps, sched, ps_cfg, allocator)
	return .None
}

tenant_runtime_destroy :: proc(rt: ^Tenant_Rule_Runtime) {
	if rt == nil {
		return
	}
	actor.partitioned_supervisor_destroy(&rt.ps)
	actor.registry_destroy(&rt.reg_u64)
	for k in rt.str_to_id {
		delete(k, rt.alloc)
	}
	delete(rt.str_to_id)
	rt^ = {}
}

tenant_runtime_id :: proc(rt: ^Tenant_Rule_Runtime, tenant_name: string) -> u64 {
	sync.mutex_lock(&rt.id_mu)
	defer sync.mutex_unlock(&rt.id_mu)
	if existing, has := rt.str_to_id[tenant_name]; has {
		return existing
	}
	id := rt.next_id
	rt.next_id += 1
	cloned, _ := strings.clone(tenant_name, rt.alloc)
	rt.str_to_id[cloned] = id
	return id
}

tenant_runtime_send :: proc(rt: ^Tenant_Rule_Runtime, tenant_id: u64, msg: Session_Msg) {
	actor.send_to_tenant(&rt.ps, tenant_id, msg)
}

tenant_runtime_send_name :: proc(rt: ^Tenant_Rule_Runtime, tenant_name: string, msg: Session_Msg) {
	tid := tenant_runtime_id(rt, tenant_name)
	actor.send_to_tenant(&rt.ps, tid, msg)
}

@(require_results)
tenant_runtime_try_call :: proc(
	rt: ^Tenant_Rule_Runtime,
	tenant_id: u64,
	msg: Session_Msg,
	$Res: typeid,
) -> (Res, actor.Call_Error) {
	return actor.try_call_tenant(&rt.ps, tenant_id, msg, Res)
}

@(require_results)
tenant_runtime_try_call_name :: proc(
	rt: ^Tenant_Rule_Runtime,
	tenant_name: string,
	msg: Session_Msg,
	$Res: typeid,
) -> (Res, actor.Call_Error) {
	tid := tenant_runtime_id(rt, tenant_name)
	return actor.try_call_tenant(&rt.ps, tid, msg, Res)
}

tenant_runtime_sweep_idle :: proc(rt: ^Tenant_Rule_Runtime, now_override: time.Tick = {}) -> int {
	return actor.sweep_idle_tenants(&rt.ps, now_override)
}

tenant_runtime_count :: proc(rt: ^Tenant_Rule_Runtime) -> int {
	return actor.tenant_count(&rt.ps)
}
