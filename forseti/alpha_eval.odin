package forseti

import xitdb "xitdb:."

// Projects a schema field from a fact on demand: O(1) slice read for materialized facts,
// or lazy cursor_read_field_path + caching on the fact's field slot when cursor-backed.
@(private)
fact_get_field :: proc(s: ^Session, f: ^Fact, field_idx: i16) -> (Value, bool) {
	if f == nil || field_idx < 0 || int(field_idx) >= len(f.fields) {
		return {}, false
	}
	if f.fields[field_idx] != nil {
		return f.fields[field_idx], true
	}
	if !f.has_cursor {
		return {}, false
	}
	bdef := s.rb.bindings[f.binding_idx]
	schema := s.rb.schemas[bdef.schema_id]
	sf := schema.fields[field_idx]
	pk := s.rb.schema_field_hashes[bdef.schema_id][field_idx]
	path := [1]Prehashed_Key{pk}
	val, found, err := cursor_read_field_path_prehashed(f.cursor, path[:], &s.interner, sf.type.kind)
	if err != nil || !found {
		return {}, false
	}
	if sid, is_s := val.(String_Id); is_s {
		txt := interner_get(&s.interner, sid)
		mapped, m_err := intern_session_string(&s.rb.interner, &s.interner, txt)
		if m_err == nil {
			val = mapped
		}
	}
	f.fields[field_idx] = val
	return val, true
}

@(private)
_alpha_get_or_create_mem :: proc(s: ^Session, alpha_id: u32) -> ^Alpha_Memory {
	if am, has := s.alpha_mems[alpha_id]; has {
		return am
	}
	am := new(Alpha_Memory, s.allocator)
	am.id = alpha_id
	am.fact_ids = make([dynamic]Fact_Id, 0, 4, s.allocator)
	am.fact_pos = make(map[Fact_Id]int, 4, s.allocator)
	s.alpha_mems[alpha_id] = am
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return am
}

@(private)
_seg_get_or_create_mem :: proc(s: ^Session, seg_id: u32) -> ^Segment_Memory {
	if sm, has := s.seg_mems[seg_id]; has {
		return sm
	}
	sm := new(Segment_Memory, s.allocator)
	sm.seg_id = seg_id
	sm.last_lia_epoch = max(u64)
	sm.last_lia_len = 0
	s.seg_mems[seg_id] = sm
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return sm
}

@(private)
_mark_segment_dirty :: proc(s: ^Session, sm: ^Segment_Memory) {
	if !sm.dirty {
		sm.dirty = true
		append(&s.dirty_segs, sm.seg_id)
		sdef := s.rb.segments[sm.seg_id]
		if int(sdef.rule_id) < len(s.rb.rules) {
			st := s.rb.rules[sdef.rule_id].stratum
			if st < s.earliest_dirty_strat {
				s.earliest_dirty_strat = st
			}
		}
	}
}

@(private)
_activate_alpha_terminal :: proc(s: ^Session, fid: Fact_Id, tid: u32) {
	am := _alpha_get_or_create_mem(s, tid)
	if fid in am.fact_pos {
		return
	}
	idx := len(am.fact_ids)
	append(&am.fact_ids, fid)
	am.fact_pos[fid] = idx
	am.version += 1

	list, had_list := &s.fact_alpha_mems[fid]
	if !had_list {
		s.fact_alpha_mems[fid] = make([dynamic]u32, 0, 4, s.allocator)
		list = &s.fact_alpha_mems[fid]
	}
	append(list, tid)

	telemetry_count_add(s.telemetry, .Alpha_Hits, 1)

	term := s.rb.alpha_terminals[tid]
	became_nonempty := len(am.fact_ids) == 1
	for sub in term.subscribers {
		sm := _seg_get_or_create_mem(s, sub.seg_id)
		sdef := s.rb.segments[sub.seg_id]
		if sub.notify_only {
			if sm.was_linked {
				_mark_segment_dirty(s, sm)
			}
			continue
		}
		if became_nonempty {
			sm.linked_mask |= sub.input_bit
		}
		is_linked := sm.linked_mask == sdef.all_linked_mask
		if is_linked {
			if !sm.was_linked {
				sm.was_linked = true
				telemetry_count_add(s.telemetry, .Segments_Linked, 1)
			}
			_mark_segment_dirty(s, sm)
		} else {
			telemetry_count_add(s.telemetry, .Segments_Skipped_Unlinked, 1)
		}
	}
}

@(private)
_eval_alpha_range_cmp :: proc(s: ^Session, lhs: Value, rhs: Value, op: Binary_Op) -> bool {
	dummy_vm := Vm_State{interner = &s.rb.interner, sess_interner = &s.interner}
	ok, err := _vm_eval_cmp_values(&dummy_vm, lhs, rhs, op)
	return err == .None && ok
}

@(private)
_eval_alpha_node :: proc(s: ^Session, f: ^Fact, node_id: u32) {
	node := s.rb.alpha_nodes[node_id]
	telemetry_count_add(s.telemetry, .Alpha_Tests, 1)

	if node.terminal_id >= 0 {
		_activate_alpha_terminal(s, f.id, u32(node.terminal_id))
	}

	if node.eq_field >= 0 && node.eq_buckets != nil && len(node.eq_buckets^) > 0 {
		if val, ok := fact_get_field(s, f, node.eq_field); ok {
			if vk, k_ok := value_key_from_runtime_value(val, &s.rb.interner, &s.interner); k_ok {
				if child_id, hit := node.eq_buckets^[vk]; hit {
					_eval_alpha_node(s, f, child_id)
				}
			}
		}
	}

	for re in node.range_edges {
		if val, ok := fact_get_field(s, f, re.field_idx); ok {
			if _eval_alpha_range_cmp(s, val, re.const_val, re.op) {
				_eval_alpha_node(s, f, re.child)
			}
		}
	}

	for ge in node.guard_edges {
		if int(ge.prog_idx) < len(s.rb.programs) {
			fb := [1]Vm_Fact_Binding{{
				fields     = f.fields,
				cursor     = f.cursor,
				has_cursor = f.has_cursor,
			}}
			res, err := vm_eval(&s.rb.programs[ge.prog_idx], nil, fb[:], s.rb.tables, &s.rb.interner, nil, &s.interner)
			if err == .None && res == Value(true) {
				_eval_alpha_node(s, f, ge.child)
			}
		}
	}
}

@(private)
alpha_eval_insert_fact :: proc(s: ^Session, fid: Fact_Id) {
	f := &s.facts[fid]
	if !f.alive || int(f.binding_idx) >= len(s.rb.alpha_roots) {
		return
	}
	root := s.rb.alpha_roots[f.binding_idx]
	_eval_alpha_node(s, f, root.root_node)
}

@(private)
alpha_eval_retract_fact :: proc(s: ^Session, fid: Fact_Id) {
	tids, has := s.fact_alpha_mems[fid]
	if !has {
		return
	}
	for tid in tids {
		am, ok := s.alpha_mems[tid]
		if !ok {
			continue
		}
		pos, in_am := am.fact_pos[fid]
		if !in_am {
			continue
		}
		last_idx := len(am.fact_ids) - 1
		if pos != last_idx {
			swapped := am.fact_ids[last_idx]
			am.fact_ids[pos] = swapped
			am.fact_pos[swapped] = pos
		}
		pop(&am.fact_ids)
		delete_key(&am.fact_pos, fid)
		am.version += 1
		am.retract_epoch += 1

		became_empty := len(am.fact_ids) == 0
		term := s.rb.alpha_terminals[tid]
		for sub in term.subscribers {
			sm, sm_ok := s.seg_mems[sub.seg_id]
			if !sm_ok {
				continue
			}
			if sub.notify_only {
				if sm.was_linked {
					_mark_segment_dirty(s, sm)
				}
				continue
			}
			if became_empty {
				was := sm.was_linked
				sm.linked_mask &= ~sub.input_bit
				sm.was_linked = false
				sm.last_lia_epoch = max(u64)
				sm.last_lia_len = 0
				if was {
					sdef := s.rb.segments[sub.seg_id]
					jtms_revoke_all_rule_firings(s, sdef.rule_id)
				}
			}
			if sm.was_linked {
				_mark_segment_dirty(s, sm)
			}
		}
	}
	if list_ptr, ok_p := &s.fact_alpha_mems[fid]; ok_p {
		clear(list_ptr)
	}
}

@(private)
_ensure_xitdb_unused :: proc() -> xitdb.Tag {
	return .None
}
