package forseti

import "core:slice"

MAX_RULE_PATTERNS :: 64

Beta_Node_Kind :: enum u8 {
	Left_Input_Adapter,
	Join,
	Decide,
	Filter,
	Bind,
	Rule_Terminal,
	Not,
	Exists,
	Accum,
}

Join_Key_Pair :: struct {
	left_var_slot:   u16,
	right_field_idx: i16,
}

Beta_Node_Def :: struct {
	id:            u32,
	kind:          Beta_Node_Kind,
	alpha_mem_id:  u32,
	subnetwork_id: u32,
	fact_slot:     u8,
	decide_slot:   u8,
	accum_op:      Accum_Op,
	prog_idx:      u32,
	rule_id:       u32,
	join_keys:     []Join_Key_Pair,
	field_binds:   []Alpha_Field_Bind,
	var_slot:      u16, // for Bind / Accum
}

Segment_Input_Link :: struct {
	alpha_mem_id: u32,
	bit_mask:     u64,
}

Segment_Def :: struct {
	id:              u32,
	node_start:      u32,
	node_count:      u32,
	inputs:          []Segment_Input_Link,
	all_linked_mask: u64,
	rule_id:         u32,
}

@(private)
_append_alpha_sub :: proc(ctx: ^Rb_Build_Ctx, alpha_mem_id: u32, seg_id: u32, bit_mask: u64, notify_only := false) {
	list, has := &ctx.sub_lists[alpha_mem_id]
	if !has {
		ctx.sub_lists[alpha_mem_id] = make([dynamic]Alpha_Segment_Target, 0, 2, context.temp_allocator)
		list = &ctx.sub_lists[alpha_mem_id]
	}
	for existing in list {
		if existing.seg_id == seg_id && existing.input_bit == bit_mask && existing.notify_only == notify_only {
			return
		}
	}
	append(list, Alpha_Segment_Target{seg_id = seg_id, input_bit = bit_mask, notify_only = notify_only})
}

@(private)
_collect_expr_outer_vars :: proc(
	ir: ^Rulebase_IR,
	eid: Expr_Id,
	outer_vars: map[String_Id]u16,
	outer_fact_descs: []Vm_Fact_Slot_Desc,
	out_slots: ^[dynamic]u16,
	uses_outer_fact: ^bool,
) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return
	}
	e := ir.exprs[eid]
	switch e.kind {
	case .Var:
		if slot, ok := outer_vars[e.str_id]; ok {
			for prev in out_slots^ {
				if prev == slot {
					return
				}
			}
			append(out_slots, slot)
			return
		}
		if uses_outer_fact != nil {
			for ofd in outer_fact_descs {
				if ofd.var_name != EMPTY_STRING && ofd.var_name == e.str_id {
					uses_outer_fact^ = true
					return
				}
			}
		}
	case .Unary, .Field_Access:
		_collect_expr_outer_vars(ir, e.lhs, outer_vars, outer_fact_descs, out_slots, uses_outer_fact)
	case .Binary, .Range:
		_collect_expr_outer_vars(ir, e.lhs, outer_vars, outer_fact_descs, out_slots, uses_outer_fact)
		_collect_expr_outer_vars(ir, e.rhs, outer_vars, outer_fact_descs, out_slots, uses_outer_fact)
	case .Cell_Cmp:
		_collect_expr_outer_vars(ir, e.rhs, outer_vars, outer_fact_descs, out_slots, uses_outer_fact)
	case .In_List, .Call:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			_collect_expr_outer_vars(ir, ir.extra_exprs[i], outer_vars, outer_fact_descs, out_slots, uses_outer_fact)
		}
	case .Invalid, .Lit_Bool, .Lit_Int, .Lit_Float, .Lit_String, .Ident, .Wildcard:
	}
}

@(private)
_compile_subnetwork :: proc(
	ctx: ^Rb_Build_Ctx,
	outer_seg_id: u32,
	sub_clauses: []Clause_IR,
	outer_vars: map[String_Id]u16,
	outer_next_var: u16,
	outer_fact_descs: []Vm_Fact_Slot_Desc,
	outer_decide_descs: []Vm_Decide_Slot_Desc,
	is_accum := false,
	accum_op := Accum_Op.Count,
	accum_expr := INVALID_EXPR,
	accum_guard := INVALID_EXPR,
	out_var_slot := u16(0),
) -> (sub_id: u32, err: Compile_Error) {
	sub_vars := make(map[String_Id]u16, len(outer_vars) + 8, context.temp_allocator)
	for k, v in outer_vars {
		sub_vars[k] = v
	}
	sub_next_var := outer_next_var
	sub_fact_descs := make([dynamic]Vm_Fact_Slot_Desc, len(outer_fact_descs), len(outer_fact_descs) + 4, context.temp_allocator)
	copy(sub_fact_descs[:], outer_fact_descs)

	steps := make([dynamic]Subnetwork_Step, 0, len(sub_clauses) + 1, context.temp_allocator)
	group_slots := make([dynamic]u16, 0, 4, context.temp_allocator)
	uses_outer_fact := false

	add_group_slot := proc(slots: ^[dynamic]u16, s: u16) {
		for prev in slots^ {
			if prev == s {
				return
			}
		}
		append(slots, s)
	}

	for cl in sub_clauses {
		#partial switch cl.kind {
		case .Pattern:
			fslot := u8(len(sub_fact_descs))
			alpha_id, bidx, binds, joins, _, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				&sub_vars,
				&sub_next_var,
				&sub_fact_descs,
			)
			if c_err != .None {
				return 0, c_err
			}
			_append_alpha_sub(ctx, alpha_id, outer_seg_id, 0, notify_only = true)
			for jk in joins {
				if jk.left_var_slot < outer_next_var {
					add_group_slot(&group_slots, jk.left_var_slot)
				}
			}
			append(&steps, Subnetwork_Step{
				kind         = .Pattern,
				alpha_mem_id = alpha_id,
				binding_idx  = bidx,
				fact_slot    = fslot,
				join_keys    = joins,
				field_binds  = binds,
				guard_prog   = -1,
			})

		case .Where:
			_collect_expr_outer_vars(ctx.ir, cl.expr, outer_vars, outer_fact_descs, &group_slots, &uses_outer_fact)
			var_map := make(map[String_Id]u8, len(sub_vars), context.temp_allocator)
			for k, v in sub_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = var_map,
				fact_descs   = sub_fact_descs[:],
				decide_descs = outer_decide_descs,
			}
			prog, verr := vm_compile_expr(&env, cl.expr, ctx.alloc)
			if verr != .None {
				return 0, .Vm_Compile_Failed
			}
			pidx := i32(len(ctx.programs))
			append(&ctx.programs, prog)
			append(&steps, Subnetwork_Step{
				kind       = .Where,
				guard_prog = pidx,
			})

		case:
			return 0, .Unsupported_Clause
		}
	}

	acc_expr_prog := i32(-1)
	acc_expr_fslot := i16(-1)
	acc_guard_prog := i32(-1)

	if is_accum {
		if accum_expr != INVALID_EXPR && int(accum_expr) < len(ctx.ir.exprs) {
			_collect_expr_outer_vars(ctx.ir, accum_expr, outer_vars, outer_fact_descs, &group_slots, &uses_outer_fact)
			ae := ctx.ir.exprs[accum_expr]
			if ae.kind == .Var {
				for fd, fi in sub_fact_descs {
					if fd.var_name == ae.str_id {
						acc_expr_fslot = i16(fi)
						break
					}
				}
			}
			if acc_expr_fslot < 0 {
				var_map := make(map[String_Id]u8, len(sub_vars), context.temp_allocator)
				for k, v in sub_vars {
					var_map[k] = u8(v)
				}
				env := Vm_Compile_Env{
					ir           = ctx.ir,
					tables       = ctx.rb.tables,
					var_names    = var_map,
					fact_descs   = sub_fact_descs[:],
					decide_descs = outer_decide_descs,
				}
				prog, verr := vm_compile_expr(&env, accum_expr, ctx.alloc)
				if verr != .None {
					return 0, .Vm_Compile_Failed
				}
				acc_expr_prog = i32(len(ctx.programs))
				append(&ctx.programs, prog)
			}
		}

		if accum_guard != INVALID_EXPR {
			_collect_expr_outer_vars(ctx.ir, accum_guard, outer_vars, outer_fact_descs, &group_slots, &uses_outer_fact)
			var_map := make(map[String_Id]u8, len(sub_vars), context.temp_allocator)
			for k, v in sub_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = var_map,
				fact_descs   = sub_fact_descs[:],
				decide_descs = outer_decide_descs,
			}
			prog, verr := vm_compile_expr(&env, accum_guard, ctx.alloc)
			if verr != .None {
				return 0, .Vm_Compile_Failed
			}
			acc_guard_prog = i32(len(ctx.programs))
			append(&ctx.programs, prog)
		}
	}

	slice.sort(group_slots[:])
	out_steps := make([]Subnetwork_Step, len(steps), ctx.alloc)
	copy(out_steps, steps[:])
	out_groups := make([]u16, len(group_slots), ctx.alloc)
	copy(out_groups, group_slots[:])

	sub_id = u32(len(ctx.subnetworks))
	append(&ctx.subnetworks, Subnetwork_Def{
		id                   = sub_id,
		steps                = out_steps,
		accum_op             = accum_op,
		accum_expr_prog      = acc_expr_prog,
		accum_expr_fact_slot = acc_expr_fslot,
		accum_guard_prog     = acc_guard_prog,
		out_var_slot         = out_var_slot,
		group_var_slots      = out_groups,
		uses_outer_fact      = uses_outer_fact,
	})
	return sub_id, .None
}

@(private)
build_compiled_rule :: proc(
	ctx: ^Rb_Build_Ctx,
	rdef: Rule_Def,
	rule_id: u32,
) -> (rc: Rule_Compiled, err: Compile_Error) {
	bound_vars := make(map[String_Id]u16, 16, context.temp_allocator)
	next_var: u16 = 0
	fact_descs := make([dynamic]Vm_Fact_Slot_Desc, 0, 4, context.temp_allocator)
	decide_descs := make([dynamic]Vm_Decide_Slot_Desc, 0, 2, context.temp_allocator)

	seg_id := u32(len(ctx.segments))
	node_start := u32(len(ctx.beta_nodes))
	input_links := make([dynamic]Segment_Input_Link, 0, 4, context.temp_allocator)
	first_decide_table := INVALID_TABLE_IDX

	pat_idx := u8(0)
	for cl in rdef.when_clauses {
		#partial switch cl.kind {
		case .Pattern:
			if pat_idx >= MAX_RULE_PATTERNS {
				return {}, .Too_Many_Patterns
			}
			fslot := u8(len(fact_descs))
			alpha_id, _, binds, joins, _, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				&bound_vars,
				&next_var,
				&fact_descs,
			)
			if c_err != .None {
				return {}, c_err
			}

			bit_mask := u64(1) << pat_idx
			append(&input_links, Segment_Input_Link{
				alpha_mem_id = alpha_id,
				bit_mask     = bit_mask,
			})
			_append_alpha_sub(ctx, alpha_id, seg_id, bit_mask)

			bn_kind := Beta_Node_Kind.Left_Input_Adapter if pat_idx == 0 else Beta_Node_Kind.Join
			append(&ctx.beta_nodes, Beta_Node_Def{
				id           = u32(len(ctx.beta_nodes)),
				kind         = bn_kind,
				alpha_mem_id = alpha_id,
				fact_slot    = fslot,
				join_keys    = joins,
				field_binds  = binds,
			})
			pat_idx += 1

		case .Not, .Exists:
			sub_id := _compile_subnetwork(
				ctx,
				seg_id,
				cl.children,
				bound_vars,
				next_var,
				fact_descs[:],
				decide_descs[:],
			) or_return
			bn_kind := Beta_Node_Kind.Not if cl.kind == .Not else Beta_Node_Kind.Exists
			append(&ctx.beta_nodes, Beta_Node_Def{
				id            = u32(len(ctx.beta_nodes)),
				kind          = bn_kind,
				subnetwork_id = sub_id,
			})

		case .Accum:
			vslot := next_var
			next_var += 1
			sub_id := _compile_subnetwork(
				ctx,
				seg_id,
				cl.inner_pat,
				bound_vars,
				next_var,
				fact_descs[:],
				decide_descs[:],
				is_accum = true,
				accum_op = cl.accum_op,
				accum_expr = cl.expr,
				accum_guard = cl.guard_expr,
				out_var_slot = vslot,
			) or_return
			if cl.bind_var != EMPTY_STRING {
				bound_vars[cl.bind_var] = vslot
			}
			append(&ctx.beta_nodes, Beta_Node_Def{
				id            = u32(len(ctx.beta_nodes)),
				kind          = .Accum,
				subnetwork_id = sub_id,
				accum_op      = cl.accum_op,
				var_slot      = vslot,
			})

		case .Decide:
			dslot := u8(len(decide_descs))
			tidx, tok := ctx.rb.table_by_name[cl.target]
			if !tok {
				return {}, .Unknown_Binding
			}
			if first_decide_table == INVALID_TABLE_IDX {
				first_decide_table = u16(tidx)
			}
			var_map := make(map[String_Id]u8, len(bound_vars), context.temp_allocator)
			for k, v in bound_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = var_map,
				fact_descs   = fact_descs[:],
				decide_descs = decide_descs[:],
			}
			prog, verr := vm_compile_decide(&env, cl.target, cl.fields, dslot, ctx.alloc)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			pidx := u32(len(ctx.programs))
			append(&ctx.programs, prog)
			append(&decide_descs, Vm_Decide_Slot_Desc{
				var_name  = cl.bind_var,
				table_idx = tidx,
			})
			append(&ctx.beta_nodes, Beta_Node_Def{
				id          = u32(len(ctx.beta_nodes)),
				kind        = .Decide,
				decide_slot = dslot,
				prog_idx    = pidx,
			})

		case .Where:
			var_map := make(map[String_Id]u8, len(bound_vars), context.temp_allocator)
			for k, v in bound_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = var_map,
				fact_descs   = fact_descs[:],
				decide_descs = decide_descs[:],
			}
			prog, verr := vm_compile_expr(&env, cl.expr, ctx.alloc)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			pidx := u32(len(ctx.programs))
			append(&ctx.programs, prog)
			append(&ctx.beta_nodes, Beta_Node_Def{
				id       = u32(len(ctx.beta_nodes)),
				kind     = .Filter,
				prog_idx = pidx,
			})

		case .Let:
			var_map := make(map[String_Id]u8, len(bound_vars), context.temp_allocator)
			for k, v in bound_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = var_map,
				fact_descs   = fact_descs[:],
				decide_descs = decide_descs[:],
			}
			prog, verr := vm_compile_expr(&env, cl.expr, ctx.alloc)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			pidx := u32(len(ctx.programs))
			append(&ctx.programs, prog)
			vslot := next_var
			next_var += 1
			bound_vars[cl.bind_var] = vslot
			append(&ctx.beta_nodes, Beta_Node_Def{
				id       = u32(len(ctx.beta_nodes)),
				kind     = .Bind,
				prog_idx = pidx,
				var_slot = vslot,
			})

		case:
			return {}, .Unsupported_Clause
		}
	}

	append(&ctx.beta_nodes, Beta_Node_Def{
		id      = u32(len(ctx.beta_nodes)),
		kind    = .Rule_Terminal,
		rule_id = rule_id,
	})

	all_mask: u64 = (u64(1) << pat_idx) - 1 if pat_idx < 64 else ~u64(0)
	if pat_idx == 0 {
		all_mask = 0
		append(&ctx.zero_input_segs, seg_id)
	}
	links := make([]Segment_Input_Link, len(input_links), ctx.alloc)
	copy(links, input_links[:])
	append(&ctx.segments, Segment_Def{
		id              = seg_id,
		node_start      = node_start,
		node_count      = u32(len(ctx.beta_nodes)) - node_start,
		inputs          = links,
		all_linked_mask = all_mask,
		rule_id         = rule_id,
	})

	seg_ids := make([]u32, 1, ctx.alloc)
	seg_ids[0] = seg_id

	// Compile actions
	var_map := make(map[String_Id]u8, len(bound_vars), context.temp_allocator)
	for k, v in bound_vars {
		var_map[k] = u8(v)
	}
	actions := make([]Compiled_Action, len(rdef.then_actions), ctx.alloc)
	for act, ai in rdef.then_actions {
		ca := Compiled_Action{
			kind          = act.kind,
			unconditional = act.unconditional,
			retract_slot  = -1,
		}
		#partial switch act.kind {
		case .Assert:
			tbind, tok := ctx.rb.binding_by_name[act.target]
			if !tok {
				return {}, .Unknown_Binding
			}
			ca.target_bind = tbind
			schema_id := ctx.ir.bindings[tbind].schema_id
			schema := ctx.ir.schemas[schema_id]
			ca.fields = make([]Compiled_Action_Field, len(act.fields), ctx.alloc)
			for fb, fi in act.fields {
				fidx := i16(-1)
				for sf, sfi in schema.fields {
					if sf.name == fb.name {
						fidx = i16(sfi)
						break
					}
				}
				if fidx < 0 {
					return {}, .Unknown_Field
				}
				env := Vm_Compile_Env{
					ir           = ctx.ir,
					tables       = ctx.rb.tables,
					var_names    = var_map,
					fact_descs   = fact_descs[:],
					decide_descs = decide_descs[:],
				}
				prog, verr := vm_compile_expr(&env, fb.expr, ctx.alloc)
				if verr != .None {
					return {}, .Vm_Compile_Failed
				}
				pidx := i32(len(ctx.programs))
				append(&ctx.programs, prog)
				ca.fields[fi] = Compiled_Action_Field{
					field_idx  = fidx,
					field_name = fb.name,
					expr_prog  = pidx,
				}
			}
		case .Retract:
			if act.expr != INVALID_EXPR {
				re := ctx.ir.exprs[act.expr]
				if re.kind == .Var {
					for fd, fi in fact_descs {
						if fd.var_name == re.str_id {
							ca.retract_slot = i16(fi)
							break
						}
					}
				}
			}
		case .Effect:
			ca.effect_kind = act.target
			ca.fields = make([]Compiled_Action_Field, len(act.fields), ctx.alloc)
			for fb, fi in act.fields {
				env := Vm_Compile_Env{
					ir           = ctx.ir,
					tables       = ctx.rb.tables,
					var_names    = var_map,
					fact_descs   = fact_descs[:],
					decide_descs = decide_descs[:],
				}
				prog, verr := vm_compile_expr(&env, fb.expr, ctx.alloc)
				if verr != .None {
					return {}, .Vm_Compile_Failed
				}
				pidx := i32(len(ctx.programs))
				append(&ctx.programs, prog)
				ca.fields[fi] = Compiled_Action_Field{
					field_idx  = i16(fi),
					field_name = fb.name,
					expr_prog  = pidx,
				}
			}
		}
		actions[ai] = ca
	}

	stratum := u32(0)
	is_rec := false
	if int(rule_id) < len(ctx.rule_stratum) {
		stratum = ctx.rule_stratum[rule_id]
	}
	if int(rule_id) < len(ctx.rule_recursive) {
		is_rec = ctx.rule_recursive[rule_id]
	}

	return Rule_Compiled{
		id               = rule_id,
		name             = rdef.name,
		phase            = rdef.phase,
		version          = ctx.ir.module_version,
		salience         = rdef.salience,
		stratum          = stratum,
		is_recursive     = is_rec,
		decide_table_idx = first_decide_table,
		input_count      = pat_idx,
		all_inputs_mask  = all_mask,
		segment_ids      = seg_ids,
		actions          = actions,
		var_count        = next_var,
		fact_slot_count  = u8(len(fact_descs)),
		decide_slots     = u8(len(decide_descs)),
	}, .None
}

@(private)
build_compiled_query :: proc(
	ctx: ^Rb_Build_Ctx,
	qdef: Query_Def,
	qid: u32,
) -> (qc: Query_Compiled, err: Compile_Error) {
	bound_vars := make(map[String_Id]u16, 16, context.temp_allocator)
	next_var: u16 = 0
	fact_descs := make([dynamic]Vm_Fact_Slot_Desc, 0, 4, context.temp_allocator)

	pnames := make([]String_Id, len(qdef.params), ctx.alloc)
	ptypes := make([]Type_Ref, len(qdef.params), ctx.alloc)
	for qp, pi in qdef.params {
		pnames[pi] = qp.name
		ptypes[pi] = qp.type
		pname_str := ir_string(ctx.ir, qp.name)
		qvar_buf: [128]u8 = ---
		if 1 + len(pname_str) <= len(qvar_buf) {
			qvar_buf[0] = '?'
			copy(qvar_buf[1:], pname_str)
			qvar_str := string(qvar_buf[:1 + len(pname_str)])
			if qid, q_ok := ctx.rb.interner.lookup[qvar_str]; q_ok {
				bound_vars[qid] = next_var
			} else if new_id, i_err := intern(&ctx.rb.interner, qvar_str); i_err == nil {
				bound_vars[new_id] = next_var
			}
		}
		bound_vars[qp.name] = next_var
		next_var += 1
	}

	steps := make([dynamic]Query_Step, 0, len(qdef.when_clauses), context.temp_allocator)
	for cl in qdef.when_clauses {
		#partial switch cl.kind {
		case .Pattern:
			fslot := u8(len(fact_descs))
			alpha_id, bidx, binds, joins, _, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				&bound_vars,
				&next_var,
				&fact_descs,
			)
			if c_err != .None {
				return {}, c_err
			}
			append(&steps, Query_Step{
				alpha_mem_id = alpha_id,
				binding_idx  = bidx,
				fact_slot    = fslot,
				join_keys    = joins,
				field_binds  = binds,
				guard_prog   = -1,
			})
		case .Where:
			var_map := make(map[String_Id]u8, len(bound_vars), context.temp_allocator)
			for k, v in bound_vars {
				var_map[k] = u8(v)
			}
			env := Vm_Compile_Env{
				ir         = ctx.ir,
				tables     = ctx.rb.tables,
				var_names  = var_map,
				fact_descs = fact_descs[:],
			}
			prog, verr := vm_compile_expr(&env, cl.expr, ctx.alloc)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			pidx := i32(len(ctx.programs))
			append(&ctx.programs, prog)
			append(&steps, Query_Step{
				guard_prog = pidx,
			})
		}
	}

	_ = slice.sort_by_cmp
	vnames := make([]String_Id, next_var, ctx.alloc)
	for k, slot in bound_vars {
		if int(slot) < len(vnames) {
			kstr := ir_string(ctx.ir, k)
			if len(kstr) > 0 && kstr[0] == '?' {
				vnames[slot] = k
			} else if vnames[slot] == EMPTY_STRING {
				vnames[slot] = k
			}
		}
	}
	out_steps := make([]Query_Step, len(steps), ctx.alloc)
	copy(out_steps, steps[:])
	return Query_Compiled{
		id          = qid,
		name        = qdef.name,
		param_names = pnames,
		param_types = ptypes,
		var_names   = vnames,
		clauses     = out_steps,
		var_count   = next_var,
	}, .None
}
