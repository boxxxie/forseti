package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"

@(private)
Scope_Var :: struct {
	name:       String_Id,
	type:       Type_Ref,
	span:       Span,
	used:       bool,
	depth:      int,
	clause_gen: u32,
}

@(private)
_Shadowed_Var :: struct {
	prev:              Scope_Var,
	shadowed_at_depth: int,
}

@(private)
Sema_Ctx :: struct {
	ir:            ^Rulebase_IR,
	diags:         ^Diagnostic_List,
	telemetry:     ^Telemetry_Sink,
	scratch_alloc: mem.Allocator,
	schema_map:    map[String_Id]u32,
	binding_map:   map[String_Id]u32,
	table_map:     map[String_Id]u32,
	schema_ref:    []bool,
	binding_ref:   []bool,
	table_ref:     []bool,
	seen_fields:   map[String_Id]bool,
	pop_buf:       [dynamic]String_Id,
	unused_buf:    [dynamic]Scope_Var,
	shadowed_vars: [dynamic]_Shadowed_Var,
	clause_gen:    u32,
}

@(private)
sema_error :: proc(
	ctx: ^Sema_Ctx,
	code: Diag_Code,
	span: Span,
	msg: string,
	hint: string = "",
) -> mem.Allocator_Error {
	return ir_diag_add(ctx.diags, ctx.ir, code, .Error, span, msg, hint, ctx.telemetry)
}

@(private)
sema_warn :: proc(
	ctx: ^Sema_Ctx,
	code: Diag_Code,
	span: Span,
	msg: string,
	hint: string = "",
) -> mem.Allocator_Error {
	return ir_diag_add(ctx.diags, ctx.ir, code, .Warning, span, msg, hint, ctx.telemetry)
}

@(private)
is_numeric_kind :: proc "contextless" (k: Type_Kind) -> bool {
	return k == .I32 || k == .I64 || k == .F64
}

@(private)
is_ordered_kind :: proc "contextless" (k: Type_Kind) -> bool {
	return is_numeric_kind(k) || k == .Time || k == .String
}

@(private)
is_int_literal_expr :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> bool {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return false
	}
	e := ir.exprs[eid]
	if e.kind == .Lit_Int {
		return true
	}
	if e.kind == .Unary && e.unary_op == .Neg && e.lhs != INVALID_EXPR && int(e.lhs) < len(ir.exprs) {
		return ir.exprs[e.lhs].kind == .Lit_Int
	}
	return false
}

@(private)
types_compatible :: proc(ir: ^Rulebase_IR, expected, actual: Type_Ref, actual_eid: Expr_Id = INVALID_EXPR) -> bool {
	if expected.kind == .Unknown || actual.kind == .Unknown {
		return true
	}
	if expected.kind == actual.kind {
		if expected.kind == .Enum && expected.ref_id != actual.ref_id {
			return false
		}
		if expected.kind == .Fact && expected.ref_id != actual.ref_id {
			return false
		}
		if expected.kind == .Table_Result && expected.ref_id != actual.ref_id {
			return false
		}
		return true
	}
	if expected.kind == .I32 && actual.kind == .I64 && is_int_literal_expr(ir, actual_eid) {
		return true
	}
	if expected.kind == .Enum && actual.kind == .String {
		return true
	}
	if expected.kind == .String && actual.kind == .Enum {
		return true
	}
	return false
}

@(private)
find_schema_field :: proc(s: Schema_Def, name: String_Id) -> (f: Field_Def, ok: bool) {
	for field in s.fields {
		if field.name == name {
			return field, true
		}
	}
	return {}, false
}

@(private)
find_table_col :: proc(cols: []Table_Col_Def, name: String_Id) -> (col: Table_Col_Def, ok: bool) {
	for c in cols {
		if c.name == name {
			return c, true
		}
	}
	return {}, false
}

@(private)
resolve_target_schema :: proc(ctx: ^Sema_Ctx, target: String_Id) -> (sid: u32, ok: bool) {
	if bid, b_ok := ctx.binding_map[target]; b_ok {
		ctx.binding_ref[bid] = true
		s := ctx.ir.bindings[bid].schema_id
		if u32(s) != INVALID_ID {
			ctx.schema_ref[s] = true
			return u32(s), true
		}
		return INVALID_ID, false
	}
	if s, s_ok := ctx.schema_map[target]; s_ok {
		ctx.schema_ref[s] = true
		return s, true
	}
	return INVALID_ID, false
}

@(private)
sema_eval_expr :: proc(
	ctx: ^Sema_Ctx,
	scope: ^map[String_Id]Scope_Var,
	eid: Expr_Id,
	mark_used := true,
	used_outer: ^bool = nil,
	outer_depth := -1,
	max_join_gen := max(u32),
) -> (ty: Type_Ref, err: mem.Allocator_Error) {
	if eid == INVALID_EXPR || int(eid) >= len(ctx.ir.exprs) {
		return Type_Ref{kind = .Unknown}, nil
	}
	e := ctx.ir.exprs[eid]
	switch e.kind {
	case .Invalid, .Wildcard:
		return Type_Ref{kind = .Unknown}, nil
	case .Lit_Bool:
		return Type_Ref{kind = .Bool}, nil
	case .Lit_Int:
		return Type_Ref{kind = .I64}, nil
	case .Lit_Float:
		return Type_Ref{kind = .F64}, nil
	case .Lit_String:
		return Type_Ref{kind = .String}, nil
	case .Var:
		if scope == nil {
			sema_error(ctx, .E2003, e.span, fmt.tprintf("unbound variable %q in constant expression", ir_string(ctx.ir, e.str_id))) or_return
			return Type_Ref{kind = .Unknown}, nil
		}
		sv, found := &scope^[e.str_id]
		if !found {
			sema_error(
				ctx,
				.E2003,
				e.span,
				fmt.tprintf("unbound variable %q", ir_string(ctx.ir, e.str_id)),
				"bind this variable in a prior pattern or query parameter",
			) or_return
			return Type_Ref{kind = .Unknown}, nil
		}
		if mark_used {
			sv.used = true
		}
		if used_outer != nil && (outer_depth < 0 || sv.depth <= outer_depth) && sv.clause_gen < max_join_gen {
			used_outer^ = true
		}
		return sv.type, nil
	case .Ident:
		return Type_Ref{kind = .Unknown}, nil
	case .Field_Access:
		base_t := sema_eval_expr(ctx, scope, e.lhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		if base_t.kind == .Unknown {
			return Type_Ref{kind = .Unknown}, nil
		}
		fname := ir_string(ctx.ir, e.str_id)
		if base_t.kind == .Fact {
			schema := ctx.ir.schemas[base_t.ref_id]
			f, ok := find_schema_field(schema, e.str_id)
			if !ok {
				sema_error(
					ctx,
					.E2001,
					e.span,
					fmt.tprintf("unknown field %q on schema %q", fname, ir_string(ctx.ir, schema.name)),
				) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return f.type, nil
		}
		if base_t.kind == .Table_Result {
			tbl := ctx.ir.tables[base_t.ref_id]
			col, ok := find_table_col(tbl.outputs, e.str_id)
			if !ok {
				sema_error(
					ctx,
					.E2001,
					e.span,
					fmt.tprintf("unknown output column %q on table %q", fname, ir_string(ctx.ir, tbl.name)),
				) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return col.type, nil
		}
		sema_error(ctx, .E2001, e.span, fmt.tprintf("cannot access field %q on non-fact value", fname)) or_return
		return Type_Ref{kind = .Unknown}, nil
	case .Unary:
		ot := sema_eval_expr(ctx, scope, e.lhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		if ot.kind == .Unknown {
			return Type_Ref{kind = .Unknown}, nil
		}
		switch e.unary_op {
		case .Neg:
			if !is_numeric_kind(ot.kind) {
				sema_error(ctx, .E2002, e.span, "unary '-' requires numeric operand") or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return ot, nil
		case .Not:
			if ot.kind != .Bool {
				sema_error(ctx, .E2002, e.span, "'not' requires boolean operand") or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return Type_Ref{kind = .Bool}, nil
		}
	case .Binary:
		lt := sema_eval_expr(ctx, scope, e.lhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		rt := sema_eval_expr(ctx, scope, e.rhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		if lt.kind == .Unknown || rt.kind == .Unknown {
			return Type_Ref{kind = .Unknown}, nil
		}
		switch e.binary_op {
		case .And, .Or:
			if lt.kind != .Bool || rt.kind != .Bool {
				sema_error(ctx, .E2002, e.span, "logical operator requires boolean operands") or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return Type_Ref{kind = .Bool}, nil
		case .Eq, .Neq:
			if !types_compatible(ctx.ir, lt, rt, e.rhs) && !types_compatible(ctx.ir, rt, lt, e.lhs) {
				sema_error(
					ctx,
					.E2002,
					e.span,
					fmt.tprintf("type mismatch in equality comparison: %s vs %s", type_kind_str(lt.kind), type_kind_str(rt.kind)),
				) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return Type_Ref{kind = .Bool}, nil
		case .Lt, .Lte, .Gt, .Gte:
			if !is_ordered_kind(lt.kind) || !is_ordered_kind(rt.kind) || (!types_compatible(ctx.ir, lt, rt, e.rhs) && !types_compatible(ctx.ir, rt, lt, e.lhs)) {
				sema_error(
					ctx,
					.E2002,
					e.span,
					fmt.tprintf("incompatible types in ordering comparison: %s vs %s", type_kind_str(lt.kind), type_kind_str(rt.kind)),
				) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return Type_Ref{kind = .Bool}, nil
		case .Add, .Sub, .Mul, .Div, .Mod:
			if !is_numeric_kind(lt.kind) || !is_numeric_kind(rt.kind) || (!types_compatible(ctx.ir, lt, rt, e.rhs) && !types_compatible(ctx.ir, rt, lt, e.lhs)) {
				sema_error(
					ctx,
					.E2002,
					e.span,
					fmt.tprintf("arithmetic requires matching numeric types, got %s and %s", type_kind_str(lt.kind), type_kind_str(rt.kind)),
				) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			if lt.kind == .I64 && rt.kind == .I32 && is_int_literal_expr(ctx.ir, e.lhs) {
				return rt, nil
			}
			return lt, nil
		}
	case .Range:
		lt := sema_eval_expr(ctx, scope, e.lhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		rt := sema_eval_expr(ctx, scope, e.rhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		if lt.kind == .Unknown || rt.kind == .Unknown {
			return Type_Ref{kind = .Unknown}, nil
		}
		if (!is_numeric_kind(lt.kind) && lt.kind != .Time) || (!is_numeric_kind(rt.kind) && rt.kind != .Time) || (!types_compatible(ctx.ir, lt, rt, e.rhs) && !types_compatible(ctx.ir, rt, lt, e.lhs)) {
			sema_error(ctx, .E2002, e.span, "range bounds must have matching numeric or time types") or_return
			return Type_Ref{kind = .Unknown}, nil
		}
		if lt.kind == .I64 && rt.kind == .I32 && is_int_literal_expr(ctx.ir, e.lhs) {
			return rt, nil
		}
		return lt, nil
	case .In_List:
		has_lhs := e.lhs != INVALID_EXPR && int(e.lhs) < len(ctx.ir.exprs)
		lt := Type_Ref{kind = .Unknown}
		if has_lhs {
			lt = sema_eval_expr(ctx, scope, e.lhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		}
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			item_id := ctx.ir.extra_exprs[i]
			it := sema_eval_expr(ctx, scope, item_id, mark_used, used_outer, outer_depth, max_join_gen) or_return
			if has_lhs && lt.kind != .Unknown && it.kind != .Unknown && !types_compatible(ctx.ir, lt, it, item_id) && !types_compatible(ctx.ir, it, lt, e.lhs) {
				item_span := ctx.ir.exprs[item_id].span if item_id != INVALID_EXPR && int(item_id) < len(ctx.ir.exprs) else e.span
				sema_error(
					ctx,
					.E2002,
					item_span,
					fmt.tprintf("'in' item type mismatch: expected %s, got %s", type_kind_str(lt.kind), type_kind_str(it.kind)),
				) or_return
			}
		}
		return Type_Ref{kind = .Bool}, nil
	case .Cell_Cmp:
		rt := sema_eval_expr(ctx, scope, e.rhs, mark_used, used_outer, outer_depth, max_join_gen) or_return
		return rt, nil
	case .Call:
		fname := ir_string(ctx.ir, e.str_id)
		arg_start := e.extra_span.start
		arg_count := e.extra_span.count
		arg_types: [8]Type_Ref
		for i in 0 ..< arg_count {
			at := sema_eval_expr(ctx, scope, ctx.ir.extra_exprs[arg_start + i], mark_used, used_outer, outer_depth, max_join_gen) or_return
			if i < len(arg_types) {
				arg_types[i] = at
			}
		}
		_expect_arity :: proc(ctx: ^Sema_Ctx, fn_name: string, want, got: u32, sp: Span) -> (ok: bool, err: mem.Allocator_Error) {
			if got == want {
				return true, nil
			}
			sema_error(ctx, .E2002, sp, fmt.tprintf("%s() expects %d argument(s), got %d", fn_name, want, got)) or_return
			return false, nil
		}
		switch fname {
		case "lower", "upper":
			if !(_expect_arity(ctx, fname, 1, arg_count, e.span) or_return) {
				return Type_Ref{kind = .String}, nil
			}
			if arg_types[0].kind != .Unknown && arg_types[0].kind != .String {
				sema_error(ctx, .E2002, e.span, fmt.tprintf("%s() expects string argument, got %s", fname, type_kind_str(arg_types[0].kind))) or_return
			}
			return Type_Ref{kind = .String}, nil
		case "len":
			if !(_expect_arity(ctx, fname, 1, arg_count, e.span) or_return) {
				return Type_Ref{kind = .I64}, nil
			}
			if arg_types[0].kind != .Unknown && arg_types[0].kind != .String {
				sema_error(ctx, .E2002, e.span, fmt.tprintf("len() expects string argument, got %s", type_kind_str(arg_types[0].kind))) or_return
			}
			return Type_Ref{kind = .I64}, nil
		case "starts_with", "contains":
			if !(_expect_arity(ctx, fname, 2, arg_count, e.span) or_return) {
				return Type_Ref{kind = .Bool}, nil
			}
			if (arg_types[0].kind != .Unknown && arg_types[0].kind != .String) || (arg_types[1].kind != .Unknown && arg_types[1].kind != .String) {
				sema_error(ctx, .E2002, e.span, fmt.tprintf("%s() expects (string, string) arguments, got (%s, %s)", fname, type_kind_str(arg_types[0].kind), type_kind_str(arg_types[1].kind))) or_return
			}
			return Type_Ref{kind = .Bool}, nil
		case "abs":
			if !(_expect_arity(ctx, fname, 1, arg_count, e.span) or_return) {
				return Type_Ref{kind = .Unknown}, nil
			}
			if arg_types[0].kind != .Unknown && !is_numeric_kind(arg_types[0].kind) {
				sema_error(ctx, .E2002, e.span, fmt.tprintf("abs() expects numeric argument, got %s", type_kind_str(arg_types[0].kind))) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			return arg_types[0], nil
		case "min", "max":
			if !(_expect_arity(ctx, fname, 2, arg_count, e.span) or_return) {
				return Type_Ref{kind = .Unknown}, nil
			}
			if (arg_types[0].kind != .Unknown && !is_numeric_kind(arg_types[0].kind)) || (arg_types[1].kind != .Unknown && !is_numeric_kind(arg_types[1].kind)) {
				sema_error(ctx, .E2002, e.span, fmt.tprintf("%s() expects numeric arguments, got (%s, %s)", fname, type_kind_str(arg_types[0].kind), type_kind_str(arg_types[1].kind))) or_return
				return Type_Ref{kind = .Unknown}, nil
			}
			if arg_types[0].kind == .F64 || arg_types[1].kind == .F64 {
				return Type_Ref{kind = .F64}, nil
			}
			if arg_types[0].kind == .I64 || arg_types[1].kind == .I64 {
				return Type_Ref{kind = .I64}, nil
			}
			return arg_types[0] if arg_types[0].kind != .Unknown else arg_types[1], nil
		case:
			sema_error(ctx, .E2002, e.span, fmt.tprintf("unknown built-in function %q", fname)) or_return
			return Type_Ref{kind = .Unknown}, nil
		}
	}
	return Type_Ref{kind = .Unknown}, nil
}

@(private)
sema_validate_table_cell :: proc(ctx: ^Sema_Ctx, col_type: Type_Ref, eid: Expr_Id) -> mem.Allocator_Error {
	if eid == INVALID_EXPR || int(eid) >= len(ctx.ir.exprs) {
		return nil
	}
	e := ctx.ir.exprs[eid]
	#partial switch e.kind {
	case .Wildcard:
		return nil
	case .Binary:
		if e.binary_op == .And || e.binary_op == .Or {
			sema_validate_table_cell(ctx, col_type, e.lhs) or_return
			sema_validate_table_cell(ctx, col_type, e.rhs) or_return
			return nil
		}
	case .Cell_Cmp:
		rt := sema_eval_expr(ctx, nil, e.rhs) or_return
		if !types_compatible(ctx.ir, col_type, rt, e.rhs) {
			sema_error(
				ctx,
				.E2002,
				e.span,
				fmt.tprintf("table cell type mismatch: expected %s, got %s", type_kind_str(col_type.kind), type_kind_str(rt.kind)),
			) or_return
			return nil
		}
		if (e.binary_op == .Lt || e.binary_op == .Lte || e.binary_op == .Gt || e.binary_op == .Gte) && !is_ordered_kind(col_type.kind) {
			sema_error(ctx, .E2002, e.span, "ordering predicate in table cell requires numeric, time, or string column") or_return
		}
		return nil
	case .Range:
		rt := sema_eval_expr(ctx, nil, eid) or_return
		compat := types_compatible(ctx.ir, col_type, rt) ||
			(col_type.kind == .I32 && rt.kind == .I64 && is_int_literal_expr(ctx.ir, e.lhs) && is_int_literal_expr(ctx.ir, e.rhs))
		if !compat {
			sema_error(
				ctx,
				.E2002,
				e.span,
				fmt.tprintf("table range type mismatch: expected %s, got %s", type_kind_str(col_type.kind), type_kind_str(rt.kind)),
			) or_return
		}
		return nil
	case .In_List:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			item_id := ctx.ir.extra_exprs[i]
			it := sema_eval_expr(ctx, nil, item_id) or_return
			if !types_compatible(ctx.ir, col_type, it, item_id) {
				sema_error(
					ctx,
					.E2002,
					ctx.ir.exprs[item_id].span,
					fmt.tprintf("table 'in' item type mismatch: expected %s, got %s", type_kind_str(col_type.kind), type_kind_str(it.kind)),
				) or_return
			}
		}
		return nil
	}

	et := sema_eval_expr(ctx, nil, eid) or_return
	if !types_compatible(ctx.ir, col_type, et, eid) {
		sema_error(
			ctx,
			.E2002,
			e.span,
			fmt.tprintf("table cell type mismatch: expected %s, got %s", type_kind_str(col_type.kind), type_kind_str(et.kind)),
		) or_return
	}
	return nil
}

@(private)
bind_scope_var :: proc(
	ctx: ^Sema_Ctx,
	scope: ^map[String_Id]Scope_Var,
	name: String_Id,
	type: Type_Ref,
	span: Span,
	depth: int,
	clause_gen: u32 = 0,
) -> mem.Allocator_Error {
	if name == EMPTY_STRING {
		return nil
	}
	if prev, exists := scope^[name]; exists {
		sema_warn(
			ctx,
			.W2005,
			span,
			fmt.tprintf("variable %q shadows an existing binding", ir_string(ctx.ir, name)),
		) or_return
		if prev.depth < depth {
			append(&ctx.shadowed_vars, _Shadowed_Var{
				prev              = prev,
				shadowed_at_depth = depth,
			})
		}
	}
	scope^[name] = Scope_Var{
		name       = name,
		type       = type,
		span       = span,
		used       = false,
		depth      = depth,
		clause_gen = clause_gen,
	}
	return nil
}

@(private)
pop_scope_depth :: proc(ctx: ^Sema_Ctx, scope: ^map[String_Id]Scope_Var, min_keep_depth: int) {
	clear(&ctx.pop_buf)
	for k, v in scope^ {
		if v.depth > min_keep_depth {
			append(&ctx.pop_buf, k)
		}
	}
	for k in ctx.pop_buf {
		delete_key(scope, k)
	}
	for len(ctx.shadowed_vars) > 0 {
		top := ctx.shadowed_vars[len(ctx.shadowed_vars) - 1]
		if top.shadowed_at_depth <= min_keep_depth {
			break
		}
		pop(&ctx.shadowed_vars)
		scope^[top.prev.name] = top.prev
	}
}

@(private)
sema_validate_pattern_field_expr :: proc(
	ctx: ^Sema_Ctx,
	scope: ^map[String_Id]Scope_Var,
	expected_t: Type_Ref,
	eid: Expr_Id,
	fname: String_Id,
	fspan: Span,
	shares_join: ^bool,
	depth: int,
	cur_gen: u32,
) -> mem.Allocator_Error {
	if eid == INVALID_EXPR || int(eid) >= len(ctx.ir.exprs) {
		return nil
	}
	e := ctx.ir.exprs[eid]
	#partial switch e.kind {
	case .Wildcard:
		return nil
	case .Cell_Cmp:
		rt := sema_eval_expr(ctx, scope, e.rhs, true, shares_join, depth, cur_gen) or_return
		if !types_compatible(ctx.ir, expected_t, rt, e.rhs) {
			sema_error(
				ctx,
				.E2002,
				fspan,
				fmt.tprintf("field %q expects %s, got %s", ir_string(ctx.ir, fname), type_kind_str(expected_t.kind), type_kind_str(rt.kind)),
			) or_return
			return nil
		}
		if (e.binary_op == .Lt || e.binary_op == .Lte || e.binary_op == .Gt || e.binary_op == .Gte) &&
		   expected_t.kind != .Unknown && !is_ordered_kind(expected_t.kind) {
			sema_error(
				ctx,
				.E2002,
				e.span,
				fmt.tprintf("ordering predicate on field %q requires numeric, time, or string type, got %s", ir_string(ctx.ir, fname), type_kind_str(expected_t.kind)),
			) or_return
		}
		return nil
	case .Range:
		rt := sema_eval_expr(ctx, scope, eid, true, shares_join, depth, cur_gen) or_return
		compat := types_compatible(ctx.ir, expected_t, rt) ||
			(expected_t.kind == .I32 && rt.kind == .I64 && is_int_literal_expr(ctx.ir, e.lhs) && is_int_literal_expr(ctx.ir, e.rhs))
		if !compat {
			sema_error(
				ctx,
				.E2002,
				fspan,
				fmt.tprintf("field %q expects %s, got %s", ir_string(ctx.ir, fname), type_kind_str(expected_t.kind), type_kind_str(rt.kind)),
			) or_return
		}
		return nil
	case .In_List:
		if e.lhs == INVALID_EXPR {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				item_id := ctx.ir.extra_exprs[i]
				it := sema_eval_expr(ctx, scope, item_id, true, shares_join, depth, cur_gen) or_return
				if !types_compatible(ctx.ir, expected_t, it, item_id) {
					item_span := ctx.ir.exprs[item_id].span if item_id != INVALID_EXPR && int(item_id) < len(ctx.ir.exprs) else fspan
					sema_error(
						ctx,
						.E2002,
						item_span,
						fmt.tprintf("field %q 'in' item expects %s, got %s", ir_string(ctx.ir, fname), type_kind_str(expected_t.kind), type_kind_str(it.kind)),
					) or_return
				}
			}
			return nil
		}
	case .Binary:
		if (e.binary_op == .And || e.binary_op == .Or) && _expr_is_field_matcher(ctx.ir, eid) {
			sema_validate_pattern_field_expr(ctx, scope, expected_t, e.lhs, fname, fspan, shares_join, depth, cur_gen) or_return
			sema_validate_pattern_field_expr(ctx, scope, expected_t, e.rhs, fname, fspan, shares_join, depth, cur_gen) or_return
			return nil
		}
	}

	et := sema_eval_expr(ctx, scope, eid, true, shares_join, depth, cur_gen) or_return
	if !types_compatible(ctx.ir, expected_t, et, eid) {
		sema_error(
			ctx,
			.E2002,
			fspan,
			fmt.tprintf("field %q expects %s, got %s", ir_string(ctx.ir, fname), type_kind_str(expected_t.kind), type_kind_str(et.kind)),
		) or_return
	}
	return nil
}

@(private)
sema_analyze_clauses :: proc(
	ctx: ^Sema_Ctx,
	scope: ^map[String_Id]Scope_Var,
	clauses: []Clause_IR,
	depth: int,
	positive_count: ^int,
	matched_targets: ^[dynamic]String_Id,
	has_not: ^bool,
) -> mem.Allocator_Error {
	for cl in clauses {
		switch cl.kind {
		case .Pattern:
			prior_had_vars := len(scope^) > 0
			shares_join := false
			ctx.clause_gen += 1
			cur_gen := ctx.clause_gen
			sid, s_ok := resolve_target_schema(ctx, cl.target)
			if !s_ok {
				sema_error(
					ctx,
					.E2001,
					cl.span,
					fmt.tprintf("unknown schema or binding %q in pattern", ir_string(ctx.ir, cl.target)),
				) or_return
			} else if matched_targets != nil && depth == 0 {
				append(matched_targets, cl.target)
			}

			if cl.bind_var != EMPTY_STRING {
				ft := Type_Ref{kind = .Fact, ref_id = sid} if s_ok else Type_Ref{kind = .Unknown}
				bind_scope_var(ctx, scope, cl.bind_var, ft, cl.span, depth, cur_gen) or_return
			}

			for fb in cl.fields {
				expected_t := Type_Ref{kind = .Unknown}
				if s_ok {
					fdef, f_ok := find_schema_field(ctx.ir.schemas[sid], fb.name)
					if !f_ok {
						sema_error(
							ctx,
							.E2001,
							fb.span,
							fmt.tprintf("unknown field %q on %q", ir_string(ctx.ir, fb.name), ir_string(ctx.ir, cl.target)),
						) or_return
					} else {
						expected_t = fdef.type
					}
				}

				if fb.expr == INVALID_EXPR || int(fb.expr) >= len(ctx.ir.exprs) {
					continue
				}
				expr := ctx.ir.exprs[fb.expr]
				if expr.kind == .Var {
					if sv, existing := &scope^[expr.str_id]; existing {
						sv.used = true
						if sv.clause_gen < cur_gen {
							shares_join = true
						}
						if !types_compatible(ctx.ir, expected_t, sv.type) {
							sema_error(
								ctx,
								.E2002,
								fb.span,
								fmt.tprintf(
									"variable %q has type %s, expected %s for field %q",
									ir_string(ctx.ir, expr.str_id),
									type_kind_str(sv.type.kind),
									type_kind_str(expected_t.kind),
									ir_string(ctx.ir, fb.name),
								),
							) or_return
						}
					} else {
						scope^[expr.str_id] = Scope_Var{
							name       = expr.str_id,
							type       = expected_t,
							span       = expr.span,
							used       = false,
							depth      = depth,
							clause_gen = cur_gen,
						}
					}
				} else {
					sema_validate_pattern_field_expr(ctx, scope, expected_t, fb.expr, fb.name, fb.span, &shares_join, depth, cur_gen) or_return
				}
			}

			if positive_count != nil && depth == 0 {
				if positive_count^ > 0 && prior_had_vars && !shares_join {
					sema_warn(
						ctx,
						.W2003,
						cl.span,
						fmt.tprintf("potential Cartesian join on %q (no shared join variables with prior patterns)", ir_string(ctx.ir, cl.target)),
						"bind a shared ?variable across adjacent patterns",
					) or_return
				}
				positive_count^ += 1
			}

		case .Eav:
			prior_had_vars := len(scope^) > 0
			shares_join := false
			ctx.clause_gen += 1
			cur_gen := ctx.clause_gen
			if cl.bind_var != EMPTY_STRING {
				bind_scope_var(ctx, scope, cl.bind_var, Type_Ref{kind = .Unknown}, cl.span, depth, cur_gen) or_return
			}
			eav_exprs := [3]Expr_Id{cl.expr, cl.guard_expr, cl.extra_expr}
			eav_types := [3]Type_Kind{.Entity, .String, .Unknown}
			for eid, slot_idx in eav_exprs {
				if eid == INVALID_EXPR || int(eid) >= len(ctx.ir.exprs) {
					continue
				}
				ex := ctx.ir.exprs[eid]
				if ex.kind == .Var {
					if sv, existing := &scope^[ex.str_id]; existing {
						sv.used = true
						if sv.clause_gen < cur_gen {
							shares_join = true
						}
					} else {
						scope^[ex.str_id] = Scope_Var{
							name       = ex.str_id,
							type       = Type_Ref{kind = eav_types[slot_idx]},
							span       = ex.span,
							used       = false,
							depth      = depth,
							clause_gen = cur_gen,
						}
					}
				} else {
					_ = sema_eval_expr(ctx, scope, eid, true, &shares_join, depth, cur_gen) or_return
				}
			}
			if positive_count != nil && depth == 0 {
				if positive_count^ > 0 && prior_had_vars && !shares_join {
					sema_warn(ctx, .W2003, cl.span, "potential Cartesian join on EAV pattern") or_return
				}
				positive_count^ += 1
			}

		case .Not, .Exists:
			if cl.kind == .Not && has_not != nil {
				has_not^ = true
			}
			sema_analyze_clauses(ctx, scope, cl.children, depth + 1, nil, nil, nil) or_return
			pop_scope_depth(ctx, scope, depth)

		case .Accum:
			sema_analyze_clauses(ctx, scope, cl.inner_pat, depth + 1, nil, nil, nil) or_return
			agg_t := sema_eval_expr(ctx, scope, cl.expr, true) or_return
			if cl.guard_expr != INVALID_EXPR && int(cl.guard_expr) < len(ctx.ir.exprs) {
				gt := sema_eval_expr(ctx, scope, cl.guard_expr, true) or_return
				if gt.kind != .Unknown && gt.kind != .Bool {
					sema_error(ctx, .E2002, ctx.ir.exprs[cl.guard_expr].span, "accumulator 'where' guard must be boolean") or_return
				}
			}
			if (cl.accum_op == .Sum || cl.accum_op == .Avg || cl.accum_op == .Min || cl.accum_op == .Max) &&
				agg_t.kind != .Unknown && !is_numeric_kind(agg_t.kind) {
				sema_error(
					ctx,
					.E2002,
					cl.span,
					fmt.tprintf("accumulator '%s' requires numeric input, got %s", accum_op_str(cl.accum_op), type_kind_str(agg_t.kind)),
				) or_return
			}
			pop_scope_depth(ctx, scope, depth)

			res_t := agg_t
			switch cl.accum_op {
			case .Count:
				res_t = Type_Ref{kind = .I64}
			case .Avg:
				res_t = Type_Ref{kind = .F64}
			case .Sum, .Min, .Max:
				res_t = agg_t
			case .Distinct, .Collect:
				res_t = Type_Ref{kind = .Unknown}
			}
			bind_scope_var(ctx, scope, cl.bind_var, res_t, cl.span, depth, ctx.clause_gen) or_return

		case .Decide:
			tid, t_ok := ctx.table_map[cl.target]
			if !t_ok {
				sema_error(
					ctx,
					.E2001,
					cl.span,
					fmt.tprintf("unknown decision table %q", ir_string(ctx.ir, cl.target)),
				) or_return
				for fb in cl.fields {
					_ = sema_eval_expr(ctx, scope, fb.expr, true) or_return
				}
			} else {
				ctx.table_ref[tid] = true
				tbl := ctx.ir.tables[tid]
				clear(&ctx.seen_fields)
				for fb in cl.fields {
					at := sema_eval_expr(ctx, scope, fb.expr, true) or_return
					col, c_ok := find_table_col(tbl.inputs, fb.name)
					if !c_ok {
						sema_error(
							ctx,
							.E2005,
							fb.span,
							fmt.tprintf("unknown input column %q for decision table %q", ir_string(ctx.ir, fb.name), ir_string(ctx.ir, tbl.name)),
						) or_return
						continue
					}
					if fb.name in ctx.seen_fields {
						sema_error(ctx, .E2005, fb.span, fmt.tprintf("duplicate argument %q in decide", ir_string(ctx.ir, fb.name))) or_return
					}
					ctx.seen_fields[fb.name] = true
					if !types_compatible(ctx.ir, col.type, at, fb.expr) {
						sema_error(
							ctx,
							.E2002,
							fb.span,
							fmt.tprintf("decide argument %q expects %s, got %s", ir_string(ctx.ir, fb.name), type_kind_str(col.type.kind), type_kind_str(at.kind)),
						) or_return
					}
				}
				for col in tbl.inputs {
					if !(col.name in ctx.seen_fields) {
						sema_error(
							ctx,
							.E2005,
							cl.span,
							fmt.tprintf("missing required input %q in decide %q", ir_string(ctx.ir, col.name), ir_string(ctx.ir, tbl.name)),
						) or_return
					}
				}
			}

			if cl.bind_var != EMPTY_STRING {
				rt := Type_Ref{kind = .Table_Result, ref_id = tid} if t_ok else Type_Ref{kind = .Unknown}
				bind_scope_var(ctx, scope, cl.bind_var, rt, cl.span, depth, ctx.clause_gen) or_return
			}

		case .Where:
			wt := sema_eval_expr(ctx, scope, cl.expr, true) or_return
			if wt.kind != .Unknown && wt.kind != .Bool {
				wspan := ctx.ir.exprs[cl.expr].span if cl.expr != INVALID_EXPR && int(cl.expr) < len(ctx.ir.exprs) else cl.span
				sema_error(
					ctx,
					.E2002,
					wspan,
					fmt.tprintf("'where' predicate must evaluate to bool, got %s", type_kind_str(wt.kind)),
				) or_return
			}

		case .Let:
			lt := sema_eval_expr(ctx, scope, cl.expr, true) or_return
			bind_scope_var(ctx, scope, cl.bind_var, lt, cl.span, depth, ctx.clause_gen) or_return
		}
	}
	return nil
}

@(private)
sema_analyze_actions :: proc(
	ctx: ^Sema_Ctx,
	scope: ^map[String_Id]Scope_Var,
	actions: []Action_IR,
	rule_span: Span,
	matched_targets: []String_Id,
	has_not: bool,
) -> mem.Allocator_Error {
	warned_self := false
	for act in actions {
		switch act.kind {
		case .Assert:
			sid, s_ok := resolve_target_schema(ctx, act.target)
			if !s_ok {
				sema_error(
					ctx,
					.E2001,
					act.span,
					fmt.tprintf("unknown schema or derived binding %q in assert", ir_string(ctx.ir, act.target)),
				) or_return
				for fb in act.fields {
					_ = sema_eval_expr(ctx, scope, fb.expr, true) or_return
				}
				continue
			}

			schema := ctx.ir.schemas[sid]
			clear(&ctx.seen_fields)
			for fb in act.fields {
				vt := sema_eval_expr(ctx, scope, fb.expr, true) or_return
				fdef, f_ok := find_schema_field(schema, fb.name)
				if !f_ok {
					sema_error(
						ctx,
						.E2005,
						fb.span,
						fmt.tprintf("unknown field %q on %q", ir_string(ctx.ir, fb.name), ir_string(ctx.ir, act.target)),
					) or_return
					continue
				}
				if fb.name in ctx.seen_fields {
					sema_error(ctx, .E2005, fb.span, fmt.tprintf("duplicate field %q in assert", ir_string(ctx.ir, fb.name))) or_return
				}
				ctx.seen_fields[fb.name] = true
				if !types_compatible(ctx.ir, fdef.type, vt, fb.expr) {
					sema_error(
						ctx,
						.E2002,
						fb.span,
						fmt.tprintf("assert field %q expects %s, got %s", ir_string(ctx.ir, fb.name), type_kind_str(fdef.type.kind), type_kind_str(vt.kind)),
					) or_return
				}
			}
			for fdef in schema.fields {
				if !(fdef.name in ctx.seen_fields) {
					sema_error(
						ctx,
						.E2005,
						act.span,
						fmt.tprintf("missing required field %q in assert %q", ir_string(ctx.ir, fdef.name), ir_string(ctx.ir, act.target)),
					) or_return
				}
			}

			if !has_not && !warned_self {
				is_source_target := false
				if bid, bok := ctx.binding_map[act.target]; bok {
					is_source_target = ctx.ir.bindings[bid].kind == .Source
				}
				if is_source_target || len(matched_targets) <= 1 {
					// Emit W2004 on self-asserting source mutations or trivial single-pattern loops;
					// derived join recursion (e.g. parent-child transitive closure) stratifies cleanly.
					for mt in matched_targets {
						if mt == act.target {
							sema_warn(
								ctx,
								.W2004,
								rule_span,
								fmt.tprintf("rule directly asserts %q which also appears in 'when' without a 'not' guard (risk of self-triggering loop)", ir_string(ctx.ir, act.target)),
							) or_return
							warned_self = true
							break
						}
					}
				}
			}

		case .Assert_Eav:
			_ = sema_eval_expr(ctx, scope, act.expr, true) or_return
			_ = sema_eval_expr(ctx, scope, act.attr_expr, true) or_return
			_ = sema_eval_expr(ctx, scope, act.val_expr, true) or_return

		case .Retract:
			rt := sema_eval_expr(ctx, scope, act.expr, true) or_return
			if rt.kind != .Unknown && rt.kind != .Fact {
				sema_error(ctx, .E2002, act.span, "'retract' requires a bound fact variable") or_return
			}

		case .Effect:
			for fb in act.fields {
				_ = sema_eval_expr(ctx, scope, fb.expr, true) or_return
			}
		}
	}
	return nil
}

@(private)
emit_unused_var_warnings :: proc(ctx: ^Sema_Ctx, scope: ^map[String_Id]Scope_Var) -> mem.Allocator_Error {
	clear(&ctx.unused_buf)
	for _, sv in scope^ {
		if sv.used {
			continue
		}
		name := ir_string(ctx.ir, sv.name)
		if strings.has_prefix(name, "?_") {
			continue
		}
		append(&ctx.unused_buf, sv)
	}
	slice.sort_by(ctx.unused_buf[:], proc(a, b: Scope_Var) -> bool {
		return a.span.offset < b.span.offset
	})
	for sv in ctx.unused_buf {
		sema_warn(
			ctx,
			.W2001,
			sv.span,
			fmt.tprintf("unused variable %q", ir_string(ctx.ir, sv.name)),
			"prefix with ?_ if intentionally unused",
		) or_return
	}
	return nil
}

@(require_results)
analyze_ir :: proc(
	ir: ^Rulebase_IR,
	diags: ^Diagnostic_List,
	telemetry: ^Telemetry_Sink = nil,
) -> (err: mem.Allocator_Error) {
	if ir == nil {
		return nil
	}
	scope_tel := telemetry_span_begin(telemetry, .Analyze, "analyze")
	defer telemetry_span_end(telemetry, scope_tel)

	sema_scratch: vmem.Arena
	if vmem.arena_init_growing(&sema_scratch) != nil {
		return .Out_Of_Memory
	}
	defer vmem.arena_destroy(&sema_scratch)
	sa := vmem.arena_allocator(&sema_scratch)

	ctx := Sema_Ctx{
		ir            = ir,
		diags         = diags,
		telemetry     = telemetry,
		scratch_alloc = sa,
	}
	ctx.schema_map = make(map[String_Id]u32, max(len(ir.schemas), 8), sa)
	ctx.binding_map = make(map[String_Id]u32, max(len(ir.bindings), 8), sa)
	ctx.table_map = make(map[String_Id]u32, max(len(ir.tables), 8), sa)
	ctx.schema_ref = make([]bool, len(ir.schemas), sa)
	ctx.binding_ref = make([]bool, len(ir.bindings), sa)
	ctx.table_ref = make([]bool, len(ir.tables), sa)
	ctx.seen_fields = make(map[String_Id]bool, 16, sa)
	ctx.pop_buf = make([dynamic]String_Id, 0, 8, sa)
	ctx.unused_buf = make([dynamic]Scope_Var, 0, 8, sa)
	ctx.shadowed_vars = make([dynamic]_Shadowed_Var, 0, 8, sa)

	// Pass 1: Symbol tables & duplicate detection (E2004)
	fset := make(map[String_Id]bool, 16, sa)
	for s, si in ir.schemas {
		if s.name in ctx.schema_map {
			sema_error(&ctx, .E2004, s.span, fmt.tprintf("duplicate schema %q", ir_string(ir, s.name))) or_return
		} else {
			ctx.schema_map[s.name] = u32(si)
		}
		clear(&fset)
		for f in s.fields {
			if f.name in fset {
				sema_error(&ctx, .E2004, f.span, fmt.tprintf("duplicate field %q in schema %q", ir_string(ir, f.name), ir_string(ir, s.name))) or_return
			}
			fset[f.name] = true
		}
	}

	for &bind, bi in ir.bindings {
		if bind.name in ctx.binding_map {
			sema_error(&ctx, .E2004, bind.span, fmt.tprintf("duplicate binding %q", ir_string(ir, bind.name))) or_return
		} else {
			ctx.binding_map[bind.name] = u32(bi)
		}
		if sid, ok := ctx.schema_map[bind.schema_name]; ok {
			bind.schema_id = Schema_Id(sid)
			ctx.schema_ref[sid] = true
		} else {
			bind.schema_id = Schema_Id(INVALID_ID)
			sema_error(
				&ctx,
				.E2001,
				bind.span,
				fmt.tprintf("unknown schema %q referenced by binding %q", ir_string(ir, bind.schema_name), ir_string(ir, bind.name)),
			) or_return
		}
	}

	in_cols := make(map[String_Id]bool, 8, sa)
	out_cols := make(map[String_Id]bool, 8, sa)
	row_ids := make(map[String_Id]bool, 16, sa)
	for tbl, ti in ir.tables {
		if tbl.name in ctx.table_map {
			sema_error(&ctx, .E2004, tbl.span, fmt.tprintf("duplicate decision table %q", ir_string(ir, tbl.name))) or_return
		} else {
			ctx.table_map[tbl.name] = u32(ti)
		}
		clear(&in_cols)
		for c in tbl.inputs {
			if c.name in in_cols {
				sema_error(&ctx, .E2004, c.span, fmt.tprintf("duplicate input column %q in table %q", ir_string(ir, c.name), ir_string(ir, tbl.name))) or_return
			}
			in_cols[c.name] = true
		}
		clear(&out_cols)
		for c in tbl.outputs {
			if c.name in out_cols {
				sema_error(&ctx, .E2004, c.span, fmt.tprintf("duplicate output column %q in table %q", ir_string(ir, c.name), ir_string(ir, tbl.name))) or_return
			}
			out_cols[c.name] = true
		}
		clear(&row_ids)
		for row in tbl.rows {
			if row.id != EMPTY_STRING {
				if row.id in row_ids {
					sema_error(&ctx, .E2004, row.span, fmt.tprintf("duplicate row id %q in table %q", ir_string(ir, row.id), ir_string(ir, tbl.name))) or_return
				}
				row_ids[row.id] = true
			}
		}
	}

	rule_names := make(map[String_Id]bool, max(len(ir.rules), 8), sa)
	for r in ir.rules {
		if r.name in rule_names {
			sema_error(&ctx, .E2004, r.span, fmt.tprintf("duplicate rule %q", ir_string(ir, r.name))) or_return
		}
		rule_names[r.name] = true
	}

	query_names := make(map[String_Id]bool, max(len(ir.queries), 8), sa)
	for q in ir.queries {
		if q.name in query_names {
			sema_error(&ctx, .E2004, q.span, fmt.tprintf("duplicate query %q", ir_string(ir, q.name))) or_return
		}
		query_names[q.name] = true
	}

	// Pass 2: Decision table cell & output validation
	for tbl in ir.tables {
		for row in tbl.rows {
			if len(row.cells) != len(tbl.inputs) {
				sema_error(
					&ctx,
					.E2005,
					row.span,
					fmt.tprintf("row %q has %d input cells, expected %d", ir_string(ir, row.id), len(row.cells), len(tbl.inputs)),
				) or_return
			}
			if len(row.outputs) != len(tbl.outputs) {
				sema_error(
					&ctx,
					.E2005,
					row.span,
					fmt.tprintf("row %q has %d outputs, expected %d", ir_string(ir, row.id), len(row.outputs), len(tbl.outputs)),
				) or_return
			}
			for cell_id, ci in row.cells {
				if ci < len(tbl.inputs) {
					sema_validate_table_cell(&ctx, tbl.inputs[ci].type, cell_id) or_return
				}
			}
			for out_id, oi in row.outputs {
				if out_id == INVALID_EXPR || int(out_id) >= len(ir.exprs) {
					continue
				}
				if oi < len(tbl.outputs) {
					if ir.exprs[out_id].kind == .Wildcard {
						continue
					}
					ot := sema_eval_expr(&ctx, nil, out_id) or_return
					if !types_compatible(ir, tbl.outputs[oi].type, ot, out_id) {
						sema_error(
							&ctx,
							.E2002,
							ir.exprs[out_id].span,
							fmt.tprintf("table output type mismatch: expected %s, got %s", type_kind_str(tbl.outputs[oi].type.kind), type_kind_str(ot.kind)),
						) or_return
					}
				}
			}
		}
	}

	// Pass 3: Rule & Query body validation (reuse per-rule scratch containers on sema_scratch)
	scope := make(map[String_Id]Scope_Var, 16, sa)
	matched_targets := make([dynamic]String_Id, 0, 8, sa)
	for r in ir.rules {
		clear(&scope)
		clear(&matched_targets)
		clear(&ctx.shadowed_vars)
		ctx.clause_gen = 0
		positive_count := 0
		has_not := false

		sema_analyze_clauses(&ctx, &scope, r.when_clauses, 0, &positive_count, &matched_targets, &has_not) or_return
		sema_analyze_actions(&ctx, &scope, r.then_actions, r.span, matched_targets[:], has_not) or_return
		emit_unused_var_warnings(&ctx, &scope) or_return
	}

	for q in ir.queries {
		clear(&scope)
		clear(&matched_targets)
		clear(&ctx.shadowed_vars)
		ctx.clause_gen = 0
		for p in q.params {
			qvar_name := fmt.tprintf("?%s", ir_string(ir, p.name))
			qid := intern(&ir.interner, qvar_name) or_return
			scope[qid] = Scope_Var{
				name  = qid,
				type  = p.type,
				span  = p.span,
				used  = false,
				depth = 0,
			}
		}
		positive_count := 0
		has_not := false
		sema_analyze_clauses(&ctx, &scope, q.when_clauses, 0, &positive_count, &matched_targets, &has_not) or_return
	}

	// Pass 4: Reachability lints (W2002)
	for s, si in ir.schemas {
		if !ctx.schema_ref[si] {
			sema_warn(&ctx, .W2002, s.span, fmt.tprintf("unreferenced schema %q", ir_string(ir, s.name))) or_return
		}
	}
	for bind, bi in ir.bindings {
		if bind.kind == .Source && !ctx.binding_ref[bi] {
			sema_warn(&ctx, .W2002, bind.span, fmt.tprintf("unreferenced source %q", ir_string(ir, bind.name))) or_return
		}
	}
	for tbl, ti in ir.tables {
		if !ctx.table_ref[ti] {
			sema_warn(&ctx, .W2002, tbl.span, fmt.tprintf("unreferenced decision table %q", ir_string(ir, tbl.name))) or_return
		}
	}

	verify_all_tables(ir, diags, telemetry) or_return
	strat_plan := stratify_ir(ir, diags, telemetry) or_return
	stratification_plan_destroy(&strat_plan)
	return nil
}
