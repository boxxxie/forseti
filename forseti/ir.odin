package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Expr_IR_Kind :: enum u8 {
	Invalid,
	Lit_Bool,
	Lit_Int,
	Lit_Float,
	Lit_String,
	Var,
	Ident,
	Wildcard,
	Unary,
	Binary,
	Field_Access,
	Range,
	In_List,
	Cell_Cmp,
	Call,
}

Expr_IR :: struct {
	kind:       Expr_IR_Kind,
	span:       Span,
	bool_val:   bool,
	inclusive:  bool,
	unary_op:   Unary_Op,
	binary_op:  Binary_Op,
	int_val:    i64,
	float_val:  f64,
	str_id:     String_Id,
	lhs:        Expr_Id,
	rhs:        Expr_Id,
	extra_span: Node_Span, // Slice into Rulebase_IR.extra_exprs
}

Enum_Def :: struct {
	name:     String_Id,
	variants: []String_Id,
}

Field_Def :: struct {
	name: String_Id,
	type: Type_Ref,
	span: Span,
}

Schema_Def :: struct {
	name:   String_Id,
	fields: []Field_Def,
	span:   Span,
}

Selector_Seg_Kind :: enum u8 {
	Field,
	Var_Key,
	Lit_Key,
	Wildcard,
}

Selector_Segment :: struct {
	kind: Selector_Seg_Kind,
	text: String_Id,
	span: Span,
}

Binding_Def :: struct {
	kind:        Binding_Kind,
	name:        String_Id,
	schema_name: String_Id,
	schema_id:   Schema_Id,
	segments:    []Selector_Segment,
	span:        Span,
}

Table_Col_Def :: struct {
	name: String_Id,
	type: Type_Ref,
	cost: u32,
	span: Span,
}

Table_Row_Def :: struct {
	id:      String_Id,
	cells:   []Expr_Id,
	outputs: []Expr_Id,
	span:    Span,
}

Table_Def :: struct {
	name:         String_Id,
	version:      String_Id,
	hit_policy:   Hit_Policy,
	verify_flags: Table_Verify_Flags,
	inputs:       []Table_Col_Def,
	outputs:      []Table_Col_Def,
	rows:         []Table_Row_Def,
	span:         Span,
}

Field_Binding_IR :: struct {
	name: String_Id,
	expr: Expr_Id,
	span: Span,
}

Clause_Kind_IR :: enum u8 {
	Pattern,
	Eav,
	Not,
	Exists,
	Accum,
	Decide,
	Where,
	Let,
}

Clause_IR :: struct {
	kind:        Clause_Kind_IR,
	bind_var:    String_Id,
	target:      String_Id,
	fields:      []Field_Binding_IR,
	children:    []Clause_IR,
	expr:        Expr_Id,
	guard_expr:  Expr_Id,
	extra_expr:  Expr_Id,
	accum_op:    Accum_Op,
	inner_pat:   []Clause_IR,
	span:        Span,
}

Action_Kind_IR :: enum u8 {
	Assert,
	Assert_Eav,
	Retract,
	Effect,
}

Action_IR :: struct {
	kind:          Action_Kind_IR,
	target:        String_Id,
	unconditional: bool,
	fields:        []Field_Binding_IR,
	expr:          Expr_Id,
	attr_expr:     Expr_Id,
	val_expr:      Expr_Id,
	span:          Span,
}

Rule_Def :: struct {
	name:         String_Id,
	phase:        String_Id,
	salience:     i32,
	has_salience: bool,
	when_clauses: []Clause_IR,
	then_actions: []Action_IR,
	span:         Span,
}

Query_Param_Def :: struct {
	name: String_Id,
	type: Type_Ref,
	span: Span,
}

Query_Def :: struct {
	name:         String_Id,
	params:       []Query_Param_Def,
	when_clauses: []Clause_IR,
	span:         Span,
}

Rulebase_IR :: struct {
	arena:          vmem.Arena,
	interner:       String_Interner,
	line_starts:    []u32,
	module_name:    String_Id,
	module_version: String_Id,
	enums:          []Enum_Def,
	schemas:        []Schema_Def,
	bindings:       []Binding_Def,
	tables:         []Table_Def,
	rules:          []Rule_Def,
	queries:        []Query_Def,
	exprs:          []Expr_IR,
	extra_exprs:    []Expr_Id,
}

ir_destroy :: proc(ir: ^Rulebase_IR) {
	vmem.arena_check_temp(&ir.arena)
	interner_destroy(&ir.interner)
	vmem.arena_destroy(&ir.arena)
	ir^ = {}
}

ir_string :: proc "contextless" (ir: ^Rulebase_IR, id: String_Id) -> string {
	return interner_get(&ir.interner, id)
}

@(private)
ir_write_expr :: proc(b: ^strings.Builder, ir: ^Rulebase_IR, id: Expr_Id) {
	if id == INVALID_EXPR || int(id) >= len(ir.exprs) {
		strings.write_string(b, "<invalid>")
		return
	}
	e := ir.exprs[id]
	switch e.kind {
	case .Invalid:
		strings.write_string(b, "<invalid>")
	case .Lit_Bool:
		strings.write_string(b, "true" if e.bool_val else "false")
	case .Lit_Int:
		fmt.sbprintf(b, "%d", e.int_val)
	case .Lit_Float:
		fmt.sbprintf(b, "%v", e.float_val)
	case .Lit_String:
		write_json_escaped_string(b, ir_string(ir, e.str_id))
	case .Var, .Ident:
		strings.write_string(b, ir_string(ir, e.str_id))
	case .Wildcard:
		strings.write_byte(b, '-')
	case .Unary:
		fmt.sbprintf(b, "(%s ", unary_op_str(e.unary_op))
		ir_write_expr(b, ir, e.lhs)
		strings.write_byte(b, ')')
	case .Binary:
		fmt.sbprintf(b, "(%s ", binary_op_str(e.binary_op))
		ir_write_expr(b, ir, e.lhs)
		strings.write_byte(b, ' ')
		ir_write_expr(b, ir, e.rhs)
		strings.write_byte(b, ')')
	case .Field_Access:
		ir_write_expr(b, ir, e.lhs)
		strings.write_byte(b, '.')
		strings.write_string(b, ir_string(ir, e.str_id))
	case .Range:
		ir_write_expr(b, ir, e.lhs)
		strings.write_string(b, "..=" if e.inclusive else "..")
		ir_write_expr(b, ir, e.rhs)
	case .In_List:
		strings.write_string(b, "in(")
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			if i > e.extra_span.start {
				strings.write_string(b, ", ")
			}
			ir_write_expr(b, ir, ir.extra_exprs[i])
		}
		strings.write_byte(b, ')')
	case .Cell_Cmp:
		fmt.sbprintf(b, "%s ", binary_op_str(e.binary_op))
		ir_write_expr(b, ir, e.rhs)
	case .Call:
		strings.write_string(b, ir_string(ir, e.str_id))
		strings.write_byte(b, '(')
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			if i > e.extra_span.start {
				strings.write_string(b, ", ")
			}
			ir_write_expr(b, ir, ir.extra_exprs[i])
		}
		strings.write_byte(b, ')')
	}
}

@(require_results)
ir_format_text :: proc(ir: ^Rulebase_IR, allocator := context.allocator) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	fmt.sbprintf(&b, "module %s version %q\n", ir_string(ir, ir.module_name), ir_string(ir, ir.module_version))
	for s in ir.schemas {
		fmt.sbprintf(&b, "schema %s (%d fields)\n", ir_string(ir, s.name), len(s.fields))
		for f in s.fields {
			fmt.sbprintf(&b, "  %s: %s\n", ir_string(ir, f.name), type_kind_str(f.type.kind))
		}
	}
	for bind in ir.bindings {
		k := "source" if bind.kind == .Source else "derived"
		fmt.sbprintf(&b, "%s %s : %s\n", k, ir_string(ir, bind.name), ir_string(ir, bind.schema_name))
	}
	for tbl in ir.tables {
		fmt.sbprintf(&b, "table %s version %q hit %v (%d in, %d out, %d rows)\n", ir_string(ir, tbl.name), ir_string(ir, tbl.version), tbl.hit_policy, len(tbl.inputs), len(tbl.outputs), len(tbl.rows))
	}
	for r in ir.rules {
		fmt.sbprintf(&b, "rule %s phase %q salience %d (%d when, %d then)\n", ir_string(ir, r.name), ir_string(ir, r.phase), r.salience, len(r.when_clauses), len(r.then_actions))
		for cl in r.when_clauses {
			fmt.sbprintf(&b, "  clause %v %s target=%s", cl.kind, ir_string(ir, cl.bind_var), ir_string(ir, cl.target))
			if cl.expr != INVALID_EXPR {
				strings.write_string(&b, " expr=")
				ir_write_expr(&b, ir, cl.expr)
			}
			strings.write_byte(&b, '\n')
		}
		for act in r.then_actions {
			fmt.sbprintf(&b, "  action %v target=%s uncond=%t\n", act.kind, ir_string(ir, act.target), act.unconditional)
		}
	}
	for q in ir.queries {
		fmt.sbprintf(&b, "query %s (%d params, %d clauses)\n", ir_string(ir, q.name), len(q.params), len(q.when_clauses))
	}

	return strings.to_string(b), nil
}

@(private)
expr_ir_equal :: proc(a: ^Rulebase_IR, aid: Expr_Id, b: ^Rulebase_IR, bid: Expr_Id) -> bool {
	if aid == INVALID_EXPR && bid == INVALID_EXPR {
		return true
	}
	if aid == INVALID_EXPR || bid == INVALID_EXPR {
		return false
	}
	ea := a.exprs[aid]
	eb := b.exprs[bid]
	if ea.kind != eb.kind {
		return false
	}
	switch ea.kind {
	case .Invalid, .Wildcard:
		return true
	case .Lit_Bool:
		return ea.bool_val == eb.bool_val
	case .Lit_Int:
		return ea.int_val == eb.int_val
	case .Lit_Float:
		return ea.float_val == eb.float_val
	case .Lit_String, .Var, .Ident:
		return ir_string(a, ea.str_id) == ir_string(b, eb.str_id)
	case .Unary:
		return ea.unary_op == eb.unary_op && expr_ir_equal(a, ea.lhs, b, eb.lhs)
	case .Binary:
		return ea.binary_op == eb.binary_op && expr_ir_equal(a, ea.lhs, b, eb.lhs) && expr_ir_equal(a, ea.rhs, b, eb.rhs)
	case .Field_Access:
		return ir_string(a, ea.str_id) == ir_string(b, eb.str_id) && expr_ir_equal(a, ea.lhs, b, eb.lhs)
	case .Range:
		return ea.inclusive == eb.inclusive && expr_ir_equal(a, ea.lhs, b, eb.lhs) && expr_ir_equal(a, ea.rhs, b, eb.rhs)
	case .Cell_Cmp:
		return ea.binary_op == eb.binary_op && expr_ir_equal(a, ea.rhs, b, eb.rhs)
	case .In_List, .Call:
		if ea.kind == .Call && ir_string(a, ea.str_id) != ir_string(b, eb.str_id) {
			return false
		}
		if ea.extra_span.count != eb.extra_span.count {
			return false
		}
		for i in 0 ..< ea.extra_span.count {
			ca := a.extra_exprs[ea.extra_span.start + i]
			cb := b.extra_exprs[eb.extra_span.start + i]
			if !expr_ir_equal(a, ca, b, cb) {
				return false
			}
		}
		return true
	}
	return false
}

@(private)
type_ref_equal :: proc(a: ^Rulebase_IR, ta: Type_Ref, b: ^Rulebase_IR, tb: Type_Ref) -> bool {
	if ta.kind != tb.kind {
		return false
	}
	if ta.kind == .Enum {
		ea := a.enums[ta.ref_id]
		eb := b.enums[tb.ref_id]
		if len(ea.variants) != len(eb.variants) {
			return false
		}
		for i in 0 ..< len(ea.variants) {
			if ir_string(a, ea.variants[i]) != ir_string(b, eb.variants[i]) {
				return false
			}
		}
	}
	return true
}

@(private)
field_bindings_equal :: proc(a: ^Rulebase_IR, fa: []Field_Binding_IR, b: ^Rulebase_IR, fb: []Field_Binding_IR) -> bool {
	if len(fa) != len(fb) {
		return false
	}
	for i in 0 ..< len(fa) {
		if ir_string(a, fa[i].name) != ir_string(b, fb[i].name) {
			return false
		}
		if !expr_ir_equal(a, fa[i].expr, b, fb[i].expr) {
			return false
		}
	}
	return true
}

@(private)
clauses_equal :: proc(a: ^Rulebase_IR, ca: []Clause_IR, b: ^Rulebase_IR, cb: []Clause_IR) -> bool {
	if len(ca) != len(cb) {
		return false
	}
	for i in 0 ..< len(ca) {
		xa := ca[i]
		xb := cb[i]
		if xa.kind != xb.kind ||
			xa.accum_op != xb.accum_op ||
			ir_string(a, xa.bind_var) != ir_string(b, xb.bind_var) ||
			ir_string(a, xa.target) != ir_string(b, xb.target) ||
			!field_bindings_equal(a, xa.fields, b, xb.fields) ||
			!clauses_equal(a, xa.children, b, xb.children) ||
			!clauses_equal(a, xa.inner_pat, b, xb.inner_pat) ||
			!expr_ir_equal(a, xa.expr, b, xb.expr) ||
			!expr_ir_equal(a, xa.guard_expr, b, xb.guard_expr) ||
			!expr_ir_equal(a, xa.extra_expr, b, xb.extra_expr) {
			return false
		}
	}
	return true
}

ir_structurally_equal :: proc(a, b: ^Rulebase_IR) -> bool {
	if ir_string(a, a.module_name) != ir_string(b, b.module_name) ||
		ir_string(a, a.module_version) != ir_string(b, b.module_version) {
		return false
	}
	if len(a.schemas) != len(b.schemas) ||
		len(a.bindings) != len(b.bindings) ||
		len(a.tables) != len(b.tables) ||
		len(a.rules) != len(b.rules) ||
		len(a.queries) != len(b.queries) {
		return false
	}

	for i in 0 ..< len(a.schemas) {
		sa := a.schemas[i]
		sb := b.schemas[i]
		if ir_string(a, sa.name) != ir_string(b, sb.name) || len(sa.fields) != len(sb.fields) {
			return false
		}
		for j in 0 ..< len(sa.fields) {
			if ir_string(a, sa.fields[j].name) != ir_string(b, sb.fields[j].name) ||
				!type_ref_equal(a, sa.fields[j].type, b, sb.fields[j].type) {
				return false
			}
		}
	}

	for i in 0 ..< len(a.bindings) {
		ba := a.bindings[i]
		bb := b.bindings[i]
		if ba.kind != bb.kind ||
			ir_string(a, ba.name) != ir_string(b, bb.name) ||
			ir_string(a, ba.schema_name) != ir_string(b, bb.schema_name) ||
			len(ba.segments) != len(bb.segments) {
			return false
		}
		for j in 0 ..< len(ba.segments) {
			if ba.segments[j].kind != bb.segments[j].kind ||
				ir_string(a, ba.segments[j].text) != ir_string(b, bb.segments[j].text) {
				return false
			}
		}
	}

	for i in 0 ..< len(a.tables) {
		ta := a.tables[i]
		tb := b.tables[i]
		if ir_string(a, ta.name) != ir_string(b, tb.name) ||
			ir_string(a, ta.version) != ir_string(b, tb.version) ||
			ta.hit_policy != tb.hit_policy ||
			ta.verify_flags != tb.verify_flags ||
			len(ta.inputs) != len(tb.inputs) ||
			len(ta.outputs) != len(tb.outputs) ||
			len(ta.rows) != len(tb.rows) {
			return false
		}
		for j in 0 ..< len(ta.inputs) {
			if ir_string(a, ta.inputs[j].name) != ir_string(b, tb.inputs[j].name) ||
				ta.inputs[j].cost != tb.inputs[j].cost ||
				!type_ref_equal(a, ta.inputs[j].type, b, tb.inputs[j].type) {
				return false
			}
		}
		for j in 0 ..< len(ta.outputs) {
			if ir_string(a, ta.outputs[j].name) != ir_string(b, tb.outputs[j].name) ||
				!type_ref_equal(a, ta.outputs[j].type, b, tb.outputs[j].type) {
				return false
			}
		}
		for j in 0 ..< len(ta.rows) {
			ra := ta.rows[j]
			rb := tb.rows[j]
			if ir_string(a, ra.id) != ir_string(b, rb.id) ||
				len(ra.cells) != len(rb.cells) ||
				len(ra.outputs) != len(rb.outputs) {
				return false
			}
			for k in 0 ..< len(ra.cells) {
				if !expr_ir_equal(a, ra.cells[k], b, rb.cells[k]) {
					return false
				}
			}
			for k in 0 ..< len(ra.outputs) {
				if !expr_ir_equal(a, ra.outputs[k], b, rb.outputs[k]) {
					return false
				}
			}
		}
	}

	for i in 0 ..< len(a.rules) {
		ra := a.rules[i]
		rb := b.rules[i]
		if ir_string(a, ra.name) != ir_string(b, rb.name) ||
			ir_string(a, ra.phase) != ir_string(b, rb.phase) ||
			ra.salience != rb.salience ||
			ra.has_salience != rb.has_salience ||
			!clauses_equal(a, ra.when_clauses, b, rb.when_clauses) ||
			len(ra.then_actions) != len(rb.then_actions) {
			return false
		}
		for j in 0 ..< len(ra.then_actions) {
			aa := ra.then_actions[j]
			ab := rb.then_actions[j]
			if aa.kind != ab.kind ||
				aa.unconditional != ab.unconditional ||
				ir_string(a, aa.target) != ir_string(b, ab.target) ||
				!field_bindings_equal(a, aa.fields, b, ab.fields) ||
				!expr_ir_equal(a, aa.expr, b, ab.expr) ||
				!expr_ir_equal(a, aa.attr_expr, b, ab.attr_expr) ||
				!expr_ir_equal(a, aa.val_expr, b, ab.val_expr) {
				return false
			}
		}
	}

	for i in 0 ..< len(a.queries) {
		qa := a.queries[i]
		qb := b.queries[i]
		if ir_string(a, qa.name) != ir_string(b, qb.name) ||
			len(qa.params) != len(qb.params) ||
			!clauses_equal(a, qa.when_clauses, b, qb.when_clauses) {
			return false
		}
		for j in 0 ..< len(qa.params) {
			if ir_string(a, qa.params[j].name) != ir_string(b, qb.params[j].name) ||
				!type_ref_equal(a, qa.params[j].type, b, qb.params[j].type) {
				return false
			}
		}
	}

	return true
}
