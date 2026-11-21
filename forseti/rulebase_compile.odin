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
	id:           u32,
	eq_field:     i16,
	eq_buckets:   map[Value_Key]u32,
	range_edges:  [dynamic]Alpha_Range_Edge,
	guard_edges:  [dynamic]Alpha_Guard_Edge,
	terminal_id:  i32, // -1 if no terminal at this node
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
	strata_count:      u32,
	stratum_recursive: []bool,
	stratum_rules:     [][]u32,
	zero_input_segs:   []u32,
	sccs:              []Scc_Info,
	telemetry:         ^Telemetry_Sink,
}

value_to_key :: proc "contextless" (v: Value) -> (k: Value_Key, ok: bool) {
	switch x in v {
	case bool:      return Value_Key{kind = .Bool, raw = 1 if x else 0}, true
	case i32:       return Value_Key{kind = .I64, raw = u64(i64(x))}, true
	case i64:       return Value_Key{kind = .I64, raw = u64(x)}, true
	case f64:       return Value_Key{kind = .F64, raw = transmute(u64)x}, true
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
	alpha_nodes:     [dynamic]Alpha_Node,
	alpha_terminals: [dynamic]Alpha_Terminal,
	beta_nodes:      [dynamic]Beta_Node_Def,
	subnetworks:     [dynamic]Subnetwork_Def,
	segments:        [dynamic]Segment_Def,
	zero_input_segs: [dynamic]u32,
	programs:        [dynamic]Bytecode_Program,
	sub_lists:       map[u32][dynamic]Alpha_Segment_Target,
	rule_stratum:    []u32,
	rule_recursive:  []bool,
	shared_count:    u64,
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
	append(&ctx.alpha_nodes, Alpha_Node{
		id          = id,
		eq_field    = -1,
		eq_buckets  = make(map[Value_Key]u32, 0, ctx.alloc),
		range_edges = make([dynamic]Alpha_Range_Edge, 0, 0, ctx.alloc),
		guard_edges = make([dynamic]Alpha_Guard_Edge, 0, 0, ctx.alloc),
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
				if existing, has := cur.eq_buckets[pr.eq_key]; has {
					ctx.shared_count += 1
					cur_id = existing
				} else {
					if len(cur.eq_buckets) > 0 {
						ctx.shared_count += 1 // Shares the parent Hash_Split node across buckets
					}
					next_id := new_alpha_node(ctx)
					ctx.alpha_nodes[cur_id].eq_buckets[pr.eq_key] = next_id
					cur_id = next_id
				}
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
				append(&ctx.alpha_nodes[cur_id].range_edges, Alpha_Range_Edge{
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
				append(&ctx.alpha_nodes[cur_id].range_edges, Alpha_Range_Edge{
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

	preds := make([dynamic]Alpha_Pred, 0, len(cl.fields), context.temp_allocator)
	bind_list := make([dynamic]Alpha_Field_Bind, 0, len(cl.fields), context.temp_allocator)
	join_list := make([dynamic]Join_Key_Pair, 0, 4, context.temp_allocator)
	res_list := make([dynamic]u32, 0, 2, context.temp_allocator)

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
				if iv, is_i := v.(i64); is_i {
					v = i32(iv)
				}
			}
			vk, _ := value_to_key(v)
			append(&preds, Alpha_Pred{
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
					if iv, is_i := v.(i64); is_i {
						v = i32(iv)
					}
				}
				if ex.binary_op == .Eq {
					vk, _ := value_to_key(v)
					append(&preds, Alpha_Pred{
						is_eq     = true,
						field_idx = i16(fidx),
						eq_key    = vk,
						const_val = v,
					})
				} else {
					append(&preds, Alpha_Pred{
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
				append(&join_list, Join_Key_Pair{
					left_var_slot   = existing_slot,
					right_field_idx = i16(fidx),
				})
				continue
			}
			slot := next_var^
			next_var^ += 1
			bound_vars^[ex.str_id] = slot
			append(&bind_list, Alpha_Field_Bind{
				field_idx = i16(fidx),
				var_slot  = slot,
			})
			continue
		}

		// Residual field expression evaluated against already-bound vars & current fact.
		// Compile `expr_rhs == cur_fact.field_name` cleanly via VM.
		var_map := make(map[String_Id]u8, len(bound_vars^), context.temp_allocator)
		for k, v in bound_vars^ {
			var_map[k] = u8(v)
		}
		env := Vm_Compile_Env{
			ir         = ctx.ir,
			tables     = ctx.rb.tables,
			var_names  = var_map,
			fact_descs = fact_descs[:],
		}
		prog, verr := vm_compile_expr(&env, fb.expr, ctx.alloc)
		if verr != .None {
			return 0, 0, nil, nil, nil, .Vm_Compile_Failed
		}
		_ = prog
		_ = pat_slot
	}

	alpha_id = insert_alpha_chain(ctx, bidx, preds[:], bind_list[:])

	out_binds := make([]Alpha_Field_Bind, len(bind_list), ctx.alloc)
	copy(out_binds, bind_list[:])

	out_joins := make([]Join_Key_Pair, len(join_list), ctx.alloc)
	copy(out_joins, join_list[:])

	out_res := make([]u32, len(res_list), ctx.alloc)
	copy(out_res, res_list[:])

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
	for s in ir.interner.strings[1:] {
		if _, ierr := intern(&rb.interner, s); ierr != nil {
			return {}, .Alloc_Failed
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

	rb.schemas = make([]Schema_Def, len(ir.schemas), a)
	copy(rb.schemas, ir.schemas)
	rb.bindings = make([]Binding_Def, len(ir.bindings), a)
	copy(rb.bindings, ir.bindings)

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

	ctx := Rb_Build_Ctx{
		ir              = ir,
		rb              = &rb,
		alloc           = a,
		alpha_nodes     = make([dynamic]Alpha_Node, 0, max(len(ir.rules), 16), context.temp_allocator),
		alpha_terminals = make([dynamic]Alpha_Terminal, 0, max(len(ir.rules), 16), context.temp_allocator),
		beta_nodes      = make([dynamic]Beta_Node_Def, 0, max(len(ir.rules) * 2, 16), context.temp_allocator),
		subnetworks     = make([dynamic]Subnetwork_Def, 0, 8, context.temp_allocator),
		segments        = make([dynamic]Segment_Def, 0, max(len(ir.rules), 16), context.temp_allocator),
		zero_input_segs = make([dynamic]u32, 0, 4, context.temp_allocator),
		programs        = make([dynamic]Bytecode_Program, 0, max(len(ir.rules), 16), context.temp_allocator),
		sub_lists       = make(map[u32][dynamic]Alpha_Segment_Target, 32, context.temp_allocator),
		rule_stratum    = strat_plan.rule_stratum,
		rule_recursive  = strat_plan.rule_recursive,
	}

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

	// Materialize compact arena slices and attach Alpha_Terminal -> Segment subscribers
	rb.alpha_nodes = make([]Alpha_Node, len(ctx.alpha_nodes), a)
	copy(rb.alpha_nodes, ctx.alpha_nodes[:])

	rb.alpha_terminals = make([]Alpha_Terminal, len(ctx.alpha_terminals), a)
	copy(rb.alpha_terminals, ctx.alpha_terminals[:])
	for tid, list in ctx.sub_lists {
		subs := make([]Alpha_Segment_Target, len(list), a)
		copy(subs, list[:])
		rb.alpha_terminals[tid].subscribers = subs
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

	// Materialize stratification topology on Rulebase arena.
	rb.strata_count = strat_plan.strata_count
	rb.stratum_recursive = make([]bool, strat_plan.strata_count, a)
	copy(rb.stratum_recursive, strat_plan.stratum_recursive)

	stratum_counts := make([]int, strat_plan.strata_count, context.temp_allocator)
	for rc in rb.rules {
		stratum_counts[rc.stratum] += 1
	}
	rb.stratum_rules = make([][]u32, strat_plan.strata_count, a)
	stratum_cursors := make([]int, strat_plan.strata_count, context.temp_allocator)
	for si in 0 ..< int(strat_plan.strata_count) {
		rb.stratum_rules[si] = make([]u32, stratum_counts[si], a)
	}
	for rc, ri in rb.rules {
		st := rc.stratum
		pos := stratum_cursors[st]
		rb.stratum_rules[st][pos] = u32(ri)
		stratum_cursors[st] = pos + 1
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
	ok_done = true
	return rb, .None
}
