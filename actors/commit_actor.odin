package forseti_actors

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import actor "actor:."
import xitdb "xitdb:."
import "../forseti"

Commit_Field :: struct {
	name:  string,
	value: Actor_Field_Value,
}

Commit_Derived_Record :: struct {
	dot_path: string,
	key:      string,
	fields:   []Commit_Field,
}

Commit_Decision_Entry :: struct {
	dec_id:          string,
	rule_name:       string,
	rule_version:    string,
	table_name:      string,
	table_row:       string,
	derived_binding: string,
	derived_key:     string,
	proof_height:    u32,
	weight:          i32,
	tx_seq:          u64,
	alive:           bool,
	parents:         []string,
}

Commit_Derived_Batch :: struct {
	module_name:   string,
	tx_seq:        u64,
	records:       []Commit_Derived_Record,
	decisions:     []Commit_Decision_Entry,
	notify_pid:    actor.PID(Session_Msg),
	owns_payload:  bool,
	payload_alloc: mem.Allocator,
}

Commit_Raw_Batch :: struct {
	dot_path:      string,
	records:       []Commit_Derived_Record,
	owns_payload:  bool,
	payload_alloc: mem.Allocator,
}

Subscribe_Commits :: struct {
	pid: actor.PID(Session_Msg),
}

Get_Moment_Count :: struct {}

Snapshot_Lookup_Field :: struct {
	dot_path:    string,
	key:         string,
	match_field: string,
	match_str:   string,
	field_name:  string,
}

Commit_Msg :: union {
	Commit_Derived_Batch,
	Commit_Raw_Batch,
	Subscribe_Commits,
	Get_Moment_Count,
	Snapshot_Lookup_Field,
}

Commit_Reply :: struct {
	moment_idx:    i64,
	derived_count: int,
	err:           forseti.Store_Error,
}

Commit_Op_Reply :: struct {
	err: forseti.Store_Error,
}

Commit_Count_Reply :: struct {
	count: i64,
	err:   forseti.Store_Error,
}

Snapshot_Field_Reply :: struct {
	found:   bool,
	str_val: string,
	int_val: i64,
	err:     forseti.Store_Error,
}

Commit_Actor_State :: struct {
	alloc:             mem.Allocator,
	bridge:            ^forseti.Store_Bridge,
	tel:               forseti.Telemetry_Sink,
	tel_inited:        bool,
	temp_arena:        vmem.Arena,
	temp_inited:       bool,
	next_dec_seq:      u64,
	subscribers:       [dynamic]actor.PID(Session_Msg),
	prev_destroy_proc: proc(base: ^actor.Actor_Base),
}

Commit_Actor_Handle :: actor.Actor(Commit_Actor_State, Commit_Msg)

commit_batch_destroy :: proc(b: ^Commit_Derived_Batch) {
	if b == nil || !b.owns_payload || b.payload_alloc.procedure == nil {
		return
	}
	a := b.payload_alloc
	delete(b.module_name, a)
	for rec in b.records {
		delete(rec.dot_path, a)
		delete(rec.key, a)
		for f in rec.fields {
			delete(f.name, a)
			if s, ok := f.value.(string); ok {
				delete(s, a)
			}
		}
		delete(rec.fields, a)
	}
	delete(b.records, a)
	for d in b.decisions {
		delete(d.dec_id, a)
		delete(d.rule_name, a)
		delete(d.rule_version, a)
		delete(d.table_name, a)
		delete(d.table_row, a)
		delete(d.derived_binding, a)
		delete(d.derived_key, a)
		for p in d.parents {
			delete(p, a)
		}
		delete(d.parents, a)
	}
	delete(b.decisions, a)
	b^ = {}
}

commit_raw_batch_destroy :: proc(b: ^Commit_Raw_Batch) {
	if b == nil || !b.owns_payload || b.payload_alloc.procedure == nil {
		return
	}
	a := b.payload_alloc
	delete(b.dot_path, a)
	for rec in b.records {
		delete(rec.dot_path, a)
		delete(rec.key, a)
		for f in rec.fields {
			delete(f.name, a)
			if s, ok := f.value.(string); ok {
				delete(s, a)
			}
		}
		delete(rec.fields, a)
	}
	delete(b.records, a)
	b^ = {}
}

commit_actor_cleanup_state :: proc(state: ^Commit_Actor_State) {
	if state == nil {
		return
	}
	alloc := state.alloc
	if state.subscribers != nil {
		delete(state.subscribers)
		state.subscribers = nil
	}
	if state.bridge != nil {
		forseti.store_bridge_destroy(state.bridge)
		free(state.bridge, alloc)
		state.bridge = nil
	}
	if state.tel_inited {
		forseti.telemetry_destroy(&state.tel)
		state.tel_inited = false
	}
	if state.temp_inited {
		vmem.arena_destroy(&state.temp_arena)
		state.temp_inited = false
	}
}

@(private)
_commit_actor_destroy_hook :: proc(base: ^actor.Actor_Base) {
	self := cast(^Commit_Actor_Handle)base
	prev := self.state.prev_destroy_proc
	commit_actor_cleanup_state(&self.state)
	if prev != nil {
		prev(base)
	}
}

@(private)
_write_actor_field :: proc(rec_m: ^xitdb.Write_Hash_Map, name: string, fv: Actor_Field_Value) -> xitdb.Error {
	switch x in fv {
	case bool:
		if forseti.write_bool_to_hash_map(rec_m, name, x) != nil {
			return .Write_Failed
		}
		return nil
	case i32:
		return xitdb.hash_map_put(rec_m, name, i64(x))
	case i64:
		return xitdb.hash_map_put(rec_m, name, x)
	case f64:
		return xitdb.hash_map_put(rec_m, name, x)
	case string:
		return xitdb.hash_map_put(rec_m, name, x)
	}
	return nil
}

@(private)
_Commit_Tx_Payload :: struct {
	batch:        ^Commit_Derived_Batch,
	next_dec_seq: ^u64,
}

@(private)
_commit_derived_batch_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	payload := (^_Commit_Tx_Payload)(user_data)
	batch := payload.batch
	for rec in batch.records {
		col_m, c_err := forseti.store_write_path_ensure_map(moment_wc, rec.dot_path)
		if c_err != nil {
			return .Write_Failed
		}
		rec_wc := xitdb.hash_map_put_cursor(&col_m, rec.key) or_return
		rec_m := xitdb.write_hash_map_init(rec_wc) or_return
		for f in rec.fields {
			_write_actor_field(&rec_m, f.name, f.value) or_return
		}
	}

	root_m := xitdb.write_hash_map_init(moment_wc^) or_return
	dec_root_wc := xitdb.hash_map_put_cursor(&root_m, "decisions") or_return
	dec_root_m := xitdb.write_hash_map_init(dec_root_wc) or_return
	idx_wc := xitdb.hash_map_put_cursor(&root_m, "idx") or_return
	idx_m := xitdb.write_hash_map_init(idx_wc) or_return
	by_ent_wc := xitdb.hash_map_put_cursor(&idx_m, "decisions_by_entity") or_return
	by_ent_m := xitdb.write_hash_map_init(by_ent_wc) or_return
	by_rule_wc := xitdb.hash_map_put_cursor(&idx_m, "decisions_by_rule") or_return
	by_rule_m := xitdb.write_hash_map_init(by_rule_wc) or_return

	_, _ = xitdb.hash_map_remove(&root_m, "__tx")
	tx_wc := xitdb.hash_map_put_cursor(&root_m, "__tx") or_return
	tx_m := xitdb.write_hash_map_init(tx_wc) or_return
	xitdb.hash_map_put(&tx_m, "tx_seq", i64(batch.tx_seq)) or_return
	xitdb.hash_map_put(&tx_m, "module", batch.module_name) or_return
	tx_ids_wc := xitdb.hash_map_put_cursor(&tx_m, "decision_ids") or_return
	tx_ids_arr := xitdb.write_array_list_init(tx_ids_wc) or_return
	rver_wc := xitdb.hash_map_put_cursor(&tx_m, "rule_versions") or_return
	rver_m := xitdb.write_hash_map_init(rver_wc) or_return

	id_buf: [32]u8 = ---
	for d in batch.decisions {
		payload.next_dec_seq^ += 1
		dec_id := fmt.bprintf(id_buf[:], "dec:%d", payload.next_dec_seq^)

		drec_wc := xitdb.hash_map_put_cursor(&dec_root_m, dec_id) or_return
		drec_m := xitdb.write_hash_map_init(drec_wc) or_return
		xitdb.hash_map_put(&drec_m, "rule", d.rule_name) or_return
		xitdb.hash_map_put(&drec_m, "rule_version", d.rule_version) or_return
		xitdb.hash_map_put(&drec_m, "proof_height", i64(d.proof_height)) or_return
		xitdb.hash_map_put(&drec_m, "weight", i64(d.weight)) or_return
		xitdb.hash_map_put(&drec_m, "tx_seq", i64(d.tx_seq)) or_return
		if forseti.write_bool_to_hash_map(&drec_m, "alive", d.alive) != nil {
			return .Write_Failed
		}
		if len(d.derived_binding) > 0 {
			xitdb.hash_map_put(&drec_m, "derived_binding", d.derived_binding) or_return
		}
		if len(d.derived_key) > 0 {
			xitdb.hash_map_put(&drec_m, "derived_key", d.derived_key) or_return
			ent_wc := xitdb.hash_map_put_cursor(&by_ent_m, d.derived_key) or_return
			ent_set := xitdb.write_hash_set_init(ent_wc) or_return
			xitdb.hash_set_put(&ent_set, dec_id) or_return
		}
		if len(d.table_name) > 0 {
			xitdb.hash_map_put(&drec_m, "table", d.table_name) or_return
		}
		if len(d.table_row) > 0 {
			xitdb.hash_map_put(&drec_m, "table_row", d.table_row) or_return
		}
		par_wc := xitdb.hash_map_put_cursor(&drec_m, "parents") or_return
		par_arr := xitdb.write_array_list_init(par_wc) or_return
		for p in d.parents {
			if len(p) > 0 {
				xitdb.array_list_append(&par_arr, p) or_return
				pent_wc := xitdb.hash_map_put_cursor(&by_ent_m, p) or_return
				pent_set := xitdb.write_hash_set_init(pent_wc) or_return
				xitdb.hash_set_put(&pent_set, dec_id) or_return
			}
		}

		rset_wc := xitdb.hash_map_put_cursor(&by_rule_m, d.rule_name) or_return
		rset := xitdb.write_hash_set_init(rset_wc) or_return
		xitdb.hash_set_put(&rset, dec_id) or_return
		xitdb.array_list_append(&tx_ids_arr, dec_id) or_return
		xitdb.hash_map_put(&rver_m, d.rule_name, d.rule_version) or_return
	}
	return nil
}

@(private)
_commit_raw_batch_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	batch := (^Commit_Raw_Batch)(user_data)
	for rec in batch.records {
		col_path := rec.dot_path if len(rec.dot_path) > 0 else batch.dot_path
		col_m, c_err := forseti.store_write_path_ensure_map(moment_wc, col_path)
		if c_err != nil {
			return .Write_Failed
		}
		rec_wc := xitdb.hash_map_put_cursor(&col_m, rec.key) or_return
		rec_m := xitdb.write_hash_map_init(rec_wc) or_return
		for f in rec.fields {
			_write_actor_field(&rec_m, f.name, f.value) or_return
		}
	}
	return nil
}

@(private)
_broadcast_commit_notification :: proc(
	ctx: ^actor.Context,
	state: ^Commit_Actor_State,
	extra_pid: actor.PID(Session_Msg),
	note: Commit_Notification,
) {
	extra_sent := false
	for sub in state.subscribers {
		if sub.ref == nil {
			continue
		}
		actor.send(ctx.sched, sub, Session_Msg(note))
		if extra_pid.ref == sub.ref {
			extra_sent = true
		}
	}
	if !extra_sent && extra_pid.ref != nil {
		actor.send(ctx.sched, extra_pid, Session_Msg(note))
	}
}

commit_actor_receive :: proc(ctx: ^actor.Context, self: ^Commit_Actor_Handle, msg: ^Commit_Msg) {
	state := &self.state
	if !state.temp_inited {
		if vmem.arena_init_growing(&state.temp_arena) == nil {
			state.temp_inited = true
		}
	}
	prev_temp := context.temp_allocator
	if state.temp_inited {
		context.temp_allocator = vmem.arena_allocator(&state.temp_arena)
	}
	defer {
		if state.temp_inited {
			vmem.arena_free_all(&state.temp_arena)
		}
		context.temp_allocator = prev_temp
	}
	switch &m in msg^ {
	case Commit_Derived_Batch:
		rec_cnt := len(m.records)
		notify_pid := m.notify_pid
		payload := _Commit_Tx_Payload{
			batch        = &m,
			next_dec_seq = &state.next_dec_seq,
		}
		moment_idx, err := forseti.store_bridge_commit_moment(state.bridge, _commit_derived_batch_tx_cb, &payload)
		commit_batch_destroy(&m)
		_broadcast_commit_notification(ctx, state, notify_pid, Commit_Notification{
			moment_idx    = moment_idx,
			derived_count = rec_cnt,
			err           = err,
		})
		actor.reply(ctx, Commit_Reply{moment_idx = moment_idx, derived_count = rec_cnt, err = err})

	case Commit_Raw_Batch:
		rec_cnt := len(m.records)
		moment_idx, err := forseti.store_bridge_commit_moment(state.bridge, _commit_raw_batch_tx_cb, &m)
		commit_raw_batch_destroy(&m)
		_broadcast_commit_notification(ctx, state, {}, Commit_Notification{
			moment_idx    = moment_idx,
			derived_count = rec_cnt,
			err           = err,
		})
		actor.reply(ctx, Commit_Reply{moment_idx = moment_idx, derived_count = rec_cnt, err = err})

	case Subscribe_Commits:
		if m.pid.ref == nil {
			actor.reply(ctx, Commit_Op_Reply{err = .Invalid_Config})
			return
		}
		already := false
		for sub in state.subscribers {
			if sub.ref == m.pid.ref {
				already = true
				break
			}
		}
		if !already {
			append(&state.subscribers, m.pid)
		}
		actor.reply(ctx, Commit_Op_Reply{err = nil})

	case Get_Moment_Count:
		cnt, err := forseti.store_bridge_moment_count(state.bridge)
		actor.reply(ctx, Commit_Count_Reply{count = cnt, err = err})

	case Snapshot_Lookup_Field:
		m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(state.bridge, -1)
		if m_err != nil || !m_ok {
			actor.reply(ctx, Snapshot_Field_Reply{found = false, err = m_err})
			return
		}
		col_cur, c_ok, c_err := forseti.store_resolve_path(m_cur, m.dot_path)
		if c_err != nil || !c_ok {
			actor.reply(ctx, Snapshot_Field_Reply{found = false, err = c_err})
			return
		}
		rec_cur: xitdb.Read_Cursor
		r_ok := false
		if len(m.key) > 0 {
			found_cur, ok, r_err := forseti.store_lookup_record(col_cur, m.key)
			if r_err != nil {
				actor.reply(ctx, Snapshot_Field_Reply{found = false, err = r_err})
				return
			}
			rec_cur = found_cur
			r_ok = ok
		} else if len(m.match_field) > 0 {
			it, it_err := xitdb.cursor_iterator(col_cur)
			if it_err != nil {
				actor.reply(ctx, Snapshot_Field_Reply{found = false, err = forseti.xitdb_to_store_err(it_err)})
				return
			}
			for {
				item, n_err := xitdb.cursor_iterator_next(&it)
				if n_err != nil {
					actor.reply(ctx, Snapshot_Field_Reply{found = false, err = forseti.xitdb_to_store_err(n_err)})
					return
				}
				entry, ok := item.?
				if !ok {
					break
				}
				_, vc, kv_err := xitdb.cursor_read_kv_pair_slots(entry)
				if kv_err != nil {
					continue
				}
				mf_cur, mf_ok, _ := forseti.store_lookup_record(vc, m.match_field)
				if !mf_ok {
					continue
				}
				raw_mf, r_err := xitdb.cursor_read_bytes(mf_cur, 0, context.temp_allocator)
				if r_err == nil && string(raw_mf) == m.match_str {
					rec_cur = vc
					r_ok = true
					break
				}
			}
		}
		if !r_ok {
			actor.reply(ctx, Snapshot_Field_Reply{found = false, err = nil})
			return
		}
		fld_cur, f_ok, f_err := forseti.store_lookup_record(rec_cur, m.field_name)
		if f_err != nil || !f_ok {
			actor.reply(ctx, Snapshot_Field_Reply{found = false, err = f_err})
			return
		}
		sp, sp_err := xitdb.cursor_resolved(fld_cur)
		if sp_err != nil {
			actor.reply(ctx, Snapshot_Field_Reply{found = false, err = forseti.xitdb_to_store_err(sp_err)})
			return
		}
		#partial switch sp.slot.tag {
		case .Bytes, .Short_Bytes:
			raw, rb_err := xitdb.cursor_read_bytes(fld_cur, 0, context.temp_allocator)
			if rb_err != nil {
				actor.reply(ctx, Snapshot_Field_Reply{found = false, err = forseti.xitdb_to_store_err(rb_err)})
				return
			}
			cloned := strings.clone(string(raw), state.alloc)
			actor.reply(ctx, Snapshot_Field_Reply{found = true, str_val = cloned, err = nil})
		case .Int:
			iv, iv_err := xitdb.cursor_read_int(fld_cur)
			actor.reply(ctx, Snapshot_Field_Reply{found = iv_err == nil, int_val = iv, err = forseti.xitdb_to_store_err(iv_err)})
		case .Uint:
			uv, uv_err := xitdb.cursor_read_uint(fld_cur)
			actor.reply(ctx, Snapshot_Field_Reply{found = uv_err == nil, int_val = i64(uv), err = forseti.xitdb_to_store_err(uv_err)})
		case:
			actor.reply(ctx, Snapshot_Field_Reply{found = true, err = nil})
		}
	}
}

@(private)
_commit_actor_spawn_common :: proc(
	sched: ^actor.Scheduler,
	bridge: ^forseti.Store_Bridge,
	tel: forseti.Telemetry_Sink,
	id: u32,
	allocator: mem.Allocator,
) -> (h: ^Commit_Actor_Handle, err: mem.Allocator_Error) {
	subs := make([dynamic]actor.PID(Session_Msg), 0, 8, allocator) or_return
	state := Commit_Actor_State{
		alloc       = allocator,
		bridge      = bridge,
		tel         = tel,
		tel_inited  = true,
		subscribers = subs,
	}
	h, err = actor.spawn(sched, state, commit_actor_receive, id = id, allocator = allocator)
	if err != nil {
		delete(subs)
		return nil, err
	}
	h.state.bridge.telemetry = &h.state.tel
	h.state.prev_destroy_proc = h.base.destroy_proc
	h.base.destroy_proc = _commit_actor_destroy_hook
	return h, .None
}

commit_actor_spawn_memory :: proc(
	sched: ^actor.Scheduler,
	cfg: forseti.Xitdb_Config = {},
	id: u32 = 0,
	allocator := context.allocator,
) -> (h: ^Commit_Actor_Handle, err: forseti.Store_Error) {
	tel: forseti.Telemetry_Sink
	forseti.telemetry_init(&tel, enabled = true, allocator = allocator) or_return
	bridge := new(forseti.Store_Bridge, allocator)
	if b_err := forseti.store_bridge_init_standalone(bridge, cfg, nil, allocator); b_err != nil {
		free(bridge, allocator)
		forseti.telemetry_destroy(&tel)
		return nil, b_err
	}
	res_h, a_err := _commit_actor_spawn_common(sched, bridge, tel, id, allocator)
	if a_err != nil {
		forseti.store_bridge_destroy(bridge)
		free(bridge, allocator)
		forseti.telemetry_destroy(&tel)
		return nil, a_err
	}
	return res_h, nil
}

commit_actor_spawn_file :: proc(
	sched: ^actor.Scheduler,
	path: string,
	cfg: forseti.Xitdb_Config = {},
	id: u32 = 0,
	allocator := context.allocator,
) -> (h: ^Commit_Actor_Handle, err: forseti.Store_Error) {
	tel: forseti.Telemetry_Sink
	forseti.telemetry_init(&tel, enabled = true, allocator = allocator) or_return
	bridge := new(forseti.Store_Bridge, allocator)
	if b_err := forseti.store_bridge_open_file(bridge, path, cfg, nil, allocator); b_err != nil {
		free(bridge, allocator)
		forseti.telemetry_destroy(&tel)
		return nil, b_err
	}
	res_h, a_err := _commit_actor_spawn_common(sched, bridge, tel, id, allocator)
	if a_err != nil {
		forseti.store_bridge_destroy(bridge)
		free(bridge, allocator)
		forseti.telemetry_destroy(&tel)
		return nil, a_err
	}
	return res_h, nil
}
