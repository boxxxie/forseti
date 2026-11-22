package forseti

import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"

Compile_Error :: enum u8 {
	None = 0,
	Alloc_Failed,
	Unknown_Binding,
	Unknown_Field,
	Unsupported_Clause,
	Too_Many_Patterns,
	Vm_Compile_Failed,
	Unstratified_Negation,
}

Value_Key :: struct {
	kind: Type_Kind,
	raw:  u64,
}

Alpha_Range_Edge :: struct {
	field_idx: i16,
	op:        Binary_Op,
	const_val: Value,
	child:     u32,
}

Alpha_Guard_Edge :: struct {
	prog_idx: u32,
	child:    u32,
}

Alpha_Node :: struct {
	eq_buckets:  ^map[Value_Key]u32,
	range_edges: []Alpha_Range_Edge,
	guard_edges: []Alpha_Guard_Edge,
	id:          u32,
	terminal_id: i32, // -1 if no terminal at this node
	eq_field:    i16,
}

@(private)
_Alpha_Build_Node :: struct {
	eq_buckets:  ^map[Value_Key]u32,
	range_edges: [dynamic]Alpha_Range_Edge,
	guard_edges: [dynamic]Alpha_Guard_Edge,
	id:          u32,
	terminal_id: i32,
	eq_field:    i16,
}

@(private)
_Sub_Edge :: struct {
	target: Alpha_Segment_Target,
	next:   i32,
}

Alpha_Root :: struct {
	binding_idx: u16,
	root_node:   u32,
}

Alpha_Segment_Target :: struct {
	seg_id:      u32,
	input_bit:   u64,
	notify_only: bool,
}

Alpha_Terminal :: struct {
	id:          u32,
	binding_idx: u16,
	field_binds: []Alpha_Field_Bind,
	subscribers: []Alpha_Segment_Target,
}

Alpha_Field_Bind :: struct {
	field_idx: i16,
	var_slot:  u16,
}

Subnetwork_Step_Kind :: enum u8 {
	Pattern,
	Where,
}

Subnetwork_Step :: struct {
	kind:         Subnetwork_Step_Kind,
	alpha_mem_id: u32,
	binding_idx:  u16,
	fact_slot:    u8,
	join_keys:    []Join_Key_Pair,
	field_binds:  []Alpha_Field_Bind,
	guard_prog:   i32, // -1 if none
}

Subnetwork_Def :: struct {
	id:                   u32,
	steps:                []Subnetwork_Step,
	accum_op:             Accum_Op,
	accum_expr_prog:      i32, // -1 if none or direct fact slot
	accum_expr_fact_slot: i16, // -1 if expression
	accum_guard_prog:     i32, // -1 if none
	out_var_slot:         u16,
	group_var_slots:      []u16,
	uses_outer_fact:      bool,
}

Compiled_Action_Field :: struct {
	field_idx:  i16,
	field_name: String_Id,
	expr_prog:  i32, // -1 if unused
}

Compiled_Action :: struct {
	kind:          Action_Kind_IR,
	target_bind:   u16,
	effect_kind:   String_Id,
	unconditional: bool,
	retract_slot:  i16,
	fields:        []Compiled_Action_Field,
}

Rule_Compiled :: struct {
	id:               u32,
	name:             String_Id,
	phase:            String_Id,
	version:          String_Id,
	salience:         i32,
	stratum:          u32,
	is_recursive:     bool,
	decide_table_idx: u16, // INVALID_TABLE_IDX if none
	input_count:      u8,
	all_inputs_mask:  u64,
	segment_ids:      []u32,
	actions:          []Compiled_Action,
	var_count:        u16,
	fact_slot_count:  u8,
	decide_slots:     u8,
}

Query_Compiled :: struct {
	id:          u32,
	name:        String_Id,
	param_names: []String_Id,
	param_types: []Type_Ref,
	var_names:   []String_Id,
	clauses:     []Query_Step,
	var_count:   u16,
}

Query_Step :: struct {
	alpha_mem_id: u32,
	binding_idx:  u16,
	fact_slot:    u8,
	join_keys:    []Join_Key_Pair,
	field_binds:  []Alpha_Field_Bind,
	guard_prog:   i32, // -1 if none
}

// Rulebase holds compiled immutable rules, alpha DAG, segments, decision tables, and VM programs.
Rulebase :: struct {
	arena:             vmem.Arena,
	interner:          String_Interner,
	module_name:       String_Id,
	module_version:    String_Id,
	schemas:           []Schema_Def,
	bindings:          []Binding_Def,
	tables:            []Compiled_Table,
	binding_by_name:   map[String_Id]u16,
	schema_by_name:    map[String_Id]u16,
	table_by_name:     map[String_Id]u32,
	alpha_roots:       []Alpha_Root,
	alpha_nodes:       []Alpha_Node,
	alpha_terminals:   []Alpha_Terminal,
	segments:          []Segment_Def,
	beta_nodes:        []Beta_Node_Def,
	subnetworks:       []Subnetwork_Def,
	rules:             []Rule_Compiled,
	queries:           []Query_Compiled,
	programs:          []Bytecode_Program,
	strata_count:        u32,
	stratum_recursive:   []bool,
	stratum_wave_safe:   []bool,
	stratum_rules:       [][]u32,
	phase_max_stratum:   map[String_Id]u32,
	zero_input_segs:     []u32,
	sccs:                []Scc_Info,
	schema_field_hashes: [][]Prehashed_Key,
	binding_path_hashes: [][]Prehashed_Key,
	telemetry:           ^Telemetry_Sink,
}

value_to_key :: proc "contextless" (v: Value) -> (k: Value_Key, ok: bool) {
	switch x in v {
	case bool:      return Value_Key{kind = .Bool, raw = 1 if x else 0}, true
	case i32:       return Value_Key{kind = .I64, raw = u64(i64(x))}, true
	case i64:       return Value_Key{kind = .I64, raw = u64(x)}, true
	case f64:
		canonical := f64(0.0) if x == 0.0 else x
		return Value_Key{kind = .F64, raw = transmute(u64)canonical}, true
	case String_Id: return Value_Key{kind = .String, raw = u64(x)}, true
	case Entity_Id: return Value_Key{kind = .Entity, raw = u64(x)}, true
	case Time_Ns:   return Value_Key{kind = .Time, raw = u64(x)}, true
	case Enum_Val:  return Value_Key{kind = .Enum, raw = (u64(x.enum_id) << 32) | u64(x.variant)}, true
	}
	return {}, false
}

@(private)
value_key_from_runtime_value :: proc "contextless" (
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
			return Value_Key{kind = .String, raw = u64(INVALID_ID)}, true
		}
		return Value_Key{kind = .String, raw = u64(sid)}, true
	}
	return value_to_key(v)
}

rulebase_destroy :: proc(rb: ^Rulebase) {
	if rb == nil {
		return
	}
	vmem.arena_check_temp(&rb.arena)
	for i := 0; i < len(rb.tables); i += 1 {
		compiled_table_destroy(&rb.tables[i])
	}
	interner_destroy(&rb.interner)
	vmem.arena_destroy(&rb.arena)
	rb^ = {}
}

@(private)
Rb_Build_Ctx :: struct {
	ir:              ^Rulebase_IR,
	rb:              ^Rulebase,
	alloc:           mem.Allocator,
	build_alloc:     mem.Allocator,
	scratch_alloc:   mem.Allocator,
	alpha_nodes:     [dynamic]_Alpha_Build_Node,
	alpha_terminals: [dynamic]Alpha_Terminal,
	beta_nodes:      [dynamic]Beta_Node_Def,
	subnetworks:     [dynamic]Subnetwork_Def,
	segments:        [dynamic]Segment_Def,
	zero_input_segs: [dynamic]u32,
	programs:        [dynamic]Bytecode_Program,
	prog_intern:     map[u64][dynamic]u32,
	sub_head:        [dynamic]i32,
	sub_counts:      [dynamic]u32,
	sub_edges:       [dynamic]_Sub_Edge,
	rule_stratum:    []u32,
	rule_recursive:  []bool,
	shared_count:    u64,
	bound_vars:      map[String_Id]u16,
	var_map:         map[String_Id]u8,
	fact_descs:      [dynamic]Vm_Fact_Slot_Desc,
	decide_descs:    [dynamic]Vm_Decide_Slot_Desc,
	input_links:     [dynamic]Segment_Input_Link,
	pat_preds:       [dynamic]Alpha_Pred,
	pat_binds:       [dynamic]Alpha_Field_Bind,
	pat_joins:       [dynamic]Join_Key_Pair,
	pat_res:         [dynamic]u32,
	vm_compiler:     Vm_Compiler,
}

@(private)
_values_bit_equal :: proc "contextless" (a, b: Value) -> bool {
	if a == nil && b == nil {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	switch va in a {
	case bool:
		vb, ok := b.(bool)
		return ok && va == vb
	case i32:
		vb, ok := b.(i32)
		return ok && va == vb
	case i64:
		vb, ok := b.(i64)
		return ok && va == vb
	case f64:
		vb, ok := b.(f64)
		return ok && (transmute(u64)va) == (transmute(u64)vb)
	case String_Id:
		vb, ok := b.(String_Id)
		return ok && va == vb
	case Entity_Id:
		vb, ok := b.(Entity_Id)
		return ok && va == vb
	case Time_Ns:
		vb, ok := b.(Time_Ns)
		return ok && va == vb
	case Enum_Val:
		vb, ok := b.(Enum_Val)
		return ok && va == vb
	}
	return false
}

@(private)
_hash_value_exact :: proc "contextless" (v: Value) -> u64 {
	if v == nil {
		return 0x6e696c
	}
	switch x in v {
	case bool:      return _hash_combine64(1, 1 if x else 0)
	case i32:       return _hash_combine64(2, u64(u32(x)))
	case i64:       return _hash_combine64(3, u64(x))
	case f64:       return _hash_combine64(4, transmute(u64)x)
	case String_Id: return _hash_combine64(5, u64(x))
	case Entity_Id: return _hash_combine64(6, u64(x))
	case Time_Ns:   return _hash_combine64(7, u64(x))
	case Enum_Val:  return _hash_combine64(8, (u64(x.enum_id) << 32) | u64(x.variant))
	}
	return 0
}

@(private)
_hash_str_bytes :: proc "contextless" (s: string) -> u64 {
	h := u64(0x73747231) ~ u64(len(s))
	b := transmute([]u8)s
	for c in b {
		h = _hash_combine64(h, u64(c))
	}
	return h
}

@(private)
_hash_vm_compiler_program :: proc "contextless" (c: ^Vm_Compiler) -> u64 {
	h := u64(0x50524f47)
	h = _hash_combine64(h, u64(c.ra.max_used))
	h = _hash_combine64(h, u64(len(c.code)))
	for ins in c.code {
		word := u64(ins.op) | (u64(ins.dst) << 8) | (u64(ins.lhs) << 16) | (u64(ins.rhs) << 24)
		h = _hash_combine64(h, word)
	}
	h = _hash_combine64(h, u64(len(c.consts)))
	for cv in c.consts {
		h = _hash_combine64(h, _hash_value_exact(cv))
	}
	h = _hash_combine64(h, u64(len(c.field_refs)))
	for fr in c.field_refs {
		h = _hash_combine64(h, u64(fr.fact_slot) | (u64(u16(fr.field_idx)) << 8) | (u64(fr.expected_type) << 24))
		h = _hash_combine64(h, u64(len(fr.segments)))
		for seg in fr.segments {
			h = _hash_combine64(h, _hash_str_bytes(seg))
		}
	}
	h = _hash_combine64(h, u64(len(c.decide_calls)))
	for dc in c.decide_calls {
		h = _hash_combine64(h, u64(dc.table_idx) | (u64(dc.result_slot) << 32))
		h = _hash_combine64(h, u64(len(dc.args)))
		for a in dc.args {
			h = _hash_combine64(h, u64(a.col_idx) | (u64(a.reg) << 8))
		}
	}
	h = _hash_combine64(h, u64(len(c.ranges)))
	for rn in c.ranges {
		h = _hash_combine64(h, _hash_value_exact(rn.lo))
		h = _hash_combine64(h, _hash_value_exact(rn.hi))
		h = _hash_combine64(h, (u64(1) if rn.lo_inc else 0) | ((u64(1) if rn.hi_inc else 0) << 1))
	}
	return h
}

@(private)
_vm_compiler_equals_program :: proc "contextless" (c: ^Vm_Compiler, p: ^Bytecode_Program) -> bool {
	if c.ra.max_used != p.max_regs ||
	   len(c.code) != len(p.code) ||
	   len(c.consts) != len(p.consts) ||
	   len(c.field_refs) != len(p.field_refs) ||
	   len(c.decide_calls) != len(p.decide_calls) ||
	   len(c.ranges) != len(p.ranges) {
		return false
	}
	for i := 0; i < len(c.code); i += 1 {
		if c.code[i] != p.code[i] {
			return false
		}
	}
	for i := 0; i < len(c.consts); i += 1 {
		if !_values_bit_equal(c.consts[i], p.consts[i]) {
			return false
		}
	}
	for i := 0; i < len(c.field_refs); i += 1 {
		fa := c.field_refs[i]
		fb := p.field_refs[i]
		if fa.fact_slot != fb.fact_slot ||
		   fa.field_idx != fb.field_idx ||
		   fa.expected_type != fb.expected_type ||
		   len(fa.segments) != len(fb.segments) {
			return false
		}
		for si := 0; si < len(fa.segments); si += 1 {
			if fa.segments[si] != fb.segments[si] {
				return false
			}
		}
	}
	for i := 0; i < len(c.decide_calls); i += 1 {
		da := c.decide_calls[i]
		db := p.decide_calls[i]
		if da.table_idx != db.table_idx ||
		   da.result_slot != db.result_slot ||
		   len(da.args) != len(db.args) {
			return false
		}
		for ai := 0; ai < len(da.args); ai += 1 {
			if da.args[ai] != db.args[ai] {
				return false
			}
		}
	}
	for i := 0; i < len(c.ranges); i += 1 {
		ra := c.ranges[i]
		rb_r := p.ranges[i]
		if ra.lo_inc != rb_r.lo_inc ||
		   ra.hi_inc != rb_r.hi_inc ||
		   !_values_bit_equal(ra.lo, rb_r.lo) ||
		   !_values_bit_equal(ra.hi, rb_r.hi) {
			return false
		}
	}
	return true
}

@(private)
_intern_scratch_program :: proc(ctx: ^Rb_Build_Ctx) -> u32 {
	h := _hash_vm_compiler_program(&ctx.vm_compiler)
	if bucket, has_b := ctx.prog_intern[h]; has_b {
		for idx in bucket {
			if _vm_compiler_equals_program(&ctx.vm_compiler, &ctx.programs[idx]) {
				return idx
			}
		}
	}
	prog := _finalize_vm_program(&ctx.vm_compiler, ctx.alloc)
	// Point Field_Access_Desc segments onto rb.interner so programs outlive ir_destroy.
	for &fr in prog.field_refs {
		for si := 0; si < len(fr.segments); si += 1 {
			seg_str := fr.segments[si]
			if rb_sid, has_sid := ctx.rb.interner.lookup[seg_str]; has_sid {
				canon := interner_get(&ctx.rb.interner, rb_sid)
				fr.segments[si] = canon
				if si < len(fr.seg_hashes) {
					fr.seg_hashes[si].key = canon
				}
			}
		}
	}
	pidx := u32(len(ctx.programs))
	append(&ctx.programs, prog)
	bucket, has_b := &ctx.prog_intern[h]
	if !has_b {
		ctx.prog_intern[h] = make([dynamic]u32, 0, 2, ctx.build_alloc)
		bucket = &ctx.prog_intern[h]
	}
	append(bucket, pidx)
	return pidx
}

@(private)
_compile_and_intern_expr :: proc(
	ctx: ^Rb_Build_Ctx,
	env: ^Vm_Compile_Env,
	eid: Expr_Id,
) -> (pidx: u32, err: Vm_Error) {
	vm_compile_expr_to_scratch(&ctx.vm_compiler, env, eid) or_return
	return _intern_scratch_program(ctx), .None
}

@(private)
_compile_and_intern_decide :: proc(
	ctx: ^Rb_Build_Ctx,
	env: ^Vm_Compile_Env,
	table_name: String_Id,
	args: []Field_Binding_IR,
	decide_slot: u8,
) -> (pidx: u32, err: Vm_Error) {
	vm_compile_decide_to_scratch(&ctx.vm_compiler, env, table_name, args, decide_slot) or_return
	return _intern_scratch_program(ctx), .None
}

@(private)
eval_literal_const_expr :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (v: Value, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return {}, false
	}
	e := ir.exprs[eid]
	#partial switch e.kind {
	case .Lit_Bool:   return e.bool_val, true
	case .Lit_Int:    return e.int_val, true
	case .Lit_Float:  return e.float_val, true
	case .Lit_String: return e.str_id, true
	case .Ident:      return e.str_id, true
	case .Unary:
		if e.unary_op == .Neg && e.lhs != INVALID_EXPR {
			iv, iok := eval_literal_const_expr(ir, e.lhs)
			if !iok {
				return {}, false
			}
			if x, is_i := iv.(i64); is_i {
				return -x, true
			}
			if x, is_f := iv.(f64); is_f {
				return -x, true
			}
		}
	}
	return {}, false
}

@(private)
new_alpha_node :: proc(ctx: ^Rb_Build_Ctx) -> u32 {
	id := u32(len(ctx.alpha_nodes))
	append(&ctx.alpha_nodes, _Alpha_Build_Node{
		id          = id,
		eq_field    = -1,
		terminal_id = -1,
	})
	return id
}

@(private)
Alpha_Pred :: struct {
	is_eq:     bool,
	field_idx: i16,
	eq_key:    Value_Key,
	op:        Binary_Op,
	const_val: Value,
}

@(private)
insert_alpha_chain :: proc(
	ctx: ^Rb_Build_Ctx,
	binding_idx: u16,
	preds: []Alpha_Pred,
	binds: []Alpha_Field_Bind,
) -> u32 {
	// Canonical sort: equalities first (by field_idx), then ranges (by field_idx, op).
	slice.sort_by(preds, proc(a, b: Alpha_Pred) -> bool {
		if a.is_eq != b.is_eq {
			return a.is_eq
		}
		if a.field_idx != b.field_idx {
			return a.field_idx < b.field_idx
		}
		if !a.is_eq {
			return u8(a.op) < u8(b.op)
		}
		return a.eq_key.raw < b.eq_key.raw
	})

	cur_id := ctx.rb.alpha_roots[binding_idx].root_node
	for pr in preds {
		cur := &ctx.alpha_nodes[cur_id]
		if pr.is_eq {
			if cur.eq_field < 0 {
				cur.eq_field = pr.field_idx
			}
			if cur.eq_field == pr.field_idx {
				if cur.eq_buckets != nil {
					if existing, has := cur.eq_buckets^[pr.eq_key]; has {
						ctx.shared_count += 1
						cur_id = existing
						continue
					}
					if len(cur.eq_buckets^) > 0 {
						ctx.shared_count += 1 // Shares the parent Hash_Split node across buckets
					}
				}
				next_id := new_alpha_node(ctx)
				parent := &ctx.alpha_nodes[cur_id]
				if parent.eq_buckets == nil {
					m := new(map[Value_Key]u32, ctx.build_alloc)
					m^ = make(map[Value_Key]u32, 4, ctx.build_alloc)
					parent.eq_buckets = m
				}
				parent.eq_buckets^[pr.eq_key] = next_id
				cur_id = next_id
				continue
			}
			// Different equality field at same node: route through range/eq edge
			found_id := i32(-1)
			for re in cur.range_edges {
				if re.field_idx == pr.field_idx && re.op == .Eq {
					if rk, r_ok := value_to_key(re.const_val); r_ok && rk == pr.eq_key {
						found_id = i32(re.child)
						break
					}
				}
			}
			if found_id >= 0 {
				ctx.shared_count += 1
				cur_id = u32(found_id)
			} else {
				next_id := new_alpha_node(ctx)
				re_list := &ctx.alpha_nodes[cur_id].range_edges
				if re_list.allocator.procedure == nil {
					re_list^ = make([dynamic]Alpha_Range_Edge, 0, 2, ctx.build_alloc)
				}
				append(re_list, Alpha_Range_Edge{
					field_idx = pr.field_idx,
					op        = .Eq,
					const_val = pr.const_val,
					child     = next_id,
				})
				cur_id = next_id
			}
		} else {
			found_id := i32(-1)
			for re in cur.range_edges {
				if re.field_idx == pr.field_idx && re.op == pr.op && re.const_val == pr.const_val {
					found_id = i32(re.child)
					break
				}
			}
			if found_id >= 0 {
				ctx.shared_count += 1
				cur_id = u32(found_id)
			} else {
				next_id := new_alpha_node(ctx)
				re_list := &ctx.alpha_nodes[cur_id].range_edges
				if re_list.allocator.procedure == nil {
					re_list^ = make([dynamic]Alpha_Range_Edge, 0, 2, ctx.build_alloc)
				}
				append(re_list, Alpha_Range_Edge{
					field_idx = pr.field_idx,
					op        = pr.op,
					const_val = pr.const_val,
					child     = next_id,
				})
				cur_id = next_id
			}
		}
	}

	leaf := &ctx.alpha_nodes[cur_id]
	if leaf.terminal_id >= 0 {
		// All rules, joins, subnetworks, and queries share the canonical Alpha_Terminal/Memory
		// at this alpha path (each consumer keeps its own `field_binds` mapping).
		ctx.shared_count += 1
		return u32(leaf.terminal_id)
	}

	tid := u32(len(ctx.alpha_terminals))
	stored_binds := make([]Alpha_Field_Bind, len(binds), ctx.alloc)
	copy(stored_binds, binds)
	append(&ctx.alpha_terminals, Alpha_Terminal{
		id          = tid,
		binding_idx = binding_idx,
		field_binds = stored_binds,
	})
	append(&ctx.sub_head, -1)
	append(&ctx.sub_counts, 0)
	leaf.terminal_id = i32(tid)
	return tid
}

@(private)
compile_pattern_clause :: proc(
	ctx: ^Rb_Build_Ctx,
	cl: Clause_IR,
	pat_slot: u8,
	bound_vars: ^map[String_Id]u16,
	next_var: ^u16,
	fact_descs: ^[dynamic]Vm_Fact_Slot_Desc,
	decide_descs: []Vm_Decide_Slot_Desc = nil,
) -> (
	alpha_id: u32,
	binding_idx: u16,
	binds: []Alpha_Field_Bind,
	joins: []Join_Key_Pair,
	residual_progs: []u32,
	err: Compile_Error,
) {
	bidx, bok := ctx.rb.binding_by_name[cl.target]
	if !bok {
		return 0, 0, nil, nil, nil, .Unknown_Binding
	}
	bdef := ctx.ir.bindings[bidx]
	sid := bdef.schema_id
	if u32(sid) == INVALID_ID || int(sid) >= len(ctx.ir.schemas) {
		return 0, 0, nil, nil, nil, .Unknown_Binding
	}
	schema := ctx.ir.schemas[sid]

	if cl.bind_var != EMPTY_STRING {
		append(fact_descs, Vm_Fact_Slot_Desc{
			var_name  = cl.bind_var,
			schema_id = sid,
		})
	} else {
		append(fact_descs, Vm_Fact_Slot_Desc{
			var_name  = EMPTY_STRING,
			schema_id = sid,
		})
	}

	clear(&ctx.pat_preds)
	clear(&ctx.pat_binds)
	clear(&ctx.pat_joins)
	clear(&ctx.pat_res)
	preds := &ctx.pat_preds
	bind_list := &ctx.pat_binds
	join_list := &ctx.pat_joins
	res_list := &ctx.pat_res

	for fb in cl.fields {
		fidx := -1
		ftype := Type_Kind.Unknown
		for sf, sfi in schema.fields {
			if sf.name == fb.name {
				fidx = sfi
				ftype = sf.type.kind
				break
			}
		}
		if fidx < 0 {
			return 0, 0, nil, nil, nil, .Unknown_Field
		}

		ex := ctx.ir.exprs[fb.expr]
		if const_v, c_ok := eval_literal_const_expr(ctx.ir, fb.expr); c_ok {
			v := const_v
			if ftype == .I32 {
				if iv, is_i := v.(i64); is_i && iv >= i64(min(i32)) && iv <= i64(max(i32)) {
					v = i32(iv)
				}
			}
			vk, _ := value_to_key(v)
			append(preds, Alpha_Pred{
				is_eq     = true,
				field_idx = i16(fidx),
				eq_key    = vk,
				const_val = v,
			})
			continue
		}
		if ex.kind == .Cell_Cmp {
			if const_v, c_ok := eval_literal_const_expr(ctx.ir, ex.rhs); c_ok {
				v := const_v
				if ftype == .I32 {
					if iv, is_i := v.(i64); is_i && iv >= i64(min(i32)) && iv <= i64(max(i32)) {
						v = i32(iv)
					}
				}
				if ex.binary_op == .Eq {
					vk, _ := value_to_key(v)
					append(preds, Alpha_Pred{
						is_eq     = true,
						field_idx = i16(fidx),
						eq_key    = vk,
						const_val = v,
					})
				} else {
					append(preds, Alpha_Pred{
						is_eq     = false,
						field_idx = i16(fidx),
						op        = ex.binary_op,
						const_val = v,
					})
				}
				continue
			}
		}
		if ex.kind == .Var {
			if existing_slot, seen := bound_vars^[ex.str_id]; seen {
				append(join_list, Join_Key_Pair{
					left_var_slot   = existing_slot,
					right_field_idx = i16(fidx),
				})
				continue
			}
			slot := next_var^
			next_var^ += 1
			bound_vars^[ex.str_id] = slot
			append(bind_list, Alpha_Field_Bind{
				field_idx = i16(fidx),
				var_slot  = slot,
			})
			continue
		}

		// Residual field expression evaluated against already-bound vars & current fact.
		// Compile `cur_fact.field_name <op> expr_rhs` cleanly via VM.
		clear(&ctx.var_map)
		for k, v in bound_vars^ {
			if v > u16(max(u8)) {
				return 0, 0, nil, nil, nil, .Vm_Compile_Failed
			}
			ctx.var_map[k] = u8(v)
		}
		env := Vm_Compile_Env{
			ir           = ctx.ir,
			tables       = ctx.rb.tables,
			var_names    = ctx.var_map,
			fact_descs   = fact_descs[:],
			decide_descs = decide_descs,
		}
		if err := vm_compile_field_residual_to_scratch(&ctx.vm_compiler, &env, pat_slot, i16(fidx), fb.name, ftype, fb.expr); err != .None {
			return 0, 0, nil, nil, nil, .Vm_Compile_Failed
		}
		pidx := _intern_scratch_program(ctx)
		append(res_list, pidx)
	}

	alpha_id = insert_alpha_chain(ctx, bidx, preds^[:], bind_list^[:])

	out_binds := make([]Alpha_Field_Bind, len(bind_list^), ctx.alloc)
	copy(out_binds, bind_list^[:])

	out_joins := make([]Join_Key_Pair, len(join_list^), ctx.alloc)
	copy(out_joins, join_list^[:])

	out_res := make([]u32, len(res_list^), ctx.alloc)
	copy(out_res, res_list^[:])

	return alpha_id, bidx, out_binds, out_joins, out_res, .None
}

// Compiles a Rulebase_IR cleanly into an immutable, thread-shareable Rulebase.
rulebase_compile :: proc(
	ir: ^Rulebase_IR,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (out_rb: Rulebase, err: Compile_Error) {
	if ir == nil {
		return {}, .Alloc_Failed
	}
	scope := telemetry_span_begin(telemetry, .Compile, "rulebase_compile")
	defer telemetry_span_end(telemetry, scope)

	rb: Rulebase
	if vmem.arena_init_growing(&rb.arena) != nil {
		return {}, .Alloc_Failed
	}
	ok_done := false
	defer if !ok_done {
		rulebase_destroy(&rb)
	}
	if interner_init(&rb.interner, allocator) != nil {
		return {}, .Alloc_Failed
	}
	if len(ir.interner.strings) > 0 {
		if reserve(&rb.interner.strings, len(ir.interner.strings)) != nil ||
		   reserve(&rb.interner.lookup, len(ir.interner.strings)) != nil {
			return {}, .Alloc_Failed
		}
	}
	if len(ir.interner.strings) > 1 {
		for s in ir.interner.strings[1:] {
			if _, ierr := intern(&rb.interner, s); ierr != nil {
				return {}, .Alloc_Failed
			}
		}
	}

	a := vmem.arena_allocator(&rb.arena)
	rb.telemetry = telemetry
	rb.module_name = ir.module_name
	rb.module_version = ir.module_version

	strat_plan, st_err := stratify_ir(ir, nil, telemetry, allocator)
	if st_err != nil {
		return {}, .Alloc_Failed
	}
	defer stratification_plan_destroy(&strat_plan)
	if strat_plan.has_unstratified_cycle {
		return {}, .Unstratified_Negation
	}

	// Deep-clone schema field and binding segment slices onto rb.arena so Rulebase outlives ir_destroy.
	rb.schemas = make([]Schema_Def, len(ir.schemas), a)
	for sch, sci in ir.schemas {
		fcopy := make([]Field_Def, len(sch.fields), a)
		copy(fcopy, sch.fields)
		rb.schemas[sci] = Schema_Def{
			name   = sch.name,
			fields = fcopy,
			span   = sch.span,
		}
	}
	rb.bindings = make([]Binding_Def, len(ir.bindings), a)
	for bd, bdi in ir.bindings {
		scopy := make([]Selector_Segment, len(bd.segments), a)
		copy(scopy, bd.segments)
		rb.bindings[bdi] = Binding_Def{
			kind        = bd.kind,
			name        = bd.name,
			schema_name = bd.schema_name,
			schema_id   = bd.schema_id,
			segments    = scopy,
			span        = bd.span,
		}
	}

	rb.schema_by_name = make(map[String_Id]u16, len(ir.schemas) + 1, a)
	for s, si in ir.schemas {
		rb.schema_by_name[s.name] = u16(si)
	}
	rb.binding_by_name = make(map[String_Id]u16, len(ir.bindings) + 1, a)
	for bd, bi in ir.bindings {
		rb.binding_by_name[bd.name] = u16(bi)
	}
	rb.table_by_name = make(map[String_Id]u32, len(ir.tables) + 1, a)
	rb.tables = make([]Compiled_Table, len(ir.tables), a)
	for ti := 0; ti < len(ir.tables); ti += 1 {
		ct, cerr := compile_table(ir, u32(ti), telemetry, allocator)
		if cerr != nil {
			return {}, .Alloc_Failed
		}
		rb.tables[ti] = ct
		rb.table_by_name[ir.tables[ti].name] = u32(ti)
	}

	build_scratch: vmem.Arena
	if vmem.arena_init_growing(&build_scratch) != nil {
		return {}, .Alloc_Failed
	}
	defer vmem.arena_destroy(&build_scratch)
	sa := vmem.arena_allocator(&build_scratch)

	ctx := Rb_Build_Ctx{
		ir              = ir,
		rb              = &rb,
		alloc           = a,
		build_alloc     = allocator,
		scratch_alloc   = sa,
		alpha_nodes     = make([dynamic]_Alpha_Build_Node, 0, max(len(ir.rules), 16), allocator),
		alpha_terminals = make([dynamic]Alpha_Terminal, 0, max(len(ir.rules), 16), allocator),
		beta_nodes      = make([dynamic]Beta_Node_Def, 0, max(len(ir.rules) * 2, 16), allocator),
		subnetworks     = make([dynamic]Subnetwork_Def, 0, 8, allocator),
		segments        = make([dynamic]Segment_Def, 0, max(len(ir.rules), 16), allocator),
		zero_input_segs = make([dynamic]u32, 0, 4, allocator),
		programs        = make([dynamic]Bytecode_Program, 0, min(max(len(ir.rules), 16), 4096), allocator),
		prog_intern     = make(map[u64][dynamic]u32, 64, allocator),
		sub_head        = make([dynamic]i32, 0, max(len(ir.rules), 16), allocator),
		sub_counts      = make([dynamic]u32, 0, max(len(ir.rules), 16), allocator),
		sub_edges       = make([dynamic]_Sub_Edge, 0, max(len(ir.rules), 16), allocator),
		rule_stratum    = strat_plan.rule_stratum,
		rule_recursive  = strat_plan.rule_recursive,
		bound_vars      = make(map[String_Id]u16, 16, allocator),
		var_map         = make(map[String_Id]u8, 16, allocator),
		fact_descs      = make([dynamic]Vm_Fact_Slot_Desc, 0, 8, allocator),
		decide_descs    = make([dynamic]Vm_Decide_Slot_Desc, 0, 4, allocator),
		input_links     = make([dynamic]Segment_Input_Link, 0, 8, allocator),
		pat_preds       = make([dynamic]Alpha_Pred, 0, 8, allocator),
		pat_binds       = make([dynamic]Alpha_Field_Bind, 0, 8, allocator),
		pat_joins       = make([dynamic]Join_Key_Pair, 0, 4, allocator),
		pat_res         = make([dynamic]u32, 0, 2, allocator),
	}
	defer {
		for &bn in ctx.alpha_nodes {
			if bn.eq_buckets != nil {
				delete(bn.eq_buckets^)
				free(bn.eq_buckets, allocator)
			}
			delete(bn.range_edges)
			delete(bn.guard_edges)
		}
		for _, b in ctx.prog_intern {
			delete(b)
		}
		delete(ctx.alpha_nodes)
		delete(ctx.alpha_terminals)
		delete(ctx.beta_nodes)
		delete(ctx.subnetworks)
		delete(ctx.segments)
		delete(ctx.zero_input_segs)
		delete(ctx.programs)
		delete(ctx.prog_intern)
		delete(ctx.sub_head)
		delete(ctx.sub_counts)
		delete(ctx.sub_edges)
		delete(ctx.bound_vars)
		delete(ctx.var_map)
		delete(ctx.fact_descs)
		delete(ctx.decide_descs)
		delete(ctx.input_links)
		delete(ctx.pat_preds)
		delete(ctx.pat_binds)
		delete(ctx.pat_joins)
		delete(ctx.pat_res)
	}
	vm_compiler_init_scratch(&ctx.vm_compiler, sa)

	rb.alpha_roots = make([]Alpha_Root, len(ir.bindings), a)
	for bi := 0; bi < len(ir.bindings); bi += 1 {
		rb.alpha_roots[bi] = Alpha_Root{
			binding_idx = u16(bi),
			root_node   = new_alpha_node(&ctx),
		}
	}

	rb.rules = make([]Rule_Compiled, len(ir.rules), a)
	for rdef, ri in ir.rules {
		rb.rules[ri] = build_compiled_rule(&ctx, rdef, u32(ri)) or_return
	}

	rb.queries = make([]Query_Compiled, len(ir.queries), a)
	for qdef, qi in ir.queries {
		rb.queries[qi] = build_compiled_query(&ctx, qdef, u32(qi)) or_return
	}

	// Materialize compact arena slices and attach contiguous Alpha_Terminal -> Segment subscribers.
	rb.alpha_nodes = make([]Alpha_Node, len(ctx.alpha_nodes), a)
	for &bn, ni in ctx.alpha_nodes {
		eq_m: ^map[Value_Key]u32 = nil
		if bn.eq_buckets != nil && len(bn.eq_buckets^) > 0 {
			eq_m = new(map[Value_Key]u32, a)
			eq_m^ = make(map[Value_Key]u32, len(bn.eq_buckets^), a)
			for k, v in bn.eq_buckets^ {
				eq_m^[k] = v
			}
		}
		r_edges: []Alpha_Range_Edge
		if len(bn.range_edges) > 0 {
			r_edges = make([]Alpha_Range_Edge, len(bn.range_edges), a)
			copy(r_edges, bn.range_edges[:])
		}
		g_edges: []Alpha_Guard_Edge
		if len(bn.guard_edges) > 0 {
			g_edges = make([]Alpha_Guard_Edge, len(bn.guard_edges), a)
			copy(g_edges, bn.guard_edges[:])
		}
		rb.alpha_nodes[ni] = Alpha_Node{
			eq_buckets  = eq_m,
			range_edges = r_edges,
			guard_edges = g_edges,
			id          = bn.id,
			terminal_id = bn.terminal_id,
			eq_field    = bn.eq_field,
		}
	}

	rb.alpha_terminals = make([]Alpha_Terminal, len(ctx.alpha_terminals), a)
	copy(rb.alpha_terminals, ctx.alpha_terminals[:])
	all_subs := make([]Alpha_Segment_Target, len(ctx.sub_edges), a)
	sub_off := 0
	for &term, tid in rb.alpha_terminals {
		cnt := int(ctx.sub_counts[tid])
		if cnt == 0 {
			continue
		}
		sub_slice := all_subs[sub_off:sub_off + cnt]
		sub_off += cnt
		cur := ctx.sub_head[tid]
		for idx := cnt - 1; idx >= 0 && cur >= 0; idx -= 1 {
			edge := ctx.sub_edges[cur]
			sub_slice[idx] = edge.target
			cur = edge.next
		}
		term.subscribers = sub_slice
	}

	rb.beta_nodes = make([]Beta_Node_Def, len(ctx.beta_nodes), a)
	copy(rb.beta_nodes, ctx.beta_nodes[:])

	rb.subnetworks = make([]Subnetwork_Def, len(ctx.subnetworks), a)
	copy(rb.subnetworks, ctx.subnetworks[:])

	rb.segments = make([]Segment_Def, len(ctx.segments), a)
	copy(rb.segments, ctx.segments[:])

	rb.zero_input_segs = make([]u32, len(ctx.zero_input_segs), a)
	copy(rb.zero_input_segs, ctx.zero_input_segs[:])

	rb.programs = make([]Bytecode_Program, len(ctx.programs), a)
	copy(rb.programs, ctx.programs[:])

	// Pre-hash static schema fields, binding paths, and rule names once at compile time.
	rb.schema_field_hashes = make([][]Prehashed_Key, len(rb.schemas), a)
	for sch, sci in rb.schemas {
		fhashes := make([]Prehashed_Key, len(sch.fields), a)
		for sf, sfi in sch.fields {
			fhashes[sfi] = prehashed_key_make(interner_get(&rb.interner, sf.name))
		}
		rb.schema_field_hashes[sci] = fhashes
	}
	rb.binding_path_hashes = make([][]Prehashed_Key, len(rb.bindings), a)
	for bd, bi in rb.bindings {
		fcount := 0
		for seg in bd.segments {
			if seg.kind == .Field {
				fcount += 1
			}
		}
		phashes := make([]Prehashed_Key, fcount, a)
		pi := 0
		for seg in bd.segments {
			if seg.kind == .Field {
				phashes[pi] = prehashed_key_make(interner_get(&rb.interner, seg.text))
				pi += 1
			}
		}
		rb.binding_path_hashes[bi] = phashes
	}
	// Materialize stratification topology on Rulebase arena.
	rb.strata_count = strat_plan.strata_count
	rb.stratum_recursive = make([]bool, strat_plan.strata_count, a)
	copy(rb.stratum_recursive, strat_plan.stratum_recursive)

	stratum_counts := make([]int, strat_plan.strata_count, sa)
	for rc in rb.rules {
		stratum_counts[rc.stratum] += 1
	}
	rb.stratum_rules = make([][]u32, strat_plan.strata_count, a)
	stratum_cursors := make([]int, strat_plan.strata_count, sa)
	for si in 0 ..< int(strat_plan.strata_count) {
		rb.stratum_rules[si] = make([]u32, stratum_counts[si], a)
	}
	for rc, ri in rb.rules {
		st := rc.stratum
		pos := stratum_cursors[st]
		rb.stratum_rules[st][pos] = u32(ri)
		stratum_cursors[st] = pos + 1
	}

	rb.stratum_wave_safe = make([]bool, strat_plan.strata_count, a)
	for st in 0 ..< int(strat_plan.strata_count) {
		rids := rb.stratum_rules[st]
		safe := true
		if len(rids) > 0 {
			first_rc := rb.rules[rids[0]]
			exp_salience := first_rc.salience
			exp_phase := first_rc.phase
			for rid in rids {
				rc := rb.rules[rid]
				if rc.salience != exp_salience || rc.phase != exp_phase {
					safe = false
					break
				}
				for act in rc.actions {
					if act.kind == .Retract || act.kind == .Effect {
						safe = false
						break
					}
				}
				if !safe {
					break
				}
				for seg_id in rc.segment_ids {
					sdef := rb.segments[seg_id]
					for ni := sdef.node_start; ni < sdef.node_start + sdef.node_count; ni += 1 {
						k := rb.beta_nodes[ni].kind
						if k == .Not || k == .Exists || k == .Accum {
							safe = false
							break
						}
					}
					if !safe {
						break
					}
				}
				if !safe {
					break
				}
			}
		}
		rb.stratum_wave_safe[st] = safe
	}

	phase_max := make(map[String_Id]u32, 4, allocator)
	defer delete(phase_max)
	for rc in rb.rules {
		if rc.phase == EMPTY_STRING {
			continue
		}
		if prev, has := phase_max[rc.phase]; !has || rc.stratum > prev {
			phase_max[rc.phase] = rc.stratum
		}
	}
	if len(phase_max) > 0 {
		rb.phase_max_stratum = make(map[String_Id]u32, len(phase_max), a)
		for ph, st in phase_max {
			rb.phase_max_stratum[ph] = st
		}
	}

	rb.sccs = make([]Scc_Info, len(strat_plan.sccs), a)
	for sc, si in strat_plan.sccs {
		pnames := make([]String_Id, len(sc.pred_names), a)
		copy(pnames, sc.pred_names)
		rb.sccs[si] = Scc_Info{
			id               = sc.id,
			pred_names       = pnames,
			is_recursive     = sc.is_recursive,
			has_neg_or_accum = sc.has_neg_or_accum,
		}
	}

	telemetry_count_add(telemetry, .Alpha_Nodes_Shared, ctx.shared_count)
	telemetry_count_add(telemetry, .Segments_Created, u64(len(rb.segments)))
	telemetry_watermark_arena(telemetry, u64(rb.arena.total_used))
	ok_done = true
	return rb, .None
}
