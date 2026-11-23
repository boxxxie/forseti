package forseti

import "base:runtime"
import "core:math"
import "core:mem"
import "core:strings"
import xitdb "xitdb:."

RUNTIME_STRING_BIT :: u32(0x80000000)

Vm_Fact_Binding :: struct {
	fields:      []Value,
	field_names: []String_Id,
	cursor:      xitdb.Read_Cursor,
	has_cursor:  bool,
}

Vm_Op_Proc :: #type proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction)

Vm_State :: struct {
	regs:           [256]Value,
	vars:           []Value,
	fact_slots:     []Vm_Fact_Binding,
	consts:         []Value,
	field_refs:     []Field_Access_Desc,
	decide_calls:   []Decide_Call_Desc,
	ranges:         []Range_Desc,
	decide_results: []Decision_Result,
	tables:         []Compiled_Table,
	interner:       ^String_Interner,
	sess_interner:  ^String_Interner,
	dispatch:       ^[Opcode]Vm_Op_Proc,
	saved_ctx:      runtime.Context,
	steps_left:     i32,
	result:         Value,
	err:            Vm_Error,
}

resolve_runtime_string :: proc "contextless" (
	rb_int: ^String_Interner,
	sess_int: ^String_Interner,
	sid: String_Id,
) -> string {
	if sid == String_Id(INVALID_ID) {
		return ""
	}
	raw := u32(sid)
	if (raw & RUNTIME_STRING_BIT) != 0 {
		if sess_int == nil {
			return ""
		}
		return interner_get(sess_int, String_Id(raw & ~RUNTIME_STRING_BIT))
	}
	if rb_int != nil {
		return interner_get(rb_int, sid)
	}
	if sess_int != nil {
		return interner_get(sess_int, sid)
	}
	return ""
}

// Look up `s` in immutable `rb_int` first (read-only); only allocate into `sess_int` if unseen at compile time.
intern_session_string :: proc(
	rb_int: ^String_Interner,
	sess_int: ^String_Interner,
	s: string,
) -> (id: String_Id, err: Store_Error) {
	if len(s) == 0 {
		return EMPTY_STRING, nil
	}
	if rb_int != nil {
		if existing, ok := rb_int.lookup[s]; ok {
			return existing, nil
		}
	}
	if sess_int == nil {
		return String_Id(INVALID_ID), nil
	}
	local_id, i_err := intern(sess_int, s)
	if i_err != nil {
		return EMPTY_STRING, i_err
	}
	return String_Id(u32(local_id) | RUNTIME_STRING_BIT), nil
}

@(private)
_vm_eval_cmp_values :: proc "contextless" (
	vm: ^Vm_State,
	a: Value,
	b: Value,
	op: Binary_Op,
) -> (res: bool, err: Vm_Error) {
	// Numeric coercion across i32 / i64 / f64
	if fa, a_is_f := a.(f64); a_is_f {
		fb, b_ok := value_to_f64(b)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return fa == fb, .None
		case .Neq: return fa != fb, .None
		case .Lt:  return fa < fb, .None
		case .Lte: return fa <= fb, .None
		case .Gt:  return fa > fb, .None
		case .Gte: return fa >= fb, .None
		}
	}
	if fb, b_is_f := b.(f64); b_is_f {
		fa, a_ok := value_to_f64(a)
		if !a_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return fa == fb, .None
		case .Neq: return fa != fb, .None
		case .Lt:  return fa < fb, .None
		case .Lte: return fa <= fb, .None
		case .Gt:  return fa > fb, .None
		case .Gte: return fa >= fb, .None
		}
	}
	if ia, a_ok := value_to_i64(a); a_ok {
		ib, b_ok := value_to_i64(b)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return ia == ib, .None
		case .Neq: return ia != ib, .None
		case .Lt:  return ia < ib, .None
		case .Lte: return ia <= ib, .None
		case .Gt:  return ia > ib, .None
		case .Gte: return ia >= ib, .None
		}
	}
	if ba, a_ok := a.(bool); a_ok {
		bb, b_ok := b.(bool)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return ba == bb, .None
		case .Neq: return ba != bb, .None
		case:      return false, .Type_Mismatch
		}
	}
	if ta, a_ok := a.(Time_Ns); a_ok {
		tb, b_ok := b.(Time_Ns)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return ta == tb, .None
		case .Neq: return ta != tb, .None
		case .Lt:  return ta < tb, .None
		case .Lte: return ta <= tb, .None
		case .Gt:  return ta > tb, .None
		case .Gte: return ta >= tb, .None
		}
	}
	if ea, a_ok := a.(Entity_Id); a_ok {
		eb, b_ok := b.(Entity_Id)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return ea == eb, .None
		case .Neq: return ea != eb, .None
		case:      return false, .Type_Mismatch
		}
	}
	if eva, a_ok := a.(Enum_Val); a_ok {
		evb, b_ok := b.(Enum_Val)
		if !b_ok {
			return false, .Type_Mismatch
		}
		#partial switch op {
		case .Eq:  return eva == evb, .None
		case .Neq: return eva != evb, .None
		case:      return false, .Type_Mismatch
		}
	}
	if sa, a_ok := a.(String_Id); a_ok {
		sb, b_ok := b.(String_Id)
		if !b_ok {
			return false, .Type_Mismatch
		}
		if sa == String_Id(INVALID_ID) || sb == String_Id(INVALID_ID) {
			#partial switch op {
			case .Eq:  return false, .None
			case .Neq: return true, .None
			case:      return false, .Type_Mismatch
			}
		}
		if sa == sb && (op == .Eq || op == .Neq) {
			return op == .Eq, .None
		}
		ta := resolve_runtime_string(vm.interner, vm.sess_interner, sa)
		tb := resolve_runtime_string(vm.interner, vm.sess_interner, sb)
		#partial switch op {
		case .Eq:  return ta == tb, .None
		case .Neq: return ta != tb, .None
		case .Lt:  return ta < tb, .None
		case .Lte: return ta <= tb, .None
		case .Gt:  return ta > tb, .None
		case .Gte: return ta >= tb, .None
		}
	}
	if a == nil && b == nil {
		#partial switch op {
		case .Eq:  return true, .None
		case .Neq: return false, .None
		case:      return false, .Type_Mismatch
		}
	}
	return false, .Type_Mismatch
}

@(private)
_vm_helper_load_field :: proc "contextless" (vm: ^Vm_State, dst: u8, ref_idx: u16) {
	if int(ref_idx) >= len(vm.field_refs) {
		vm.err = .Missing_Field
		return
	}
	fr := vm.field_refs[ref_idx]
	if int(fr.fact_slot) >= len(vm.fact_slots) {
		vm.err = .Missing_Field
		return
	}
	fb := vm.fact_slots[fr.fact_slot]
	if fr.field_idx >= 0 && int(fr.field_idx) < len(fb.fields) {
		vm.regs[dst] = fb.fields[fr.field_idx]
		return
	}
	if !fb.has_cursor {
		vm.err = .Missing_Field
		return
	}

	context = vm.saved_ctx
	if vm.sess_interner != nil {
		raw_val: Value
		found: bool
		f_err: Store_Error
		if len(fr.seg_hashes) > 0 {
			raw_val, found, f_err = cursor_read_field_path_prehashed(fb.cursor, fr.seg_hashes, vm.sess_interner, fr.expected_type)
		} else {
			raw_val, found, f_err = cursor_read_field_path(fb.cursor, fr.segments, vm.sess_interner, fr.expected_type)
		}
		if f_err != nil || !found {
			vm.err = .Missing_Field
			return
		}
		if sid, is_s := raw_val.(String_Id); is_s {
			txt := interner_get(vm.sess_interner, sid)
			mapped, m_err := intern_session_string(vm.interner, vm.sess_interner, txt)
			if m_err != nil {
				vm.err = .Missing_Field
				return
			}
			vm.regs[dst] = mapped
		} else {
			vm.regs[dst] = raw_val
		}
		return
	}

	// Read-only probe against immutable interner when no session interner is supplied (e.g. unit test).
	tmp_int: String_Interner
	if interner_init(&tmp_int, context.allocator) != nil {
		vm.err = .Missing_Field
		return
	}
	defer interner_destroy(&tmp_int)

	raw_val: Value
	found: bool
	f_err: Store_Error
	if len(fr.seg_hashes) > 0 {
		raw_val, found, f_err = cursor_read_field_path_prehashed(fb.cursor, fr.seg_hashes, &tmp_int, fr.expected_type)
	} else {
		raw_val, found, f_err = cursor_read_field_path(fb.cursor, fr.segments, &tmp_int, fr.expected_type)
	}
	if f_err != nil || !found {
		vm.err = .Missing_Field
		return
	}
	if sid, is_s := raw_val.(String_Id); is_s {
		txt := interner_get(&tmp_int, sid)
		if len(txt) == 0 {
			vm.regs[dst] = EMPTY_STRING
			return
		}
		if vm.interner != nil {
			if rb_sid, has := vm.interner.lookup[txt]; has {
				vm.regs[dst] = rb_sid
				return
			}
		}
		vm.regs[dst] = String_Id(INVALID_ID)
	} else {
		vm.regs[dst] = raw_val
	}
}

@(private)
_vm_helper_decide_call :: proc "contextless" (vm: ^Vm_State, dst: u8, desc_idx: u8, res_slot: u8) {
	if int(desc_idx) >= len(vm.decide_calls) {
		vm.err = .Unknown_Table
		return
	}
	dc := vm.decide_calls[desc_idx]
	if int(dc.table_idx) >= len(vm.tables) || int(res_slot) >= len(vm.decide_results) {
		vm.err = .Unknown_Table
		return
	}

	context = vm.saved_ctx
	ct := &vm.tables[dc.table_idx]
	vals: [64]Value
	for a in dc.args {
		if int(a.col_idx) < len(vals) {
			v := vm.regs[a.reg]
			if sid, is_s := v.(String_Id); is_s {
				if sid == String_Id(INVALID_ID) {
					v = String_Id(INVALID_ID)
				} else if sid == EMPTY_STRING {
					v = EMPTY_STRING
				} else {
					txt := resolve_runtime_string(vm.interner, vm.sess_interner, sid)
					if ct_sid, ok := ct.interner.lookup[txt]; ok {
						v = ct_sid
					} else {
						v = String_Id(INVALID_ID)
					}
				}
			}
			vals[a.col_idx] = v
		}
	}
	n_in := min(ct.col_count, len(vals))
	res := decide_values(ct, vals[:n_in])

	// Map string outputs back into Rulebase interner IDs when present so Eq checks match `String_Id`.
	for oi := 0; oi < int(res.output_count); oi += 1 {
		if res.output_set[oi] {
			if sid, is_s := res.outputs[oi].(String_Id); is_s {
				txt := interner_get(&ct.interner, sid)
				mapped, m_err := intern_session_string(vm.interner, vm.sess_interner, txt)
				if m_err != nil {
					vm.err = .Missing_Field
					return
				}
				res.outputs[oi] = mapped
			}
		}
	}
	vm.decide_results[res_slot] = res
	vm.regs[dst] = res.matched
}

// =============================================================================
// #must_tail Preserve/None Threaded VM Handlers
// =============================================================================

@(private)
_op_halt :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	vm.result = vm.regs[pc[0].dst]
}

@(private)
_op_load_const :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	idx := (u16(ins.lhs) << 8) | u16(ins.rhs)
	if int(idx) >= len(vm.consts) {
		vm.err = .Missing_Field
		return
	}
	vm.regs[ins.dst] = vm.consts[idx]
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_load_var :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	if int(ins.lhs) >= len(vm.vars) {
		vm.err = .Missing_Field
		return
	}
	vm.regs[ins.dst] = vm.vars[ins.lhs]
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_move :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	vm.regs[ins.dst] = vm.regs[ins.lhs]
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_load_field :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	ref_idx := (u16(ins.lhs) << 8) | u16(ins.rhs)
	_vm_helper_load_field(vm, ins.dst, ref_idx)
	if vm.err != .None {
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_add :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a := vm.regs[ins.lhs]
	b := vm.regs[ins.rhs]
	if fa, a_f := a.(f64); a_f {
		if fb, ok := value_to_f64(b); ok {
			vm.regs[ins.dst] = fa + fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if fb, b_f := b.(f64); b_f {
		if fa2, ok := value_to_f64(a); ok {
			vm.regs[ins.dst] = fa2 + fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if ia, a_i := value_to_i64(a); a_i {
		if ib, ok := value_to_i64(b); ok {
			vm.regs[ins.dst] = ia + ib
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else {
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_sub :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a := vm.regs[ins.lhs]
	b := vm.regs[ins.rhs]
	if fa, a_f := a.(f64); a_f {
		if fb, ok := value_to_f64(b); ok {
			vm.regs[ins.dst] = fa - fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if fb, b_f := b.(f64); b_f {
		if fa2, ok := value_to_f64(a); ok {
			vm.regs[ins.dst] = fa2 - fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if ia, a_i := value_to_i64(a); a_i {
		if ib, ok := value_to_i64(b); ok {
			vm.regs[ins.dst] = ia - ib
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else {
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_mul :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a := vm.regs[ins.lhs]
	b := vm.regs[ins.rhs]
	if fa, a_f := a.(f64); a_f {
		if fb, ok := value_to_f64(b); ok {
			vm.regs[ins.dst] = fa * fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if fb, b_f := b.(f64); b_f {
		if fa2, ok := value_to_f64(a); ok {
			vm.regs[ins.dst] = fa2 * fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if ia, a_i := value_to_i64(a); a_i {
		if ib, ok := value_to_i64(b); ok {
			vm.regs[ins.dst] = ia * ib
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else {
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_div :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a := vm.regs[ins.lhs]
	b := vm.regs[ins.rhs]
	if fa, a_f := a.(f64); a_f {
		if fb, ok := value_to_f64(b); ok {
			if fb == 0 {
				vm.err = .Trap_Div_By_Zero
				return
			}
			vm.regs[ins.dst] = fa / fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if fb, b_f := b.(f64); b_f {
		if fa2, ok := value_to_f64(a); ok {
			if fb == 0 {
				vm.err = .Trap_Div_By_Zero
				return
			}
			vm.regs[ins.dst] = fa2 / fb
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else if ia, a_i := value_to_i64(a); a_i {
		if ib, ok := value_to_i64(b); ok {
			if ib == 0 {
				vm.err = .Trap_Div_By_Zero
				return
			}
			if ia == min(i64) && ib == -1 {
				vm.err = .Trap_Int_Overflow
				return
			}
			vm.regs[ins.dst] = ia / ib
		} else {
			vm.err = .Type_Mismatch
			return
		}
	} else {
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_mod :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	ia, a_ok := value_to_i64(vm.regs[ins.lhs])
	ib, b_ok := value_to_i64(vm.regs[ins.rhs])
	if !a_ok || !b_ok {
		vm.err = .Type_Mismatch
		return
	}
	if ib == 0 {
		vm.err = .Trap_Div_By_Zero
		return
	}
	if ia == min(i64) && ib == -1 {
		vm.err = .Trap_Int_Overflow
		return
	}
	vm.regs[ins.dst] = ia % ib
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_neg :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a := vm.regs[ins.lhs]
	if fa, ok := a.(f64); ok {
		vm.regs[ins.dst] = -fa
	} else if ia, i_ok := value_to_i64(a); i_ok {
		if ia == min(i64) {
			vm.err = .Trap_Int_Overflow
			return
		}
		vm.regs[ins.dst] = -ia
	} else {
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_not :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	b, ok := vm.regs[ins.lhs].(bool)
	if !ok {
		vm.err = .Type_Mismatch
		return
	}
	vm.regs[ins.dst] = !b
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_cmp_exec :: #force_inline proc "contextless" (vm: ^Vm_State, ins: Instruction, op: Binary_Op) -> bool {
	r, cerr := _vm_eval_cmp_values(vm, vm.regs[ins.lhs], vm.regs[ins.rhs], op)
	if cerr != .None {
		vm.err = cerr
		return false
	}
	vm.regs[ins.dst] = r
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return false
	}
	return true
}

@(private)
_op_eq :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Eq) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_neq :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Neq) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_lt :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Lt) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_lte :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Lte) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_gt :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Gt) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_gte :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_op_cmp_exec(vm, pc[0], .Gte) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_and :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a, aok := vm.regs[ins.lhs].(bool)
	b, bok := vm.regs[ins.rhs].(bool)
	if !aok || !bok {
		vm.err = .Type_Mismatch
		return
	}
	vm.regs[ins.dst] = a && b
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_or :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	a, aok := vm.regs[ins.lhs].(bool)
	b, bok := vm.regs[ins.rhs].(bool)
	if !aok || !bok {
		vm.err = .Type_Mismatch
		return
	}
	vm.regs[ins.dst] = a || b
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_jmp :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	off := int((u16(ins.lhs) << 8) | u16(ins.rhs))
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1 + off:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_jmp_if_false :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	b, ok := vm.regs[ins.dst].(bool)
	if !ok {
		vm.err = .Type_Mismatch
		return
	}
	off := int((u16(ins.lhs) << 8) | u16(ins.rhs)) if !b else 0
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1 + off:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_jmp_if_true :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	b, ok := vm.regs[ins.dst].(bool)
	if !ok {
		vm.err = .Type_Mismatch
		return
	}
	off := int((u16(ins.lhs) << 8) | u16(ins.rhs)) if b else 0
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1 + off:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_decide_call :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	_vm_helper_decide_call(vm, ins.dst, ins.lhs, ins.rhs)
	if vm.err != .None {
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_load_decide_out :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	slot := int(ins.lhs)
	col := int(ins.rhs)
	if slot >= len(vm.decide_results) || col >= MAX_TABLE_OUTPUTS {
		vm.err = .Missing_Field
		return
	}
	dr := &vm.decide_results[slot]
	if !dr.output_set[col] {
		vm.err = .Missing_Field
		return
	}
	vm.regs[ins.dst] = dr.outputs[col]
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_in_range :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	ridx := int(ins.rhs)
	if ridx >= len(vm.ranges) {
		vm.err = .Missing_Field
		return
	}
	rng := vm.ranges[ridx]
	v := vm.regs[ins.lhs]
	ok_lo, err_lo := _vm_eval_cmp_values(vm, v, rng.lo, .Gte if rng.lo_inc else .Gt)
	if err_lo != .None {
		vm.err = err_lo
		return
	}
	ok_hi, err_hi := _vm_eval_cmp_values(vm, v, rng.hi, .Lte if rng.hi_inc else .Lt)
	if err_hi != .None {
		vm.err = err_hi
		return
	}
	vm.regs[ins.dst] = ok_lo && ok_hi
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_vm_case_transform :: proc(vm: ^Vm_State, s: string, upper: bool) -> (String_Id, Vm_Error) {
	if len(s) == 0 {
		return EMPTY_STRING, .None
	}
	ascii_only := true
	for i := 0; i < len(s); i += 1 {
		if s[i] >= 0x80 {
			ascii_only = false
			break
		}
	}
	out_str: string
	stack_buf: [512]u8 = ---
	if ascii_only && len(s) <= len(stack_buf) {
		for i := 0; i < len(s); i += 1 {
			c := s[i]
			if upper && c >= 'a' && c <= 'z' {
				c -= 32
			} else if !upper && c >= 'A' && c <= 'Z' {
				c += 32
			}
			stack_buf[i] = c
		}
		out_str = string(stack_buf[:len(s)])
	} else {
		out_str = strings.to_upper(s, context.temp_allocator) if upper else strings.to_lower(s, context.temp_allocator)
	}
	if vm.sess_interner != nil {
		sid, s_err := intern_session_string(vm.interner, vm.sess_interner, out_str)
		if s_err != nil {
			return EMPTY_STRING, .Type_Mismatch
		}
		return sid, .None
	}
	if vm.interner != nil {
		sid, i_err := intern(vm.interner, out_str)
		if i_err != nil {
			return EMPTY_STRING, .Type_Mismatch
		}
		return sid, .None
	}
	return EMPTY_STRING, .Type_Mismatch
}

@(private)
_vm_exec_str_case :: proc(vm: ^Vm_State, ins: Instruction, upper: bool) -> bool {
	sid, ok := vm.regs[ins.lhs].(String_Id)
	if !ok {
		vm.err = .Type_Mismatch
		return false
	}
	context = vm.saved_ctx
	s := resolve_runtime_string(vm.interner, vm.sess_interner, sid)
	out_id, t_err := _vm_case_transform(vm, s, upper)
	if t_err != .None {
		vm.err = t_err
		return false
	}
	vm.regs[ins.dst] = out_id
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return false
	}
	return true
}

@(private)
_op_str_lower :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	context = vm.saved_ctx
	if !_vm_exec_str_case(vm, pc[0], false) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_str_upper :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	context = vm.saved_ctx
	if !_vm_exec_str_case(vm, pc[0], true) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_str_len :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	sid, ok := vm.regs[ins.lhs].(String_Id)
	if !ok {
		vm.err = .Type_Mismatch
		return
	}
	s := resolve_runtime_string(vm.interner, vm.sess_interner, sid)
	vm.regs[ins.dst] = i64(len(s))
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_vm_exec_str_pred :: proc(vm: ^Vm_State, ins: Instruction, is_prefix: bool) -> bool {
	lsid, lok := vm.regs[ins.lhs].(String_Id)
	rsid, rok := vm.regs[ins.rhs].(String_Id)
	if !lok || !rok {
		vm.err = .Type_Mismatch
		return false
	}
	ls := resolve_runtime_string(vm.interner, vm.sess_interner, lsid)
	rs := resolve_runtime_string(vm.interner, vm.sess_interner, rsid)
	vm.regs[ins.dst] = strings.has_prefix(ls, rs) if is_prefix else strings.contains(ls, rs)
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return false
	}
	return true
}

@(private)
_op_str_starts_with :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	context = vm.saved_ctx
	if !_vm_exec_str_pred(vm, pc[0], true) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_str_contains :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	context = vm.saved_ctx
	if !_vm_exec_str_pred(vm, pc[0], false) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_math_abs :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	ins := pc[0]
	#partial switch x in vm.regs[ins.lhs] {
	case i32:
		if x == min(i32) {
			vm.err = .Trap_Int_Overflow
			return
		}
		vm.regs[ins.dst] = -x if x < 0 else x
	case i64:
		if x == min(i64) {
			vm.err = .Trap_Int_Overflow
			return
		}
		vm.regs[ins.dst] = -x if x < 0 else x
	case f64:
		vm.regs[ins.dst] = math.abs(x)
	case:
		vm.err = .Type_Mismatch
		return
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_vm_exec_math_minmax :: proc "contextless" (vm: ^Vm_State, ins: Instruction, is_max: bool) -> bool {
	lv := vm.regs[ins.lhs]
	rv := vm.regs[ins.rhs]
	if li32, ok1 := lv.(i32); ok1 {
		if ri32, ok2 := rv.(i32); ok2 {
			vm.regs[ins.dst] = max(li32, ri32) if is_max else min(li32, ri32)
		} else if ri64, ok3 := rv.(i64); ok3 {
			vm.regs[ins.dst] = max(i64(li32), ri64) if is_max else min(i64(li32), ri64)
		} else if rf64, ok4 := rv.(f64); ok4 {
			vm.regs[ins.dst] = max(f64(li32), rf64) if is_max else min(f64(li32), rf64)
		} else {
			vm.err = .Type_Mismatch
			return false
		}
	} else if li64, ok5 := lv.(i64); ok5 {
		if ri32, ok6 := rv.(i32); ok6 {
			vm.regs[ins.dst] = max(li64, i64(ri32)) if is_max else min(li64, i64(ri32))
		} else if ri64, ok7 := rv.(i64); ok7 {
			vm.regs[ins.dst] = max(li64, ri64) if is_max else min(li64, ri64)
		} else if rf64, ok8 := rv.(f64); ok8 {
			vm.regs[ins.dst] = max(f64(li64), rf64) if is_max else min(f64(li64), rf64)
		} else {
			vm.err = .Type_Mismatch
			return false
		}
	} else if lf64, ok9 := lv.(f64); ok9 {
		rf64, fok := value_to_f64(rv)
		if !fok {
			vm.err = .Type_Mismatch
			return false
		}
		vm.regs[ins.dst] = max(lf64, rf64) if is_max else min(lf64, rf64)
	} else {
		vm.err = .Type_Mismatch
		return false
	}
	vm.steps_left -= 1
	if vm.steps_left <= 0 {
		vm.err = .Step_Limit_Exceeded
		return false
	}
	return true
}

@(private)
_op_math_min :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_vm_exec_math_minmax(vm, pc[0], false) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(private)
_op_math_max :: proc "preserve/none" (vm: ^Vm_State, pc: [^]Instruction) {
	if !_vm_exec_math_minmax(vm, pc[0], true) {
		return
	}
	next := pc[1:]
	when .Address in ODIN_SANITIZER_FLAGS {
		vm.dispatch[next[0].op](vm, next)
	} else {
		#must_tail vm.dispatch[next[0].op](vm, next)
	}
}

@(rodata)
VM_DISPATCH_TABLE := [Opcode]Vm_Op_Proc{
	.Halt            = _op_halt,
	.Load_Const      = _op_load_const,
	.Load_Var        = _op_load_var,
	.Move            = _op_move,
	.Load_Field      = _op_load_field,
	.Add             = _op_add,
	.Sub             = _op_sub,
	.Mul             = _op_mul,
	.Div             = _op_div,
	.Mod             = _op_mod,
	.Neg             = _op_neg,
	.Eq              = _op_eq,
	.Neq             = _op_neq,
	.Lt              = _op_lt,
	.Lte             = _op_lte,
	.Gt              = _op_gt,
	.Gte             = _op_gte,
	.Not             = _op_not,
	.And             = _op_and,
	.Or              = _op_or,
	.Jmp             = _op_jmp,
	.Jmp_If_False    = _op_jmp_if_false,
	.Jmp_If_True     = _op_jmp_if_true,
	.Decide_Call     = _op_decide_call,
	.Load_Decide_Out = _op_load_decide_out,
	.In_Range        = _op_in_range,
	.Str_Lower       = _op_str_lower,
	.Str_Upper       = _op_str_upper,
	.Str_Len         = _op_str_len,
	.Str_Starts_With = _op_str_starts_with,
	.Str_Contains    = _op_str_contains,
	.Math_Abs        = _op_math_abs,
	.Math_Min        = _op_math_min,
	.Math_Max        = _op_math_max,
}

vm_eval :: proc(
	prog: ^Bytecode_Program,
	vars: []Value,
	fact_slots: []Vm_Fact_Binding,
	tables: []Compiled_Table,
	interner: ^String_Interner,
	decide_out: []Decision_Result = nil,
	sess_interner: ^String_Interner = nil,
	step_limit: i32 = 4096,
) -> (res: Value, err: Vm_Error) {
	if prog == nil || len(prog.code) == 0 {
		return {}, .Unsupported_Expr
	}
	local_decide: [4]Decision_Result = ---
	wide_decide: [16]Decision_Result = ---
	eff_decide := decide_out
	if eff_decide == nil && len(prog.decide_calls) > 0 {
		if len(prog.decide_calls) <= len(local_decide) {
			local_decide = {}
			eff_decide = local_decide[:]
		} else {
			wide_decide = {}
			eff_decide = wide_decide[:]
		}
	}
	table := VM_DISPATCH_TABLE
	vm: Vm_State = ---
	reg_n := int(prog.max_regs)
	if reg_n <= 0 || reg_n > len(vm.regs) {
		mem.zero_slice(vm.regs[:]) // safe fallback for hand-built Bytecode_Program in unit tests
	} else {
		mem.zero_slice(vm.regs[:reg_n])
	}
	vm.vars = vars
	vm.fact_slots = fact_slots
	vm.consts = prog.consts
	vm.field_refs = prog.field_refs
	vm.decide_calls = prog.decide_calls
	vm.ranges = prog.ranges
	vm.decide_results = eff_decide
	vm.tables = tables
	vm.interner = interner
	vm.sess_interner = sess_interner
	vm.dispatch = &table
	vm.saved_ctx = context
	vm.steps_left = step_limit
	vm.result = nil
	vm.err = .None
	vm.dispatch[prog.code[0].op](&vm, raw_data(prog.code))
	if vm.err != .None {
		return {}, vm.err
	}
	return vm.result, .None
}
