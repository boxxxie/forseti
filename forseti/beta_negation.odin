package forseti

Not_Exists_Memory :: struct {
	node_id:        u32,
	blocker_counts: map[u64]i32,
}

@(private)
_neg_get_or_create_mem :: proc(s: ^Session, node_id: u32) -> ^Not_Exists_Memory {
	if nm, has := s.neg_mems[node_id]; has {
		return nm
	}
	nm := new(Not_Exists_Memory, s.allocator)
	nm.node_id = node_id
	nm.blocker_counts = make(map[u64]i32, 8, s.allocator)
	s.neg_mems[node_id] = nm
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return nm
}

@(private)
_sub_beta_get_or_create_mem :: proc(s: ^Session, sub_key: u64) -> ^Beta_Memory {
	if bm, has := s.sub_beta_mems[sub_key]; has {
		return bm
	}
	bm := new(Beta_Memory, s.allocator)
	_beta_mem_init(bm, u32(sub_key & 0xffffffff), s.allocator)
	s.sub_beta_mems[sub_key] = bm
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return bm
}

// Evaluates a single Subnetwork_Def step across `cur` tokens -> `nxt` tokens.
@(private)
_subnetwork_eval_step :: proc(
	s: ^Session,
	sub_id: u32,
	step_idx: u32,
	step: Subnetwork_Step,
	cur: []Beta_Token,
	nxt: ^[dynamic]Beta_Token,
) -> Session_Error {
	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding

	switch step.kind {
	case .Pattern:
		if len(cur) == 0 {
			return .None
		}
		am, am_ok := s.alpha_mems[step.alpha_mem_id]
		if !am_ok || len(am.fact_ids) == 0 {
			return .None
		}
		if len(step.join_keys) > 0 {
			sub_key := (u64(sub_id) << 32) | u64(step_idx)
			bm := _sub_beta_get_or_create_mem(s, sub_key)
			syn_bn := Beta_Node_Def{
				id           = step_idx,
				alpha_mem_id = step.alpha_mem_id,
				join_keys    = step.join_keys,
				field_binds  = step.field_binds,
			}
			_beta_sync_right_index(s, bm, syn_bn, am)
			for &ltok in cur {
				h := u64(0x4a4f494e)
				for jk in step.join_keys {
					lv := ltok.vars[jk.left_var_slot]
					h = _hash_combine64(h, _hash_value_key(s, lv))
				}
				head, found := bm.right_idx.heads[h]
				if !found {
					continue
				}
				node_idx := head
				for node_idx >= 0 {
					node := bm.right_idx.nodes[node_idx]
					node_idx = node.next
					telemetry_count_add(s.telemetry, .Beta_Joins, 1)
					rf := &s.facts[node.fid]
					if !rf.alive {
						continue
					}
					eq_all := true
					for jk in step.join_keys {
						lv := ltok.vars[jk.left_var_slot]
						rv, r_ok := fact_get_field(s, rf, jk.right_field_idx)
						if !r_ok || !_join_values_equal(s, lv, rv) {
							eq_all = false
							break
						}
					}
					if eq_all {
						if ext, ok := _token_extend_fact(s, &ltok, rf, step.field_binds); ok {
							append(nxt, ext)
						}
					}
				}
			}
			return .None
		}

		for &ltok in cur {
			for fid in am.fact_ids {
				rf := &s.facts[fid]
				if !rf.alive {
					continue
				}
				telemetry_count_add(s.telemetry, .Beta_Joins, 1)
				if ext, ok := _token_extend_fact(s, &ltok, rf, step.field_binds); ok {
					append(nxt, ext)
				}
			}
		}

	case .Where:
		if step.guard_prog < 0 {
			for tok in cur {
				append(nxt, tok)
			}
			return .None
		}
		for &tok in cur {
			fslots := _fill_vm_fact_slots(s, &tok, fact_slots_buf[:])
			val, verr := vm_eval(
				&s.rb.programs[step.guard_prog],
				tok.vars[:],
				fslots,
				s.rb.tables,
				&s.rb.interner,
				_token_decide_slice(s, &tok),
				&s.interner,
			)
			if verr != .None {
				return .Vm_Eval_Failed
			}
			if val == Value(true) {
				append(nxt, tok)
			}
		}
	}
	return .None
}

// Evaluates subnetwork iteratively starting from `outer_tok`, returning match count (and tokens if requested).
@(private)
subnetwork_eval_for_token :: proc(
	s: ^Session,
	sub: Subnetwork_Def,
	outer_tok: Beta_Token,
	out_matches: ^[dynamic]Beta_Token = nil,
) -> (count: i32, err: Session_Error) {
	if len(sub.steps) == 0 {
		if out_matches != nil {
			append(out_matches, outer_tok)
		}
		return 1, .None
	}

	cur := make([dynamic]Beta_Token, 0, 8, context.temp_allocator)
	nxt := make([dynamic]Beta_Token, 0, 8, context.temp_allocator)
	append(&cur, outer_tok)

	for step, si in sub.steps {
		clear(&nxt)
		_subnetwork_eval_step(s, sub.id, u32(si), step, cur[:], &nxt) or_return
		cur, nxt = nxt, cur
		if len(cur) == 0 {
			break
		}
	}

	if out_matches != nil {
		for tok in cur {
			append(out_matches, tok)
		}
	}
	return i32(len(cur)), .None
}
