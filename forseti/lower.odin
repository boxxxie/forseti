package forseti

import "core:mem"
import vmem "core:mem/virtual"

@(private)
Lower_Ctx :: struct {
	pool:        ^Ast_Pool,
	src_int:     ^String_Interner,
	ir:          ^Rulebase_IR,
	enums:       [dynamic]Enum_Def,
	exprs:       [dynamic]Expr_IR,
	extra_exprs: [dynamic]Expr_Id,
}

@(private)
lower_intern :: proc(ctx: ^Lower_Ctx, sid: String_Id) -> (out: String_Id, err: mem.Allocator_Error) {
	if sid == EMPTY_STRING {
		return EMPTY_STRING, nil
	}
	return intern(&ctx.ir.interner, interner_get(ctx.src_int, sid))
}

@(private)
lower_type_spec :: proc(ctx: ^Lower_Ctx, owner_name: String_Id, ts: Ast_Type_Spec) -> (tr: Type_Ref, err: mem.Allocator_Error) {
	tr.kind = ts.kind
	if ts.kind == .Enum {
		alloc := vmem.arena_allocator(&ctx.ir.arena)
		vars := make([]String_Id, ts.enum_variants.count, alloc) or_return
		for i in 0 ..< ts.enum_variants.count {
			vars[i] = lower_intern(ctx, ctx.pool.enum_variants[ts.enum_variants.start + i]) or_return
		}
		eid := u32(len(ctx.enums))
		append(&ctx.enums, Enum_Def{name = owner_name, variants = vars}) or_return
		tr.ref_id = eid
	}
	return tr, nil
}

@(private)
lower_expr :: proc(ctx: ^Lower_Ctx, nid: Node_Id) -> (eid: Expr_Id, err: mem.Allocator_Error) {
	if nid == INVALID_NODE || int(nid) >= len(ctx.pool.nodes) {
		return INVALID_EXPR, nil
	}
	node := ctx.pool.nodes[nid]
	ir_e := Expr_IR{span = node.span}

	switch p in node.payload {
	case Ast_Lit_Bool:
		ir_e.kind = .Lit_Bool
		ir_e.bool_val = p.val
	case Ast_Lit_Int:
		ir_e.kind = .Lit_Int
		ir_e.int_val = p.val
	case Ast_Lit_Float:
		ir_e.kind = .Lit_Float
		ir_e.float_val = p.val
	case Ast_Lit_String:
		ir_e.kind = .Lit_String
		ir_e.str_id = lower_intern(ctx, p.str) or_return
	case Ast_Var:
		ir_e.kind = .Var
		ir_e.str_id = lower_intern(ctx, p.name) or_return
	case Ast_Ident:
		ir_e.kind = .Ident
		ir_e.str_id = lower_intern(ctx, p.name) or_return
	case Ast_Wildcard:
		ir_e.kind = .Wildcard
	case Ast_Unary:
		ir_e.kind = .Unary
		ir_e.unary_op = p.op
		ir_e.lhs = lower_expr(ctx, p.operand) or_return
	case Ast_Binary:
		ir_e.kind = .Binary
		ir_e.binary_op = p.op
		ir_e.lhs = lower_expr(ctx, p.lhs) or_return
		ir_e.rhs = lower_expr(ctx, p.rhs) or_return
	case Ast_Field_Access:
		ir_e.kind = .Field_Access
		ir_e.lhs = lower_expr(ctx, p.base) or_return
		ir_e.str_id = lower_intern(ctx, p.field) or_return
	case Ast_Range:
		ir_e.kind = .Range
		ir_e.inclusive = p.inclusive
		ir_e.lhs = lower_expr(ctx, p.lo) or_return
		ir_e.rhs = lower_expr(ctx, p.hi) or_return
	case Ast_Cell_Cmp:
		ir_e.kind = .Cell_Cmp
		ir_e.binary_op = p.op
		ir_e.rhs = lower_expr(ctx, p.rhs) or_return
	case Ast_In_List:
		ir_e.kind = .In_List
		staged := make([]Expr_Id, p.items.count, context.temp_allocator) or_return
		for i in 0 ..< p.items.count {
			staged[i] = lower_expr(ctx, ctx.pool.extra_children[p.items.start + i]) or_return
		}
		start := u32(len(ctx.extra_exprs))
		append(&ctx.extra_exprs, ..staged) or_return
		ir_e.extra_span = Node_Span{start = start, count = p.items.count}
	case Ast_Call:
		ir_e.kind = .Call
		ir_e.str_id = lower_intern(ctx, p.callee) or_return
		staged := make([]Expr_Id, p.args.count, context.temp_allocator) or_return
		for i in 0 ..< p.args.count {
			staged[i] = lower_expr(ctx, ctx.pool.extra_children[p.args.start + i]) or_return
		}
		start := u32(len(ctx.extra_exprs))
		append(&ctx.extra_exprs, ..staged) or_return
		ir_e.extra_span = Node_Span{start = start, count = p.args.count}
	case Ast_Error:
		ir_e.kind = .Invalid
	}

	eid = Expr_Id(len(ctx.exprs))
	append(&ctx.exprs, ir_e) or_return
	return eid, nil
}

@(private)
lower_field_assigns :: proc(ctx: ^Lower_Ctx, span: Node_Span) -> (out: []Field_Binding_IR, err: mem.Allocator_Error) {
	if span.count == 0 {
		return nil, nil
	}
	alloc := vmem.arena_allocator(&ctx.ir.arena)
	out = make([]Field_Binding_IR, span.count, alloc) or_return
	for i in 0 ..< span.count {
		fa := ctx.pool.field_assigns[span.start + i]
		out[i] = Field_Binding_IR{
			name = lower_intern(ctx, fa.name) or_return,
			expr = lower_expr(ctx, fa.expr) or_return,
			span = fa.span,
		}
	}
	return out, nil
}

@(private)
lower_clauses :: proc(ctx: ^Lower_Ctx, span: Node_Span) -> (out: []Clause_IR, err: mem.Allocator_Error) {
	if span.count == 0 {
		return nil, nil
	}
	alloc := vmem.arena_allocator(&ctx.ir.arena)
	staged := make([dynamic]Clause_IR, 0, int(span.count), context.temp_allocator)
	for i in 0 ..< span.count {
		cl := ctx.pool.clauses[span.start + i]
		if cl.kind == .Error {
			continue
		}
		kind_ir: Clause_Kind_IR
		switch cl.kind {
		case .Pattern:
			kind_ir = .Pattern
		case .Eav:
			kind_ir = .Eav
		case .Not:
			kind_ir = .Not
		case .Exists:
			kind_ir = .Exists
		case .Accum:
			kind_ir = .Accum
		case .Decide:
			kind_ir = .Decide
		case .Where:
			kind_ir = .Where
		case .Let:
			kind_ir = .Let
		case .Error:
			continue
		}
		append(&staged, Clause_IR{
			kind       = kind_ir,
			bind_var   = lower_intern(ctx, cl.bind_var) or_return,
			target     = lower_intern(ctx, cl.target) or_return,
			fields     = lower_field_assigns(ctx, cl.fields) or_return,
			children   = lower_clauses(ctx, cl.children) or_return,
			expr       = lower_expr(ctx, cl.expr) or_return,
			guard_expr = lower_expr(ctx, cl.guard_expr) or_return,
			extra_expr = lower_expr(ctx, cl.extra_expr) or_return,
			accum_op   = cl.accum_op,
			inner_pat  = lower_clauses(ctx, cl.inner_pat) or_return,
			span       = cl.span,
		})
	}
	if len(staged) == 0 {
		return nil, nil
	}
	out = make([]Clause_IR, len(staged), alloc) or_return
	copy(out, staged[:])
	return out, nil
}

@(require_results)
lower_ast_to_ir :: proc(
	pool: ^Ast_Pool,
	src_interner: ^String_Interner,
	line_starts: []u32 = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ir: Rulebase_IR, err: mem.Allocator_Error) {
	scope := telemetry_span_begin(telemetry, .Ir_Lower, "ir_lower")
	defer telemetry_span_end(telemetry, scope)

	vmem.arena_init_growing(&ir.arena) or_return
	defer if err != nil {
		ir_destroy(&ir)
	}
	interner_init(&ir.interner, allocator) or_return

	arena_alloc := vmem.arena_allocator(&ir.arena)
	if len(line_starts) > 0 {
		ir.line_starts = make([]u32, len(line_starts), arena_alloc) or_return
		copy(ir.line_starts, line_starts)
	}

	ctx := Lower_Ctx{
		pool    = pool,
		src_int = src_interner,
		ir      = &ir,
	}
	ctx.enums = make([dynamic]Enum_Def, 0, 8, context.temp_allocator)
	ctx.exprs = make([dynamic]Expr_IR, 0, max(len(pool.nodes), 16), context.temp_allocator)
	ctx.extra_exprs = make([dynamic]Expr_Id, 0, 32, context.temp_allocator)
	append(&ctx.exprs, Expr_IR{kind = .Invalid}) // INVALID_EXPR == 0

	ir.module_name = lower_intern(&ctx, pool.module_name) or_return
	ir.module_version = lower_intern(&ctx, pool.module_version) or_return

	ir.schemas = make([]Schema_Def, len(pool.schemas), arena_alloc) or_return
	for s, si in pool.schemas {
		fields := make([]Field_Def, s.fields.count, arena_alloc) or_return
		for fi in 0 ..< s.fields.count {
			af := pool.schema_fields[s.fields.start + fi]
			fname := lower_intern(&ctx, af.name) or_return
			fields[fi] = Field_Def{
				name = fname,
				type = lower_type_spec(&ctx, fname, af.type) or_return,
				span = af.span,
			}
		}
		ir.schemas[si] = Schema_Def{
			name   = lower_intern(&ctx, s.name) or_return,
			fields = fields,
			span   = s.span,
		}
	}

	ir.bindings = make([]Binding_Def, len(pool.bindings), arena_alloc) or_return
	for b, bi in pool.bindings {
		segs := make([]Selector_Segment, b.segs.count, arena_alloc) or_return
		for si in 0 ..< b.segs.count {
			as := pool.selector_segs[b.segs.start + si]
			sk: Selector_Seg_Kind
			switch as.kind {
			case .Field:
				sk = .Field
			case .Var_Key:
				sk = .Var_Key
			case .Lit_Key:
				sk = .Lit_Key
			case .Wildcard:
				sk = .Wildcard
			}
			segs[si] = Selector_Segment{
				kind = sk,
				text = lower_intern(&ctx, as.text) or_return,
				span = as.span,
			}
		}
		ir.bindings[bi] = Binding_Def{
			kind        = b.kind,
			name        = lower_intern(&ctx, b.name) or_return,
			schema_name = lower_intern(&ctx, b.schema_name) or_return,
			schema_id   = Schema_Id(INVALID_ID),
			segments    = segs,
			span        = b.span,
		}
	}

	ir.tables = make([]Table_Def, len(pool.tables), arena_alloc) or_return
	for t, ti in pool.tables {
		inputs := make([]Table_Col_Def, t.inputs.count, arena_alloc) or_return
		for ci in 0 ..< t.inputs.count {
			ac := pool.table_cols[t.inputs.start + ci]
			cname := lower_intern(&ctx, ac.name) or_return
			inputs[ci] = Table_Col_Def{
				name = cname,
				type = lower_type_spec(&ctx, cname, ac.type) or_return,
				cost = ac.cost,
				span = ac.span,
			}
		}
		outputs := make([]Table_Col_Def, t.outputs.count, arena_alloc) or_return
		for ci in 0 ..< t.outputs.count {
			ac := pool.table_cols[t.outputs.start + ci]
			cname := lower_intern(&ctx, ac.name) or_return
			outputs[ci] = Table_Col_Def{
				name = cname,
				type = lower_type_spec(&ctx, cname, ac.type) or_return,
				cost = ac.cost,
				span = ac.span,
			}
		}
		rows := make([]Table_Row_Def, t.rows.count, arena_alloc) or_return
		for ri in 0 ..< t.rows.count {
			ar := pool.table_rows[t.rows.start + ri]
			cells := make([]Expr_Id, ar.cells.count, arena_alloc) or_return
			for k in 0 ..< ar.cells.count {
				cells[k] = lower_expr(&ctx, pool.extra_children[ar.cells.start + k]) or_return
			}
			outs := make([]Expr_Id, ar.outputs.count, arena_alloc) or_return
			for k in 0 ..< ar.outputs.count {
				outs[k] = lower_expr(&ctx, pool.extra_children[ar.outputs.start + k]) or_return
			}
			rows[ri] = Table_Row_Def{
				id      = lower_intern(&ctx, ar.id) or_return,
				cells   = cells,
				outputs = outs,
				span    = ar.span,
			}
		}
		ir.tables[ti] = Table_Def{
			name         = lower_intern(&ctx, t.name) or_return,
			version      = lower_intern(&ctx, t.version) or_return,
			hit_policy   = t.hit_policy,
			verify_flags = t.verify_flags,
			inputs       = inputs,
			outputs      = outputs,
			rows         = rows,
			span         = t.span,
		}
	}

	ir.rules = make([]Rule_Def, len(pool.rules), arena_alloc) or_return
	for r, ri in pool.rules {
		acts := make([]Action_IR, r.then_actions.count, arena_alloc) or_return
		for ai in 0 ..< r.then_actions.count {
			aa := pool.actions[r.then_actions.start + ai]
			ak: Action_Kind_IR
			switch aa.kind {
			case .Assert, .Error:
				ak = .Assert
			case .Assert_Eav:
				ak = .Assert_Eav
			case .Retract:
				ak = .Retract
			case .Effect:
				ak = .Effect
			}
			acts[ai] = Action_IR{
				kind          = ak,
				target        = lower_intern(&ctx, aa.target) or_return,
				unconditional = aa.unconditional,
				fields        = lower_field_assigns(&ctx, aa.fields) or_return,
				expr          = lower_expr(&ctx, aa.expr) or_return,
				attr_expr     = lower_expr(&ctx, aa.attr_expr) or_return,
				val_expr      = lower_expr(&ctx, aa.val_expr) or_return,
				span          = aa.span,
			}
		}
		ir.rules[ri] = Rule_Def{
			name         = lower_intern(&ctx, r.name) or_return,
			phase        = lower_intern(&ctx, r.phase) or_return,
			salience     = r.salience,
			has_salience = r.has_salience,
			when_clauses = lower_clauses(&ctx, r.when_clauses) or_return,
			then_actions = acts,
			span         = r.span,
		}
	}

	ir.queries = make([]Query_Def, len(pool.queries), arena_alloc) or_return
	for q, qi in pool.queries {
		params := make([]Query_Param_Def, q.params.count, arena_alloc) or_return
		for pi in 0 ..< q.params.count {
			ap := pool.query_params[q.params.start + pi]
			pname := lower_intern(&ctx, ap.name) or_return
			params[pi] = Query_Param_Def{
				name = pname,
				type = lower_type_spec(&ctx, pname, ap.type) or_return,
				span = ap.span,
			}
		}
		ir.queries[qi] = Query_Def{
			name         = lower_intern(&ctx, q.name) or_return,
			params       = params,
			when_clauses = lower_clauses(&ctx, q.when_clauses) or_return,
			span         = q.span,
		}
	}

	if len(ctx.enums) > 0 {
		ir.enums = make([]Enum_Def, len(ctx.enums), arena_alloc) or_return
		copy(ir.enums, ctx.enums[:])
	}
	ir.exprs = make([]Expr_IR, len(ctx.exprs), arena_alloc) or_return
	copy(ir.exprs, ctx.exprs[:])
	if len(ctx.extra_exprs) > 0 {
		ir.extra_exprs = make([]Expr_Id, len(ctx.extra_exprs), arena_alloc) or_return
		copy(ir.extra_exprs, ctx.extra_exprs[:])
	}

	telemetry_count_add(telemetry, .Ir_Schemas, u64(len(ir.schemas)))
	telemetry_count_add(telemetry, .Ir_Bindings, u64(len(ir.bindings)))
	telemetry_count_add(telemetry, .Ir_Tables, u64(len(ir.tables)))
	telemetry_count_add(telemetry, .Ir_Rules, u64(len(ir.rules)))
	telemetry_count_add(telemetry, .Ir_Queries, u64(len(ir.queries)))
	return ir, nil
}

@(require_results)
compile_source :: proc(
	src: string,
	source_name: string = "",
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ir: Rulebase_IR, err: mem.Allocator_Error) {
	parsed := parse_source_to_ast(src, source_name, diags, telemetry, allocator) or_return
	defer parsed_ast_destroy(&parsed)

	ir = lower_ast_to_ir(&parsed.pool, &parsed.interner, parsed.line_starts[:], telemetry, allocator) or_return
	defer if err != nil {
		ir_destroy(&ir)
	}
	analyze_ir(&ir, diags, telemetry) or_return
	return ir, nil
}
