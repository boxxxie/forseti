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
	join_keys:     []Join_Key_Pair,
	field_binds:   []Alpha_Field_Bind,
	id:            u32,
	alpha_mem_id:  u32,
	subnetwork_id: u32,
	prog_idx:      u32,
	rule_id:       u32,
	var_slot:      u16, // for Bind / Accum
	kind:          Beta_Node_Kind,
	fact_slot:     u8,
	decide_slot:   u8,
	accum_op:      Accum_Op,
	owner_pat:     i8, // Pattern index in [0, pat_idx) owning all join_keys for pure_multi_join (-1 otherwise)
}

Segment_Input_Link :: struct {
	alpha_mem_id: u32,
	bit_mask:     u64,
}

Segment_Def :: struct {
	inputs:          []Segment_Input_Link,
	all_linked_mask: u64,
	id:              u32,
	node_start:      u32,
	node_count:      u32,
	rule_id:         u32,
	pure_single_lia: bool,
	delta_outer_ok:  bool,
	pure_two_join:   bool,
	pure_multi_join: bool,
	join_prefix_len: u8,
	delta_accum_ok:  bool,
	accum_node_idx:  u8,
}

@(private)
_append_alpha_sub :: proc(ctx: ^Rb_Build_Ctx, alpha_mem_id: u32, seg_id: u32, bit_mask: u64, notify_only := false) {
	for int(alpha_mem_id) >= len(ctx.sub_head) {
		append(&ctx.sub_head, -1)
		append(&ctx.sub_counts, 0)
	}
	target := Alpha_Segment_Target{seg_id = seg_id, input_bit = bit_mask, notify_only = notify_only}
	// Same segment appends in rule/node order, so scanning up to 8 recent links avoids O(N^2) work at 1M rules.
	cur := ctx.sub_head[alpha_mem_id]
	for step := 0; cur >= 0 && step < 8; step += 1 {
		edge := ctx.sub_edges[cur]
		if edge.target == target {
			return
		}
		cur = edge.next
	}
	eidx := i32(len(ctx.sub_edges))
	append(&ctx.sub_edges, _Sub_Edge{
		target = target,
		next   = ctx.sub_head[alpha_mem_id],
	})
	ctx.sub_head[alpha_mem_id] = eidx
	ctx.sub_counts[alpha_mem_id] += 1
}

@(private)
_fill_var_map :: proc(ctx: ^Rb_Build_Ctx, vars: map[String_Id]u16) -> Compile_Error {
	clear(&ctx.var_map)
	for k, v in vars {
		if v > u16(max(u8)) {
			return .Vm_Compile_Failed
		}
		ctx.var_map[k] = u8(v)
	}
	return .None
}

@(private)
_collect_expr_outer_vars :: proc(
	ir: ^Rulebase_IR,
	eid: Expr_Id,
	outer_vars: map[String_Id]u16,
	outer_fact_descs: []Vm_Fact_Slot_Desc,
	outer_decide_descs: []Vm_Decide_Slot_Desc,
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
			for odd in outer_decide_descs {
				if odd.var_name != EMPTY_STRING && odd.var_name == e.str_id {
					uses_outer_fact^ = true
					return
				}
			}
		}
	case .Unary, .Field_Access:
		_collect_expr_outer_vars(ir, e.lhs, outer_vars, outer_fact_descs, outer_decide_descs, out_slots, uses_outer_fact)
	case .Binary, .Range:
		_collect_expr_outer_vars(ir, e.lhs, outer_vars, outer_fact_descs, outer_decide_descs, out_slots, uses_outer_fact)
		_collect_expr_outer_vars(ir, e.rhs, outer_vars, outer_fact_descs, outer_decide_descs, out_slots, uses_outer_fact)
	case .Cell_Cmp:
		_collect_expr_outer_vars(ir, e.rhs, outer_vars, outer_fact_descs, outer_decide_descs, out_slots, uses_outer_fact)
	case .In_List, .Call:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			_collect_expr_outer_vars(ir, ir.extra_exprs[i], outer_vars, outer_fact_descs, outer_decide_descs, out_slots, uses_outer_fact)
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
	sub_vars := make(map[String_Id]u16, len(outer_vars) + 8, ctx.scratch_alloc)
	for k, v in outer_vars {
		sub_vars[k] = v
	}
	sub_next_var := outer_next_var
	sub_fact_descs := make([dynamic]Vm_Fact_Slot_Desc, len(outer_fact_descs), len(outer_fact_descs) + 4, ctx.scratch_alloc)
	copy(sub_fact_descs[:], outer_fact_descs)

	steps := make([dynamic]Subnetwork_Step, 0, len(sub_clauses) + 1, ctx.scratch_alloc)
	group_slots := make([dynamic]u16, 0, 4, ctx.scratch_alloc)
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
			if len(sub_fact_descs) > int(max(u8)) {
				return 0, .Too_Many_Patterns
			}
			fslot := u8(len(sub_fact_descs))
			alpha_id, bidx, binds, joins, res_progs, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				&sub_vars,
				&sub_next_var,
				&sub_fact_descs,
				outer_decide_descs,
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
			if len(res_progs) > 0 {
				for fb in cl.fields {
					_collect_expr_outer_vars(ctx.ir, fb.expr, outer_vars, outer_fact_descs, outer_decide_descs, &group_slots, &uses_outer_fact)
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
			for pidx in res_progs {
				append(&steps, Subnetwork_Step{
					kind       = .Where,
					guard_prog = i32(pidx),
				})
			}

		case .Where:
			_collect_expr_outer_vars(ctx.ir, cl.expr, outer_vars, outer_fact_descs, outer_decide_descs, &group_slots, &uses_outer_fact)
			_fill_var_map(ctx, sub_vars) or_return
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = ctx.var_map,
				fact_descs   = sub_fact_descs[:],
				decide_descs = outer_decide_descs,
			}
			pidx, verr := _compile_and_intern_expr(ctx, &env, cl.expr)
			if verr != .None {
				return 0, .Vm_Compile_Failed
			}
			append(&steps, Subnetwork_Step{
				kind       = .Where,
				guard_prog = i32(pidx),
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
			_collect_expr_outer_vars(ctx.ir, accum_expr, outer_vars, outer_fact_descs, outer_decide_descs, &group_slots, &uses_outer_fact)
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
				_fill_var_map(ctx, sub_vars) or_return
				env := Vm_Compile_Env{
					ir           = ctx.ir,
					tables       = ctx.rb.tables,
					var_names    = ctx.var_map,
					fact_descs   = sub_fact_descs[:],
					decide_descs = outer_decide_descs,
				}
				pidx, verr := _compile_and_intern_expr(ctx, &env, accum_expr)
				if verr != .None {
					return 0, .Vm_Compile_Failed
				}
				acc_expr_prog = i32(pidx)
			}
		}

		if accum_guard != INVALID_EXPR {
			_collect_expr_outer_vars(ctx.ir, accum_guard, outer_vars, outer_fact_descs, outer_decide_descs, &group_slots, &uses_outer_fact)
			_fill_var_map(ctx, sub_vars) or_return
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = ctx.var_map,
				fact_descs   = sub_fact_descs[:],
				decide_descs = outer_decide_descs,
			}
			pidx, verr := _compile_and_intern_expr(ctx, &env, accum_guard)
			if verr != .None {
				return 0, .Vm_Compile_Failed
			}
			acc_guard_prog = i32(pidx)
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
	clear(&ctx.bound_vars)
	clear(&ctx.fact_descs)
	clear(&ctx.decide_descs)
	clear(&ctx.input_links)
	bound_vars := &ctx.bound_vars
	next_var: u16 = 0
	fact_descs := &ctx.fact_descs
	decide_descs := &ctx.decide_descs

	seg_id := u32(len(ctx.segments))
	node_start := u32(len(ctx.beta_nodes))
	input_links := &ctx.input_links
	first_decide_table := INVALID_TABLE_IDX

	pat_idx := u8(0)
	for cl in rdef.when_clauses {
		#partial switch cl.kind {
		case .Pattern:
			if pat_idx >= MAX_RULE_PATTERNS || len(fact_descs^) >= int(max(u8)) {
				return {}, .Too_Many_Patterns
			}
			fslot := u8(len(fact_descs^))
			alpha_id, _, binds, joins, res_progs, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				bound_vars,
				&next_var,
				fact_descs,
				decide_descs^[:],
			)
			if c_err != .None {
				return {}, c_err
			}

			bit_mask := u64(1) << pat_idx
			append(input_links, Segment_Input_Link{
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
			for rp in res_progs {
				append(&ctx.beta_nodes, Beta_Node_Def{
					id       = u32(len(ctx.beta_nodes)),
					kind     = .Filter,
					prog_idx = rp,
				})
			}
			pat_idx += 1

		case .Not, .Exists:
			sub_id := _compile_subnetwork(
				ctx,
				seg_id,
				cl.children,
				bound_vars^,
				next_var,
				fact_descs^[:],
				decide_descs^[:],
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
				bound_vars^,
				next_var,
				fact_descs^[:],
				decide_descs^[:],
				is_accum = true,
				accum_op = cl.accum_op,
				accum_expr = cl.expr,
				accum_guard = cl.guard_expr,
				out_var_slot = vslot,
			) or_return
			if cl.bind_var != EMPTY_STRING {
				bound_vars^[cl.bind_var] = vslot
			}
			append(&ctx.beta_nodes, Beta_Node_Def{
				id            = u32(len(ctx.beta_nodes)),
				kind          = .Accum,
				subnetwork_id = sub_id,
				accum_op      = cl.accum_op,
				var_slot      = vslot,
			})

		case .Decide:
			if len(decide_descs^) >= int(max(u8)) {
				return {}, .Vm_Compile_Failed
			}
			dslot := u8(len(decide_descs^))
			tidx, tok := ctx.rb.table_by_name[cl.target]
			if !tok {
				return {}, .Unknown_Binding
			}
			if first_decide_table == INVALID_TABLE_IDX {
				first_decide_table = u16(tidx)
			}
			_fill_var_map(ctx, bound_vars^) or_return
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = ctx.var_map,
				fact_descs   = fact_descs^[:],
				decide_descs = decide_descs^[:],
			}
			pidx, verr := _compile_and_intern_decide(ctx, &env, cl.target, cl.fields, dslot)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			append(decide_descs, Vm_Decide_Slot_Desc{
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
			_fill_var_map(ctx, bound_vars^) or_return
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = ctx.var_map,
				fact_descs   = fact_descs^[:],
				decide_descs = decide_descs^[:],
			}
			pidx, verr := _compile_and_intern_expr(ctx, &env, cl.expr)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			append(&ctx.beta_nodes, Beta_Node_Def{
				id       = u32(len(ctx.beta_nodes)),
				kind     = .Filter,
				prog_idx = pidx,
			})

		case .Let:
			_fill_var_map(ctx, bound_vars^) or_return
			env := Vm_Compile_Env{
				ir           = ctx.ir,
				tables       = ctx.rb.tables,
				var_names    = ctx.var_map,
				fact_descs   = fact_descs^[:],
				decide_descs = decide_descs^[:],
			}
			pidx, verr := _compile_and_intern_expr(ctx, &env, cl.expr)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			vslot := next_var
			next_var += 1
			bound_vars^[cl.bind_var] = vslot
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
	is_pure_lia := pat_idx == 1
	is_delta_outer := pat_idx == 1
	if is_pure_lia {
		for ni := node_start; ni < u32(len(ctx.beta_nodes)); ni += 1 {
			k := ctx.beta_nodes[ni].kind
			if k == .Join || k == .Not || k == .Exists || k == .Accum {
				is_pure_lia = false
				if k == .Join || k == .Accum {
					is_delta_outer = false
					break
				}
			}
		}
	}

	is_pure_two_join := false
	node_count := u32(len(ctx.beta_nodes)) - node_start
	if pat_idx == 2 && node_count >= 3 {
		bn0 := ctx.beta_nodes[node_start]
		bn1 := ctx.beta_nodes[node_start + 1]
		if bn0.kind == .Left_Input_Adapter && bn1.kind == .Join && len(bn1.join_keys) > 0 {
			all_ok := true
			for jk in bn1.join_keys {
				found_bind := false
				for fb in bn0.field_binds {
					if fb.var_slot == jk.left_var_slot {
						found_bind = true
						break
					}
				}
				if !found_bind {
					all_ok = false
					break
				}
			}
			if all_ok {
				for ni := node_start + 2; ni < u32(len(ctx.beta_nodes)); ni += 1 {
					k := ctx.beta_nodes[ni].kind
					if k == .Join || k == .Not || k == .Exists || k == .Accum {
						all_ok = false
						break
					}
				}
			}
			is_pure_two_join = all_ok
		}
	}

	is_pure_multi_join := false
	join_prefix := u8(0)
	if pat_idx >= 3 && pat_idx <= 8 && node_count >= u32(pat_idx) + 1 {
		bn0 := ctx.beta_nodes[node_start]
		if bn0.kind == .Left_Input_Adapter {
			prefix_ok := true
			for mi := u32(1); mi < u32(pat_idx); mi += 1 {
				bn_m := ctx.beta_nodes[node_start + mi]
				if bn_m.kind != .Join || len(bn_m.join_keys) == 0 {
					prefix_ok = false
					break
				}
			}
			if prefix_ok {
				for ni := node_start + u32(pat_idx); ni < u32(len(ctx.beta_nodes)); ni += 1 {
					k := ctx.beta_nodes[ni].kind
					if k == .Join || k == .Not || k == .Exists || k == .Accum {
						prefix_ok = false
						break
					}
				}
			}
			if prefix_ok {
				owners: [8]i8
				for &o in owners {
					o = -1
				}
				for mi := u32(1); mi < u32(pat_idx); mi += 1 {
					bn_m := ctx.beta_nodes[node_start + mi]
					owner_found := i8(-1)
					multi_owner := false
					for jk in bn_m.join_keys {
						slot_owner := i8(-1)
						for pi := u32(0); pi < mi; pi += 1 {
							cand_bn := ctx.beta_nodes[node_start + pi]
							for fb in cand_bn.field_binds {
								if fb.var_slot == jk.left_var_slot {
									slot_owner = i8(pi)
									break
								}
							}
							if slot_owner >= 0 {
								break
							}
						}
						if slot_owner < 0 {
							multi_owner = true
							break
						}
						if owner_found < 0 {
							owner_found = slot_owner
						} else if owner_found != slot_owner {
							multi_owner = true
							break
						}
					}
					if multi_owner || owner_found < 0 {
						prefix_ok = false
						break
					}
					owners[mi] = owner_found
				}
				if prefix_ok {
					for mi := u32(1); mi < u32(pat_idx); mi += 1 {
						ctx.beta_nodes[node_start + mi].owner_pat = owners[mi]
					}
					is_pure_multi_join = true
					join_prefix = pat_idx
				}
			}
		}
	}

	is_delta_accum := false
	accum_rel_idx := u8(0)
	if pat_idx == 1 && len(rdef.then_actions) > 0 {
		accum_cnt := 0
		has_other := false
		for ni := node_start; ni < u32(len(ctx.beta_nodes)); ni += 1 {
			k := ctx.beta_nodes[ni].kind
			if k == .Accum {
				accum_cnt += 1
				accum_rel_idx = u8(ni - node_start)
			} else if k == .Join || k == .Not || k == .Exists {
				has_other = true
				break
			}
		}
		if !has_other && accum_cnt == 1 {
			lia_bn := ctx.beta_nodes[node_start]
			acc_bn := ctx.beta_nodes[node_start + u32(accum_rel_idx)]
			acc_sub := ctx.subnetworks[acc_bn.subnetwork_id]
			if lia_bn.kind == .Left_Input_Adapter && _accum_can_track_incrementally(acc_sub) {
				binds_ok := true
				for gslot in acc_sub.group_var_slots {
					found_g := false
					for fb in lia_bn.field_binds {
						if fb.var_slot == gslot {
							found_g = true
							break
						}
					}
					if !found_g {
						binds_ok = false
						break
					}
				}
				if binds_ok {
					actions_ok := true
					for act in rdef.then_actions {
						if act.kind != .Assert || act.unconditional {
							actions_ok = false
							break
						}
					}
					is_delta_accum = actions_ok
				}
			}
		}
	}

	links := make([]Segment_Input_Link, len(input_links^), ctx.alloc)
	copy(links, input_links^[:])
	append(&ctx.segments, Segment_Def{
		id              = seg_id,
		node_start      = node_start,
		node_count      = node_count,
		inputs          = links,
		all_linked_mask = all_mask,
		rule_id         = rule_id,
		pure_single_lia = is_pure_lia,
		delta_outer_ok  = is_delta_outer,
		pure_two_join   = is_pure_two_join,
		pure_multi_join = is_pure_multi_join,
		join_prefix_len = join_prefix,
		delta_accum_ok  = is_delta_accum,
		accum_node_idx  = accum_rel_idx,
	})

	seg_ids := make([]u32, 1, ctx.alloc)
	seg_ids[0] = seg_id

	// Compile actions
	_fill_var_map(ctx, bound_vars^) or_return
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
					var_names    = ctx.var_map,
					fact_descs   = fact_descs^[:],
					decide_descs = decide_descs^[:],
				}
				pidx, verr := _compile_and_intern_expr(ctx, &env, fb.expr)
				if verr != .None {
					return {}, .Vm_Compile_Failed
				}
				ca.fields[fi] = Compiled_Action_Field{
					field_idx  = fidx,
					field_name = fb.name,
					expr_prog  = i32(pidx),
				}
			}
		case .Retract:
			if act.expr != INVALID_EXPR {
				re := ctx.ir.exprs[act.expr]
				if re.kind == .Var {
					for fd, fi in fact_descs^ {
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
					var_names    = ctx.var_map,
					fact_descs   = fact_descs^[:],
					decide_descs = decide_descs^[:],
				}
				pidx, verr := _compile_and_intern_expr(ctx, &env, fb.expr)
				if verr != .None {
					return {}, .Vm_Compile_Failed
				}
				ca.fields[fi] = Compiled_Action_Field{
					field_idx  = i16(fi),
					field_name = fb.name,
					expr_prog  = i32(pidx),
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
		fact_slot_count  = u8(len(fact_descs^)),
		decide_slots     = u8(len(decide_descs^)),
	}, .None
}

@(private)
build_compiled_query :: proc(
	ctx: ^Rb_Build_Ctx,
	qdef: Query_Def,
	qid: u32,
) -> (qc: Query_Compiled, err: Compile_Error) {
	clear(&ctx.bound_vars)
	clear(&ctx.fact_descs)
	bound_vars := &ctx.bound_vars
	next_var: u16 = 0
	fact_descs := &ctx.fact_descs

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
			if q_sid, q_ok := ctx.rb.interner.lookup[qvar_str]; q_ok {
				bound_vars^[q_sid] = next_var
			} else if new_id, i_err := intern(&ctx.rb.interner, qvar_str); i_err == nil {
				bound_vars^[new_id] = next_var
			}
		}
		bound_vars^[qp.name] = next_var
		next_var += 1
	}

	steps := make([dynamic]Query_Step, 0, len(qdef.when_clauses), ctx.scratch_alloc)
	for cl in qdef.when_clauses {
		#partial switch cl.kind {
		case .Pattern:
			if len(fact_descs^) > int(max(u8)) {
				return {}, .Too_Many_Patterns
			}
			fslot := u8(len(fact_descs^))
			alpha_id, bidx, binds, joins, res_progs, c_err := compile_pattern_clause(
				ctx,
				cl,
				fslot,
				bound_vars,
				&next_var,
				fact_descs,
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
			for rp in res_progs {
				append(&steps, Query_Step{
					guard_prog = i32(rp),
				})
			}
		case .Where:
			_fill_var_map(ctx, bound_vars^) or_return
			env := Vm_Compile_Env{
				ir         = ctx.ir,
				tables     = ctx.rb.tables,
				var_names  = ctx.var_map,
				fact_descs = fact_descs^[:],
			}
			pidx, verr := _compile_and_intern_expr(ctx, &env, cl.expr)
			if verr != .None {
				return {}, .Vm_Compile_Failed
			}
			append(&steps, Query_Step{
				guard_prog = i32(pidx),
			})
		case:
			return {}, .Unsupported_Clause
		}
	}

	_ = slice.sort_by_cmp
	vnames := make([]String_Id, next_var, ctx.alloc)
	for k, slot in bound_vars^ {
		if int(slot) < len(vnames) {
			kstr := interner_get(&ctx.rb.interner, k)
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
