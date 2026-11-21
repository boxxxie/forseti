package forseti

import "core:fmt"
import "core:mem"
import "core:strings"

@(private)
unary_op_str :: proc "contextless" (op: Unary_Op) -> string {
	switch op {
	case .Neg:
		return "-"
	case .Not:
		return "not"
	}
	return "?"
}

@(private)
binary_op_str :: proc "contextless" (op: Binary_Op) -> string {
	switch op {
	case .Add:
		return "+"
	case .Sub:
		return "-"
	case .Mul:
		return "*"
	case .Div:
		return "/"
	case .Mod:
		return "%"
	case .Eq:
		return "=="
	case .Neq:
		return "!="
	case .Lt:
		return "<"
	case .Lte:
		return "<="
	case .Gt:
		return ">"
	case .Gte:
		return ">="
	case .And:
		return "and"
	case .Or:
		return "or"
	}
	return "?"
}

@(private)
type_kind_str :: proc "contextless" (k: Type_Kind) -> string {
	switch k {
	case .Unknown:
		return "unknown"
	case .Bool:
		return "bool"
	case .I32:
		return "i32"
	case .I64:
		return "i64"
	case .F64:
		return "f64"
	case .String:
		return "string"
	case .Entity:
		return "entity"
	case .Time:
		return "time"
	case .Enum:
		return "enum"
	case .Fact:
		return "fact"
	case .Table_Result:
		return "table_result"
	}
	return "unknown"
}

@(private)
accum_op_str :: proc "contextless" (op: Accum_Op) -> string {
	switch op {
	case .Count:
		return "count"
	case .Sum:
		return "sum"
	case .Min:
		return "min"
	case .Max:
		return "max"
	case .Avg:
		return "avg"
	case .Distinct:
		return "distinct"
	case .Collect:
		return "collect"
	}
	return "count"
}

@(private)
write_expr_sexp :: proc(b: ^strings.Builder, pool: ^Ast_Pool, interner: ^String_Interner, id: Node_Id) {
	if id == INVALID_NODE || int(id) >= len(pool.nodes) {
		strings.write_string(b, "<nil>")
		return
	}
	node := pool.nodes[id]
	switch p in node.payload {
	case Ast_Lit_Bool:
		strings.write_string(b, "true" if p.val else "false")
	case Ast_Lit_Int:
		fmt.sbprintf(b, "%d", p.val)
	case Ast_Lit_Float:
		fmt.sbprintf(b, "%v", p.val)
	case Ast_Lit_String:
		write_json_escaped_string(b, interner_get(interner, p.str))
	case Ast_Var:
		strings.write_string(b, interner_get(interner, p.name))
	case Ast_Ident:
		strings.write_string(b, interner_get(interner, p.name))
	case Ast_Wildcard:
		strings.write_byte(b, '-')
	case Ast_Unary:
		fmt.sbprintf(b, "(%s ", unary_op_str(p.op))
		write_expr_sexp(b, pool, interner, p.operand)
		strings.write_byte(b, ')')
	case Ast_Binary:
		fmt.sbprintf(b, "(%s ", binary_op_str(p.op))
		write_expr_sexp(b, pool, interner, p.lhs)
		strings.write_byte(b, ' ')
		write_expr_sexp(b, pool, interner, p.rhs)
		strings.write_byte(b, ')')
	case Ast_Field_Access:
		strings.write_string(b, "(. ")
		write_expr_sexp(b, pool, interner, p.base)
		strings.write_byte(b, ' ')
		strings.write_string(b, interner_get(interner, p.field))
		strings.write_byte(b, ')')
	case Ast_Range:
		strings.write_string(b, "(..= " if p.inclusive else "(.. ")
		write_expr_sexp(b, pool, interner, p.lo)
		strings.write_byte(b, ' ')
		write_expr_sexp(b, pool, interner, p.hi)
		strings.write_byte(b, ')')
	case Ast_In_List:
		strings.write_string(b, "(in")
		for idx in p.items.start ..< p.items.start + p.items.count {
			strings.write_byte(b, ' ')
			write_expr_sexp(b, pool, interner, pool.extra_children[idx])
		}
		strings.write_byte(b, ')')
	case Ast_Cell_Cmp:
		fmt.sbprintf(b, "(cell %s ", binary_op_str(p.op))
		write_expr_sexp(b, pool, interner, p.rhs)
		strings.write_byte(b, ')')
	case Ast_Call:
		strings.write_string(b, "(call ")
		strings.write_string(b, interner_get(interner, p.callee))
		for idx in p.args.start ..< p.args.start + p.args.count {
			strings.write_byte(b, ' ')
			write_expr_sexp(b, pool, interner, pool.extra_children[idx])
		}
		strings.write_byte(b, ')')
	case Ast_Error:
		strings.write_string(b, "<error>")
	}
}

@(private)
write_field_assigns_sexp :: proc(b: ^strings.Builder, pool: ^Ast_Pool, interner: ^String_Interner, span: Node_Span) {
	for idx in span.start ..< span.start + span.count {
		fa := pool.field_assigns[idx]
		strings.write_string(b, " (")
		strings.write_string(b, interner_get(interner, fa.name))
		strings.write_byte(b, ' ')
		write_expr_sexp(b, pool, interner, fa.expr)
		strings.write_byte(b, ')')
	}
}

@(private)
write_clause_sexp :: proc(b: ^strings.Builder, pool: ^Ast_Pool, interner: ^String_Interner, cl: Ast_Clause) {
	switch cl.kind {
	case .Pattern:
		strings.write_string(b, "(pat ")
		if cl.bind_var != EMPTY_STRING {
			strings.write_string(b, interner_get(interner, cl.bind_var))
			strings.write_byte(b, ' ')
		}
		strings.write_string(b, interner_get(interner, cl.target))
		write_field_assigns_sexp(b, pool, interner, cl.fields)
		strings.write_byte(b, ')')
	case .Eav:
		strings.write_string(b, "(eav ")
		if cl.bind_var != EMPTY_STRING {
			strings.write_string(b, interner_get(interner, cl.bind_var))
			strings.write_byte(b, ' ')
		}
		write_expr_sexp(b, pool, interner, cl.expr)
		strings.write_byte(b, ' ')
		write_expr_sexp(b, pool, interner, cl.guard_expr)
		strings.write_byte(b, ' ')
		write_expr_sexp(b, pool, interner, cl.extra_expr)
		strings.write_byte(b, ')')
	case .Not:
		strings.write_string(b, "(not")
		for idx in cl.children.start ..< cl.children.start + cl.children.count {
			strings.write_byte(b, ' ')
			write_clause_sexp(b, pool, interner, pool.clauses[idx])
		}
		strings.write_byte(b, ')')
	case .Exists:
		strings.write_string(b, "(exists")
		for idx in cl.children.start ..< cl.children.start + cl.children.count {
			strings.write_byte(b, ' ')
			write_clause_sexp(b, pool, interner, pool.clauses[idx])
		}
		strings.write_byte(b, ')')
	case .Accum:
		fmt.sbprintf(b, "(accum %s %s ", interner_get(interner, cl.bind_var), accum_op_str(cl.accum_op))
		write_expr_sexp(b, pool, interner, cl.expr)
		if cl.inner_pat.count > 0 {
			strings.write_byte(b, ' ')
			write_clause_sexp(b, pool, interner, pool.clauses[cl.inner_pat.start])
		}
		if cl.guard_expr != INVALID_NODE {
			strings.write_string(b, " (where ")
			write_expr_sexp(b, pool, interner, cl.guard_expr)
			strings.write_byte(b, ')')
		}
		strings.write_byte(b, ')')
	case .Decide:
		strings.write_string(b, "(decide ")
		if cl.bind_var != EMPTY_STRING {
			strings.write_string(b, interner_get(interner, cl.bind_var))
			strings.write_byte(b, ' ')
		}
		strings.write_string(b, interner_get(interner, cl.target))
		write_field_assigns_sexp(b, pool, interner, cl.fields)
		strings.write_byte(b, ')')
	case .Where:
		strings.write_string(b, "(where ")
		write_expr_sexp(b, pool, interner, cl.expr)
		strings.write_byte(b, ')')
	case .Let:
		fmt.sbprintf(b, "(let %s ", interner_get(interner, cl.bind_var))
		write_expr_sexp(b, pool, interner, cl.expr)
		strings.write_byte(b, ')')
	case .Error:
		strings.write_string(b, "<error-clause>")
	}
}

@(require_results)
ast_expr_to_sexp :: proc(
	pool: ^Ast_Pool,
	interner: ^String_Interner,
	id: Node_Id,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}
	write_expr_sexp(&b, pool, interner, id)
	return strings.to_string(b), nil
}

@(require_results)
ast_print_sexp :: proc(
	pool: ^Ast_Pool,
	interner: ^String_Interner,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, "(module")
	if pool.module_name != EMPTY_STRING {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, interner_get(interner, pool.module_name))
		if pool.module_version != EMPTY_STRING {
			strings.write_byte(&b, ' ')
			write_json_escaped_string(&b, interner_get(interner, pool.module_version))
		}
	}

	for s in pool.schemas {
		strings.write_string(&b, " (schema ")
		strings.write_string(&b, interner_get(interner, s.name))
		for idx in s.fields.start ..< s.fields.start + s.fields.count {
			f := pool.schema_fields[idx]
			fmt.sbprintf(&b, " (%s %s)", interner_get(interner, f.name), type_kind_str(f.type.kind))
		}
		strings.write_byte(&b, ')')
	}

	for bind in pool.bindings {
		kind_str := "source" if bind.kind == .Source else "derived"
		fmt.sbprintf(&b, " (%s %s %s)", kind_str, interner_get(interner, bind.name), interner_get(interner, bind.schema_name))
	}

	for tbl in pool.tables {
		fmt.sbprintf(&b, " (table %s", interner_get(interner, tbl.name))
		if tbl.version != EMPTY_STRING {
			strings.write_byte(&b, ' ')
			write_json_escaped_string(&b, interner_get(interner, tbl.version))
		}
		fmt.sbprintf(&b, " (rows %d))", tbl.rows.count)
	}

	for r in pool.rules {
		fmt.sbprintf(&b, " (rule %s", interner_get(interner, r.name))
		if r.phase != EMPTY_STRING {
			strings.write_string(&b, " (phase ")
			write_json_escaped_string(&b, interner_get(interner, r.phase))
			strings.write_byte(&b, ')')
		}
		if r.has_salience {
			fmt.sbprintf(&b, " (salience %d)", r.salience)
		}
		if r.when_clauses.count > 0 {
			strings.write_string(&b, " (when")
			for idx in r.when_clauses.start ..< r.when_clauses.start + r.when_clauses.count {
				strings.write_byte(&b, ' ')
				write_clause_sexp(&b, pool, interner, pool.clauses[idx])
			}
			strings.write_byte(&b, ')')
		}
		if r.then_actions.count > 0 {
			strings.write_string(&b, " (then")
			for idx in r.then_actions.start ..< r.then_actions.start + r.then_actions.count {
				act := pool.actions[idx]
				switch act.kind {
				case .Assert:
					label := "assert!" if act.unconditional else "assert"
					fmt.sbprintf(&b, " (%s %s", label, interner_get(interner, act.target))
					write_field_assigns_sexp(&b, pool, interner, act.fields)
					strings.write_byte(&b, ')')
				case .Assert_Eav:
					label := "assert!" if act.unconditional else "assert"
					fmt.sbprintf(&b, " (%s-eav ", label)
					write_expr_sexp(&b, pool, interner, act.expr)
					strings.write_byte(&b, ' ')
					write_expr_sexp(&b, pool, interner, act.attr_expr)
					strings.write_byte(&b, ' ')
					write_expr_sexp(&b, pool, interner, act.val_expr)
					strings.write_byte(&b, ')')
				case .Retract:
					strings.write_string(&b, " (retract ")
					write_expr_sexp(&b, pool, interner, act.expr)
					strings.write_byte(&b, ')')
				case .Effect:
					strings.write_string(&b, " (effect ")
					write_json_escaped_string(&b, interner_get(interner, act.target))
					write_field_assigns_sexp(&b, pool, interner, act.fields)
					strings.write_byte(&b, ')')
				case .Error:
					strings.write_string(&b, " <error-action>")
				}
			}
			strings.write_byte(&b, ')')
		}
		strings.write_byte(&b, ')')
	}

	for q in pool.queries {
		fmt.sbprintf(&b, " (query %s)", interner_get(interner, q.name))
	}

	strings.write_byte(&b, ')')
	return strings.to_string(b), nil
}
