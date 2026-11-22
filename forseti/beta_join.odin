package forseti

import "core:encoding/endian"
import "core:mem"

MAX_TOKEN_FACTS :: 16
MAX_TOKEN_VARS  :: 32

Beta_Token :: struct {
	fact_ids:      [MAX_TOKEN_FACTS]Fact_Id,
	fact_count:    u8,
	decide_count:  u8,
	decide_start:  u32,
	vars:          [MAX_TOKEN_VARS]Value,
	max_recency:   u64,
	fact_sig_hash: u64,
}

@(private)
_token_decide_slice :: #force_inline proc "contextless" (s: ^Session, tok: ^Beta_Token) -> []Decision_Result {
	if tok == nil || tok.decide_count == 0 {
		return nil
	}
	start := int(tok.decide_start)
	end := start + int(tok.decide_count)
	if start < 0 || end > len(s.eval_decide_pool) {
		return nil
	}
	return s.eval_decide_pool[start:end]
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
_beta_bucket_index_init :: proc(idx: ^Beta_Bucket_Index, allocator: mem.Allocator) {
	idx.heads = make(map[u64]i32, 8, allocator)
	idx.fact_node = make(map[Fact_Id]i32, 8, allocator)
	idx.nodes = make([dynamic]Beta_Bucket_Node, 0, 8, allocator)
	idx.free_list = make([dynamic]i32, 0, 8, allocator)
}

@(private)
_beta_bucket_index_destroy :: proc(idx: ^Beta_Bucket_Index) {
	delete(idx.heads)
	delete(idx.fact_node)
	delete(idx.nodes)
	delete(idx.free_list)
	idx^ = {}
}

@(private)
_beta_bucket_index_clear :: proc(idx: ^Beta_Bucket_Index) {
	clear(&idx.heads)
	clear(&idx.fact_node)
	clear(&idx.nodes)
	clear(&idx.free_list)
}

@(private)
_beta_bucket_index_insert :: proc(idx: ^Beta_Bucket_Index, fid: Fact_Id, h: u64) {
	if fid in idx.fact_node {
		return
	}
	nidx: i32
	if len(idx.free_list) > 0 {
		nidx = pop(&idx.free_list)
	} else {
		nidx = i32(len(idx.nodes))
		append(&idx.nodes, Beta_Bucket_Node{})
	}
	old_head := i32(-1)
	if oh, has := idx.heads[h]; has {
		old_head = oh
	}
	idx.nodes[nidx] = Beta_Bucket_Node{
		fid  = fid,
		hash = h,
		prev = -1,
		next = old_head,
	}
	if old_head >= 0 {
		idx.nodes[old_head].prev = nidx
	}
	idx.heads[h] = nidx
	idx.fact_node[fid] = nidx
}

@(private)
_beta_bucket_index_remove :: proc(idx: ^Beta_Bucket_Index, fid: Fact_Id) {
	nidx, has := idx.fact_node[fid]
	if !has {
		return
	}
	delete_key(&idx.fact_node, fid)
	node := idx.nodes[nidx]
	if node.prev >= 0 {
		idx.nodes[node.prev].next = node.next
	} else {
		if node.next >= 0 {
			idx.heads[node.hash] = node.next
		} else {
			delete_key(&idx.heads, node.hash)
		}
	}
	if node.next >= 0 {
		idx.nodes[node.next].prev = node.prev
	}
	idx.nodes[nidx] = {}
	append(&idx.free_list, nidx)
}

@(private)
_beta_mem_init :: proc(bm: ^Beta_Memory, node_id: u32, allocator: mem.Allocator) {
	bm.node_id = node_id
	bm.right_alpha_version = max(u64) // Force initial index build on first join
	bm.right_retract_epoch = max(u64)
	bm.right_insert_epoch = 0
	bm.indexed_count = 0
	bm.right_facts = make([dynamic]Fact_Id, 0, 8, allocator)
	bm.right_fact_pos = make(map[Fact_Id]int, 8, allocator)
	_beta_bucket_index_init(&bm.right_idx, allocator)
	bm.left_retract_epoch = max(u64)
	_beta_bucket_index_init(&bm.left_idx, allocator)
}

@(private)
_beta_mem_destroy :: proc(bm: ^Beta_Memory) {
	_beta_bucket_index_destroy(&bm.right_idx)
	delete(bm.right_fact_pos)
	delete(bm.right_facts)
	_beta_bucket_index_destroy(&bm.left_idx)
}

@(private)
_beta_get_or_create_mem :: proc(s: ^Session, node_id: u32) -> ^Beta_Memory {
	if bm, has := s.beta_mems[node_id]; has {
		return bm
	}
	bm := new(Beta_Memory, s.allocator)
	_beta_mem_init(bm, node_id, s.allocator)
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
	if fid in bm.right_idx.fact_node {
		return
	}
	h := _beta_hash_right_fact(s, bn.join_keys, f)
	_beta_bucket_index_insert(&bm.right_idx, fid, h)
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
	_beta_bucket_index_remove(&bm.right_idx, fid)
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
	if !f.alive || (fid in bm.left_idx.fact_node) {
		return
	}
	h := _beta_hash_left_fact(s, lia_binds, join_keys, f)
	_beta_bucket_index_insert(&bm.left_idx, fid, h)
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
	_beta_bucket_index_clear(&bm.right_idx)
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
	_beta_bucket_index_clear(&bm.left_idx)
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
	ltok: ^Beta_Token,
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

	// 2. Update bm.left_idx incrementally with L deltas.
	if bm.left_alpha_version != am_l.version {
		for e := rl_start; e < rl_end; e += 1 {
			_beta_bucket_index_remove(&bm.left_idx, am_l.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
		}
		for lfid in delta_l {
			_beta_insert_left_fact(s, bm, lia.field_binds, join_bn.join_keys, lfid)
		}
		bm.left_indexed_count = len(am_l.fact_ids)
		bm.left_retract_epoch = am_l.retract_epoch
		bm.left_insert_epoch = am_l.insert_epoch
		bm.left_alpha_version = am_l.version
	}

	base_tok := Beta_Token{fact_sig_hash = 0x544f4b00}

	// 3. Emit (delta_L ⋈ R_new).
	for lfid in delta_l {
		lf := &s.facts[lfid]
		if !lf.alive {
			continue
		}
		ltok, ltok_ok := _token_extend_fact(s, &base_tok, lf, lia.field_binds)
		if !ltok_ok {
			continue
		}
		h := u64(0x4a4f494e)
		for jk in join_bn.join_keys {
			lv := ltok.vars[jk.left_var_slot]
			h = _hash_combine64(h, _hash_value_key(s, lv))
		}
		if head, found := bm.right_idx.heads[h]; found {
			cur := head
			for cur >= 0 {
				node := bm.right_idx.nodes[cur]
				cur = node.next
				_beta_join_pair_if_match(s, &ltok, join_bn, node.fid, out_tokens)
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
		if head, found := bm.left_idx.heads[h]; found {
			cur := head
			for cur >= 0 {
				node := bm.left_idx.nodes[cur]
				cur = node.next
				lfid := node.fid
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
				ltok, ltok_ok := _token_extend_fact(s, &base_tok, lf, lia.field_binds)
				if !ltok_ok {
					continue
				}
				_beta_join_pair_if_match(s, &ltok, join_bn, rfid, out_tokens)
			}
		}
	}

	sm.last_lia_epoch = am_l.retract_epoch
	sm.last_lia_insert_epoch = am_l.insert_epoch
	sm.last_lia_len = len(am_l.fact_ids)
	return true
}

@(private)
_Multi_Join_Step :: struct {
	from_pat: u8,
	to_pat:   u8,
	edge_idx: u8,
	to_right: bool,
}

@(private)
_Multi_Join_Ctx :: struct {
	s:          ^Session,
	k:          int,
	root_pat:   int,
	bns:        [8]Beta_Node_Def,
	ams:        [8]^Alpha_Memory,
	bms:        [8]^Beta_Memory,
	owners:     [8]i8,
	deltas:     [8][]Fact_Id,
	app:        [8]bool,
	prev_len:   [8]int,
	steps:      [8]_Multi_Join_Step,
	assigned:   [8]Fact_Id,
	out_tokens: ^[dynamic]Beta_Token,
}

@(private)
_multi_fid_in_delta :: proc(ctx: ^_Multi_Join_Ctx, pat: int, fid: Fact_Id) -> bool {
	d := ctx.deltas[pat]
	if len(d) == 0 {
		return false
	}
	if ctx.app[pat] {
		if pos, has_p := ctx.ams[pat].fact_pos[fid]; has_p && pos >= ctx.prev_len[pat] {
			return true
		}
		return false
	}
	for did in d {
		if did == fid {
			return true
		}
	}
	return false
}

@(private)
_beta_pair_fields_equal :: proc(
	s: ^Session,
	left_binds: []Alpha_Field_Bind,
	join_keys: []Join_Key_Pair,
	left_f: ^Fact,
	right_f: ^Fact,
) -> bool {
	for jk in join_keys {
		lv: Value
		for fb in left_binds {
			if fb.var_slot == jk.left_var_slot {
				lv, _ = fact_get_field(s, left_f, fb.field_idx)
				break
			}
		}
		rv, rv_ok := fact_get_field(s, right_f, jk.right_field_idx)
		if !rv_ok || !_join_values_equal(s, lv, rv) {
			return false
		}
	}
	return true
}

@(private)
_multi_join_dfs :: proc(ctx: ^_Multi_Join_Ctx, depth: int) {
	if depth >= ctx.k - 1 {
		tok := Beta_Token{fact_sig_hash = 0x544f4b00}
		ok := true
		for p := 0; p < ctx.k; p += 1 {
			pf := &ctx.s.facts[ctx.assigned[p]]
			if !pf.alive {
				return
			}
			tok, ok = _token_extend_fact(ctx.s, &tok, pf, ctx.bns[p].field_binds)
			if !ok {
				return
			}
		}
		append(ctx.out_tokens, tok)
		return
	}

	st := ctx.steps[depth]
	from_f := &ctx.s.facts[ctx.assigned[st.from_pat]]
	if !from_f.alive {
		return
	}
	e := int(st.edge_idx)
	join_bn := ctx.bns[e]
	owner_bn := ctx.bns[ctx.owners[e]]
	bm := ctx.bms[e]

	if st.to_right {
		h := _beta_hash_left_fact(ctx.s, owner_bn.field_binds, join_bn.join_keys, from_f)
		head, found := bm.right_idx.heads[h]
		if !found {
			return
		}
		cur := head
		for cur >= 0 {
			node := bm.right_idx.nodes[cur]
			cur = node.next
			cand := node.fid
			telemetry_count_add(ctx.s.telemetry, .Beta_Joins, 1)
			if int(st.to_pat) < ctx.root_pat && _multi_fid_in_delta(ctx, int(st.to_pat), cand) {
				continue
			}
			cand_f := &ctx.s.facts[cand]
			if !cand_f.alive {
				continue
			}
			if _beta_pair_fields_equal(ctx.s, owner_bn.field_binds, join_bn.join_keys, from_f, cand_f) {
				ctx.assigned[st.to_pat] = cand
				_multi_join_dfs(ctx, depth + 1)
			}
		}
	} else {
		h := _beta_hash_right_fact(ctx.s, join_bn.join_keys, from_f)
		head, found := bm.left_idx.heads[h]
		if !found {
			return
		}
		cur := head
		for cur >= 0 {
			node := bm.left_idx.nodes[cur]
			cur = node.next
			cand := node.fid
			telemetry_count_add(ctx.s.telemetry, .Beta_Joins, 1)
			if int(st.to_pat) < ctx.root_pat && _multi_fid_in_delta(ctx, int(st.to_pat), cand) {
				continue
			}
			cand_f := &ctx.s.facts[cand]
			if !cand_f.alive {
				continue
			}
			if _beta_pair_fields_equal(ctx.s, owner_bn.field_binds, join_bn.join_keys, cand_f, from_f) {
				ctx.assigned[st.to_pat] = cand
				_multi_join_dfs(ctx, depth + 1)
			}
		}
	}
}

@(private)
_beta_join_try_delta_multi :: proc(
	s: ^Session,
	sm: ^Segment_Memory,
	seg: Segment_Def,
	out_tokens: ^[dynamic]Beta_Token,
) -> bool {
	k := int(seg.join_prefix_len)
	if k < 3 || k > 8 {
		return false
	}

	ctx := _Multi_Join_Ctx{
		s          = s,
		k          = k,
		out_tokens = out_tokens,
	}
	for p := 0; p < k; p += 1 {
		ctx.bns[p] = s.rb.beta_nodes[seg.node_start + u32(p)]
		ctx.owners[p] = ctx.bns[p].owner_pat
		am, am_ok := s.alpha_mems[ctx.bns[p].alpha_mem_id]
		if !am_ok || len(am.fact_ids) == 0 {
			return false
		}
		ctx.ams[p] = am
	}

	need_rebuild := sm.last_lia_epoch == max(u64) || sm.subnetwork_dirty
	for m := 1; m < k; m += 1 {
		ctx.bms[m] = _beta_get_or_create_mem(s, ctx.bns[m].id)
		if !ctx.bms[m].left_initialized || ctx.owners[m] < 0 || int(ctx.owners[m]) >= m {
			need_rebuild = true
		}
	}

	_rebuild_all_multi :: proc(ctx: ^_Multi_Join_Ctx) {
		for m := 1; m < ctx.k; m += 1 {
			o := int(ctx.owners[m])
			_beta_sync_right_index(ctx.s, ctx.bms[m], ctx.bns[m], ctx.ams[m])
			_rebuild_join_left_index(ctx.s, ctx.bms[m], ctx.bns[o].field_binds, ctx.bns[m].join_keys, ctx.ams[o])
		}
	}

	if need_rebuild {
		_rebuild_all_multi(&ctx)
		return false
	}

	ins_bufs: [8][MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	left_ins_bufs: [8][MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	r_start: [8]u64
	r_end: [8]u64
	rl_start: [8]u64
	rl_end: [8]u64
	left_deltas: [8][]Fact_Id

	can0, app0, d0, rs0, re0 := _alpha_collect_delta_window(
		s,
		ctx.ams[0],
		sm.last_lia_epoch,
		sm.last_lia_insert_epoch,
		sm.last_lia_len,
		&ins_bufs[0],
	)
	if !can0 {
		_rebuild_all_multi(&ctx)
		return false
	}
	ctx.app[0] = app0
	ctx.prev_len[0] = sm.last_lia_len
	ctx.deltas[0] = d0
	r_start[0] = rs0
	r_end[0] = re0

	for m := 1; m < k; m += 1 {
		bm := ctx.bms[m]
		am_r := ctx.ams[m]
		can_r, app_r, dr, rrs, rre := _alpha_collect_delta_window(
			s,
			am_r,
			bm.right_retract_epoch,
			bm.right_insert_epoch,
			bm.indexed_count,
			&ins_bufs[m],
		)
		am_o := ctx.ams[ctx.owners[m]]
		can_l, _, dl, lrs, lre := _alpha_collect_delta_window(
			s,
			am_o,
			bm.left_retract_epoch,
			bm.left_insert_epoch,
			bm.left_indexed_count,
			&left_ins_bufs[m],
		)
		if !can_r || !can_l {
			_rebuild_all_multi(&ctx)
			return false
		}
		ctx.app[m] = app_r
		ctx.prev_len[m] = bm.indexed_count
		ctx.deltas[m] = dr
		r_start[m] = rrs
		r_end[m] = rre
		left_deltas[m] = dl
		rl_start[m] = lrs
		rl_end[m] = lre
	}

	// Incrementally update every Join node's right_idx and left_idx.
	for m := 1; m < k; m += 1 {
		bm := ctx.bms[m]
		bn_m := ctx.bns[m]
		am_r := ctx.ams[m]
		if bm.right_alpha_version != am_r.version {
			for e := r_start[m]; e < r_end[m]; e += 1 {
				_beta_remove_right_fact(bm, bn_m, am_r.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
			}
			for rfid in ctx.deltas[m] {
				_beta_insert_right_fact(s, bm, bn_m, rfid)
			}
			bm.indexed_count = len(am_r.fact_ids)
			bm.right_retract_epoch = am_r.retract_epoch
			bm.right_insert_epoch = am_r.insert_epoch
			bm.right_alpha_version = am_r.version
		}

		o := int(ctx.owners[m])
		bn_o := ctx.bns[o]
		am_o := ctx.ams[o]
		if bm.left_alpha_version != am_o.version {
			for e := rl_start[m]; e < rl_end[m]; e += 1 {
				_beta_bucket_index_remove(&bm.left_idx, am_o.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
			}
			for lfid in left_deltas[m] {
				_beta_insert_left_fact(s, bm, bn_o.field_binds, bn_m.join_keys, lfid)
			}
			bm.left_indexed_count = len(am_o.fact_ids)
			bm.left_retract_epoch = am_o.retract_epoch
			bm.left_insert_epoch = am_o.insert_epoch
			bm.left_alpha_version = am_o.version
		}
	}

	// Emit disjoint delta join terms M_m over patterns p in [0, k).
	for m := 0; m < k; m += 1 {
		if len(ctx.deltas[m]) == 0 {
			continue
		}
		ctx.root_pat = m

		// Build BFS traversal schedule rooted at `m` over tree edges (owners[e], e).
		q: [8]u8
		visited: [8]bool
		visited[m] = true
		q[0] = u8(m)
		qh := 0
		qt := 1
		n_steps := 0
		for qh < qt {
			u := int(q[qh])
			qh += 1
			for e := 1; e < k; e += 1 {
				if int(ctx.owners[e]) == u && !visited[e] {
					visited[e] = true
					ctx.steps[n_steps] = _Multi_Join_Step{from_pat = u8(u), to_pat = u8(e), edge_idx = u8(e), to_right = true}
					n_steps += 1
					q[qt] = u8(e)
					qt += 1
				} else if e == u && !visited[ctx.owners[e]] {
					v := int(ctx.owners[e])
					visited[v] = true
					ctx.steps[n_steps] = _Multi_Join_Step{from_pat = u8(u), to_pat = u8(v), edge_idx = u8(e), to_right = false}
					n_steps += 1
					q[qt] = u8(v)
					qt += 1
				}
			}
		}

		for dfid in ctx.deltas[m] {
			if !s.facts[dfid].alive {
				continue
			}
			ctx.assigned[m] = dfid
			_multi_join_dfs(&ctx, 0)
		}
	}

	sm.last_lia_epoch = ctx.ams[0].retract_epoch
	sm.last_lia_insert_epoch = ctx.ams[0].insert_epoch
	sm.last_lia_len = len(ctx.ams[0].fact_ids)
	return true
}

@(private)
_token_extend_fact :: proc(s: ^Session, base: ^Beta_Token, f: ^Fact, binds: []Alpha_Field_Bind) -> (out: Beta_Token, ok: bool) {
	if int(base.fact_count) >= MAX_TOKEN_FACTS {
		return {}, false
	}
	out = base^
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
		for &ltok in left_tokens {
			for rfid in bm.right_facts {
				telemetry_count_add(s.telemetry, .Beta_Joins, 1)
				rf := &s.facts[rfid]
				if !rf.alive {
					continue
				}
				if joined, j_ok := _token_extend_fact(s, &ltok, rf, bn.field_binds); j_ok {
					append(out_tokens, joined)
				}
			}
		}
		return
	}

	for &ltok in left_tokens {
		h := u64(0x4a4f494e)
		for jk in bn.join_keys {
			lv := ltok.vars[jk.left_var_slot]
			h = _hash_combine64(h, _hash_value_key(s, lv))
		}
		head, found := bm.right_idx.heads[h]
		if !found {
			continue
		}
		cur := head
		for cur >= 0 {
			node := bm.right_idx.nodes[cur]
			cur = node.next
			rfid := node.fid
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
				if joined, j_ok := _token_extend_fact(s, &ltok, rf, bn.field_binds); j_ok {
					append(out_tokens, joined)
				}
			}
		}
	}
}
