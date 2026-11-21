package forseti

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

MAX_ACCUM_GROUP_COLS :: 8

Accum_Group_Key :: struct {
	count: u8,
	keys:  [MAX_ACCUM_GROUP_COLS]Value_Key,
}

Accum_Bag_Entry :: struct {
	key:          Value_Key,
	val:          Value,
	num_val:      f64,
	is_num:       bool,
	multiplicity: i32,
}

Accum_State :: struct {
	op:              Accum_Op,
	count:           i64,
	sum_i64:         i64,
	f64_vals:        [dynamic]f64,
	sorted_bag:      [dynamic]Accum_Bag_Entry,
	distinct_counts: map[Value_Key]i32,
	collect_entries: map[Value_Key]Accum_Bag_Entry,
	allocator:       mem.Allocator,
}

Accum_Tracked_Fact :: struct {
	included:  bool,
	recency:   u64,
	group_key: Accum_Group_Key,
	val:       Value,
}

Accum_Memory :: struct {
	node_id:             u32,
	last_alpha_version:  u64,
	groups:              map[Accum_Group_Key]Accum_State,
	group_tokens:        map[Accum_Group_Key]i64,
	fact_to_groups:      map[Fact_Id][dynamic]Accum_Group_Key,
	tracked_facts:       map[Fact_Id]Accum_Tracked_Fact,
}

accum_init :: proc(st: ^Accum_State, op: Accum_Op, allocator := context.allocator) {
	st^ = {}
	st.op = op
	st.allocator = allocator
	switch op {
	case .Count, .Sum, .Avg:
		st.f64_vals = make([dynamic]f64, 0, 0, allocator)
	case .Min, .Max:
		st.sorted_bag = make([dynamic]Accum_Bag_Entry, 0, 8, allocator)
	case .Distinct:
		st.distinct_counts = make(map[Value_Key]i32, 8, allocator)
	case .Collect:
		st.collect_entries = make(map[Value_Key]Accum_Bag_Entry, 8, allocator)
	}
}

accum_destroy :: proc(st: ^Accum_State) {
	if st == nil {
		return
	}
	delete(st.f64_vals)
	delete(st.sorted_bag)
	delete(st.distinct_counts)
	delete(st.collect_entries)
	st^ = {}
}

@(private)
_accum_entry_cmp :: proc "contextless" (a, b: Accum_Bag_Entry) -> int {
	if a.is_num && b.is_num {
		if a.num_val < b.num_val {
			return -1
		}
		if a.num_val > b.num_val {
			return 1
		}
	}
	if u8(a.key.kind) < u8(b.key.kind) {
		return -1
	}
	if u8(a.key.kind) > u8(b.key.kind) {
		return 1
	}
	if a.key.raw < b.key.raw {
		return -1
	}
	if a.key.raw > b.key.raw {
		return 1
	}
	return 0
}

@(private)
_accum_unique_value_key :: proc(
	v: Value,
	rb_int: ^String_Interner,
	sess_int: ^String_Interner,
) -> (k: Value_Key, ok: bool) {
	if sid, is_s := v.(String_Id); is_s {
		if (u32(sid) & RUNTIME_STRING_BIT) != 0 && rb_int != nil && sess_int != nil {
			txt := resolve_runtime_string(rb_int, sess_int, sid)
			if mapped, has := rb_int.lookup[txt]; has {
				return Value_Key{kind = .String, raw = u64(mapped)}, true
			}
			return Value_Key{kind = .String, raw = u64(u32(sid))}, true
		}
		return Value_Key{kind = .String, raw = u64(sid)}, true
	}
	return value_to_key(v)
}

@(private)
_accum_make_bag_entry :: proc(v: Value, rb_int: ^String_Interner = nil, sess_int: ^String_Interner = nil) -> Accum_Bag_Entry {
	vk, _ := _accum_unique_value_key(v, rb_int, sess_int)
	nv, is_n := value_to_f64(v)
	return Accum_Bag_Entry{
		key          = vk,
		val          = v,
		num_val      = nv,
		is_num       = is_n,
		multiplicity = 1,
	}
}

@(private)
_accum_bag_find :: proc "contextless" (bag: []Accum_Bag_Entry, target: Accum_Bag_Entry) -> (idx: int, found: bool) {
	lo := 0
	hi := len(bag) - 1
	for lo <= hi {
		mid := lo + (hi - lo) / 2
		c := _accum_entry_cmp(bag[mid], target)
		if c == 0 {
			return mid, true
		}
		if c < 0 {
			lo = mid + 1
		} else {
			hi = mid - 1
		}
	}
	return lo, false
}

accum_insert :: proc(
	st: ^Accum_State,
	v: Value,
	rb_int: ^String_Interner = nil,
	sess_int: ^String_Interner = nil,
) {
	if st == nil {
		return
	}
	st.count += 1
	switch st.op {
	case .Count:
		// Tracked via st.count
	case .Sum, .Avg:
		if fv, is_f := v.(f64); is_f {
			append(&st.f64_vals, fv)
		} else if iv, i_ok := value_to_i64(v); i_ok {
			st.sum_i64 += iv
		}
	case .Min, .Max:
		entry := _accum_make_bag_entry(v, rb_int, sess_int)
		idx, found := _accum_bag_find(st.sorted_bag[:], entry)
		if found {
			st.sorted_bag[idx].multiplicity += 1
		} else {
			inject_at(&st.sorted_bag, idx, entry)
		}
	case .Distinct:
		vk, _ := _accum_unique_value_key(v, rb_int, sess_int)
		st.distinct_counts[vk] = (st.distinct_counts[vk] or_else 0) + 1
	case .Collect:
		entry := _accum_make_bag_entry(v, rb_int, sess_int)
		if cur, has := &st.collect_entries[entry.key]; has {
			cur.multiplicity += 1
		} else {
			st.collect_entries[entry.key] = entry
		}
	}
}

accum_retract :: proc(
	st: ^Accum_State,
	v: Value,
	rb_int: ^String_Interner = nil,
	sess_int: ^String_Interner = nil,
) {
	if st == nil || st.count <= 0 {
		return
	}
	st.count -= 1
	switch st.op {
	case .Count:
		// Tracked via st.count
	case .Sum, .Avg:
		if fv, is_f := v.(f64); is_f {
			for x, i in st.f64_vals {
				if x == fv {
					unordered_remove(&st.f64_vals, i)
					break
				}
			}
		} else if iv, i_ok := value_to_i64(v); i_ok {
			st.sum_i64 -= iv
		}
	case .Min, .Max:
		entry := _accum_make_bag_entry(v, rb_int, sess_int)
		idx, found := _accum_bag_find(st.sorted_bag[:], entry)
		if found {
			st.sorted_bag[idx].multiplicity -= 1
			if st.sorted_bag[idx].multiplicity <= 0 {
				ordered_remove(&st.sorted_bag, idx)
			}
		}
	case .Distinct:
		vk, _ := _accum_unique_value_key(v, rb_int, sess_int)
		if cur, has := st.distinct_counts[vk]; has {
			if cur <= 1 {
				delete_key(&st.distinct_counts, vk)
			} else {
				st.distinct_counts[vk] = cur - 1
			}
		}
	case .Collect:
		vk, _ := _accum_unique_value_key(v, rb_int, sess_int)
		if cur, has := &st.collect_entries[vk]; has {
			if cur.multiplicity <= 1 {
				delete_key(&st.collect_entries, vk)
			} else {
				cur.multiplicity -= 1
			}
		}
	}
}

accum_finalize :: proc(
	st: ^Accum_State,
	rb_int: ^String_Interner = nil,
	sess_int: ^String_Interner = nil,
) -> (val: Value, valid: bool) {
	if st == nil {
		return {}, false
	}
	switch st.op {
	case .Count:
		return st.count, true
	case .Sum:
		if len(st.f64_vals) > 0 {
			fsum := f64(st.sum_i64)
			for fv in st.f64_vals {
				fsum += fv
			}
			return fsum, true
		}
		return st.sum_i64, true
	case .Avg:
		if st.count <= 0 {
			return {}, false
		}
		total := f64(st.sum_i64)
		for fv in st.f64_vals {
			total += fv
		}
		return total / f64(st.count), true
	case .Min:
		if len(st.sorted_bag) == 0 {
			return {}, false
		}
		return st.sorted_bag[0].val, true
	case .Max:
		if len(st.sorted_bag) == 0 {
			return {}, false
		}
		return st.sorted_bag[len(st.sorted_bag) - 1].val, true
	case .Distinct:
		return i64(len(st.distinct_counts)), true
	case .Collect:
		if len(st.collect_entries) == 0 {
			return EMPTY_STRING, true
		}
		items := make([dynamic]string, 0, len(st.collect_entries), context.temp_allocator)
		for _, entry in st.collect_entries {
			s := ""
			switch x in entry.val {
			case String_Id:
				s = resolve_runtime_string(rb_int, sess_int, x)
			case i64:
				s = fmt.tprintf("%d", x)
			case i32:
				s = fmt.tprintf("%d", x)
			case f64:
				s = fmt.tprintf("%v", x)
			case bool:
				s = "true" if x else "false"
			case Entity_Id:
				s = fmt.tprintf("%d", u64(x))
			case Time_Ns:
				s = fmt.tprintf("%d", i64(x))
			case Enum_Val:
				s = fmt.tprintf("%d:%d", x.enum_id, x.variant)
			}
			for _ in 0 ..< int(entry.multiplicity) {
				append(&items, s)
			}
		}
		slice.sort(items[:])
		joined := strings.join(items[:], ",", context.temp_allocator)
		if sess_int != nil {
			sid, _ := intern_session_string(rb_int, sess_int, joined)
			return sid, true
		}
		return EMPTY_STRING, true
	}
	return {}, false
}

@(private)
_accum_get_or_create_mem :: proc(s: ^Session, node_id: u32) -> ^Accum_Memory {
	if am, has := s.accum_mems[node_id]; has {
		return am
	}
	am := new(Accum_Memory, s.allocator)
	am.node_id = node_id
	am.last_alpha_version = max(u64)
	am.groups = make(map[Accum_Group_Key]Accum_State, 8, s.allocator)
	am.group_tokens = make(map[Accum_Group_Key]i64, 8, s.allocator)
	am.fact_to_groups = make(map[Fact_Id][dynamic]Accum_Group_Key, 8, s.allocator)
	am.tracked_facts = make(map[Fact_Id]Accum_Tracked_Fact, 16, s.allocator)
	s.accum_mems[node_id] = am
	s.live_memories_count += 1
	_record_live_memory_watermark(s)
	return am
}

@(private)
_accum_make_group_key :: proc(s: ^Session, tok: ^Beta_Token, slots: []u16) -> Accum_Group_Key {
	gk: Accum_Group_Key
	n := min(len(slots), MAX_ACCUM_GROUP_COLS)
	gk.count = u8(n)
	for i := 0; i < n; i += 1 {
		vk, _ := _accum_unique_value_key(tok.vars[slots[i]], &s.rb.interner, &s.interner)
		gk.keys[i] = vk
	}
	return gk
}

@(private)
_accum_extract_right_group_key :: proc(
	s: ^Session,
	rf: ^Fact,
	step0: Subnetwork_Step,
	slots: []u16,
) -> (gk: Accum_Group_Key, ok: bool) {
	if len(step0.join_keys) != len(slots) {
		return {}, false
	}
	n := min(len(slots), MAX_ACCUM_GROUP_COLS)
	gk.count = u8(n)
	for i := 0; i < n; i += 1 {
		target_slot := slots[i]
		matched := false
		for jk in step0.join_keys {
			if jk.left_var_slot == target_slot {
				v, fok := fact_get_field(s, rf, jk.right_field_idx)
				if !fok {
					return {}, false
				}
				vk, _ := _accum_unique_value_key(v, &s.rb.interner, &s.interner)
				gk.keys[i] = vk
				matched = true
				break
			}
		}
		if !matched {
			return {}, false
		}
	}
	return gk, true
}

@(private)
_accum_can_track_incrementally :: proc(sub: Subnetwork_Def) -> bool {
	if sub.uses_outer_fact || len(sub.steps) == 0 || sub.steps[0].kind != .Pattern {
		return false
	}
	for st in sub.steps[1:] {
		if st.kind == .Pattern {
			return false
		}
	}
	if len(sub.group_var_slots) > MAX_ACCUM_GROUP_COLS {
		return false
	}
	if len(sub.group_var_slots) != len(sub.steps[0].join_keys) {
		return false
	}
	// Verify every group_var_slot is covered 1:1 by step[0].join_keys.
	for gslot in sub.group_var_slots {
		covered := false
		for jk in sub.steps[0].join_keys {
			if jk.left_var_slot == gslot {
				covered = true
				break
			}
		}
		if !covered {
			return false
		}
	}
	return true
}

@(private)
_accum_eval_item_value :: proc(
	s: ^Session,
	sub: Subnetwork_Def,
	tok: ^Beta_Token,
) -> (val: Value, pass_guard: bool, err: Session_Error) {
	fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding
	fslots := _fill_vm_fact_slots(s, tok, fact_slots_buf[:])

	if sub.accum_guard_prog >= 0 {
		gv, gerr := vm_eval(
			&s.rb.programs[sub.accum_guard_prog],
			tok.vars[:],
			fslots,
			s.rb.tables,
			&s.rb.interner,
			tok.decide_results[:],
			&s.interner,
		)
		if gerr != .None {
			return {}, false, .Vm_Eval_Failed
		}
		if gv != Value(true) {
			return {}, false, .None
		}
	}

	if sub.accum_expr_fact_slot >= 0 {
		fs := int(sub.accum_expr_fact_slot)
		if fs < int(tok.fact_count) {
			return i64(tok.fact_ids[fs]), true, .None
		}
		return i64(1), true, .None
	}
	if sub.accum_expr_prog >= 0 {
		ev, eerr := vm_eval(
			&s.rb.programs[sub.accum_expr_prog],
			tok.vars[:],
			fslots,
			s.rb.tables,
			&s.rb.interner,
			tok.decide_results[:],
			&s.interner,
		)
		if eerr != .None {
			return {}, false, .Vm_Eval_Failed
		}
		return ev, true, .None
	}
	return i64(1), true, .None
}

// Incrementally syncs an Accum_Memory against step[0]'s Alpha_Memory and evaluates `outer_tok`.
@(private)
beta_accum_eval_token :: proc(
	s: ^Session,
	bn: Beta_Node_Def,
	sub: Subnetwork_Def,
	outer_tok: Beta_Token,
) -> (out_tok: Beta_Token, emit: bool, err: Session_Error) {
	if _accum_can_track_incrementally(sub) {
		step0 := sub.steps[0]
		am_acc := _accum_get_or_create_mem(s, bn.id)
		alpha_m, has_alpha := s.alpha_mems[step0.alpha_mem_id]
		cur_ver := alpha_m.version if has_alpha else u64(0)

		if am_acc.last_alpha_version != cur_ver {
			// Retract any facts removed since last sync.
			to_remove := make([dynamic]Fact_Id, 0, 8, context.temp_allocator)
			for fid, rec in am_acc.tracked_facts {
				in_am := has_alpha && (fid in alpha_m.fact_pos) && s.facts[fid].alive && s.facts[fid].recency == rec.recency
				if !in_am {
					if rec.included {
						if gstate, has_g := &am_acc.groups[rec.group_key]; has_g {
							accum_retract(gstate, rec.val, &s.rb.interner, &s.interner)
						}
					}
					append(&to_remove, fid)
				}
			}
			for fid in to_remove {
				delete_key(&am_acc.tracked_facts, fid)
			}

			// Insert any new facts added to alpha_m.
			if has_alpha {
				for fid in alpha_m.fact_ids {
					if fid in am_acc.tracked_facts {
						continue
					}
					rf := &s.facts[fid]
					if !rf.alive {
						continue
					}
					gk, gk_ok := _accum_extract_right_group_key(s, rf, step0, sub.group_var_slots)
					if !gk_ok {
						am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
						continue
					}

					// Build a synthetic token for inner filters/guard evaluation.
					syn := Beta_Token{}
					for jk in step0.join_keys {
						rv, _ := fact_get_field(s, rf, jk.right_field_idx)
						if int(jk.left_var_slot) < MAX_TOKEN_VARS {
							syn.vars[jk.left_var_slot] = rv
						}
					}
					// Place fact at `step0.fact_slot`
					if int(step0.fact_slot) < MAX_TOKEN_FACTS {
						syn.fact_ids[step0.fact_slot] = rf.id
						syn.fact_count = step0.fact_slot + 1
					}
					for b in step0.field_binds {
						if int(b.var_slot) < MAX_TOKEN_VARS {
							if v, fok := fact_get_field(s, rf, b.field_idx); fok {
								syn.vars[b.var_slot] = v
							}
						}
					}

					// Evaluate inner WHERE filters (steps[1..]).
					passed_where := true
					fact_slots_buf: [MAX_TOKEN_FACTS]Vm_Fact_Binding
					for st in sub.steps[1:] {
						if st.kind == .Where && st.guard_prog >= 0 {
							fslots := _fill_vm_fact_slots(s, &syn, fact_slots_buf[:])
							wv, werr := vm_eval(
								&s.rb.programs[st.guard_prog],
								syn.vars[:],
								fslots,
								s.rb.tables,
								&s.rb.interner,
								syn.decide_results[:],
								&s.interner,
							)
							if werr != .None {
								return {}, false, .Vm_Eval_Failed
							}
							if wv != Value(true) {
								passed_where = false
								break
							}
						}
					}
					if !passed_where {
						am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
						continue
					}

					item_val, pass_g := _accum_eval_item_value(s, sub, &syn) or_return
					if !pass_g {
						am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
						continue
					}

					gstate, has_g := &am_acc.groups[gk]
					if !has_g {
						st_init: Accum_State
						accum_init(&st_init, sub.accum_op, s.allocator)
						am_acc.groups[gk] = st_init
						gstate = &am_acc.groups[gk]
					}
					accum_insert(gstate, item_val, &s.rb.interner, &s.interner)
					am_acc.tracked_facts[fid] = Accum_Tracked_Fact{
						included  = true,
						recency   = rf.recency,
						group_key = gk,
						val       = item_val,
					}
				}
			}
			am_acc.last_alpha_version = cur_ver
		}

		// Finalize accumulator state for outer_tok's group key.
		tok := outer_tok
		gk := _accum_make_group_key(s, &tok, sub.group_var_slots)
		val: Value
		valid: bool
		if gstate, has_g := &am_acc.groups[gk]; has_g {
			val, valid = accum_finalize(gstate, &s.rb.interner, &s.interner)
		} else {
			empty_st: Accum_State
			accum_init(&empty_st, sub.accum_op, context.temp_allocator)
			val, valid = accum_finalize(&empty_st, &s.rb.interner, &s.interner)
			accum_destroy(&empty_st)
		}
		if !valid {
			return {}, false, .None
		}
		if int(bn.var_slot) < MAX_TOKEN_VARS {
			tok.vars[bn.var_slot] = val
		}
		tok.fact_sig_hash = _hash_combine64(tok.fact_sig_hash, _hash_value_key(s, val))
		return tok, true, .None
	}

	// Fallback path for multi-pattern or cross-variable inner subnetworks.
	matches := make([dynamic]Beta_Token, 0, 8, context.temp_allocator)
	_ = subnetwork_eval_for_token(s, sub, outer_tok, &matches) or_return

	st: Accum_State
	accum_init(&st, sub.accum_op, context.temp_allocator)
	defer accum_destroy(&st)

	for &m in matches {
		item_val, pass_g := _accum_eval_item_value(s, sub, &m) or_return
		if pass_g {
			accum_insert(&st, item_val, &s.rb.interner, &s.interner)
		}
	}
	val, valid := accum_finalize(&st, &s.rb.interner, &s.interner)
	if !valid {
		return {}, false, .None
	}
	tok := outer_tok
	if int(bn.var_slot) < MAX_TOKEN_VARS {
		tok.vars[bn.var_slot] = val
	}
	tok.fact_sig_hash = _hash_combine64(tok.fact_sig_hash, _hash_value_key(s, val))
	return tok, true, .None
}
