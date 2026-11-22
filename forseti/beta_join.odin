package forseti

import "core:encoding/endian"

MAX_TOKEN_FACTS :: 16
MAX_TOKEN_VARS  :: 32

Beta_Token :: struct {
	fact_ids:       [MAX_TOKEN_FACTS]Fact_Id,
	fact_count:     u8,
	vars:           [MAX_TOKEN_VARS]Value,
	decide_results: [4]Decision_Result,
	max_recency:    u64,
	fact_sig_hash:  u64,
}

@(private)
_hash_combine64 :: #force_inline proc "contextless" (h, x: u64) -> u64 {
	z := h ~ (x + 0x9e3779b97f4a7c15 + (h << 6) + (h >> 2))
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	return z ~ (z >> 27)
}

@(private)
_hash_value_key :: proc(s: ^Session, v: Value) -> u64 {
	if vk, ok := value_key_from_runtime_value(v, &s.rb.interner, &s.interner); ok {
		if vk.kind == .String && vk.raw == u64(INVALID_ID) {
			txt := session_string(s, v.(String_Id))
			b := transmute([]u8)txt
			h := u64(0x73747200) ~ u64(len(b))
			i := 0
			for i + 8 <= len(b) {
				w, _ := endian.get_u64(b[i:i + 8], .Little)
				h = _hash_combine64(h, w)
				i += 8
			}
			for i < len(b) {
				h = _hash_combine64(h, u64(b[i]))
				i += 1
			}
			return h
		}
		return _hash_combine64(u64(vk.kind), vk.raw)
	}
	return 0
}

@(private)
_join_values_equal :: proc(s: ^Session, a, b: Value) -> bool {
	dummy_vm := Vm_State{interner = &s.rb.interner, sess_interner = &s.interner}
	eq, err := _vm_eval_cmp_values(&dummy_vm, a, b, .Eq)
	return err == .None && eq
}

@(private)
_beta_get_or_create_mem :: proc(s: ^Session, node_id: u32) -> ^Beta_Memory {
	if bm, has := s.beta_mems[node_id]; has {
		return bm
	}
	bm := new(Beta_Memory, s.allocator)
	bm.node_id = node_id
	bm.right_alpha_version = max(u64) // Force initial index build on first join
	bm.right_retract_epoch = max(u64)
	bm.right_insert_epoch = 0
	bm.indexed_count = 0
	bm.right_facts = make([dynamic]Fact_Id, 0, 8, s.allocator)
	bm.right_fact_pos = make(map[Fact_Id]int, 8, s.allocator)
	bm.right_buckets = make(map[u64][dynamic]Fact_Id, 8, s.allocator)
	bm.right_bucket_hash = make(map[Fact_Id]u64, 8, s.allocator)
	bm.left_retract_epoch = max(u64)
	bm.left_buckets = make(map[u64][dynamic]Fact_Id, 8, s.allocator)
	bm.left_bucket_hash = make(map[Fact_Id]u64, 8, s.allocator)
	s.beta_mems[node_id] = bm
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return bm
}

@(private)
_alpha_collect_delta_window :: proc(
	s: ^Session,
	am: ^Alpha_Memory,
	prev_retract_epoch: u64,
	prev_insert_epoch: u64,
	prev_len: int,
	ins_buf: ^[MAX_ALPHA_DELTA_LOG]Fact_Id,
) -> (
	can_delta: bool,
	append_only: bool,
	inserts: []Fact_Id,
	retract_start: u64,
	retract_end: u64,
) {
	if prev_retract_epoch == max(u64) {
		return false, false, nil, 0, 0
	}
	if prev_retract_epoch == am.retract_epoch && prev_len <= len(am.fact_ids) {
		return true, true, am.fact_ids[prev_len:], 0, 0
	}
	if am.retract_epoch >= prev_retract_epoch &&
	   (am.retract_epoch - prev_retract_epoch) <= MAX_ALPHA_DELTA_LOG &&
	   am.insert_epoch >= prev_insert_epoch &&
	   (am.insert_epoch - prev_insert_epoch) <= MAX_ALPHA_DELTA_LOG {
		cnt := 0
		for e := prev_insert_epoch; e < am.insert_epoch; e += 1 {
			fid := am.recent_inserts[e % MAX_ALPHA_DELTA_LOG]
			if !s.facts[fid].alive || !(fid in am.fact_pos) {
				continue
			}
			dup := false
			for j := 0; j < cnt; j += 1 {
				if ins_buf[j] == fid {
					dup = true
					break
				}
			}
			if !dup {
				ins_buf[cnt] = fid
				cnt += 1
			}
		}
		return true, false, ins_buf[:cnt], prev_retract_epoch, am.retract_epoch
	}
	return false, false, nil, 0, 0
}

@(private)
_beta_hash_right_fact :: proc(s: ^Session, join_keys: []Join_Key_Pair, f: ^Fact) -> u64 {
	h := u64(0x4a4f494e) // "JOIN"
	for jk in join_keys {
		rv, _ := fact_get_field(s, f, jk.right_field_idx)
		h = _hash_combine64(h, _hash_value_key(s, rv))
	}
	return h
}

@(private)
_beta_hash_left_fact :: proc(s: ^Session, lia_binds: []Alpha_Field_Bind, join_keys: []Join_Key_Pair, f: ^Fact) -> u64 {
	h := u64(0x4a4f494e) // "JOIN"
	for jk in join_keys {
		var_val: Value
		for fb in lia_binds {
			if fb.var_slot == jk.left_var_slot {
				var_val, _ = fact_get_field(s, f, fb.field_idx)
				break
			}
		}
		h = _hash_combine64(h, _hash_value_key(s, var_val))
	}
	return h
}

@(private)
_beta_remove_from_bucket :: proc(
	buckets: ^map[u64][dynamic]Fact_Id,
	bucket_hash: ^map[Fact_Id]u64,
	fid: Fact_Id,
) {
	h, has_h := bucket_hash^[fid]
	if !has_h {
		return
	}
	delete_key(bucket_hash, fid)
	if bucket, has_b := &buckets^[h]; has_b {
		for entry, idx in bucket^ {
			if entry == fid {
				unordered_remove(bucket, idx)
				break
			}
		}
	}
}

@(private)
_beta_insert_right_fact :: proc(s: ^Session, bm: ^Beta_Memory, bn: Beta_Node_Def, fid: Fact_Id) {
	f := &s.facts[fid]
	if !f.alive {
		return
	}
	if len(bn.join_keys) == 0 {
		if fid in bm.right_fact_pos {
			return
		}
		bm.right_fact_pos[fid] = len(bm.right_facts)
		append(&bm.right_facts, fid)
		return
	}
	if fid in bm.right_bucket_hash {
		return
	}
	h := _beta_hash_right_fact(s, bn.join_keys, f)
	bm.right_bucket_hash[fid] = h
	bucket, has := &bm.right_buckets[h]
	if !has {
		bm.right_buckets[h] = make([dynamic]Fact_Id, 0, 4, s.allocator)
		bucket = &bm.right_buckets[h]
	}
	append(bucket, fid)
}

@(private)
_beta_remove_right_fact :: proc(bm: ^Beta_Memory, bn: Beta_Node_Def, fid: Fact_Id) {
	if len(bn.join_keys) == 0 {
		pos, has_p := bm.right_fact_pos[fid]
		if !has_p {
			return
		}
		last_idx := len(bm.right_facts) - 1
		if pos != last_idx {
			swapped := bm.right_facts[last_idx]
			bm.right_facts[pos] = swapped
			bm.right_fact_pos[swapped] = pos
		}
		pop(&bm.right_facts)
		delete_key(&bm.right_fact_pos, fid)
		return
	}
	_beta_remove_from_bucket(&bm.right_buckets, &bm.right_bucket_hash, fid)
}

@(private)
_beta_insert_left_fact :: proc(
	s: ^Session,
	bm: ^Beta_Memory,
	lia_binds: []Alpha_Field_Bind,
	join_keys: []Join_Key_Pair,
	fid: Fact_Id,
) {
	f := &s.facts[fid]
	if !f.alive || (fid in bm.left_bucket_hash) {
		return
	}
	h := _beta_hash_left_fact(s, lia_binds, join_keys, f)
	bm.left_bucket_hash[fid] = h
	bucket, has := &bm.left_buckets[h]
	if !has {
		bm.left_buckets[h] = make([dynamic]Fact_Id, 0, 4, s.allocator)
		bucket = &bm.left_buckets[h]
	}
	append(bucket, fid)
}

@(private)
_index_join_right_range :: proc(
	s: ^Session,
	bm: ^Beta_Memory,
	bn: Beta_Node_Def,
	am: ^Alpha_Memory,
	start_idx: int,
	end_idx: int,
) {
	for i := start_idx; i < end_idx; i += 1 {
		_beta_insert_right_fact(s, bm, bn, am.fact_ids[i])
	}
	bm.indexed_count = end_idx
	bm.right_retract_epoch = am.retract_epoch
	bm.right_insert_epoch = am.insert_epoch
	bm.right_alpha_version = am.version
}

@(private)
_rebuild_join_right_index :: proc(s: ^Session, bm: ^Beta_Memory, bn: Beta_Node_Def, am: ^Alpha_Memory) {
	clear(&bm.right_facts)
	clear(&bm.right_fact_pos)
	clear(&bm.right_bucket_hash)
	for _, &bucket in bm.right_buckets {
		clear(&bucket)
	}
	_index_join_right_range(s, bm, bn, am, 0, len(am.fact_ids))
}

@(private)
_rebuild_join_left_index :: proc(
	s: ^Session,
	bm: ^Beta_Memory,
	lia_binds: []Alpha_Field_Bind,
	join_keys: []Join_Key_Pair,
	am_l: ^Alpha_Memory,
) {
	clear(&bm.left_bucket_hash)
	for _, &bucket in bm.left_buckets {
		clear(&bucket)
	}
	for fid in am_l.fact_ids {
		_beta_insert_left_fact(s, bm, lia_binds, join_keys, fid)
	}
	bm.left_initialized = true
	bm.left_indexed_count = len(am_l.fact_ids)
	bm.left_retract_epoch = am_l.retract_epoch
	bm.left_insert_epoch = am_l.insert_epoch
	bm.left_alpha_version = am_l.version
}

@(private)
_beta_sync_right_index :: proc(s: ^Session, bm: ^Beta_Memory, bn: Beta_Node_Def, am: ^Alpha_Memory) {
	if bm.right_alpha_version == am.version {
		return
	}
	ins_buf: [MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	can_delta, _, inserts, r_start, r_end := _alpha_collect_delta_window(
		s,
		am,
		bm.right_retract_epoch,
		bm.right_insert_epoch,
		bm.indexed_count,
		&ins_buf,
	)
	if can_delta {
		for e := r_start; e < r_end; e += 1 {
			_beta_remove_right_fact(bm, bn, am.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
		}
		for ifid in inserts {
			_beta_insert_right_fact(s, bm, bn, ifid)
		}
		bm.indexed_count = len(am.fact_ids)
		bm.right_retract_epoch = am.retract_epoch
		bm.right_insert_epoch = am.insert_epoch
		bm.right_alpha_version = am.version
		return
	}
	_rebuild_join_right_index(s, bm, bn, am)
}

@(private)
_beta_join_pair_if_match :: proc(
	s: ^Session,
	ltok: Beta_Token,
	join_bn: Beta_Node_Def,
	rfid: Fact_Id,
	out_tokens: ^[dynamic]Beta_Token,
) {
	telemetry_count_add(s.telemetry, .Beta_Joins, 1)
	rf := &s.facts[rfid]
	if !rf.alive {
		return
	}
	eq_all := true
	for jk in join_bn.join_keys {
		lv := ltok.vars[jk.left_var_slot]
		rv, rv_ok := fact_get_field(s, rf, jk.right_field_idx)
		if !rv_ok || !_join_values_equal(s, lv, rv) {
			eq_all = false
			break
		}
	}
	if eq_all {
		if joined, j_ok := _token_extend_fact(s, ltok, rf, join_bn.field_binds); j_ok {
			append(out_tokens, joined)
		}
	}
}

@(private)
_beta_join_try_delta_two_way :: proc(
	s: ^Session,
	sm: ^Segment_Memory,
	lia: Beta_Node_Def,
	join_bn: Beta_Node_Def,
	out_tokens: ^[dynamic]Beta_Token,
) -> bool {
	am_l, l_ok := s.alpha_mems[lia.alpha_mem_id]
	am_r, r_ok := s.alpha_mems[join_bn.alpha_mem_id]
	if !l_ok || !r_ok || len(am_l.fact_ids) == 0 || len(am_r.fact_ids) == 0 {
		return false
	}
	bm := _beta_get_or_create_mem(s, join_bn.id)
	if !bm.left_initialized || sm.last_lia_epoch == max(u64) || sm.subnetwork_dirty {
		_beta_sync_right_index(s, bm, join_bn, am_r)
		_rebuild_join_left_index(s, bm, lia.field_binds, join_bn.join_keys, am_l)
		return false
	}

	ins_l_buf: [MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	can_l, app_l, delta_l, rl_start, rl_end := _alpha_collect_delta_window(
		s,
		am_l,
		bm.left_retract_epoch,
		bm.left_insert_epoch,
		bm.left_indexed_count,
		&ins_l_buf,
	)
	ins_r_buf: [MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	can_r, _, delta_r, rr_start, rr_end := _alpha_collect_delta_window(
		s,
		am_r,
		bm.right_retract_epoch,
		bm.right_insert_epoch,
		bm.indexed_count,
		&ins_r_buf,
	)
	if !can_l || !can_r {
		_beta_sync_right_index(s, bm, join_bn, am_r)
		_rebuild_join_left_index(s, bm, lia.field_binds, join_bn.join_keys, am_l)
		return false
	}

	prev_l_len := bm.left_indexed_count

	// 1. Update bm.right_buckets incrementally with R deltas.
	if bm.right_alpha_version != am_r.version {
		for e := rr_start; e < rr_end; e += 1 {
			_beta_remove_right_fact(bm, join_bn, am_r.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
		}
		for rfid in delta_r {
			_beta_insert_right_fact(s, bm, join_bn, rfid)
		}
		bm.indexed_count = len(am_r.fact_ids)
		bm.right_retract_epoch = am_r.retract_epoch
		bm.right_insert_epoch = am_r.insert_epoch
		bm.right_alpha_version = am_r.version
	}

	// 2. Update bm.left_buckets incrementally with L deltas.
	if bm.left_alpha_version != am_l.version {
		for e := rl_start; e < rl_end; e += 1 {
			_beta_remove_from_bucket(&bm.left_buckets, &bm.left_bucket_hash, am_l.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
		}
		for lfid in delta_l {
			_beta_insert_left_fact(s, bm, lia.field_binds, join_bn.join_keys, lfid)
		}
		bm.left_indexed_count = len(am_l.fact_ids)
		bm.left_retract_epoch = am_l.retract_epoch
		bm.left_insert_epoch = am_l.insert_epoch
		bm.left_alpha_version = am_l.version
	}

	// 3. Emit (delta_L ⋈ R_new).
	for lfid in delta_l {
		lf := &s.facts[lfid]
		if !lf.alive {
			continue
		}
		ltok, ltok_ok := _token_extend_fact(s, Beta_Token{fact_sig_hash = 0x544f4b00}, lf, lia.field_binds)
		if !ltok_ok {
			continue
		}
		h := u64(0x4a4f494e)
		for jk in join_bn.join_keys {
			lv := ltok.vars[jk.left_var_slot]
			h = _hash_combine64(h, _hash_value_key(s, lv))
		}
		if cands, found := bm.right_buckets[h]; found {
			for rfid in cands {
				_beta_join_pair_if_match(s, ltok, join_bn, rfid, out_tokens)
			}
		}
	}

	// 4. Emit (L_old ⋈ delta_R), skipping lfid ∈ delta_L to avoid self-join duplicates.
	for rfid in delta_r {
		rf := &s.facts[rfid]
		if !rf.alive {
			continue
		}
		h := _beta_hash_right_fact(s, join_bn.join_keys, rf)
		if lcands, found := bm.left_buckets[h]; found {
			for lfid in lcands {
				in_dl := false
				if len(delta_l) > 0 {
					if app_l {
						if pos, has_p := am_l.fact_pos[lfid]; has_p && pos >= prev_l_len {
							in_dl = true
						}
					} else {
						for dl_id in delta_l {
							if dl_id == lfid {
								in_dl = true
								break
							}
						}
					}
				}
				if in_dl {
					continue
				}
				lf := &s.facts[lfid]
				if !lf.alive {
					continue
				}
				ltok, ltok_ok := _token_extend_fact(s, Beta_Token{fact_sig_hash = 0x544f4b00}, lf, lia.field_binds)
				if !ltok_ok {
					continue
				}
				_beta_join_pair_if_match(s, ltok, join_bn, rfid, out_tokens)
			}
		}
	}

	sm.last_lia_epoch = am_l.retract_epoch
	sm.last_lia_insert_epoch = am_l.insert_epoch
	sm.last_lia_len = len(am_l.fact_ids)
	return true
}

@(private)
_token_extend_fact :: proc(s: ^Session, base: Beta_Token, f: ^Fact, binds: []Alpha_Field_Bind) -> (out: Beta_Token, ok: bool) {
	if int(base.fact_count) >= MAX_TOKEN_FACTS {
		return {}, false
	}
	out = base
	idx := out.fact_count
	out.fact_ids[idx] = f.id
	out.fact_count = idx + 1
	if f.recency > out.max_recency {
		out.max_recency = f.recency
	}
	out.fact_sig_hash = _hash_combine64(out.fact_sig_hash, u64(f.id))
	for b in binds {
		if int(b.var_slot) < MAX_TOKEN_VARS {
			val, found := fact_get_field(s, f, b.field_idx)
			if found {
				out.vars[b.var_slot] = val
			}
		}
	}
	return out, true
}

@(private)
_fill_vm_fact_slots :: proc(s: ^Session, tok: ^Beta_Token, slots_buf: []Vm_Fact_Binding) -> []Vm_Fact_Binding {
	n := min(int(tok.fact_count), len(slots_buf))
	for i := 0; i < n; i += 1 {
		fid := tok.fact_ids[i]
		f := &s.facts[fid]
		slots_buf[i] = Vm_Fact_Binding{
			fields     = f.fields,
			cursor     = f.cursor,
			has_cursor = f.has_cursor,
		}
	}
	return slots_buf[:n]
}

@(private)
beta_join_expand :: proc(
	s: ^Session,
	bn: Beta_Node_Def,
	left_tokens: []Beta_Token,
	out_tokens: ^[dynamic]Beta_Token,
) {
	am, am_ok := s.alpha_mems[bn.alpha_mem_id]
	if !am_ok || len(am.fact_ids) == 0 {
		return
	}
	bm := _beta_get_or_create_mem(s, bn.id)
	_beta_sync_right_index(s, bm, bn, am)

	if len(bn.join_keys) == 0 {
		for ltok in left_tokens {
			for rfid in bm.right_facts {
				telemetry_count_add(s.telemetry, .Beta_Joins, 1)
				rf := &s.facts[rfid]
				if !rf.alive {
					continue
				}
				if joined, j_ok := _token_extend_fact(s, ltok, rf, bn.field_binds); j_ok {
					append(out_tokens, joined)
				}
			}
		}
		return
	}

	for ltok in left_tokens {
		h := u64(0x4a4f494e)
		for jk in bn.join_keys {
			lv := ltok.vars[jk.left_var_slot]
			h = _hash_combine64(h, _hash_value_key(s, lv))
		}
		cands, found := bm.right_buckets[h]
		if !found {
			continue
		}
		for rfid in cands {
			telemetry_count_add(s.telemetry, .Beta_Joins, 1)
			rf := &s.facts[rfid]
			if !rf.alive {
				continue
			}
			eq_all := true
			for jk in bn.join_keys {
				lv := ltok.vars[jk.left_var_slot]
				rv, r_ok := fact_get_field(s, rf, jk.right_field_idx)
				if !r_ok || !_join_values_equal(s, lv, rv) {
					eq_all = false
					break
				}
			}
			if eq_all {
				if joined, j_ok := _token_extend_fact(s, ltok, rf, bn.field_binds); j_ok {
					append(out_tokens, joined)
				}
			}
		}
	}
}
