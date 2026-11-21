package forseti

import "core:mem"

Firing_Key :: struct {
	rule_id:  u32,
	tok_hash: u64,
}

Justification :: struct {
	id:           u32,
	rule_id:      u32,
	firing_key:   Firing_Key,
	derived_fact: Fact_Id,
	deriv_id:     Derivation_Id,
	parent_start: u32,
	parent_count: u16,
	proof_height: u32,
	alive:        bool,
}

Active_Firing :: struct {
	key:        Firing_Key,
	rule_id:    u32,
	just_ids:   [dynamic]u32,
	deriv_ids:  [dynamic]Derivation_Id,
	alive:      bool,
}

Jtms_State :: struct {
	justs:            [dynamic]Justification,
	just_parents:     [dynamic]Fact_Id,
	fact_justs:       map[Fact_Id][dynamic]u32, // derived_fact -> list of justification IDs supporting it
	premise_to_justs: map[Fact_Id][dynamic]u32, // premise_fact -> list of justification IDs depending on it
	active_firings:   map[Firing_Key]Active_Firing,
	rule_firings:     map[u32][dynamic]Firing_Key,
	allocator:        mem.Allocator,
}

@(private)
jtms_init :: proc(j: ^Jtms_State, allocator: mem.Allocator) {
	j^ = {}
	j.allocator = allocator
	j.justs = make([dynamic]Justification, 1, 16, allocator) // slot 0 = sentinel
	j.just_parents = make([dynamic]Fact_Id, 0, 32, allocator)
	j.fact_justs = make(map[Fact_Id][dynamic]u32, 16, allocator)
	j.premise_to_justs = make(map[Fact_Id][dynamic]u32, 16, allocator)
	j.active_firings = make(map[Firing_Key]Active_Firing, 16, allocator)
	j.rule_firings = make(map[u32][dynamic]Firing_Key, 8, allocator)
}

@(private)
jtms_destroy :: proc(j: ^Jtms_State) {
	if j == nil || j.allocator.procedure == nil {
		return
	}
	for _, list in j.fact_justs {
		delete(list)
	}
	delete(j.fact_justs)
	for _, list in j.premise_to_justs {
		delete(list)
	}
	delete(j.premise_to_justs)
	for _, af in j.active_firings {
		delete(af.just_ids)
		delete(af.deriv_ids)
	}
	delete(j.active_firings)
	for _, flist in j.rule_firings {
		delete(flist)
	}
	delete(j.rule_firings)
	delete(j.just_parents)
	delete(j.justs)
	j^ = {}
}

@(private)
_compute_fact_content_hash :: proc(s: ^Session, binding_idx: u16, fields: []Value) -> u64 {
	h := u64(0x4c4f4749) // "LOGI"
	h = _hash_combine64(h, u64(binding_idx))
	h = _hash_combine64(h, u64(len(fields)))
	for v in fields {
		if v == nil {
			h = _hash_combine64(h, 0xdeadbeef)
			continue
		}
		h = _hash_combine64(h, _hash_value_key(s, v))
	}
	return h
}

@(private)
_fact_fields_equal :: proc(s: ^Session, a, b: []Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		va := a[i]
		vb := b[i]
		if va == nil && vb == nil {
			continue
		}
		if va == nil || vb == nil {
			return false
		}
		if !_join_values_equal(s, va, vb) {
			return false
		}
	}
	return true
}

@(private)
_find_matching_logical_fact :: proc(
	s: ^Session,
	binding_idx: u16,
	norm_fields: []Value,
	chash: u64,
) -> (fid: Fact_Id, ok: bool) {
	bucket, has := s.logical_buckets[chash]
	if !has {
		return INVALID_FACT, false
	}
	for cand in bucket {
		cf := &s.facts[cand]
		if !cf.alive || cf.origin != .Logical || cf.binding_idx != binding_idx {
			continue
		}
		if _fact_fields_equal(s, cf.fields, norm_fields) {
			return cand, true
		}
	}
	return INVALID_FACT, false
}

@(private)
jtms_remove_logical_bucket_entry :: proc(s: ^Session, fid: Fact_Id) {
	f := &s.facts[fid]
	bucket, has := &s.logical_buckets[f.content_hash]
	if !has {
		return
	}
	for entry, i in bucket^ {
		if entry == fid {
			unordered_remove(bucket, i)
			break
		}
	}
	if len(bucket^) == 0 {
		delete(bucket^)
		delete_key(&s.logical_buckets, f.content_hash)
	}
}

@(private)
_jtms_register_firing :: proc(s: ^Session, fkey: Firing_Key) -> ^Active_Firing {
	if existing, has := &s.jtms.active_firings[fkey]; has {
		if !existing.alive {
			existing.alive = true
			clear(&existing.just_ids)
			clear(&existing.deriv_ids)
		}
		return existing
	}
	s.jtms.active_firings[fkey] = Active_Firing{
		key       = fkey,
		rule_id   = fkey.rule_id,
		just_ids  = make([dynamic]u32, 0, 2, s.allocator),
		deriv_ids = make([dynamic]Derivation_Id, 0, 2, s.allocator),
		alive     = true,
	}
	rlist, has_r := &s.jtms.rule_firings[fkey.rule_id]
	if !has_r {
		s.jtms.rule_firings[fkey.rule_id] = make([dynamic]Firing_Key, 0, 4, s.allocator)
		rlist = &s.jtms.rule_firings[fkey.rule_id]
	}
	append(rlist, fkey)
	return &s.jtms.active_firings[fkey]
}

// Records a rule firing with zero logical assertions (e.g. Assert!, Retract, Effect) so revocation clears refraction.
@(private)
jtms_track_firing_only :: proc(s: ^Session, fkey: Firing_Key, deriv_id := INVALID_DERIVATION) {
	af := _jtms_register_firing(s, fkey)
	if deriv_id != INVALID_DERIVATION {
		append(&af.deriv_ids, deriv_id)
	}
}

@(private)
_rule_ver_u16 :: proc(s: ^Session, rule_id: u32) -> u16 {
	return u16((rule_id + 1) & 0xffff)
}

// Asserts a logical fact via Z-set JTMS: deduplicates identical logical content,
// increments support weight, tracks Soufflé proof_height, and records Derivation provenance.
@(private)
jtms_assert_logical :: proc(
	s: ^Session,
	rule_id: u32,
	fkey: Firing_Key,
	binding_idx: u16,
	raw_fields: []Value,
	parent_facts: []Fact_Id,
	table_idx: u16 = INVALID_TABLE_IDX,
	table_row_id: u16 = INVALID_ROW_ID,
) -> (
	fid: Fact_Id,
	is_new: bool,
	height_improved: bool,
	deriv_id: Derivation_Id,
	err: Session_Error,
) {
	bdef := s.rb.bindings[binding_idx]
	schema := s.rb.schemas[bdef.schema_id]
	norm_fields := _normalize_fact_fields(s, schema, raw_fields)
	chash := _compute_fact_content_hash(s, binding_idx, norm_fields)

	// Compute candidate proof_height = 1 + max(parent proof_heights).
	max_p_h := u32(0)
	for pfid in parent_facts {
		if pfid != INVALID_FACT && int(pfid) < len(s.facts) && s.facts[pfid].alive {
			ph := s.facts[pfid].proof_height
			if ph > max_p_h {
				max_p_h = ph
			}
		}
	}
	new_height := max_p_h + 1

	existing_fid, found := _find_matching_logical_fact(s, binding_idx, norm_fields, chash)
	if found {
		delete(norm_fields, s.allocator)
		fid = existing_fid
		ef := &s.facts[fid]

		// Check if already justified by the exact same firing_key while alive.
		if fjusts, has_fj := s.jtms.fact_justs[fid]; has_fj {
			for jid in fjusts {
				if s.jtms.justs[jid].alive && s.jtms.justs[jid].firing_key == fkey {
					return fid, false, false, s.jtms.justs[jid].deriv_id, .None
				}
			}
		}
		ef.support_count += 1
		if new_height < ef.proof_height || ef.proof_height == 0 {
			ef.proof_height = new_height
			height_improved = true
		}
	} else {
		is_new = true
		key := _next_derived_key(s, binding_idx)
		key_id, k_err := intern_session_string(&s.rb.interner, &s.interner, key)
		if k_err != nil {
			delete(norm_fields, s.allocator)
			return INVALID_FACT, false, false, INVALID_DERIVATION, .Alloc_Failed
		}

		fid = Fact_Id(len(s.facts))
		recency := s.next_recency
		s.next_recency += 1
		append(&s.facts, Fact{
			id            = fid,
			binding_idx   = binding_idx,
			key           = key_id,
			fields        = norm_fields,
			recency       = recency,
			alive         = true,
			support_count = 1,
			proof_height  = new_height,
			content_hash  = chash,
			origin        = .Logical,
		})
		s.facts_by_key[Fact_Lookup_Key{binding_idx = binding_idx, key = key_id}] = fid

		bucket, has_b := &s.logical_buckets[chash]
		if !has_b {
			s.logical_buckets[chash] = make([dynamic]Fact_Id, 0, 2, s.allocator)
			bucket = &s.logical_buckets[chash]
		}
		append(bucket, fid)
	}

	deriv_id = provenance_record(
		&s.provenance,
		s.telemetry,
		fid,
		rule_id,
		_rule_ver_u16(s, rule_id),
		parent_facts,
		new_height,
		.Logical,
		table_idx,
		table_row_id,
	)
	if deriv_id != INVALID_DERIVATION && (is_new || height_improved || s.facts[fid].best_derivation == INVALID_DERIVATION) {
		s.facts[fid].best_derivation = deriv_id
	}

	// Register JTMS Justification & premise links.
	p_start := u32(len(s.jtms.just_parents))
	for pf in parent_facts {
		append(&s.jtms.just_parents, pf)
	}
	jid := u32(len(s.jtms.justs))
	append(&s.jtms.justs, Justification{
		id           = jid,
		rule_id      = rule_id,
		firing_key   = fkey,
		derived_fact = fid,
		deriv_id     = deriv_id,
		parent_start = p_start,
		parent_count = u16(min(len(parent_facts), int(max(u16)))),
		proof_height = new_height,
		alive        = true,
	})

	fj_list, has_fj := &s.jtms.fact_justs[fid]
	if !has_fj {
		s.jtms.fact_justs[fid] = make([dynamic]u32, 0, 2, s.allocator)
		fj_list = &s.jtms.fact_justs[fid]
	}
	append(fj_list, jid)

	for pf in parent_facts {
		pj_list, has_pj := &s.jtms.premise_to_justs[pf]
		if !has_pj {
			s.jtms.premise_to_justs[pf] = make([dynamic]u32, 0, 4, s.allocator)
			pj_list = &s.jtms.premise_to_justs[pf]
		}
		append(pj_list, jid)
	}

	af := _jtms_register_firing(s, fkey)
	append(&af.just_ids, jid)
	if deriv_id != INVALID_DERIVATION {
		append(&af.deriv_ids, deriv_id)
	}

	if is_new {
		alpha_eval_insert_fact(s, fid)
		s.stratum_changed = true
	} else if height_improved {
		s.stratum_changed = true
	}

	return fid, is_new, height_improved, deriv_id, .None
}

// Performs cycle-safe groundedness JTMS propagation after justifications or facts become dead.
@(private)
jtms_cascade_from_affected_facts :: proc(s: ^Session, seed_facts: []Fact_Id) {
	if len(seed_facts) == 0 {
		return
	}
	scope := telemetry_span_begin(s.telemetry, .Tms, "jtms_cascade")
	defer telemetry_span_end(s.telemetry, scope)

	// Step 1: Collect reachable forward cone S of currently-alive Logical facts downstream of `seed_facts`.
	in_cone := make(map[Fact_Id]bool, 16, context.temp_allocator)
	cone_list := make([dynamic]Fact_Id, 0, 16, context.temp_allocator)
	bfs := make([dynamic]Fact_Id, 0, 16, context.temp_allocator)

	for sf in seed_facts {
		if sf == INVALID_FACT || int(sf) >= len(s.facts) {
			continue
		}
		if s.facts[sf].alive && s.facts[sf].origin == .Logical {
			if !(sf in in_cone) {
				in_cone[sf] = true
				append(&cone_list, sf)
				append(&bfs, sf)
			}
		} else if !s.facts[sf].alive {
			// If seed itself was retracted externally, its direct dependents enter the cone via premise_to_justs.
			if pjusts, has_pj := s.jtms.premise_to_justs[sf]; has_pj {
				for jid in pjusts {
					df := s.jtms.justs[jid].derived_fact
					if df != INVALID_FACT && int(df) < len(s.facts) && s.facts[df].alive && s.facts[df].origin == .Logical {
						if !(df in in_cone) {
							in_cone[df] = true
							append(&cone_list, df)
							append(&bfs, df)
						}
					}
				}
			}
		}
	}

	for bi := 0; bi < len(bfs); bi += 1 {
		cur := bfs[bi]
		if pjusts, has_pj := s.jtms.premise_to_justs[cur]; has_pj {
			for jid in pjusts {
				j := s.jtms.justs[jid]
				df := j.derived_fact
				if df == INVALID_FACT || int(df) >= len(s.facts) {
					continue
				}
				if s.facts[df].alive && s.facts[df].origin == .Logical && !(df in in_cone) {
					in_cone[df] = true
					append(&cone_list, df)
					append(&bfs, df)
				}
			}
		}
	}

	if len(cone_list) == 0 {
		return
	}

	// Step 2 & 3: Re-compute minimal grounded support bottom-up from outside `in_cone` -> fixes diamonds & breaks ghost cycles!
	grounded := make(map[Fact_Id]bool, len(cone_list), context.temp_allocator)
	best_h := make(map[Fact_Id]u32, len(cone_list), context.temp_allocator)
	best_deriv := make(map[Fact_Id]Derivation_Id, len(cone_list), context.temp_allocator)
	worklist := make([dynamic]Fact_Id, 0, len(cone_list), context.temp_allocator)

	_eval_just_grounded :: proc(
		s: ^Session,
		j: Justification,
		in_cone: map[Fact_Id]bool,
		grounded: map[Fact_Id]bool,
		best_h: map[Fact_Id]u32,
	) -> (ok: bool, height: u32) {
		if !j.alive {
			return false, 0
		}
		max_p := u32(0)
		start := int(j.parent_start)
		end := start + int(j.parent_count)
		for i := start; i < end; i += 1 {
			pf := s.jtms.just_parents[i]
			if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
				return false, 0
			}
			ph := s.facts[pf].proof_height
			if pf in in_cone {
				if !(pf in grounded) {
					return false, 0
				}
				ph = best_h[pf]
			}
			if ph > max_p {
				max_p = ph
			}
		}
		return true, max_p + 1
	}

	// Initial pass: seed facts justified purely from outside `in_cone`.
	for cf in cone_list {
		if fjusts, has_fj := s.jtms.fact_justs[cf]; has_fj {
			for jid in fjusts {
				j := s.jtms.justs[jid]
				ok, h := _eval_just_grounded(s, j, in_cone, grounded, best_h)
				if ok {
					prev_g := cf in grounded
					if !prev_g || h < best_h[cf] {
						grounded[cf] = true
						best_h[cf] = h
						best_deriv[cf] = j.deriv_id
						if !prev_g {
							append(&worklist, cf)
						}
					}
				}
			}
		}
	}

	// Step 4: Propagate groundedness forward cleanly inside the cone (min proof_height convergence).
	for wi := 0; wi < len(worklist); wi += 1 {
		pf := worklist[wi]
		if pjusts, has_pj := s.jtms.premise_to_justs[pf]; has_pj {
			for jid in pjusts {
				j := s.jtms.justs[jid]
				df := j.derived_fact
				if !(df in in_cone) {
					continue
				}
				ok, h := _eval_just_grounded(s, j, in_cone, grounded, best_h)
				if ok {
					prev_g := df in grounded
					if !prev_g || h < best_h[df] {
						grounded[df] = true
						best_h[df] = h
						best_deriv[df] = j.deriv_id
						append(&worklist, df)
					}
				}
			}
		}
	}

	// Step 5: Any fact in `cone_list` still not grounded has zero acyclic support -> retract atomically!
	to_retract := make([dynamic]Fact_Id, 0, len(cone_list), context.temp_allocator)
	for cf in cone_list {
		if cf in grounded {
			f := &s.facts[cf]
			f.proof_height = best_h[cf]
			if bd := best_deriv[cf]; bd != INVALID_DERIVATION {
				f.best_derivation = bd
			}
			// Recompute exact alive support_count.
			cnt := i32(0)
			if fjusts, has_fj := s.jtms.fact_justs[cf]; has_fj {
				for jid in fjusts {
					j := &s.jtms.justs[jid]
					if j.alive {
						ok, jh := _eval_just_grounded(s, j^, in_cone, grounded, best_h)
						if ok {
							cnt += 1
							j.proof_height = jh
						}
					}
				}
			}
			f.support_count = cnt
		} else {
			append(&to_retract, cf)
		}
	}

	if len(to_retract) == 0 {
		return
	}

	for rf in to_retract {
		f := &s.facts[rf]
		if !f.alive {
			continue
		}
		f.alive = false
		f.support_count = 0
		lk := Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}
		if cur, has := s.facts_by_key[lk]; has && cur == rf {
			delete_key(&s.facts_by_key, lk)
		}
		jtms_remove_logical_bucket_entry(s, rf)

		if fjusts, has_fj := s.jtms.fact_justs[rf]; has_fj {
			for jid in fjusts {
				j := &s.jtms.justs[jid]
				if j.alive {
					j.alive = false
					provenance_mark_retracted(&s.provenance, j.deriv_id)
				}
			}
		}
		// Mark outgoing justifications & rule firings dead so refraction stays clean.
		if pjusts, has_pj := s.jtms.premise_to_justs[rf]; has_pj {
			for jid in pjusts {
				j := &s.jtms.justs[jid]
				j.alive = false
				provenance_mark_retracted(&s.provenance, j.deriv_id)
				if af, has_af := &s.jtms.active_firings[j.firing_key]; has_af {
					af.alive = false
				}
			}
		}

		alpha_eval_retract_fact(s, rf)
		agenda_remove_fact(&s.agenda, rf)
		telemetry_count_add(s.telemetry, .Jtms_Retractions, 1)
		s.stratum_changed = true
	}
}

@(private)
jtms_retract_cascades_for_fact :: proc(s: ^Session, fid: Fact_Id) {
	if s == nil {
		return
	}
	affected := make([dynamic]Fact_Id, 0, 8, context.temp_allocator)
	if pjusts, has_pj := s.jtms.premise_to_justs[fid]; has_pj {
		for jid in pjusts {
			j := &s.jtms.justs[jid]
			if j.alive {
				j.alive = false
				provenance_mark_retracted(&s.provenance, j.deriv_id)
				if af, has_af := &s.jtms.active_firings[j.firing_key]; has_af {
					af.alive = false
				}
				df := j.derived_fact
				if df != INVALID_FACT && int(df) < len(s.facts) && s.facts[df].alive && s.facts[df].origin == .Logical {
					append(&affected, df)
				}
			}
		}
	}
	if len(affected) > 0 {
		jtms_cascade_from_affected_facts(s, affected[:])
	}
}

// Revokes a previously active rule firing (e.g. due to Not/Exists/Accum change or unlink).
@(private)
jtms_revoke_firing :: proc(s: ^Session, fkey: Firing_Key) {
	delete_key(&s.agenda.refracted, Activation_Key{rule_id = fkey.rule_id, tok_hash = fkey.tok_hash})
	delete_key(&s.agenda.queued, Activation_Key{rule_id = fkey.rule_id, tok_hash = fkey.tok_hash})

	af, has := &s.jtms.active_firings[fkey]
	if !has || !af.alive {
		return
	}
	af.alive = false

	affected := make([dynamic]Fact_Id, 0, len(af.just_ids), context.temp_allocator)
	for jid in af.just_ids {
		j := &s.jtms.justs[jid]
		if j.alive {
			j.alive = false
			provenance_mark_retracted(&s.provenance, j.deriv_id)
			df := j.derived_fact
			if df != INVALID_FACT && int(df) < len(s.facts) && s.facts[df].alive && s.facts[df].origin == .Logical {
				append(&affected, df)
			}
		}
	}
	for did in af.deriv_ids {
		provenance_mark_retracted(&s.provenance, did)
	}
	if len(affected) > 0 {
		jtms_cascade_from_affected_facts(s, affected[:])
	}
}

@(private)
jtms_revoke_all_rule_firings :: proc(s: ^Session, rule_id: u32) {
	flist, has := s.jtms.rule_firings[rule_id]
	if !has {
		return
	}
	// Copy keys before iteration because cascade may inspect active_firings.
	keys := make([dynamic]Firing_Key, len(flist), context.temp_allocator)
	copy(keys[:], flist[:])
	for fk in keys {
		jtms_revoke_firing(s, fk)
	}
}
