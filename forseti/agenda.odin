package forseti

import "core:mem"

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
_pick_next_activation_for_stratum :: proc(s: ^Session, stratum: u32, check_stratum := true) -> (idx: int, found: bool) {
	ag := &s.agenda
	rule_matches := proc(s: ^Session, rule_id: u32, stratum: u32, check_stratum: bool) -> bool {
		if !check_stratum {
			return true
		}
		return int(rule_id) < len(s.rb.rules) && s.rb.rules[rule_id].stratum == stratum
	}

	// Only consume phase focus entries once all rules or current phase finishes across strata,
	// or pick highest matching activation in current phase first without dropping phase prematurely
	// if rules in that phase exist in higher strata.
	if len(ag.phases) > 0 {
		for pi := 0; pi < len(ag.phases); {
			cur_phase := ag.phases[pi]
			best_idx := -1
			any_in_phase := false
			for act, i in ag.items {
				if !act.alive || act.phase != cur_phase {
					continue
				}
				any_in_phase = true
				if !rule_matches(s, act.rule_id, stratum, check_stratum) {
					continue
				}
				if best_idx < 0 || _activation_better(act, ag.items[best_idx]) {
					best_idx = i
				}
			}
			if best_idx >= 0 {
				return best_idx, true
			}
			// Do not remove phase if activations in another stratum remain for it, or check if higher stratum needs it:
			has_pending_in_rb_later := false
			if check_stratum {
				for r in s.rb.rules {
					if r.phase == cur_phase && r.stratum > stratum {
						has_pending_in_rb_later = true
						break
					}
				}
			}
			if any_in_phase || has_pending_in_rb_later {
				pi += 1
				continue
			}
			ordered_remove(&ag.phases, pi)
		}
	}

	best_idx := -1
	for act, i in ag.items {
		if !act.alive || !rule_matches(s, act.rule_id, stratum, check_stratum) {
			continue
		}
		if best_idx < 0 || _activation_better(act, ag.items[best_idx]) {
			best_idx = i
		}
	}
	return best_idx, best_idx >= 0
}

@(private)
_pick_next_activation :: proc(s: ^Session) -> (idx: int, found: bool) {
	return _pick_next_activation_for_stratum(s, 0, check_stratum = false)
}

@(private)
_execute_rule_actions :: proc(s: ^Session, rule: Rule_Compiled, tok: ^Beta_Token) -> Session_Error {
	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding
	fslots := _fill_vm_fact_slots(s, tok, fact_slots_buf[:])

	fkey := Firing_Key{rule_id = rule.id, tok_hash = tok.fact_sig_hash}
	parents := tok.fact_ids[:tok.fact_count]
	primary_deriv := INVALID_DERIVATION

	tidx := rule.decide_table_idx
	trow := INVALID_ROW_ID
	if rule.decide_slots > 0 && tok.decide_results[0].matched && tok.decide_results[0].trace.winning_row_idx >= 0 {
		trow = u16(tok.decide_results[0].trace.winning_row_idx)
	}

	had_logical := false
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
			if !act.unconditional {
				_, _, _, did, j_err := jtms_assert_logical(
					s,
					rule.id,
					fkey,
					act.target_bind,
					vals,
					parents,
					tidx,
					trow,
				)
				if j_err != .None {
					return j_err
				}
				had_logical = true
				if primary_deriv == INVALID_DERIVATION {
					primary_deriv = did
				}
			} else {
				key := _next_derived_key(s, act.target_bind)
				fid := session_insert_fact_by_idx(s, act.target_bind, key, vals, .Unconditional) or_return
				max_ph := u32(0)
				for pf in parents {
					if pf != INVALID_FACT && int(pf) < len(s.facts) && s.facts[pf].alive && s.facts[pf].proof_height > max_ph {
						max_ph = s.facts[pf].proof_height
					}
				}
				s.facts[fid].proof_height = max_ph + 1
				did := provenance_record(
					&s.provenance,
					s.telemetry,
					fid,
					rule.id,
					_rule_ver_u16(s, rule.id),
					parents,
					max_ph + 1,
					.Unconditional,
					tidx,
					trow,
				)
				if did != INVALID_DERIVATION {
					s.facts[fid].best_derivation = did
					if primary_deriv == INVALID_DERIVATION {
						primary_deriv = did
					}
				}
				jtms_track_firing_only(s, fkey, did)
			}

		case .Retract:
			jtms_track_firing_only(s, fkey)
			if act.retract_slot >= 0 && int(act.retract_slot) < int(tok.fact_count) {
				target_fid := tok.fact_ids[act.retract_slot]
				session_retract_fact(s, target_fid) or_return
			}

		case .Effect:
			if primary_deriv == INVALID_DERIVATION && !had_logical {
				primary_deriv = provenance_record(
					&s.provenance,
					s.telemetry,
					INVALID_FACT,
					rule.id,
					_rule_ver_u16(s, rule.id),
					parents,
					1,
					.Logical,
					tidx,
					trow,
				)
			}
			jtms_track_firing_only(s, fkey, primary_deriv if !had_logical else INVALID_DERIVATION)
			effects_stage_job(s, rule, act, tok, fslots, primary_deriv) or_return
		}
	}
	return .None
}

// Evaluates stratified dirty segments and fires queued Agenda activations to fixed point.
session_fire :: proc(s: ^Session) -> (fired_count: u64, err: Session_Error) {
	if s == nil || s.rb == nil {
		return 0, .Invalid_Arg
	}
	clear(&s.fired_trace)
	provenance_begin_tx(&s.provenance)

	strata := max(s.rb.strata_count, u32(1))
	st := u32(0)
	for st < strata {
		s.earliest_dirty_strat = max(u32)
		session_fire_stratum(s, st, &fired_count) or_return
		if s.earliest_dirty_strat < st {
			st = s.earliest_dirty_strat
			continue
		}
		st += 1
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

// Syncs incremental Z-set deltas from `bridge` into `s`, fires PHREAK + Agenda,
// and optionally commits derived facts and Audit_Full provenance back to `bridge` in an atomic xitdb moment.
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
		_, c_err := session_commit_derived_and_audit(s, bridge)
		if c_err != nil {
			return cnt, c_err
		}
	}

	return cnt, nil
}
