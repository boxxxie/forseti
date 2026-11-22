package forseti

import "core:fmt"
import "core:math"
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
	op:                  Accum_Op,
	count:               i64,
	sum_i64:             i64,
	f64_counts:          map[u64]i32,
	f64_sum:             f64,
	f64_comp:            f64,
	f64_max_abs:         f64,
	f64_count:           i64,
	f64_nonfinite_count: i64,
	f64_dirty:           bool,
	bag_heap:            [dynamic]Accum_Bag_Entry,
	bag_counts:          map[Value_Key]Accum_Bag_Entry,
	distinct_counts:     map[Value_Key]i32,
	collect_entries:     map[Value_Key]Accum_Bag_Entry,
	allocator:           mem.Allocator,
}

Accum_Tracked_Fact :: struct {
	included:  bool,
	recency:   u64,
	group_key: Accum_Group_Key,
	val:       Value,
}

Accum_Outer_Node :: struct {
	fid:       Fact_Id,
	gk:        Accum_Group_Key,
	last_hash: u64,
	has_hash:  bool,
	prev:      i32,
	next:      i32,
}

Accum_Memory :: struct {
	node_id:             u32,
	last_alpha_version:  u64,
	last_retract_epoch:  u64,
	last_insert_epoch:   u64,
	last_indexed_count:  int,
	groups:              map[Accum_Group_Key]Accum_State,
	dirty_groups:        map[Accum_Group_Key]bool,
	tracked_facts:       map[Fact_Id]Accum_Tracked_Fact,
	outer_initialized:   bool,
	outer_alpha_version: u64,
	outer_retract_epoch: u64,
	outer_insert_epoch:  u64,
	outer_indexed_count: int,
	outer_by_group:      map[Accum_Group_Key]i32,
	outer_fact_node:     map[Fact_Id]i32,
	outer_nodes:         [dynamic]Accum_Outer_Node,
	free_outer_nodes:    [dynamic]i32,
}

accum_init :: proc(st: ^Accum_State, op: Accum_Op, allocator := context.allocator) {
	st^ = {}
	st.op = op
	st.allocator = allocator
	switch op {
	case .Count, .Sum, .Avg:
		// f64_counts initializes lazily on first f64 value
	case .Min, .Max:
		st.bag_heap = make([dynamic]Accum_Bag_Entry, 0, 8, allocator)
		st.bag_counts = make(map[Value_Key]Accum_Bag_Entry, 8, allocator)
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
	delete(st.f64_counts)
	delete(st.bag_heap)
	delete(st.bag_counts)
	delete(st.distinct_counts)
	delete(st.collect_entries)
	st^ = {}
}

@(private)
_accum_f64_canonical_bits :: #force_inline proc "contextless" (v: f64) -> u64 {
	if math.is_nan(v) {
		return 0x7ff8000000000000
	}
	if v == 0.0 {
		return 0
	}
	return transmute(u64)v
}

@(private)
_accum_f64_is_finite :: #force_inline proc "contextless" (v: f64) -> bool {
	return !math.is_nan(v) && !math.is_inf(v, 0)
}

@(private)
_accum_heap_better :: #force_inline proc "contextless" (a, b: Accum_Bag_Entry, is_max: bool) -> bool {
	c := _accum_entry_cmp(a, b)
	return c > 0 if is_max else c < 0
}

@(private)
_accum_heap_push :: proc(h: ^[dynamic]Accum_Bag_Entry, e: Accum_Bag_Entry, is_max: bool) {
	idx := len(h^)
	append(h, e)
	for idx > 0 {
		parent := (idx - 1) >> 1
		if _accum_heap_better(h^[idx], h^[parent], is_max) {
			h^[idx], h^[parent] = h^[parent], h^[idx]
			idx = parent
		} else {
			break
		}
	}
}

@(private)
_accum_heap_pop :: proc(h: ^[dynamic]Accum_Bag_Entry, is_max: bool) {
	n := len(h^)
	if n == 0 {
		return
	}
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
			if right < n && _accum_heap_better(h^[right], h^[left], is_max) {
				best = right
			}
			if _accum_heap_better(h^[best], h^[idx], is_max) {
				h^[idx], h^[best] = h^[best], h^[idx]
				idx = best
			} else {
				break
			}
		}
	}
}

@(private)
_accum_heap_compact :: proc(st: ^Accum_State, is_max: bool) {
	clear(&st.bag_heap)
	for _, entry in st.bag_counts {
		if entry.multiplicity > 0 {
			append(&st.bag_heap, entry)
		}
	}
	n := len(st.bag_heap)
	if n <= 1 {
		return
	}
	for start := n / 2 - 1; start >= 0; start -= 1 {
		idx := start
		for {
			left := (idx << 1) + 1
			if left >= n {
				break
			}
			best := left
			right := left + 1
			if right < n && _accum_heap_better(st.bag_heap[right], st.bag_heap[left], is_max) {
				best = right
			}
			if _accum_heap_better(st.bag_heap[best], st.bag_heap[idx], is_max) {
				st.bag_heap[idx], st.bag_heap[best] = st.bag_heap[best], st.bag_heap[idx]
				idx = best
			} else {
				break
			}
		}
	}
}

@(private)
_accum_f64_total :: proc(st: ^Accum_State) -> f64 {
	if st.f64_count <= 0 {
		return 0
	}
	if !st.f64_dirty && st.f64_nonfinite_count == 0 {
		return st.f64_sum + st.f64_comp
	}
	if st.f64_nonfinite_count > 0 {
		total := 0.0
		for bits, mult in st.f64_counts {
			if mult <= 0 {
				continue
			}
			v := transmute(f64)bits
			if !_accum_f64_is_finite(v) {
				reps := min(int(mult), 2)
				for _ in 0 ..< reps {
					total += v
				}
			} else {
				total += v * f64(mult)
			}
		}
		return total
	}
	// Exact Neumaier recomputation over remaining finite floats.
	sum := 0.0
	comp := 0.0
	max_abs := 0.0
	for bits, mult in st.f64_counts {
		if mult <= 0 {
			continue
		}
		v := transmute(f64)bits * f64(mult)
		av := math.abs(v)
		if av > max_abs {
			max_abs = av
		}
		t := sum + v
		if math.abs(sum) >= av {
			comp += (sum - t) + v
		} else {
			comp += (v - t) + sum
		}
		sum = t
	}
	st.f64_sum = sum
	st.f64_comp = comp
	st.f64_max_abs = max_abs
	st.f64_dirty = false
	return sum + comp
}

@(private)
_accum_entry_cmp :: proc "contextless" (a, b: Accum_Bag_Entry) -> int {
	if a.is_num != b.is_num {
		return -1 if a.is_num else 1
	}
	if a.is_num && b.is_num {
		a_nan := math.is_nan(a.num_val)
		b_nan := math.is_nan(b.num_val)
		if a_nan != b_nan {
			return 1 if a_nan else -1
		}
		if !a_nan {
			if a.num_val < b.num_val {
				return -1
			}
			if a.num_val > b.num_val {
				return 1
			}
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
			bits := _accum_f64_canonical_bits(fv)
			if cap(st.f64_counts) == 0 {
				st.f64_counts = make(map[u64]i32, 4, st.allocator)
			}
			st.f64_counts[bits] = (st.f64_counts[bits] or_else 0) + 1
			st.f64_count += 1
			if !_accum_f64_is_finite(fv) {
				st.f64_nonfinite_count += 1
				st.f64_dirty = true
			} else {
				av := math.abs(fv)
				if av > st.f64_max_abs {
					st.f64_max_abs = av
				}
				if !st.f64_dirty {
					t := st.f64_sum + fv
					if math.abs(st.f64_sum) >= av {
						st.f64_comp += (st.f64_sum - t) + fv
					} else {
						st.f64_comp += (fv - t) + st.f64_sum
					}
					st.f64_sum = t
					if st.f64_max_abs > 0 && math.abs(st.f64_sum + st.f64_comp) <= st.f64_max_abs * 1e-6 {
						st.f64_dirty = true
					}
				}
			}
		} else if iv, i_ok := value_to_i64(v); i_ok {
			st.sum_i64 += iv
		}
	case .Min, .Max:
		entry := _accum_make_bag_entry(v, rb_int, sess_int)
		if cur, has := &st.bag_counts[entry.key]; has {
			was_zero := cur.multiplicity <= 0
			cur.multiplicity += 1
			if was_zero {
				_accum_heap_push(&st.bag_heap, cur^, st.op == .Max)
			}
		} else {
			st.bag_counts[entry.key] = entry
			_accum_heap_push(&st.bag_heap, entry, st.op == .Max)
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
			bits := _accum_f64_canonical_bits(fv)
			if cur, has := st.f64_counts[bits]; has && cur > 0 {
				if cur <= 1 {
					delete_key(&st.f64_counts, bits)
				} else {
					st.f64_counts[bits] = cur - 1
				}
				st.f64_count -= 1
				if st.f64_count <= 0 {
					st.f64_count = 0
					st.f64_sum = 0
					st.f64_comp = 0
					st.f64_max_abs = 0
					st.f64_nonfinite_count = 0
					st.f64_dirty = false
				} else if !_accum_f64_is_finite(fv) {
					if st.f64_nonfinite_count > 0 {
						st.f64_nonfinite_count -= 1
					}
					st.f64_dirty = true
				} else if !st.f64_dirty {
					nv := -fv
					av := math.abs(nv)
					t := st.f64_sum + nv
					if math.abs(st.f64_sum) >= av {
						st.f64_comp += (st.f64_sum - t) + nv
					} else {
						st.f64_comp += (nv - t) + st.f64_sum
					}
					st.f64_sum = t
					if st.f64_max_abs > 0 && (av >= st.f64_max_abs * 0.5 || math.abs(st.f64_sum + st.f64_comp) <= st.f64_max_abs * 1e-6) {
						st.f64_dirty = true
					}
				}
			}
		} else if iv, i_ok := value_to_i64(v); i_ok {
			st.sum_i64 -= iv
		}
	case .Min, .Max:
		vk, _ := _accum_unique_value_key(v, rb_int, sess_int)
		if cur, has := &st.bag_counts[vk]; has {
			cur.multiplicity -= 1
			if cur.multiplicity <= 0 {
				delete_key(&st.bag_counts, vk)
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
		if st.f64_count > 0 {
			return f64(st.sum_i64) + _accum_f64_total(st), true
		}
		return st.sum_i64, true
	case .Avg:
		if st.count <= 0 {
			return {}, false
		}
		total := f64(st.sum_i64) + _accum_f64_total(st)
		return total / f64(st.count), true
	case .Min, .Max:
		is_max := st.op == .Max
		for len(st.bag_heap) > 0 {
			top := st.bag_heap[0]
			if cur, has := st.bag_counts[top.key]; has && cur.multiplicity > 0 {
				if len(st.bag_heap) > 64 && len(st.bag_heap) > len(st.bag_counts) * 2 {
					_accum_heap_compact(st, is_max)
				}
				return st.bag_heap[0].val, true
			}
			_accum_heap_pop(&st.bag_heap, is_max)
		}
		return {}, false
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
	am.last_retract_epoch = max(u64)
	am.outer_alpha_version = max(u64)
	am.outer_retract_epoch = max(u64)
	am.groups = make(map[Accum_Group_Key]Accum_State, 8, s.allocator)
	am.dirty_groups = make(map[Accum_Group_Key]bool, 8, s.allocator)
	am.tracked_facts = make(map[Fact_Id]Accum_Tracked_Fact, 16, s.allocator)
	am.outer_by_group = make(map[Accum_Group_Key]i32, 8, s.allocator)
	am.outer_fact_node = make(map[Fact_Id]i32, 8, s.allocator)
	am.outer_nodes = make([dynamic]Accum_Outer_Node, 0, 8, s.allocator)
	am.free_outer_nodes = make([dynamic]i32, 0, 8, s.allocator)
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
			_token_decide_slice(s, tok),
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
			_token_decide_slice(s, tok),
			&s.interner,
		)
		if eerr != .None {
			return {}, false, .Vm_Eval_Failed
		}
		return ev, true, .None
	}
	return i64(1), true, .None
}

@(private)
_accum_finalize_empty :: proc(op: Accum_Op) -> (val: Value, valid: bool) {
	switch op {
	case .Count, .Sum, .Distinct:
		return i64(0), true
	case .Collect:
		return EMPTY_STRING, true
	case .Avg, .Min, .Max:
		return {}, false
	}
	return {}, false
}

@(private)
_accum_try_insert_right_fact :: proc(
	s: ^Session,
	am_acc: ^Accum_Memory,
	sub: Subnetwork_Def,
	step0: Subnetwork_Step,
	fid: Fact_Id,
) -> Session_Error {
	rf := &s.facts[fid]
	if !rf.alive {
		return .None
	}
	gk, gk_ok := _accum_extract_right_group_key(s, rf, step0, sub.group_var_slots)
	if !gk_ok {
		am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
		return .None
	}

	syn := Beta_Token{}
	for jk in step0.join_keys {
		rv, _ := fact_get_field(s, rf, jk.right_field_idx)
		if int(jk.left_var_slot) < MAX_TOKEN_VARS {
			syn.vars[jk.left_var_slot] = rv
		}
	}
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
				nil,
				&s.interner,
			)
			if werr != .None {
				return .Vm_Eval_Failed
			}
			if wv != Value(true) {
				am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
				return .None
			}
		}
	}

	item_val, pass_g := _accum_eval_item_value(s, sub, &syn) or_return
	if !pass_g {
		am_acc.tracked_facts[fid] = Accum_Tracked_Fact{included = false, recency = rf.recency}
		return .None
	}

	gstate, has_g := &am_acc.groups[gk]
	if !has_g {
		st_init: Accum_State
		accum_init(&st_init, sub.accum_op, s.allocator)
		am_acc.groups[gk] = st_init
		gstate = &am_acc.groups[gk]
	}
	accum_insert(gstate, item_val, &s.rb.interner, &s.interner)
	am_acc.dirty_groups[gk] = true
	am_acc.tracked_facts[fid] = Accum_Tracked_Fact{
		included  = true,
		recency   = rf.recency,
		group_key = gk,
		val       = item_val,
	}
	return .None
}

@(private)
_accum_sync_inner :: proc(
	s: ^Session,
	am_acc: ^Accum_Memory,
	sub: Subnetwork_Def,
) -> Session_Error {
	step0 := sub.steps[0]
	alpha_m, has_alpha := s.alpha_mems[step0.alpha_mem_id]
	cur_ver := alpha_m.version if has_alpha else u64(0)
	if am_acc.last_alpha_version == cur_ver {
		return .None
	}

	if !has_alpha {
		if len(am_acc.tracked_facts) > 0 {
			for _, rec in am_acc.tracked_facts {
				if rec.included {
					if gstate, has_g := &am_acc.groups[rec.group_key]; has_g {
						accum_retract(gstate, rec.val, &s.rb.interner, &s.interner)
						am_acc.dirty_groups[rec.group_key] = true
					}
				}
			}
			clear(&am_acc.tracked_facts)
		}
		am_acc.last_retract_epoch = max(u64)
		am_acc.last_insert_epoch = 0
		am_acc.last_indexed_count = 0
		am_acc.last_alpha_version = 0
		return .None
	}

	ins_buf: [MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	can_delta, _, inserts, r_start, r_end := _alpha_collect_delta_window(
		s,
		alpha_m,
		am_acc.last_retract_epoch,
		am_acc.last_insert_epoch,
		am_acc.last_indexed_count,
		&ins_buf,
	)
	if can_delta {
		for e := r_start; e < r_end; e += 1 {
			rfid := alpha_m.recent_retracts[e % MAX_ALPHA_DELTA_LOG]
			if rec, has := am_acc.tracked_facts[rfid]; has {
				if rec.included {
					if gstate, has_g := &am_acc.groups[rec.group_key]; has_g {
						accum_retract(gstate, rec.val, &s.rb.interner, &s.interner)
						am_acc.dirty_groups[rec.group_key] = true
					}
				}
				delete_key(&am_acc.tracked_facts, rfid)
			}
		}
		for fid in inserts {
			rf := &s.facts[fid]
			if !rf.alive {
				continue
			}
			if prev_rec, has_prev := am_acc.tracked_facts[fid]; has_prev {
				if prev_rec.recency == rf.recency {
					continue
				}
				if prev_rec.included {
					if gstate, has_g := &am_acc.groups[prev_rec.group_key]; has_g {
						accum_retract(gstate, prev_rec.val, &s.rb.interner, &s.interner)
						am_acc.dirty_groups[prev_rec.group_key] = true
					}
				}
				delete_key(&am_acc.tracked_facts, fid)
			}
			_accum_try_insert_right_fact(s, am_acc, sub, step0, fid) or_return
		}
		am_acc.last_retract_epoch = alpha_m.retract_epoch
		am_acc.last_insert_epoch = alpha_m.insert_epoch
		am_acc.last_indexed_count = len(alpha_m.fact_ids)
		am_acc.last_alpha_version = cur_ver
		return .None
	}

	// Fallback full reconciliation against alpha_m.
	to_remove := make([dynamic]Fact_Id, 0, 8, context.temp_allocator)
	for fid, rec in am_acc.tracked_facts {
		in_am := (fid in alpha_m.fact_pos) && s.facts[fid].alive && s.facts[fid].recency == rec.recency
		if !in_am {
			if rec.included {
				if gstate, has_g := &am_acc.groups[rec.group_key]; has_g {
					accum_retract(gstate, rec.val, &s.rb.interner, &s.interner)
					am_acc.dirty_groups[rec.group_key] = true
				}
			}
			append(&to_remove, fid)
		}
	}
	for fid in to_remove {
		delete_key(&am_acc.tracked_facts, fid)
	}
	for fid in alpha_m.fact_ids {
		if fid in am_acc.tracked_facts {
			continue
		}
		_accum_try_insert_right_fact(s, am_acc, sub, step0, fid) or_return
	}
	am_acc.last_retract_epoch = alpha_m.retract_epoch
	am_acc.last_insert_epoch = alpha_m.insert_epoch
	am_acc.last_indexed_count = len(alpha_m.fact_ids)
	am_acc.last_alpha_version = cur_ver
	return .None
}

@(private)
_accum_extract_left_group_key :: proc(
	s: ^Session,
	f: ^Fact,
	lia_binds: []Alpha_Field_Bind,
	slots: []u16,
) -> (gk: Accum_Group_Key, ok: bool) {
	n := min(len(slots), MAX_ACCUM_GROUP_COLS)
	gk.count = u8(n)
	for i := 0; i < n; i += 1 {
		target_slot := slots[i]
		matched := false
		for fb in lia_binds {
			if fb.var_slot == target_slot {
				v, fok := fact_get_field(s, f, fb.field_idx)
				if fok {
					gk.keys[i], _ = _accum_unique_value_key(v, &s.rb.interner, &s.interner)
				}
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
_accum_outer_insert :: proc(
	s: ^Session,
	am_acc: ^Accum_Memory,
	lia_bn: Beta_Node_Def,
	sub: Subnetwork_Def,
	fid: Fact_Id,
) {
	f := &s.facts[fid]
	if !f.alive || (fid in am_acc.outer_fact_node) {
		return
	}
	gk, _ := _accum_extract_left_group_key(s, f, lia_bn.field_binds, sub.group_var_slots)
	nidx: i32
	if len(am_acc.free_outer_nodes) > 0 {
		nidx = pop(&am_acc.free_outer_nodes)
	} else {
		nidx = i32(len(am_acc.outer_nodes))
		append(&am_acc.outer_nodes, Accum_Outer_Node{})
	}
	old_head := i32(-1)
	if oh, has := am_acc.outer_by_group[gk]; has {
		old_head = oh
	}
	am_acc.outer_nodes[nidx] = Accum_Outer_Node{
		fid  = fid,
		gk   = gk,
		prev = -1,
		next = old_head,
	}
	if old_head >= 0 {
		am_acc.outer_nodes[old_head].prev = nidx
	}
	am_acc.outer_by_group[gk] = nidx
	am_acc.outer_fact_node[fid] = nidx
}

@(private)
_accum_outer_remove :: proc(s: ^Session, am_acc: ^Accum_Memory, rule_id: u32, fid: Fact_Id) {
	nidx, has := am_acc.outer_fact_node[fid]
	if !has {
		return
	}
	delete_key(&am_acc.outer_fact_node, fid)
	node := am_acc.outer_nodes[nidx]
	if node.has_hash {
		jtms_revoke_firing(s, Firing_Key{rule_id = rule_id, tok_hash = node.last_hash})
	}
	if node.prev >= 0 {
		am_acc.outer_nodes[node.prev].next = node.next
	} else {
		if node.next >= 0 {
			am_acc.outer_by_group[node.gk] = node.next
		} else {
			delete_key(&am_acc.outer_by_group, node.gk)
		}
	}
	if node.next >= 0 {
		am_acc.outer_nodes[node.next].prev = node.prev
	}
	am_acc.outer_nodes[nidx] = {}
	append(&am_acc.free_outer_nodes, nidx)
}

@(private)
_accum_rebuild_outer_index :: proc(
	s: ^Session,
	am_acc: ^Accum_Memory,
	lia_bn: Beta_Node_Def,
	sub: Subnetwork_Def,
	am_l: ^Alpha_Memory,
) {
	clear(&am_acc.outer_by_group)
	clear(&am_acc.outer_fact_node)
	clear(&am_acc.outer_nodes)
	clear(&am_acc.free_outer_nodes)
	if am_l != nil {
		for fid in am_l.fact_ids {
			_accum_outer_insert(s, am_acc, lia_bn, sub, fid)
		}
		am_acc.outer_retract_epoch = am_l.retract_epoch
		am_acc.outer_insert_epoch = am_l.insert_epoch
		am_acc.outer_indexed_count = len(am_l.fact_ids)
		am_acc.outer_alpha_version = am_l.version
	} else {
		am_acc.outer_retract_epoch = max(u64)
		am_acc.outer_insert_epoch = 0
		am_acc.outer_indexed_count = 0
		am_acc.outer_alpha_version = 0
	}
	am_acc.outer_initialized = true
}

@(private)
_accum_record_terminal_hashes :: proc(am_acc: ^Accum_Memory, tokens: []Beta_Token) {
	for &node in am_acc.outer_nodes {
		node.has_hash = false
		node.last_hash = 0
	}
	for tok in tokens {
		if tok.fact_count > 0 {
			if nidx, has := am_acc.outer_fact_node[tok.fact_ids[0]]; has {
				am_acc.outer_nodes[nidx].last_hash = tok.fact_sig_hash
				am_acc.outer_nodes[nidx].has_hash = true
			}
		}
	}
}

@(private)
_accum_try_delta_outer :: proc(
	s: ^Session,
	sm: ^Segment_Memory,
	seg: Segment_Def,
	lia_bn: Beta_Node_Def,
	accum_bn: Beta_Node_Def,
	out_tokens: ^[dynamic]Beta_Token,
) -> (used_delta: bool, err: Session_Error) {
	sub := s.rb.subnetworks[accum_bn.subnetwork_id]
	am_acc := _accum_get_or_create_mem(s, accum_bn.id)
	_accum_sync_inner(s, am_acc, sub) or_return

	am_l, has_l := s.alpha_mems[lia_bn.alpha_mem_id]
	if !am_acc.outer_initialized || sm.last_lia_epoch == max(u64) {
		_accum_rebuild_outer_index(s, am_acc, lia_bn, sub, am_l if has_l else nil)
		clear(&am_acc.dirty_groups)
		clear(&s.partial_reconcile_fids)
		clear(&s.partial_reconcile_seen)
		return false, .None
	}
	if !has_l {
		if len(am_acc.outer_fact_node) > 0 {
			// Fall back to full empty reconcile when outer alpha disappeared.
			_accum_rebuild_outer_index(s, am_acc, lia_bn, sub, nil)
		}
		clear(&am_acc.dirty_groups)
		clear(&s.partial_reconcile_fids)
		clear(&s.partial_reconcile_seen)
		return false, .None
	}

	ins_buf: [MAX_ALPHA_DELTA_LOG]Fact_Id = ---
	can_l, _, outer_inserts, r_start, r_end := _alpha_collect_delta_window(
		s,
		am_l,
		am_acc.outer_retract_epoch,
		am_acc.outer_insert_epoch,
		am_acc.outer_indexed_count,
		&ins_buf,
	)
	if !can_l {
		_accum_rebuild_outer_index(s, am_acc, lia_bn, sub, am_l)
		clear(&am_acc.dirty_groups)
		clear(&s.partial_reconcile_fids)
		clear(&s.partial_reconcile_seen)
		return false, .None
	}

	clear(&s.partial_reconcile_fids)
	clear(&s.partial_reconcile_seen)

	if am_acc.outer_alpha_version != am_l.version {
		for e := r_start; e < r_end; e += 1 {
			_accum_outer_remove(s, am_acc, seg.rule_id, am_l.recent_retracts[e % MAX_ALPHA_DELTA_LOG])
		}
		for lfid in outer_inserts {
			if nidx, already := am_acc.outer_fact_node[lfid]; already {
				_ = nidx
				_accum_outer_remove(s, am_acc, seg.rule_id, lfid)
			}
			_accum_outer_insert(s, am_acc, lia_bn, sub, lfid)
			if !(lfid in s.partial_reconcile_seen) {
				s.partial_reconcile_seen[lfid] = true
				append(&s.partial_reconcile_fids, lfid)
			}
		}
		am_acc.outer_indexed_count = len(am_l.fact_ids)
		am_acc.outer_retract_epoch = am_l.retract_epoch
		am_acc.outer_insert_epoch = am_l.insert_epoch
		am_acc.outer_alpha_version = am_l.version
	}

	for dgk in am_acc.dirty_groups {
		if head, has_h := am_acc.outer_by_group[dgk]; has_h {
			cur := head
			for cur >= 0 {
				node := am_acc.outer_nodes[cur]
				cur = node.next
				fid := node.fid
				if fid != INVALID_FACT && int(fid) < len(s.facts) && s.facts[fid].alive {
					if !(fid in s.partial_reconcile_seen) {
						s.partial_reconcile_seen[fid] = true
						append(&s.partial_reconcile_fids, fid)
					}
				}
			}
		}
	}
	clear(&am_acc.dirty_groups)

	base_tok := Beta_Token{fact_sig_hash = 0x544f4b00}
	for fid in s.partial_reconcile_fids {
		f := &s.facts[fid]
		if !f.alive {
			continue
		}
		if tok, ok := _token_extend_fact(s, &base_tok, f, lia_bn.field_binds); ok {
			append(out_tokens, tok)
		}
	}

	sm.last_lia_epoch = am_l.retract_epoch
	sm.last_lia_insert_epoch = am_l.insert_epoch
	sm.last_lia_len = len(am_l.fact_ids)
	sm.subnetwork_dirty = false
	return true, .None
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
		am_acc := _accum_get_or_create_mem(s, bn.id)
		_accum_sync_inner(s, am_acc, sub) or_return
		if len(am_acc.dirty_groups) > 0 && len(am_acc.outer_fact_node) == 0 {
			clear(&am_acc.dirty_groups)
		}

		// Finalize accumulator state for outer_tok's group key.
		tok := outer_tok
		gk := _accum_make_group_key(s, &tok, sub.group_var_slots)
		val: Value
		valid: bool
		if gstate, has_g := &am_acc.groups[gk]; has_g {
			val, valid = accum_finalize(gstate, &s.rb.interner, &s.interner)
		} else {
			val, valid = _accum_finalize_empty(sub.accum_op)
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
