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
	bm.indexed_count = 0
	bm.right_facts = make([dynamic]Fact_Id, 0, 8, s.allocator)
	bm.right_buckets = make(map[u64][dynamic]Fact_Id, 8, s.allocator)
	s.beta_mems[node_id] = bm
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return bm
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
		fid := am.fact_ids[i]
		f := &s.facts[fid]
		if !f.alive {
			continue
		}
		append(&bm.right_facts, fid)
		h := u64(0x4a4f494e) // "JOIN"
		for jk in bn.join_keys {
			rv, _ := fact_get_field(s, f, jk.right_field_idx)
			h = _hash_combine64(h, _hash_value_key(s, rv))
		}
		bucket, has := &bm.right_buckets[h]
		if !has {
			bm.right_buckets[h] = make([dynamic]Fact_Id, 0, 4, s.allocator)
			bucket = &bm.right_buckets[h]
		}
		append(bucket, fid)
	}
	bm.indexed_count = end_idx
	bm.right_retract_epoch = am.retract_epoch
	bm.right_alpha_version = am.version
}

@(private)
_rebuild_join_right_index :: proc(s: ^Session, bm: ^Beta_Memory, bn: Beta_Node_Def, am: ^Alpha_Memory) {
	clear(&bm.right_facts)
	for _, &bucket in bm.right_buckets {
		clear(&bucket)
	}
	_index_join_right_range(s, bm, bn, am, 0, len(am.fact_ids))
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
	if bm.right_alpha_version != am.version {
		if bm.right_retract_epoch == am.retract_epoch && bm.indexed_count <= len(am.fact_ids) {
			_index_join_right_range(s, bm, bn, am, bm.indexed_count, len(am.fact_ids))
		} else {
			_rebuild_join_right_index(s, bm, bn, am)
		}
	}

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
