package forseti_actors

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:strings"
import actor "actor:."
import "../forseti"

@(private)
_global_session_actor_seq: u64 = 0

Actor_Field_Value :: union {
	bool,
	i32,
	i64,
	f64,
	string,
}

Actor_Fact_Input :: struct {
	binding_name:  string,
	key:           string,
	fields:        []Actor_Field_Value,
	unconditional: bool,
}

Session_SPSC_Mailbox :: actor.Sharded_SPSC_Mailbox(Actor_Fact_Input, actor.DEFAULT_SPSC_CAPACITY)

session_spsc_init :: proc(
	m: ^Session_SPSC_Mailbox,
	num_producers: int,
	allocator := context.allocator,
) -> mem.Allocator_Error {
	return actor.sharded_spsc_init(m, num_producers, allocator)
}

session_spsc_destroy :: proc(m: ^Session_SPSC_Mailbox) {
	actor.sharded_spsc_destroy(m)
}

session_spsc_push :: #force_inline proc(
	m: ^Session_SPSC_Mailbox,
	producer_id: int,
	fact: Actor_Fact_Input,
) {
	actor.sharded_spsc_push(m, producer_id, fact)
}

Insert_Fact :: struct {
	fact:      Actor_Fact_Input,
	auto_fire: bool,
}

Insert_Batch :: struct {
	facts:     []Actor_Fact_Input,
	auto_fire: bool,
}

Retract_Fact :: struct {
	binding_name: string,
	key:          string,
	auto_fire:    bool,
}

Fire_Session :: struct {}

Sync_And_Fire :: struct {
	store:          ^forseti.Store_Bridge,
	watched_paths:  []string,
	commit_derived: bool,
}

Run_Query :: struct {
	query_name: string,
	args:       []Actor_Query_Arg,
}

Actor_Query_Arg :: struct {
	name:  string,
	value: Actor_Field_Value,
}

Explain_Fact :: struct {
	binding_name: string,
	key:          string,
	fields:       []Actor_Field_Value,
}

Impact_Rule :: struct {
	rule_name: string,
}

Prepare_Effects :: struct {}

Apply_Effects :: struct {
	results:   []forseti.Effect_Result,
	auto_fire: bool,
}

Swap_Rulebase :: struct {
	rb:              ^forseti.Rulebase,
	rehydrate_store: ^forseti.Store_Bridge,
	watched_paths:   []string,
	on_retired:      proc(old_rb: ^forseti.Rulebase, user_data: rawptr),
	retired_ctx:     rawptr,
}

Drain_SPSC :: struct {
	mailbox:        ^Session_SPSC_Mailbox,
	quota_per_lane: int,
	auto_fire:      bool,
}

Commit_Derived_To_Writer :: struct {
	writer: actor.PID(Commit_Msg),
}

Get_Session_Stats :: struct {}

Commit_Notification :: struct {
	moment_idx:    i64,
	derived_count: int,
	err:           forseti.Store_Error,
}

Session_Msg :: union {
	Insert_Fact,
	Insert_Batch,
	Retract_Fact,
	Fire_Session,
	Sync_And_Fire,
	Run_Query,
	Explain_Fact,
	Impact_Rule,
	Prepare_Effects,
	Apply_Effects,
	Swap_Rulebase,
	Drain_SPSC,
	Commit_Derived_To_Writer,
	Get_Session_Stats,
	Commit_Notification,
}

Session_Op_Reply :: struct {
	fact_id: forseti.Fact_Id,
	err:     forseti.Session_Error,
}

Session_Batch_Reply :: struct {
	inserted: int,
	fired:    u64,
	err:      forseti.Session_Error,
}

Session_Fire_Reply :: struct {
	fired: u64,
	err:   forseti.Session_Error,
}

Session_Sync_Reply :: struct {
	fired: u64,
	err:   forseti.Store_Error,
}

Session_Query_Reply :: struct {
	result: forseti.Query_Result,
	err:    forseti.Session_Error,
}

Session_Text_Reply :: struct {
	text:  string,
	found: bool,
	err:   forseti.Session_Error,
}

Session_Impact_Reply :: struct {
	report: forseti.Impact_Report,
	err:    forseti.Session_Error,
}

Session_Prepared_Effects_Reply :: struct {
	jobs: []forseti.Effect_Job,
	err:  forseti.Session_Error,
}

Session_Apply_Reply :: struct {
	applied: []forseti.Fact_Id,
	fired:   u64,
	err:     forseti.Session_Error,
}

Session_Stats_Reply :: struct {
	generation:           u32,
	alive_facts:          int,
	derived_facts:        int,
	fired_total:          u64,
	telemetry_events:     int,
	commit_notifications: int,
	last_commit_moment:   i64,
}

Session_Actor_Config :: struct {
	session_cfg:      forseti.Session_Config,
	rehydrate_store:  ^forseti.Store_Bridge,
	rehydrate_paths:  []string,
	pre_fire_hook:    proc(state: ^Session_Actor_State),
	on_retired_rb:    proc(old_rb: ^forseti.Rulebase, user_data: rawptr),
	retired_rb_ctx:   rawptr,
}

Session_Actor_State :: struct {
	alloc:                mem.Allocator,
	actor_seq:            u64,
	rb:                   ^forseti.Rulebase,
	cfg:                  forseti.Session_Config,
	sess:                 ^forseti.Session,
	tel:                  forseti.Telemetry_Sink,
	tel_inited:           bool,
	rehydrate_store:      ^forseti.Store_Bridge,
	rehydrate_paths:      []string,
	pre_fire_hook:        proc(state: ^Session_Actor_State),
	on_retired_rb:        proc(old_rb: ^forseti.Rulebase, user_data: rawptr),
	retired_rb_ctx:       rawptr,
	prev_destroy_proc:    proc(base: ^actor.Actor_Base),
	fired_total:          u64,
	commit_notifications: int,
	last_commit_moment:   i64,
}

Session_Actor_Handle :: actor.Actor(Session_Actor_State, Session_Msg)

@(private)
_session_actor_ensure_init :: proc(state: ^Session_Actor_State) -> forseti.Session_Error {
	if state.sess != nil {
		return .None
	}
	if state.rb == nil {
		return .Invalid_Arg
	}
	alloc := state.alloc
	if !state.tel_inited {
		if forseti.telemetry_init(&state.tel, enabled = true, allocator = alloc) != nil {
			return .Alloc_Failed
		}
		state.tel_inited = true
	}
	s := new(forseti.Session, alloc)
	cfg := state.cfg
	if err := forseti.session_init(s, state.rb, cfg, &state.tel, alloc); err != .None {
		forseti.session_destroy(s)
		free(s, alloc)
		return err
	}
	state.sess = s

	if state.rehydrate_store != nil && len(state.rehydrate_paths) > 0 {
		syncer: forseti.Delta_Syncer
		if forseti.delta_syncer_init(&syncer, &state.tel, alloc) == nil {
			defer forseti.delta_syncer_destroy(&syncer)
			for p in state.rehydrate_paths {
				_ = forseti.delta_syncer_watch(&syncer, p)
			}
			_, _ = forseti.session_sync_and_fire(state.sess, state.rehydrate_store, &syncer, commit_derived = false)
		}
	}
	return .None
}

session_actor_cleanup_state :: proc(state: ^Session_Actor_State) {
	if state == nil {
		return
	}
	alloc := state.alloc
	if state.sess != nil {
		forseti.session_destroy(state.sess)
		free(state.sess, alloc)
		state.sess = nil
	}
	if state.tel_inited {
		forseti.telemetry_destroy(&state.tel)
		state.tel_inited = false
	}
}

session_actor_on_stop :: proc(state: ^Session_Actor_State, reason: actor.Exit_Reason) {
	_ = reason
	session_actor_cleanup_state(state)
}

session_actor_on_reinit :: proc(state: ^Session_Actor_State, arena_alloc: mem.Allocator) {
	_ = arena_alloc
	state.sess = nil
	state.tel_inited = false
	_ = _session_actor_ensure_init(state)
}

@(private)
_session_actor_destroy_hook :: proc(base: ^actor.Actor_Base) {
	self := cast(^Session_Actor_Handle)base
	prev := self.state.prev_destroy_proc
	session_actor_cleanup_state(&self.state)
	if prev != nil {
		prev(base)
	}
}

@(private)
_actor_fields_to_values :: proc(
	sess: ^forseti.Session,
	fields: []Actor_Field_Value,
	alloc: mem.Allocator,
) -> (vals: []forseti.Value, err: forseti.Session_Error) {
	if len(fields) == 0 {
		return nil, .None
	}
	vals = make([]forseti.Value, len(fields), alloc)
	for fv, i in fields {
		switch x in fv {
		case bool:
			vals[i] = x
		case i32:
			vals[i] = x
		case i64:
			vals[i] = x
		case f64:
			vals[i] = x
		case string:
			sid, s_err := forseti.intern_session_string(&sess.rb.interner, &sess.interner, x)
			if s_err != nil {
				delete(vals, alloc)
				return nil, .Alloc_Failed
			}
			vals[i] = sid
		}
	}
	return vals, .None
}

@(private)
_actor_args_to_query_args :: proc(
	sess: ^forseti.Session,
	args: []Actor_Query_Arg,
	alloc: mem.Allocator,
) -> []forseti.Query_Arg {
	if len(args) == 0 {
		return nil
	}
	out := make([]forseti.Query_Arg, len(args), alloc)
	for a, i in args {
		out[i].name = a.name
		switch x in a.value {
		case bool:   out[i].value = x
		case i32:    out[i].value = x
		case i64:    out[i].value = x
		case f64:    out[i].value = x
		case string:
			sid, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, x)
			out[i].value = sid
		}
	}
	return out
}

@(private)
_insert_actor_fact :: proc(state: ^Session_Actor_State, f: Actor_Fact_Input) -> (forseti.Fact_Id, forseti.Session_Error) {
	vals, v_err := _actor_fields_to_values(state.sess, f.fields, state.alloc)
	if v_err != .None {
		return forseti.INVALID_FACT, v_err
	}
	defer if vals != nil {
		delete(vals, state.alloc)
	}
	origin: forseti.Fact_Origin = .Unconditional if f.unconditional else .External
	return forseti.session_insert_fact(state.sess, f.binding_name, f.key, vals, origin)
}

@(private)
_binding_dot_path :: proc(rb: ^forseti.Rulebase, bdef: forseti.Binding_Def, alloc: mem.Allocator) -> (res: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, alloc) or_return
	for seg in bdef.segments {
		if seg.kind != .Field {
			continue
		}
		strings.write_byte(&b, '.')
		strings.write_string(&b, forseti.interner_get(&rb.interner, seg.text))
	}
	return strings.to_string(b), nil
}

@(private)
_extract_commit_batch :: proc(
	state: ^Session_Actor_State,
	alloc: mem.Allocator,
) -> (batch: Commit_Derived_Batch, err: mem.Allocator_Error) {
	s := state.sess
	batch.module_name = strings.clone(forseti.interner_get(&s.rb.interner, s.rb.module_name), alloc) or_return
	batch.tx_seq = u64(s.provenance.tx_seq)
	batch.owns_payload = true
	batch.payload_alloc = alloc

	recs := make([dynamic]Commit_Derived_Record, 0, 16, alloc) or_return
	decs := make([dynamic]Commit_Decision_Entry, 0, 16, alloc) or_return
	defer if err != nil {
		batch.records = recs[:]
		batch.decisions = decs[:]
		commit_batch_destroy(&batch)
	}

	for &f in s.facts {
		if !f.alive || int(f.binding_idx) >= len(s.rb.bindings) {
			continue
		}
		bdef := s.rb.bindings[f.binding_idx]
		if bdef.kind != .Derived {
			continue
		}
		if int(bdef.schema_id) >= len(s.rb.schemas) {
			continue
		}
		sdef := s.rb.schemas[bdef.schema_id]
		cf_slice := make([]Commit_Field, len(sdef.fields), alloc) or_return
		for sf, fi in sdef.fields {
			fname := forseti.interner_get(&s.rb.interner, sf.name)
			cf_slice[fi].name = strings.clone(fname, alloc) or_return
			if fi < len(f.fields) {
				switch v in f.fields[fi] {
				case bool:   cf_slice[fi].value = v
				case i32:    cf_slice[fi].value = v
				case i64:    cf_slice[fi].value = v
				case f64:    cf_slice[fi].value = v
				case forseti.String_Id:
					cf_slice[fi].value = strings.clone(forseti.session_string(s, v), alloc) or_return
				case forseti.Entity_Id:
					cf_slice[fi].value = i64(v)
				case forseti.Time_Ns:
					cf_slice[fi].value = i64(v)
				case forseti.Enum_Val:
					cf_slice[fi].value = i64(v.variant)
				}
			}
		}
		dot_path := _binding_dot_path(s.rb, bdef, alloc) or_return
		raw_key := forseti.session_string(s, f.key)
		scoped_key := fmt.aprintf("s%d:%s", state.actor_seq, raw_key, allocator = alloc)
		append(&recs, Commit_Derived_Record{
			dot_path = dot_path,
			key      = scoped_key,
			fields   = cf_slice,
		}) or_return
	}

	if s.provenance.mode == .Audit_Full {
		id_buf: [32]u8 = ---
		for di := 1; di < len(s.provenance.derivs); di += 1 {
			d := s.provenance.derivs[di]
			did_str := fmt.bprintf(id_buf[:], "dec:%d", di)
			rname := "unknown"
			rver := "1.0"
			if int(d.rule_id) < len(s.rb.rules) {
				rc := s.rb.rules[d.rule_id]
				rname = forseti.interner_get(&s.rb.interner, rc.name)
				if rc.version != forseti.EMPTY_STRING {
					rver = forseti.interner_get(&s.rb.interner, rc.version)
				}
			}
			tname := ""
			trow := ""
			if d.table_idx != forseti.INVALID_TABLE_IDX && int(d.table_idx) < len(s.rb.tables) {
				ct := &s.rb.tables[d.table_idx]
				tname = forseti.compiled_table_string(ct, ct.table_name)
				if d.table_row_id != forseti.INVALID_ROW_ID && int(d.table_row_id) < len(ct.row_ids) {
					trow = forseti.compiled_table_string(ct, ct.row_ids[d.table_row_id])
				}
			}
			dbind := ""
			dkey := ""
			if d.derived_fact != forseti.INVALID_FACT && int(d.derived_fact) < len(s.facts) {
				df := &s.facts[d.derived_fact]
				dbind = forseti.interner_get(&s.rb.interner, s.rb.bindings[df.binding_idx].name)
				dkey = forseti.session_string(s, df.key)
			}
			pstart := int(d.parent_start)
			pend := min(pstart + int(d.parent_count), len(s.provenance.parent_facts))
			raw_parents: []forseti.Fact_Id
			if pstart >= 0 && pstart <= pend {
				raw_parents = s.provenance.parent_facts[pstart:pend]
			}
			par_keys := make([]string, len(raw_parents), alloc) or_return
			for pf, pi in raw_parents {
				if pf != forseti.INVALID_FACT && int(pf) < len(s.facts) {
					par_keys[pi] = strings.clone(forseti.session_string(s, s.facts[pf].key), alloc) or_return
				} else {
					par_keys[pi] = strings.clone("", alloc) or_return
				}
			}

			append(&decs, Commit_Decision_Entry{
				dec_id          = strings.clone(did_str, alloc) or_return,
				rule_name       = strings.clone(rname, alloc) or_return,
				rule_version    = strings.clone(rver, alloc) or_return,
				table_name      = strings.clone(tname, alloc) or_return,
				table_row       = strings.clone(trow, alloc) or_return,
				derived_binding = strings.clone(dbind, alloc) or_return,
				derived_key     = strings.clone(dkey, alloc) or_return,
				proof_height    = d.proof_height,
				weight          = i32(d.weight),
				tx_seq          = u64(d.tx_seq),
				alive           = d.alive,
				parents         = par_keys,
			}) or_return
		}
	}

	batch.records = recs[:]
	batch.decisions = decs[:]
	return batch, nil
}

@(private)
_spsc_drain_handler :: proc(ctx: ^_Spsc_Drain_Ctx, f: ^Actor_Fact_Input) {
	if ctx.err != .None {
		return
	}
	_, err := _insert_actor_fact(ctx.state, f^)
	if err != .None {
		ctx.err = err
		return
	}
	ctx.inserted += 1
}

@(private)
_Spsc_Drain_Ctx :: struct {
	state:    ^Session_Actor_State,
	inserted: int,
	err:      forseti.Session_Error,
}

session_actor_receive :: proc(ctx: ^actor.Context, self: ^Session_Actor_Handle, msg: ^Session_Msg) {
	state := &self.state
	if init_err := _session_actor_ensure_init(state); init_err != .None {
		switch m in msg^ {
		case Insert_Fact, Retract_Fact, Swap_Rulebase:
			actor.reply(ctx, Session_Op_Reply{err = init_err})
		case Insert_Batch, Drain_SPSC:
			actor.reply(ctx, Session_Batch_Reply{err = init_err})
		case Fire_Session:
			actor.reply(ctx, Session_Fire_Reply{err = init_err})
		case Sync_And_Fire:
			actor.reply(ctx, Session_Sync_Reply{err = .Invalid_Config})
		case Run_Query:
			actor.reply(ctx, Session_Query_Reply{err = init_err})
		case Explain_Fact:
			actor.reply(ctx, Session_Text_Reply{err = init_err})
		case Impact_Rule:
			actor.reply(ctx, Session_Impact_Reply{err = init_err})
		case Prepare_Effects:
			actor.reply(ctx, Session_Prepared_Effects_Reply{err = init_err})
		case Apply_Effects:
			actor.reply(ctx, Session_Apply_Reply{err = init_err})
		case Commit_Derived_To_Writer:
			actor.reply(ctx, Commit_Reply{err = .Invalid_Config})
		case Get_Session_Stats:
			actor.reply(ctx, Session_Stats_Reply{generation = actor.current_generation()})
		case Commit_Notification:
		}
		return
	}

	switch &m in msg^ {
	case Insert_Fact:
		fid, err := _insert_actor_fact(state, m.fact)
		if err == .None && m.auto_fire {
			if state.pre_fire_hook != nil {
				state.pre_fire_hook(state)
			}
			fired, f_err := forseti.session_fire(state.sess)
			state.fired_total += fired
			err = f_err
		}
		actor.reply(ctx, Session_Op_Reply{fact_id = fid, err = err})

	case Insert_Batch:
		inserted := 0
		err := forseti.Session_Error.None
		for f in m.facts {
			_, i_err := _insert_actor_fact(state, f)
			if i_err != .None {
				err = i_err
				break
			}
			inserted += 1
		}
		fired := u64(0)
		if err == .None && m.auto_fire {
			if state.pre_fire_hook != nil {
				state.pre_fire_hook(state)
			}
			fired, err = forseti.session_fire(state.sess)
			state.fired_total += fired
		}
		actor.reply(ctx, Session_Batch_Reply{inserted = inserted, fired = fired, err = err})

	case Retract_Fact:
		err := forseti.session_retract_fact_by_key(state.sess, m.binding_name, m.key)
		if err == .None && m.auto_fire {
			fired, f_err := forseti.session_fire(state.sess)
			state.fired_total += fired
			err = f_err
		}
		actor.reply(ctx, Session_Op_Reply{err = err})

	case Fire_Session:
		if state.pre_fire_hook != nil {
			state.pre_fire_hook(state)
		}
		fired, err := forseti.session_fire(state.sess)
		state.fired_total += fired
		actor.reply(ctx, Session_Fire_Reply{fired = fired, err = err})

	case Sync_And_Fire:
		if m.store == nil {
			actor.reply(ctx, Session_Sync_Reply{err = .Invalid_Config})
			return
		}
		syncer: forseti.Delta_Syncer
		if s_err := forseti.delta_syncer_init(&syncer, &state.tel, state.alloc); s_err != nil {
			actor.reply(ctx, Session_Sync_Reply{err = s_err})
			return
		}
		defer forseti.delta_syncer_destroy(&syncer)
		for wp in m.watched_paths {
			if w_err := forseti.delta_syncer_watch(&syncer, wp); w_err != nil {
				actor.reply(ctx, Session_Sync_Reply{err = w_err})
				return
			}
		}
		fired, err := forseti.session_sync_and_fire(state.sess, m.store, &syncer, m.commit_derived)
		if err == nil {
			state.fired_total += fired
		}
		actor.reply(ctx, Session_Sync_Reply{fired = fired, err = err})

	case Run_Query:
		qargs := _actor_args_to_query_args(state.sess, m.args, state.alloc)
		defer if qargs != nil {
			delete(qargs, state.alloc)
		}
		qr: forseti.Query_Result
		err := forseti.session_query(state.sess, m.query_name, qargs, &qr)
		actor.reply(ctx, Session_Query_Reply{result = qr, err = err})

	case Explain_Fact:
		fid, found := _find_fact_for_explain(state.sess, m.binding_name, m.key, m.fields)
		if !found {
			actor.reply(ctx, Session_Text_Reply{found = false, err = .None})
			return
		}
		tree := forseti.explain(state.sess, fid, state.alloc)
		defer forseti.explain_tree_destroy(&tree)
		txt := forseti.explain_format(&tree, state.alloc)
		actor.reply(ctx, Session_Text_Reply{text = txt, found = tree.found, err = .None})

	case Impact_Rule:
		rid, has_r := _find_rule_id_by_name(state.rb, m.rule_name)
		if !has_r {
			actor.reply(ctx, Session_Impact_Reply{err = .Invalid_Arg})
			return
		}
		rep := forseti.impact(state.sess, rid, "", state.alloc)
		actor.reply(ctx, Session_Impact_Reply{report = rep, err = .None})

	case Prepare_Effects:
		jobs := forseti.session_prepare_effects(state.sess, state.alloc)
		actor.reply(ctx, Session_Prepared_Effects_Reply{jobs = jobs, err = .None})

	case Apply_Effects:
		applied, err := forseti.session_apply_effects(state.sess, m.results, state.alloc)
		fired := u64(0)
		if err == .None && m.auto_fire {
			fired, err = forseti.session_fire(state.sess)
			state.fired_total += fired
		}
		actor.reply(ctx, Session_Apply_Reply{applied = applied, fired = fired, err = err})

	case Swap_Rulebase:
		if m.rb == nil {
			actor.reply(ctx, Session_Op_Reply{err = .Invalid_Arg})
			return
		}
		old_rb := state.rb
		old_cb := m.on_retired if m.on_retired != nil else state.on_retired_rb
		old_ctx := m.retired_ctx if m.on_retired != nil else state.retired_rb_ctx

		session_actor_cleanup_state(state)
		state.rb = m.rb
		if m.rehydrate_store != nil {
			state.rehydrate_store = m.rehydrate_store
		}
		if len(m.watched_paths) > 0 {
			state.rehydrate_paths = m.watched_paths
		}
		init_err := _session_actor_ensure_init(state)
		if old_cb != nil && old_rb != nil {
			old_cb(old_rb, old_ctx)
		}
		actor.reply(ctx, Session_Op_Reply{err = init_err})

	case Drain_SPSC:
		if m.mailbox == nil {
			actor.reply(ctx, Session_Batch_Reply{err = .Invalid_Arg})
			return
		}
		quota := m.quota_per_lane if m.quota_per_lane > 0 else 64
		dctx := _Spsc_Drain_Ctx{state = state}
		_ = actor.sharded_spsc_consume(m.mailbox, quota, &dctx, _spsc_drain_handler)
		fired := u64(0)
		if dctx.err == .None && m.auto_fire && dctx.inserted > 0 {
			fired, dctx.err = forseti.session_fire(state.sess)
			state.fired_total += fired
		}
		actor.reply(ctx, Session_Batch_Reply{inserted = dctx.inserted, fired = fired, err = dctx.err})

	case Commit_Derived_To_Writer:
		batch, b_err := _extract_commit_batch(state, state.alloc)
		if b_err != nil {
			actor.reply(ctx, Commit_Reply{err = b_err})
			return
		}
		rep := actor.call(ctx.sched, m.writer, Commit_Msg(batch), Commit_Reply)
		actor.reply(ctx, rep)

	case Get_Session_Stats:
		alive := 0
		derived := 0
		for &f in state.sess.facts {
			if !f.alive {
				continue
			}
			alive += 1
			if int(f.binding_idx) < len(state.rb.bindings) && state.rb.bindings[f.binding_idx].kind == .Derived {
				derived += 1
			}
		}
		actor.reply(ctx, Session_Stats_Reply{
			generation           = actor.current_generation(),
			alive_facts          = alive,
			derived_facts        = derived,
			fired_total          = state.fired_total,
			telemetry_events     = len(state.tel.events),
			commit_notifications = state.commit_notifications,
			last_commit_moment   = state.last_commit_moment,
		})

	case Commit_Notification:
		state.commit_notifications += 1
		state.last_commit_moment = m.moment_idx
	}
}

@(private)
_find_fact_for_explain :: proc(
	s: ^forseti.Session,
	binding_name: string,
	key: string,
	fields: []Actor_Field_Value,
) -> (forseti.Fact_Id, bool) {
	bidx, has_b := forseti.session_find_binding(s, binding_name)
	if !has_b {
		return forseti.INVALID_FACT, false
	}
	for &f in s.facts {
		if !f.alive || f.binding_idx != bidx {
			continue
		}
		if len(key) > 0 && forseti.session_string(s, f.key) == key {
			return f.id, true
		}
		if len(fields) > 0 && len(f.fields) >= len(fields) {
			match := true
			for fv, fi in fields {
				switch exp in fv {
				case bool:
					v, ok := f.fields[fi].(bool)
					if !ok || v != exp { match = false }
				case i32:
					v, ok := f.fields[fi].(i32)
					if !ok || v != exp { match = false }
				case i64:
					v, ok := f.fields[fi].(i64)
					if !ok || v != exp { match = false }
				case f64:
					v, ok := f.fields[fi].(f64)
					if !ok || v != exp { match = false }
				case string:
					sid, ok := f.fields[fi].(forseti.String_Id)
					if !ok || forseti.session_string(s, sid) != exp { match = false }
				}
				if !match {
					break
				}
			}
			if match {
				return f.id, true
			}
		}
	}
	return forseti.INVALID_FACT, false
}

@(private)
_find_rule_id_by_name :: proc(rb: ^forseti.Rulebase, name: string) -> (u32, bool) {
	if rb == nil {
		return 0, false
	}
	for rc, ri in rb.rules {
		if forseti.interner_get(&rb.interner, rc.name) == name {
			return u32(ri), true
		}
	}
	return 0, false
}

session_actor_make_init_state :: proc(
	rb: ^forseti.Rulebase,
	cfg: Session_Actor_Config = {},
	alloc := context.allocator,
) -> Session_Actor_State {
	scfg := cfg.session_cfg
	if scfg.max_activations == 0 && len(scfg.initial_phases) == 0 {
		scfg.provenance_mode = .Audit_Full
	}
	seq := intrinsics.atomic_add_explicit(&_global_session_actor_seq, 1, .Relaxed) + 1
	return Session_Actor_State{
		alloc              = alloc,
		actor_seq          = seq,
		rb                 = rb,
		cfg                = scfg,
		rehydrate_store    = cfg.rehydrate_store,
		rehydrate_paths    = cfg.rehydrate_paths,
		pre_fire_hook      = cfg.pre_fire_hook,
		on_retired_rb      = cfg.on_retired_rb,
		retired_rb_ctx     = cfg.retired_rb_ctx,
		last_commit_moment = -1,
	}
}

session_actor_attach_cleanup :: proc(h: ^Session_Actor_Handle) {
	if h == nil {
		return
	}
	h.state.prev_destroy_proc = h.base.destroy_proc
	h.base.destroy_proc = _session_actor_destroy_hook
}

session_actor_spawn :: proc(
	sched: ^actor.Scheduler,
	rb: ^forseti.Rulebase,
	cfg: Session_Actor_Config = {},
	id: u32 = 0,
	allocator := context.allocator,
) -> (h: ^Session_Actor_Handle, err: mem.Allocator_Error) {
	if rb == nil {
		return nil, .Invalid_Pointer
	}
	init_state := session_actor_make_init_state(rb, cfg, allocator)
	h = actor.spawn(sched, init_state, session_actor_receive, id = id, allocator = allocator) or_return
	session_actor_attach_cleanup(h)
	return h, .None
}
