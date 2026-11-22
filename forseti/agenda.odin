package forseti

import "core:mem"

Activation_Key :: struct {
	rule_id:  u32,
	tok_hash: u64,
}

Activation :: struct {
	rule_id:    u32,
	stratum:    u32,
	phase:      String_Id,
	salience:   i32,
	gen:        u32,
	rule_q_idx: u32,
	token:      Beta_Token,
	alive:      bool,
}

Agenda_Heap_Entry :: struct {
	slot_idx:    u32,
	gen:         u32,
	salience:    i32,
	rule_id:     u32,
	max_recency: u64,
	tok_hash:    u64,
}

Agenda_Bucket_Key :: struct {
	stratum: u32,
	phase:   String_Id,
}

Agenda_Queued_Ref :: struct {
	slot_idx: u32,
	gen:      u32,
}

Agenda :: struct {
	slots:             [dynamic]Activation,
	free_slots:        [dynamic]u32,
	next_gen:          u32,
	stratum_heaps:     map[u32][dynamic]Agenda_Heap_Entry,
	phase_heaps:       map[Agenda_Bucket_Key][dynamic]Agenda_Heap_Entry,
	phase_live_counts: map[String_Id]u32,
	queued:            map[Activation_Key]Agenda_Queued_Ref,
	rule_queued:       map[u32][dynamic]Activation_Key,
	refracted:         map[Activation_Key]bool,
	fact_activations:  map[Fact_Id][dynamic]Activation_Key,
	phases:            [dynamic]String_Id,
	allocator:         mem.Allocator,
}

@(private)
agenda_init :: proc(ag: ^Agenda, allocator: mem.Allocator) {
	ag.allocator = allocator
	ag.next_gen = 1
	ag.slots = make([dynamic]Activation, 0, 16, allocator)
	ag.free_slots = make([dynamic]u32, 0, 16, allocator)
	ag.stratum_heaps = make(map[u32][dynamic]Agenda_Heap_Entry, 8, allocator)
	ag.phase_heaps = make(map[Agenda_Bucket_Key][dynamic]Agenda_Heap_Entry, 8, allocator)
	ag.phase_live_counts = make(map[String_Id]u32, 8, allocator)
	ag.queued = make(map[Activation_Key]Agenda_Queued_Ref, 16, allocator)
	ag.rule_queued = make(map[u32][dynamic]Activation_Key, 8, allocator)
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
	for _, list in ag.rule_queued {
		delete(list)
	}
	delete(ag.rule_queued)
	for _, h in ag.phase_heaps {
		delete(h)
	}
	delete(ag.phase_heaps)
	for _, h in ag.stratum_heaps {
		delete(h)
	}
	delete(ag.stratum_heaps)
	delete(ag.phase_live_counts)
	delete(ag.refracted)
	delete(ag.queued)
	delete(ag.free_slots)
	delete(ag.slots)
	delete(ag.phases)
	ag^ = {}
}

@(private)
_heap_entry_better :: #force_inline proc "contextless" (a, b: Agenda_Heap_Entry) -> bool {
	if a.salience != b.salience {
		return a.salience > b.salience
	}
	if a.max_recency != b.max_recency {
		return a.max_recency > b.max_recency
	}
	if a.rule_id != b.rule_id {
		return a.rule_id < b.rule_id
	}
	return a.tok_hash < b.tok_hash
}

@(private)
_agenda_heap_push :: proc(h: ^[dynamic]Agenda_Heap_Entry, entry: Agenda_Heap_Entry) {
	idx := len(h^)
	append(h, entry)
	for idx > 0 {
		parent := (idx - 1) >> 1
		if _heap_entry_better(h^[idx], h^[parent]) {
			h^[idx], h^[parent] = h^[parent], h^[idx]
			idx = parent
		} else {
			break
		}
	}
}

@(private)
_agenda_heap_pop :: proc(h: ^[dynamic]Agenda_Heap_Entry) -> (entry: Agenda_Heap_Entry, ok: bool) {
	n := len(h^)
	if n == 0 {
		return {}, false
	}
	entry = h^[0]
	last := pop(h)
	n -= 1
	if n > 0 {
		h^[0] = last
		idx := 0
		for {
			left := (idx << 1) + 1
			if left >= n {
				break
			}
			best := left
			right := left + 1
			if right < n && _heap_entry_better(h^[right], h^[left]) {
				best = right
			}
			if _heap_entry_better(h^[best], h^[idx]) {
				h^[idx], h^[best] = h^[best], h^[idx]
				idx = best
			} else {
				break
			}
		}
	}
	return entry, true
}

@(private)
_agenda_kill_slot :: proc(ag: ^Agenda, slot_idx: u32) {
	if int(slot_idx) >= len(ag.slots) {
		return
	}
	slot := &ag.slots[slot_idx]
	if !slot.alive {
		return
	}
	slot.alive = false
	slot.gen = ag.next_gen
	ag.next_gen += 1
	if slot.phase != EMPTY_STRING {
		if cnt, has := ag.phase_live_counts[slot.phase]; has && cnt > 0 {
			ag.phase_live_counts[slot.phase] = cnt - 1
		}
	}
	ak := Activation_Key{rule_id = slot.rule_id, tok_hash = slot.token.fact_sig_hash}
	if rq, has_rq := &ag.rule_queued[slot.rule_id]; has_rq {
		idx := int(slot.rule_q_idx)
		last := len(rq^) - 1
		if idx >= 0 && idx <= last {
			if idx != last {
				moved_ak := rq^[last]
				rq^[idx] = moved_ak
				if mref, has_m := ag.queued[moved_ak]; has_m {
					ag.slots[mref.slot_idx].rule_q_idx = u32(idx)
				}
			}
			pop(rq)
		}
	}
	delete_key(&ag.queued, ak)
	append(&ag.free_slots, slot_idx)
}

@(private)
agenda_cancel_key :: proc(ag: ^Agenda, ak: Activation_Key) {
	if qref, has := ag.queued[ak]; has {
		_agenda_kill_slot(ag, qref.slot_idx)
	}
}

@(private)
_agenda_has_active_phase :: proc "contextless" (ag: ^Agenda, phase: String_Id) -> bool {
	if len(ag.phases) == 0 || phase == EMPTY_STRING {
		return false
	}
	for ph in ag.phases {
		if ph == phase {
			return true
		}
	}
	return false
}

@(private)
_agenda_heap_compact :: proc(ag: ^Agenda, h: ^[dynamic]Agenda_Heap_Entry) {
	kept := 0
	for e in h^ {
		if int(e.slot_idx) < len(ag.slots) {
			slot := &ag.slots[e.slot_idx]
			if slot.alive && slot.gen == e.gen {
				h^[kept] = e
				kept += 1
			}
		}
	}
	resize(h, kept)
	if kept <= 1 {
		return
	}
	for start := kept / 2 - 1; start >= 0; start -= 1 {
		idx := start
		for {
			left := (idx << 1) + 1
			if left >= kept {
				break
			}
			best := left
			right := left + 1
			if right < kept && _heap_entry_better(h^[right], h^[left]) {
				best = right
			}
			if _heap_entry_better(h^[best], h^[idx]) {
				h^[idx], h^[best] = h^[best], h^[idx]
				idx = best
			} else {
				break
			}
		}
	}
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
	for _, &h in s.agenda.phase_heaps {
		clear(&h)
	}
	if len(s.agenda.phases) > 0 {
		for &slot, si in s.agenda.slots {
			if !slot.alive || !_agenda_has_active_phase(&s.agenda, slot.phase) {
				continue
			}
			bk := Agenda_Bucket_Key{stratum = slot.stratum, phase = slot.phase}
			ph_h, has_ph := &s.agenda.phase_heaps[bk]
			if !has_ph {
				s.agenda.phase_heaps[bk] = make([dynamic]Agenda_Heap_Entry, 0, 8, s.agenda.allocator)
				ph_h = &s.agenda.phase_heaps[bk]
			}
			_agenda_heap_push(ph_h, Agenda_Heap_Entry{
				slot_idx    = u32(si),
				gen         = slot.gen,
				salience    = slot.salience,
				rule_id     = slot.rule_id,
				max_recency = slot.token.max_recency,
				tok_hash    = slot.token.fact_sig_hash,
			})
		}
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
	rule := s.rb.rules[rule_id]

	slot_idx: u32
	if len(ag.free_slots) > 0 {
		slot_idx = pop(&ag.free_slots)
	} else {
		slot_idx = u32(len(ag.slots))
		append(&ag.slots, Activation{})
	}
	gen := ag.next_gen
	ag.next_gen += 1

	rq, has_rq := &ag.rule_queued[rule_id]
	if !has_rq {
		ag.rule_queued[rule_id] = make([dynamic]Activation_Key, 0, 4, ag.allocator)
		rq = &ag.rule_queued[rule_id]
	}
	rule_q_idx := u32(len(rq^))
	append(rq, ak)

	ag.slots[slot_idx] = Activation{
		rule_id    = rule_id,
		stratum    = rule.stratum,
		phase      = rule.phase,
		salience   = rule.salience,
		gen        = gen,
		rule_q_idx = rule_q_idx,
		token      = tok,
		alive      = true,
	}
	ag.queued[ak] = Agenda_Queued_Ref{slot_idx = slot_idx, gen = gen}

	entry := Agenda_Heap_Entry{
		slot_idx    = slot_idx,
		gen         = gen,
		salience    = rule.salience,
		rule_id     = rule_id,
		max_recency = tok.max_recency,
		tok_hash    = tok.fact_sig_hash,
	}
	sh, has_sh := &ag.stratum_heaps[rule.stratum]
	if !has_sh {
		ag.stratum_heaps[rule.stratum] = make([dynamic]Agenda_Heap_Entry, 0, 16, ag.allocator)
		sh = &ag.stratum_heaps[rule.stratum]
	}
	if len(sh^) > 2 * len(ag.queued) + 64 {
		_agenda_heap_compact(ag, sh)
	}
	_agenda_heap_push(sh, entry)

	if rule.phase != EMPTY_STRING {
		ag.phase_live_counts[rule.phase] = ag.phase_live_counts[rule.phase] + 1
		if _agenda_has_active_phase(ag, rule.phase) {
			bk := Agenda_Bucket_Key{stratum = rule.stratum, phase = rule.phase}
			ph_h, has_ph := &ag.phase_heaps[bk]
			if !has_ph {
				ag.phase_heaps[bk] = make([dynamic]Agenda_Heap_Entry, 0, 8, ag.allocator)
				ph_h = &ag.phase_heaps[bk]
			}
			if len(ph_h^) > 2 * int(ag.phase_live_counts[rule.phase]) + 64 {
				_agenda_heap_compact(ag, ph_h)
			}
			_agenda_heap_push(ph_h, entry)
		}
	}

	for i := 0; i < int(tok.fact_count); i += 1 {
		fid := tok.fact_ids[i]
		list, has := &ag.fact_activations[fid]
		if !has {
			ag.fact_activations[fid] = make([dynamic]Activation_Key, 0, 4, ag.allocator)
			list = &ag.fact_activations[fid]
		}
		already := false
		if len(list^) <= 8 {
			for prev in list^ {
				if prev == ak {
					already = true
					break
				}
			}
		}
		if !already {
			if len(list^) == cap(list^) {
				kept := 0
				for prev in list^ {
					if (prev in ag.queued) || (prev in ag.refracted) {
						list^[kept] = prev
						kept += 1
					}
				}
				resize(list, kept)
			}
			append(list, ak)
		}
	}
}

@(private)
agenda_remove_fact :: proc(ag: ^Agenda, fid: Fact_Id) {
	if list, has := &ag.fact_activations[fid]; has {
		for ak in list^ {
			if qref, is_q := ag.queued[ak]; is_q {
				_agenda_kill_slot(ag, qref.slot_idx)
			}
			delete_key(&ag.refracted, ak)
		}
		clear(list)
	}
}

@(private)
agenda_cancel_rule_not_in_set :: proc(ag: ^Agenda, rule_id: u32, live_hashes: map[u64]bool) {
	rq, has := &ag.rule_queued[rule_id]
	if !has || len(rq^) == 0 {
		return
	}
	for i := len(rq^) - 1; i >= 0; i -= 1 {
		ak := rq^[i]
		if !(ak.tok_hash in live_hashes) {
			if qref, has_q := ag.queued[ak]; has_q {
				_agenda_kill_slot(ag, qref.slot_idx)
			}
		}
	}
}

@(private)
_agenda_pop_live_from_heap :: proc(ag: ^Agenda, h: ^[dynamic]Agenda_Heap_Entry) -> (act: Activation, found: bool) {
	for {
		entry, ok := _agenda_heap_pop(h)
		if !ok {
			return {}, false
		}
		if int(entry.slot_idx) >= len(ag.slots) {
			continue
		}
		slot := &ag.slots[entry.slot_idx]
		if !slot.alive || slot.gen != entry.gen {
			continue
		}
		act = slot^
		_agenda_kill_slot(ag, entry.slot_idx)
		return act, true
	}
}

@(private)
_agenda_pop_for_stratum :: proc(s: ^Session, stratum: u32) -> (act: Activation, found: bool) {
	ag := &s.agenda

	if len(ag.phases) > 0 {
		for cur_phase in ag.phases {
			bk := Agenda_Bucket_Key{stratum = stratum, phase = cur_phase}
			if ph_h, has_ph := &ag.phase_heaps[bk]; has_ph {
				if popped, ok := _agenda_pop_live_from_heap(ag, ph_h); ok {
					return popped, true
				}
			}
		}
	}

	if sh, has_sh := &ag.stratum_heaps[stratum]; has_sh {
		return _agenda_pop_live_from_heap(ag, sh)
	}
	return {}, false
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
			vals_buf: [32]Value
			vals: []Value
			if len(schema.fields) <= len(vals_buf) {
				vals = vals_buf[:len(schema.fields)]
			} else {
				vals = make([]Value, len(schema.fields), context.temp_allocator)
			}
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

// Formats the dot-separated collection path (e.g. ".orgs.raw") for `binding_idx` into `buf`.
rulebase_binding_dot_path :: proc(rb: ^Rulebase, binding_idx: u16, buf: []u8) -> string {
	if rb == nil || int(binding_idx) >= len(rb.bindings) {
		return ""
	}
	return _binding_dot_path(rb, rb.bindings[binding_idx], buf)
}

// Resolves a binding index by name on a compiled Rulebase.
rulebase_find_binding :: proc(rb: ^Rulebase, name: string) -> (u16, bool) {
	if rb == nil {
		return 0, false
	}
	sid, ok := rb.interner.lookup[name]
	if !ok {
		return 0, false
	}
	bidx, has := rb.binding_by_name[sid]
	return bidx, has
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
