package forseti

import "core:fmt"
import "core:mem"
import xitdb "xitdb:."

Activation_Key :: struct {
	rule_id:  u32,
	tok_hash: u64,
}

Activation :: struct {
	rule_id:  u32,
	phase:    String_Id,
	salience: i32,
	token:    Beta_Token,
	alive:    bool,
}

Agenda :: struct {
	items:            [dynamic]Activation,
	queued:           map[Activation_Key]bool,
	refracted:        map[Activation_Key]bool,
	fact_activations: map[Fact_Id][dynamic]Activation_Key,
	phases:           [dynamic]String_Id,
	allocator:        mem.Allocator,
}

@(private)
agenda_init :: proc(ag: ^Agenda, allocator: mem.Allocator) {
	ag.allocator = allocator
	ag.items = make([dynamic]Activation, 0, 16, allocator)
	ag.queued = make(map[Activation_Key]bool, 16, allocator)
	ag.refracted = make(map[Activation_Key]bool, 16, allocator)
	ag.fact_activations = make(map[Fact_Id][dynamic]Activation_Key, 16, allocator)
	ag.phases = make([dynamic]String_Id, 0, 8, allocator)
}

@(private)
agenda_destroy :: proc(ag: ^Agenda) {
	for _, list in ag.fact_activations {
		delete(list)
	}
	delete(ag.fact_activations)
	delete(ag.refracted)
	delete(ag.queued)
	delete(ag.items)
	delete(ag.phases)
	ag^ = {}
}

session_set_phases :: proc(s: ^Session, phases: []string) -> Session_Error {
	if s == nil || s.rb == nil {
		return .Invalid_Arg
	}
	clear(&s.agenda.phases)
	for ph in phases {
		sid, err := intern_session_string(&s.rb.interner, &s.interner, ph)
		if err != nil {
			return .Alloc_Failed
		}
		append(&s.agenda.phases, sid)
	}
	return .None
}

@(private)
agenda_stage_activation :: proc(s: ^Session, rule_id: u32, tok: Beta_Token) {
	ag := &s.agenda
	ak := Activation_Key{rule_id = rule_id, tok_hash = tok.fact_sig_hash}
	if ak in ag.refracted || ak in ag.queued {
		return
	}
	ag.queued[ak] = true
	rule := s.rb.rules[rule_id]
	append(&ag.items, Activation{
		rule_id  = rule_id,
		phase    = rule.phase,
		salience = rule.salience,
		token    = tok,
		alive    = true,
	})
	for i := 0; i < int(tok.fact_count); i += 1 {
		fid := tok.fact_ids[i]
		list, has := &ag.fact_activations[fid]
		if !has {
			ag.fact_activations[fid] = make([dynamic]Activation_Key, 0, 2, ag.allocator)
			list = &ag.fact_activations[fid]
		}
		append(list, ak)
	}
}

@(private)
agenda_remove_fact :: proc(ag: ^Agenda, fid: Fact_Id) {
	for &act in ag.items {
		if !act.alive {
			continue
		}
		for i := 0; i < int(act.token.fact_count); i += 1 {
			if act.token.fact_ids[i] == fid {
				act.alive = false
				ak := Activation_Key{rule_id = act.rule_id, tok_hash = act.token.fact_sig_hash}
				delete_key(&ag.queued, ak)
				break
			}
		}
	}
	if list, has := ag.fact_activations[fid]; has {
		for ak in list {
			delete_key(&ag.refracted, ak)
			delete_key(&ag.queued, ak)
		}
		delete(list)
		delete_key(&ag.fact_activations, fid)
	}
}

@(private)
_activation_better :: proc(a, b: Activation) -> bool {
	if a.salience != b.salience {
		return a.salience > b.salience
	}
	if a.token.max_recency != b.token.max_recency {
		return a.token.max_recency > b.token.max_recency
	}
	if a.rule_id != b.rule_id {
		return a.rule_id < b.rule_id
	}
	return a.token.fact_sig_hash < b.token.fact_sig_hash
}

@(private)
_pick_next_activation :: proc(s: ^Session) -> (idx: int, found: bool) {
	ag := &s.agenda
	for len(ag.phases) > 0 {
		cur_phase := ag.phases[0]
		best_idx := -1
		for act, i in ag.items {
			if !act.alive || act.phase != cur_phase {
				continue
			}
			if best_idx < 0 || _activation_better(act, ag.items[best_idx]) {
				best_idx = i
			}
		}
		if best_idx >= 0 {
			return best_idx, true
		}
		ordered_remove(&ag.phases, 0)
	}

	best_idx := -1
	for act, i in ag.items {
		if !act.alive {
			continue
		}
		if best_idx < 0 || _activation_better(act, ag.items[best_idx]) {
			best_idx = i
		}
	}
	return best_idx, best_idx >= 0
}

@(private)
_execute_rule_actions :: proc(s: ^Session, rule: Rule_Compiled, tok: ^Beta_Token) -> Session_Error {
	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding
	fslots := _fill_vm_fact_slots(s, tok, fact_slots_buf[:])

	for act in rule.actions {
		#partial switch act.kind {
		case .Assert:
			schema := s.rb.schemas[s.rb.bindings[act.target_bind].schema_id]
			vals := make([]Value, len(schema.fields), context.temp_allocator)
			for fb in act.fields {
				if fb.field_idx >= 0 && int(fb.field_idx) < len(vals) && fb.expr_prog >= 0 {
					v, verr := vm_eval(
						&s.rb.programs[fb.expr_prog],
						tok.vars[:],
						fslots,
						s.rb.tables,
						&s.rb.interner,
						tok.decide_results[:],
						&s.interner,
					)
					if verr != .None {
						return .Vm_Eval_Failed
					}
					vals[fb.field_idx] = v
				}
			}
			key := _next_derived_key(s, act.target_bind)
			origin := Fact_Origin.Unconditional if act.unconditional else Fact_Origin.Logical
			_ = session_insert_fact_by_idx(s, act.target_bind, key, vals, origin) or_return

		case .Retract:
			if act.retract_slot >= 0 && int(act.retract_slot) < int(tok.fact_count) {
				target_fid := tok.fact_ids[act.retract_slot]
				session_retract_fact(s, target_fid) or_return
			}
		}
	}
	return .None
}

// Evaluates all dirty linked segments and fires queued Agenda activations deterministically.
session_fire :: proc(s: ^Session) -> (fired_count: u64, err: Session_Error) {
	if s == nil || s.rb == nil {
		return 0, .Invalid_Arg
	}
	clear(&s.fired_trace)

	for {
		phreak_evaluate_linked_rules(s) or_return

		idx, ok := _pick_next_activation(s)
		if !ok {
			break
		}
		if fired_count >= s.max_activations {
			return fired_count, .Max_Activations_Exceeded
		}

		act := s.agenda.items[idx]
		ordered_remove(&s.agenda.items, idx)
		ak := Activation_Key{rule_id = act.rule_id, tok_hash = act.token.fact_sig_hash}
		delete_key(&s.agenda.queued, ak)

		// Verify all participating facts are still alive right before firing.
		all_alive := true
		for i := 0; i < int(act.token.fact_count); i += 1 {
			if !s.facts[act.token.fact_ids[i]].alive {
				all_alive = false
				break
			}
		}
		if !all_alive {
			continue
		}

		s.agenda.refracted[ak] = true
		rule := s.rb.rules[act.rule_id]
		fired_count += 1
		append(&s.fired_trace, rule.name)
		telemetry_count_add(s.telemetry, .Rules_Fired, 1)

		_execute_rule_actions(s, rule, &act.token) or_return
	}

	return fired_count, .None
}

@(private)
_binding_dot_path :: proc(rb: ^Rulebase, bdef: Binding_Def, buf: []u8) -> string {
	n := 0
	for seg in bdef.segments {
		if seg.kind != .Field {
			continue
		}
		name := interner_get(&rb.interner, seg.text)
		if n + 1 + len(name) > len(buf) {
			break
		}
		buf[n] = '.'
		n += 1
		copy(buf[n:], name)
		n += len(name)
	}
	return string(buf[:n])
}

@(private)
_Commit_Derived_Ctx :: struct {
	sess: ^Session,
}

@(private)
_commit_derived_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Commit_Derived_Ctx)(user_data)
	s := ctx.sess
	path_buf: [256]u8 = ---

	for bdef, bi in s.rb.bindings {
		if bdef.kind != .Derived {
			continue
		}
		path := _binding_dot_path(s.rb, bdef, path_buf[:])
		if len(path) == 0 {
			continue
		}
		col_map, err := store_write_path_ensure_map(moment_wc, path)
		if err != nil {
			return .Write_Failed
		}
		schema := s.rb.schemas[bdef.schema_id]
		for &f in s.facts {
			if !f.alive || f.binding_idx != u16(bi) {
				continue
			}
			kstr := session_string(s, f.key)
			rec_wc := xitdb.hash_map_put_cursor(&col_map, kstr) or_return
			rec_m := xitdb.write_hash_map_init(rec_wc) or_return
			for sf, sfi in schema.fields {
				if sfi >= len(f.fields) || f.fields[sfi] == nil {
					continue
				}
				fname := interner_get(&s.rb.interner, sf.name)
				val := f.fields[sfi]
				switch v in val {
				case bool:
					if b_err := write_bool_to_hash_map(&rec_m, fname, v); b_err != nil {
						return .Write_Failed
					}
				case i32:
					xitdb.hash_map_put(&rec_m, fname, i64(v)) or_return
				case i64:
					xitdb.hash_map_put(&rec_m, fname, v) or_return
				case f64:
					xitdb.hash_map_put(&rec_m, fname, v) or_return
				case String_Id:
					xitdb.hash_map_put(&rec_m, fname, session_string(s, v)) or_return
				case Entity_Id:
					xitdb.hash_map_put(&rec_m, fname, u64(v)) or_return
				case Time_Ns:
					xitdb.hash_map_put(&rec_m, fname, i64(v)) or_return
				case Enum_Val:
					xitdb.hash_map_put(&rec_m, fname, i64(v.variant)) or_return
				}
			}
		}
	}
	return nil
}

// Syncs incremental Z-set deltas from `bridge` into `s`, fires PHREAK + Agenda,
// and optionally commits derived facts back to `bridge` in an atomic xitdb moment.
session_sync_and_fire :: proc(
	s: ^Session,
	bridge: ^Store_Bridge,
	syncer: ^Delta_Syncer,
	commit_derived := false,
) -> (fired_count: u64, err: Store_Error) {
	if s == nil || s.rb == nil || bridge == nil || syncer == nil {
		return 0, .Invalid_Config
	}

	sr: Sync_Result
	delta_syncer_sync(syncer, bridge, &sr) or_return
	defer sync_result_destroy(&sr)

	// Map watched dot paths -> Rulebase source Binding_Def indices cleanly.
	path_buf: [256]u8 = ---
	for d in sr.deltas {
		for bdef, bi in s.rb.bindings {
			if bdef.kind != .Source {
				continue
			}
			bpath := _binding_dot_path(s.rb, bdef, path_buf[:])
			if bpath != d.collection {
				continue
			}
			switch d.kind {
			case .Removed, .Changed_Old:
				_ = session_retract_fact_by_key(s, interner_get(&s.rb.interner, bdef.name), d.key)
			case .Added, .Changed_New:
				if _, ierr := session_insert_cursor_fact(s, u16(bi), d.key, d.new_value); ierr != nil {
					return 0, .Invalid_Config
				}
			}
		}
	}

	cnt, f_err := session_fire(s)
	if f_err != .None {
		return cnt, .Invalid_Config
	}

	if commit_derived {
		cctx := _Commit_Derived_Ctx{sess = s}
		_, c_err := store_bridge_commit_moment(bridge, _commit_derived_tx_cb, &cctx)
		if c_err != nil {
			return cnt, c_err
		}
	}

	_ = fmt.sbprintf
	return cnt, nil
}
