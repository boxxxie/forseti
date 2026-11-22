package forseti

import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Expr_Spec_Kind :: enum u8 {
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

Expr_Spec :: struct {
	kind:       Expr_Spec_Kind,
	bool_val:   bool,
	inclusive:  bool,
	unary_op:   Unary_Op,
	binary_op:  Binary_Op,
	int_val:    i64,
	float_val:  f64,
	text:       string,
	children:   []Expr_Spec,
}

Field_Spec :: struct {
	name:     string,
	type:     Type_Kind,
	variants: []string,
}

Field_Binding_Spec :: struct {
	name: string,
	expr: Expr_Spec,
}

Table_Col_Spec :: struct {
	name:     string,
	type:     Type_Kind,
	cost:     u32,
	variants: []string,
}

Table_Row_Spec :: struct {
	id:      string,
	cells:   []Expr_Spec,
	outputs: []Expr_Spec,
}

Table_Spec :: struct {
	name:         string,
	version:      string,
	hit_policy:   Hit_Policy,
	verify_flags: Table_Verify_Flags,
	inputs:       []Table_Col_Spec,
	outputs:      []Table_Col_Spec,
	rows:         []Table_Row_Spec,
}

Clause_Spec :: struct {
	kind:       Clause_Kind_IR,
	bind_var:   string,
	target:     string,
	fields:     []Field_Binding_Spec,
	children:   []Clause_Spec,
	expr:       Expr_Spec,
	guard_expr: Expr_Spec,
	extra_expr: Expr_Spec,
	accum_op:   Accum_Op,
	inner_pat:  []Clause_Spec,
	has_expr:   bool,
	has_guard:  bool,
}

Action_Spec :: struct {
	kind:          Action_Kind_IR,
	target:        string,
	unconditional: bool,
	fields:        []Field_Binding_Spec,
	expr:          Expr_Spec,
	attr_expr:     Expr_Spec,
	val_expr:      Expr_Spec,
}

Rule_Spec :: struct {
	name:         string,
	phase:        string,
	salience:     i32,
	has_salience: bool,
	when_clauses: []Clause_Spec,
	then_actions: []Action_Spec,
}

Query_Spec :: struct {
	name:         string,
	params:       []Field_Spec,
	when_clauses: []Clause_Spec,
}

Ir_Builder :: struct {
	arena:          vmem.Arena,
	module_name:    string,
	module_version: string,
	schemas:        [dynamic]Schema_Spec_Stored,
	bindings:       [dynamic]Binding_Spec_Stored,
	tables:         [dynamic]Table_Spec,
	rules:          [dynamic]Rule_Spec,
	queries:        [dynamic]Query_Spec,
}

@(private)
Schema_Spec_Stored :: struct {
	name:   string,
	fields: []Field_Spec,
}

@(private)
Binding_Spec_Stored :: struct {
	kind:        Binding_Kind,
	name:        string,
	schema_name: string,
	selector:    string,
}

@(require_results)
ir_builder_init :: proc(
	b: ^Ir_Builder,
	module_name: string = "",
	module_version: string = "",
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	b^ = {}
	vmem.arena_init_growing(&b.arena) or_return
	defer if err != nil {
		ir_builder_destroy(b)
	}
	a := vmem.arena_allocator(&b.arena)
	b.module_name = strings.clone(module_name, a) or_return
	b.module_version = strings.clone(module_version, a) or_return
	b.schemas = make([dynamic]Schema_Spec_Stored, 0, 8, allocator) or_return
	b.bindings = make([dynamic]Binding_Spec_Stored, 0, 8, allocator) or_return
	b.tables = make([dynamic]Table_Spec, 0, 8, allocator) or_return
	b.rules = make([dynamic]Rule_Spec, 0, 16, allocator) or_return
	b.queries = make([dynamic]Query_Spec, 0, 8, allocator) or_return
	return nil
}

ir_builder_destroy :: proc(b: ^Ir_Builder) {
	vmem.arena_check_temp(&b.arena)
	delete(b.queries)
	delete(b.rules)
	delete(b.tables)
	delete(b.bindings)
	delete(b.schemas)
	vmem.arena_destroy(&b.arena)
	b^ = {}
}

field :: proc "contextless" (name: string, type: Type_Kind, variants: []string = nil) -> Field_Spec {
	return Field_Spec{name = name, type = type, variants = variants}
}

lit_bool :: proc "contextless" (v: bool) -> Expr_Spec { return Expr_Spec{kind = .Lit_Bool, bool_val = v} }
lit_int :: proc "contextless" (v: i64) -> Expr_Spec { return Expr_Spec{kind = .Lit_Int, int_val = v} }
lit_float :: proc "contextless" (v: f64) -> Expr_Spec { return Expr_Spec{kind = .Lit_Float, float_val = v} }
lit_string :: proc "contextless" (v: string) -> Expr_Spec { return Expr_Spec{kind = .Lit_String, text = v} }
lit :: proc{lit_bool, lit_int, lit_float, lit_string}

vref :: proc "contextless" (name: string) -> Expr_Spec {
	return Expr_Spec{kind = .Var, text = name}
}

wildcard :: proc "contextless" () -> Expr_Spec {
	return Expr_Spec{kind = .Wildcard}
}

fget :: proc(base_var, field_name: string, allocator := context.temp_allocator) -> Expr_Spec {
	args := make([]Expr_Spec, 1, allocator)
	args[0] = vref(base_var)
	return Expr_Spec{kind = .Field_Access, text = field_name, children = args}
}

cond_bin :: proc(op: Binary_Op, lhs, rhs: Expr_Spec, allocator := context.temp_allocator) -> Expr_Spec {
	ch := make([]Expr_Spec, 2, allocator)
	ch[0] = lhs
	ch[1] = rhs
	return Expr_Spec{kind = .Binary, binary_op = op, children = ch}
}

cond_unary :: proc(op: Unary_Op, operand: Expr_Spec, allocator := context.temp_allocator) -> Expr_Spec {
	ch := make([]Expr_Spec, 1, allocator)
	ch[0] = operand
	return Expr_Spec{kind = .Unary, unary_op = op, children = ch}
}

cond_cell_int :: proc(op: Binary_Op, rhs: i64, allocator := context.temp_allocator) -> Expr_Spec {
	ch := make([]Expr_Spec, 1, allocator)
	ch[0] = lit_int(rhs)
	return Expr_Spec{kind = .Cell_Cmp, binary_op = op, children = ch}
}

cond_cell_float :: proc(op: Binary_Op, rhs: f64, allocator := context.temp_allocator) -> Expr_Spec {
	ch := make([]Expr_Spec, 1, allocator)
	ch[0] = lit_float(rhs)
	return Expr_Spec{kind = .Cell_Cmp, binary_op = op, children = ch}
}

cond :: proc{cond_bin, cond_unary, cond_cell_int, cond_cell_float}

field_bind :: proc "contextless" (name: string, expr: Expr_Spec) -> Field_Binding_Spec {
	return Field_Binding_Spec{name = name, expr = expr}
}

pat :: proc "contextless" (bind_var, target: string, fields: []Field_Binding_Spec = nil) -> Clause_Spec {
	return Clause_Spec{kind = .Pattern, bind_var = bind_var, target = target, fields = fields}
}

eav_pat :: proc "contextless" (bind_var: string, e, a, v: Expr_Spec) -> Clause_Spec {
	return Clause_Spec{kind = .Eav, bind_var = bind_var, expr = e, guard_expr = a, extra_expr = v, has_expr = true}
}

not_pat :: proc "contextless" (children: []Clause_Spec) -> Clause_Spec {
	return Clause_Spec{kind = .Not, children = children}
}

exists_pat :: proc "contextless" (children: []Clause_Spec) -> Clause_Spec {
	return Clause_Spec{kind = .Exists, children = children}
}

accum_clause :: proc "contextless" (
	bind_var: string,
	op: Accum_Op,
	expr: Expr_Spec,
	from_pat: []Clause_Spec,
) -> Clause_Spec {
	return Clause_Spec{kind = .Accum, bind_var = bind_var, accum_op = op, expr = expr, inner_pat = from_pat, has_expr = true}
}

decide_clause :: proc "contextless" (bind_var, table_name: string, args: []Field_Binding_Spec) -> Clause_Spec {
	return Clause_Spec{kind = .Decide, bind_var = bind_var, target = table_name, fields = args}
}

where_clause :: proc "contextless" (expr: Expr_Spec) -> Clause_Spec {
	return Clause_Spec{kind = .Where, expr = expr, has_expr = true}
}

assert_fact :: proc "contextless" (target: string, fields: []Field_Binding_Spec) -> Action_Spec {
	return Action_Spec{kind = .Assert, target = target, fields = fields}
}

assert_unconditional :: proc "contextless" (target: string, fields: []Field_Binding_Spec) -> Action_Spec {
	return Action_Spec{kind = .Assert, target = target, unconditional = true, fields = fields}
}

retract_fact :: proc "contextless" (var_name: string) -> Action_Spec {
	return Action_Spec{kind = .Retract, expr = vref(var_name)}
}

effect_spec :: proc "contextless" (kind: string, fields: []Field_Binding_Spec) -> Action_Spec {
	return Action_Spec{kind = .Effect, target = kind, fields = fields}
}

@(private)
clone_expr_spec :: proc(alloc: mem.Allocator, e: Expr_Spec) -> (out: Expr_Spec, err: mem.Allocator_Error) {
	out = e
	out.text = strings.clone(e.text, alloc) or_return
	if len(e.children) > 0 {
		ch := make([]Expr_Spec, len(e.children), alloc) or_return
		for c, i in e.children {
			ch[i] = clone_expr_spec(alloc, c) or_return
		}
		out.children = ch
	}
	return out, nil
}

@(private)
clone_field_bindings :: proc(alloc: mem.Allocator, src: []Field_Binding_Spec) -> (out: []Field_Binding_Spec, err: mem.Allocator_Error) {
	if len(src) == 0 {
		return nil, nil
	}
	out = make([]Field_Binding_Spec, len(src), alloc) or_return
	for fb, i in src {
		out[i] = Field_Binding_Spec{
			name = strings.clone(fb.name, alloc) or_return,
			expr = clone_expr_spec(alloc, fb.expr) or_return,
		}
	}
	return out, nil
}

@(private)
clone_clauses :: proc(alloc: mem.Allocator, src: []Clause_Spec) -> (out: []Clause_Spec, err: mem.Allocator_Error) {
	if len(src) == 0 {
		return nil, nil
	}
	out = make([]Clause_Spec, len(src), alloc) or_return
	for c, i in src {
		out[i] = Clause_Spec{
			kind       = c.kind,
			bind_var   = strings.clone(c.bind_var, alloc) or_return,
			target     = strings.clone(c.target, alloc) or_return,
			fields     = clone_field_bindings(alloc, c.fields) or_return,
			children   = clone_clauses(alloc, c.children) or_return,
			expr       = clone_expr_spec(alloc, c.expr) or_return,
			guard_expr = clone_expr_spec(alloc, c.guard_expr) or_return,
			extra_expr = clone_expr_spec(alloc, c.extra_expr) or_return,
			accum_op   = c.accum_op,
			inner_pat  = clone_clauses(alloc, c.inner_pat) or_return,
			has_expr   = c.has_expr,
			has_guard  = c.has_guard,
		}
	}
	return out, nil
}

@(private)
clone_string_slice :: proc(alloc: mem.Allocator, src: []string) -> (out: []string, err: mem.Allocator_Error) {
	if len(src) == 0 {
		return nil, nil
	}
	out = make([]string, len(src), alloc) or_return
	for s, i in src {
		out[i] = strings.clone(s, alloc) or_return
	}
	return out, nil
}

ir_schema :: proc(b: ^Ir_Builder, name: string, fields: []Field_Spec) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	cloned := make([]Field_Spec, len(fields), a) or_return
	for f, i in fields {
		cloned[i] = Field_Spec{
			name     = strings.clone(f.name, a) or_return,
			type     = f.type,
			variants = clone_string_slice(a, f.variants) or_return,
		}
	}
	append(&b.schemas, Schema_Spec_Stored{
		name   = strings.clone(name, a) or_return,
		fields = cloned,
	}) or_return
	return nil
}

ir_source :: proc(b: ^Ir_Builder, name, schema_name, selector: string) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	append(&b.bindings, Binding_Spec_Stored{
		kind        = .Source,
		name        = strings.clone(name, a) or_return,
		schema_name = strings.clone(schema_name, a) or_return,
		selector    = strings.clone(selector, a) or_return,
	}) or_return
	return nil
}

ir_derived :: proc(b: ^Ir_Builder, name, schema_name, selector: string) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	append(&b.bindings, Binding_Spec_Stored{
		kind        = .Derived,
		name        = strings.clone(name, a) or_return,
		schema_name = strings.clone(schema_name, a) or_return,
		selector    = strings.clone(selector, a) or_return,
	}) or_return
	return nil
}

ir_table :: proc(b: ^Ir_Builder, spec: Table_Spec) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	in_c := make([]Table_Col_Spec, len(spec.inputs), a) or_return
	for c, i in spec.inputs {
		in_c[i] = Table_Col_Spec{
			name     = strings.clone(c.name, a) or_return,
			type     = c.type,
			cost     = c.cost,
			variants = clone_string_slice(a, c.variants) or_return,
		}
	}
	out_c := make([]Table_Col_Spec, len(spec.outputs), a) or_return
	for c, i in spec.outputs {
		out_c[i] = Table_Col_Spec{
			name     = strings.clone(c.name, a) or_return,
			type     = c.type,
			cost     = c.cost,
			variants = clone_string_slice(a, c.variants) or_return,
		}
	}
	rows := make([]Table_Row_Spec, len(spec.rows), a) or_return
	for r, ri in spec.rows {
		cells := make([]Expr_Spec, len(r.cells), a) or_return
		for c, ci in r.cells {
			cells[ci] = clone_expr_spec(a, c) or_return
		}
		outs := make([]Expr_Spec, len(r.outputs), a) or_return
		for o, oi in r.outputs {
			outs[oi] = clone_expr_spec(a, o) or_return
		}
		rows[ri] = Table_Row_Spec{
			id      = strings.clone(r.id, a) or_return,
			cells   = cells,
			outputs = outs,
		}
	}
	append(&b.tables, Table_Spec{
		name         = strings.clone(spec.name, a) or_return,
		version      = strings.clone(spec.version, a) or_return,
		hit_policy   = spec.hit_policy,
		verify_flags = spec.verify_flags,
		inputs       = in_c,
		outputs      = out_c,
		rows         = rows,
	}) or_return
	return nil
}

ir_rule :: proc(b: ^Ir_Builder, spec: Rule_Spec) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	acts := make([]Action_Spec, len(spec.then_actions), a) or_return
	for act, i in spec.then_actions {
		acts[i] = Action_Spec{
			kind          = act.kind,
			target        = strings.clone(act.target, a) or_return,
			unconditional = act.unconditional,
			fields        = clone_field_bindings(a, act.fields) or_return,
			expr          = clone_expr_spec(a, act.expr) or_return,
			attr_expr     = clone_expr_spec(a, act.attr_expr) or_return,
			val_expr      = clone_expr_spec(a, act.val_expr) or_return,
		}
	}
	append(&b.rules, Rule_Spec{
		name         = strings.clone(spec.name, a) or_return,
		phase        = strings.clone(spec.phase, a) or_return,
		salience     = spec.salience,
		has_salience = spec.has_salience,
		when_clauses = clone_clauses(a, spec.when_clauses) or_return,
		then_actions = acts,
	}) or_return
	return nil
}

ir_query :: proc(b: ^Ir_Builder, spec: Query_Spec) -> mem.Allocator_Error {
	a := vmem.arena_allocator(&b.arena)
	params := make([]Field_Spec, len(spec.params), a) or_return
	for p, i in spec.params {
		params[i] = Field_Spec{
			name     = strings.clone(p.name, a) or_return,
			type     = p.type,
			variants = clone_string_slice(a, p.variants) or_return,
		}
	}
	append(&b.queries, Query_Spec{
		name         = strings.clone(spec.name, a) or_return,
		params       = params,
		when_clauses = clone_clauses(a, spec.when_clauses) or_return,
	}) or_return
	return nil
}

@(private)
lower_spec_expr :: proc(
	ir: ^Rulebase_IR,
	exprs: ^[dynamic]Expr_IR,
	extra_exprs: ^[dynamic]Expr_Id,
	e: Expr_Spec,
) -> (eid: Expr_Id, err: mem.Allocator_Error) {
	ir_e := Expr_IR{}
	switch e.kind {
	case .Lit_Bool:
		ir_e.kind = .Lit_Bool
		ir_e.bool_val = e.bool_val
	case .Lit_Int:
		ir_e.kind = .Lit_Int
		ir_e.int_val = e.int_val
	case .Lit_Float:
		ir_e.kind = .Lit_Float
		ir_e.float_val = e.float_val
	case .Lit_String:
		ir_e.kind = .Lit_String
		ir_e.str_id = intern(&ir.interner, e.text) or_return
	case .Var:
		ir_e.kind = .Var
		ir_e.str_id = intern(&ir.interner, e.text) or_return
	case .Ident:
		ir_e.kind = .Ident
		ir_e.str_id = intern(&ir.interner, e.text) or_return
	case .Wildcard:
		ir_e.kind = .Wildcard
	case .Unary:
		ir_e.kind = .Unary
		ir_e.unary_op = e.unary_op
		if len(e.children) > 0 {
			ir_e.lhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[0]) or_return
		}
	case .Binary:
		ir_e.kind = .Binary
		ir_e.binary_op = e.binary_op
		if len(e.children) >= 2 {
			ir_e.lhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[0]) or_return
			ir_e.rhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[1]) or_return
		}
	case .Field_Access:
		ir_e.kind = .Field_Access
		ir_e.str_id = intern(&ir.interner, e.text) or_return
		if len(e.children) > 0 {
			ir_e.lhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[0]) or_return
		}
	case .Range:
		ir_e.kind = .Range
		ir_e.inclusive = e.inclusive
		if len(e.children) >= 2 {
			ir_e.lhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[0]) or_return
			ir_e.rhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[1]) or_return
		}
	case .Cell_Cmp:
		ir_e.kind = .Cell_Cmp
		ir_e.binary_op = e.binary_op
		if len(e.children) > 0 {
			ir_e.rhs = lower_spec_expr(ir, exprs, extra_exprs, e.children[0]) or_return
		}
	case .In_List, .Call:
		ir_e.kind = .In_List if e.kind == .In_List else .Call
		if e.kind == .Call {
			ir_e.str_id = intern(&ir.interner, e.text) or_return
		}
		staged := make([]Expr_Id, len(e.children), context.temp_allocator) or_return
		for c, i in e.children {
			staged[i] = lower_spec_expr(ir, exprs, extra_exprs, c) or_return
		}
		start := u32(len(extra_exprs^))
		append(extra_exprs, ..staged) or_return
		ir_e.extra_span = Node_Span{start = start, count = u32(len(staged))}
	}
	eid = Expr_Id(len(exprs^))
	append(exprs, ir_e) or_return
	return eid, nil
}

@(private)
lower_spec_field_bindings :: proc(
	ir: ^Rulebase_IR,
	exprs: ^[dynamic]Expr_IR,
	extra_exprs: ^[dynamic]Expr_Id,
	src: []Field_Binding_Spec,
) -> (out: []Field_Binding_IR, err: mem.Allocator_Error) {
	if len(src) == 0 {
		return nil, nil
	}
	a := vmem.arena_allocator(&ir.arena)
	out = make([]Field_Binding_IR, len(src), a) or_return
	for fb, i in src {
		out[i] = Field_Binding_IR{
			name = intern(&ir.interner, fb.name) or_return,
			expr = lower_spec_expr(ir, exprs, extra_exprs, fb.expr) or_return,
		}
	}
	return out, nil
}

@(private)
lower_spec_clauses :: proc(
	ir: ^Rulebase_IR,
	exprs: ^[dynamic]Expr_IR,
	extra_exprs: ^[dynamic]Expr_Id,
	src: []Clause_Spec,
) -> (out: []Clause_IR, err: mem.Allocator_Error) {
	if len(src) == 0 {
		return nil, nil
	}
	a := vmem.arena_allocator(&ir.arena)
	out = make([]Clause_IR, len(src), a) or_return
	for c, i in src {
		e_id := INVALID_EXPR
		if c.has_expr || c.kind == .Eav || ((c.kind == .Where || c.kind == .Let || c.kind == .Accum) && (c.expr.kind != .Lit_Bool || c.expr.bool_val)) {
			e_id = lower_spec_expr(ir, exprs, extra_exprs, c.expr) or_return
		}
		g_id := INVALID_EXPR
		if c.has_guard || c.kind == .Eav {
			g_id = lower_spec_expr(ir, exprs, extra_exprs, c.guard_expr) or_return
		}
		x_id := INVALID_EXPR
		if c.kind == .Eav {
			x_id = lower_spec_expr(ir, exprs, extra_exprs, c.extra_expr) or_return
		}
		out[i] = Clause_IR{
			kind       = c.kind,
			bind_var   = intern(&ir.interner, c.bind_var) or_return,
			target     = intern(&ir.interner, c.target) or_return,
			fields     = lower_spec_field_bindings(ir, exprs, extra_exprs, c.fields) or_return,
			children   = lower_spec_clauses(ir, exprs, extra_exprs, c.children) or_return,
			expr       = e_id,
			guard_expr = g_id,
			extra_expr = x_id,
			accum_op   = c.accum_op,
			inner_pat  = lower_spec_clauses(ir, exprs, extra_exprs, c.inner_pat) or_return,
		}
	}
	return out, nil
}

@(private)
lower_spec_type_ref :: proc(
	ir: ^Rulebase_IR,
	enums: ^[dynamic]Enum_Def,
	owner_name: String_Id,
	kind: Type_Kind,
	variants: []string,
	alloc: mem.Allocator,
) -> (tr: Type_Ref, err: mem.Allocator_Error) {
	tr.kind = kind
	if kind == .Enum {
		vars: []String_Id
		if len(variants) > 0 {
			vars = make([]String_Id, len(variants), alloc) or_return
			for v, vi in variants {
				vars[vi] = intern(&ir.interner, v) or_return
			}
		}
		tr.ref_id = u32(len(enums^))
		append(enums, Enum_Def{name = owner_name, variants = vars}) or_return
	}
	return tr, nil
}

@(private)
parse_selector_string :: proc(
	ir: ^Rulebase_IR,
	selector: string,
	alloc: mem.Allocator,
) -> (out: []Selector_Segment, err: mem.Allocator_Error) {
	if len(selector) == 0 {
		return nil, nil
	}
	segs := make([dynamic]Selector_Segment, 0, 4, context.temp_allocator)
	i := 0
	for i < len(selector) {
		c := selector[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			i += 1
			continue
		}
		if c == '[' {
			i += 1
			close := strings.index_byte(selector[i:], ']')
			if close < 0 {
				break
			}
			inner := strings.trim_space(selector[i:i + close])
			i = i + close + 1
			if inner == "*" {
				append(&segs, Selector_Segment{kind = .Wildcard})
			} else if len(inner) >= 2 && inner[0] == '"' && inner[len(inner) - 1] == '"' {
				tid := intern(&ir.interner, inner[1:len(inner) - 1]) or_return
				append(&segs, Selector_Segment{kind = .Lit_Key, text = tid})
			} else {
				tid := intern(&ir.interner, inner) or_return
				append(&segs, Selector_Segment{kind = .Var_Key, text = tid})
			}
		} else {
			if c == '.' {
				i += 1
			}
			start := i
			for i < len(selector) {
				sc := selector[i]
				if sc == '.' || sc == '[' || sc == ' ' || sc == '\t' || sc == '\n' || sc == '\r' {
					break
				}
				i += 1
			}
			if i > start {
				tid := intern(&ir.interner, selector[start:i]) or_return
				append(&segs, Selector_Segment{kind = .Field, text = tid})
			}
		}
	}
	if len(segs) == 0 {
		return nil, nil
	}
	out = make([]Selector_Segment, len(segs), alloc) or_return
	copy(out, segs[:])
	return out, nil
}

@(require_results)
ir_builder_build :: proc(
	b: ^Ir_Builder,
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ir: Rulebase_IR, err: mem.Allocator_Error) {
	_ = diags
	scope := telemetry_span_begin(telemetry, .Ir_Lower, "ir_builder_build")
	defer telemetry_span_end(telemetry, scope)

	vmem.arena_init_growing(&ir.arena) or_return
	defer if err != nil {
		ir_destroy(&ir)
	}
	interner_init(&ir.interner, allocator) or_return
	a := vmem.arena_allocator(&ir.arena)

	ir.module_name = intern(&ir.interner, b.module_name) or_return
	ir.module_version = intern(&ir.interner, b.module_version) or_return

	enums := make([dynamic]Enum_Def, 0, 8, context.temp_allocator) or_return
	exprs := make([dynamic]Expr_IR, 0, 64, context.temp_allocator) or_return
	extra_exprs := make([dynamic]Expr_Id, 0, 32, context.temp_allocator) or_return
	append(&exprs, Expr_IR{kind = .Invalid}) or_return

	ir.schemas = make([]Schema_Def, len(b.schemas), a) or_return
	for s, si in b.schemas {
		fields := make([]Field_Def, len(s.fields), a) or_return
		for f, fi in s.fields {
			fid := intern(&ir.interner, f.name) or_return
			tr := lower_spec_type_ref(&ir, &enums, fid, f.type, f.variants, a) or_return
			fields[fi] = Field_Def{name = fid, type = tr}
		}
		ir.schemas[si] = Schema_Def{name = intern(&ir.interner, s.name) or_return, fields = fields}
	}

	ir.bindings = make([]Binding_Def, len(b.bindings), a) or_return
	for bind, bi in b.bindings {
		ir.bindings[bi] = Binding_Def{
			kind        = bind.kind,
			name        = intern(&ir.interner, bind.name) or_return,
			schema_name = intern(&ir.interner, bind.schema_name) or_return,
			schema_id   = Schema_Id(INVALID_ID),
			segments    = parse_selector_string(&ir, bind.selector, a) or_return,
		}
	}

	ir.tables = make([]Table_Def, len(b.tables), a) or_return
	for t, ti in b.tables {
		inputs := make([]Table_Col_Def, len(t.inputs), a) or_return
		for c, ci in t.inputs {
			cid := intern(&ir.interner, c.name) or_return
			tr := lower_spec_type_ref(&ir, &enums, cid, c.type, c.variants, a) or_return
			inputs[ci] = Table_Col_Def{name = cid, type = tr, cost = c.cost}
		}
		outputs := make([]Table_Col_Def, len(t.outputs), a) or_return
		for c, ci in t.outputs {
			cid := intern(&ir.interner, c.name) or_return
			tr := lower_spec_type_ref(&ir, &enums, cid, c.type, c.variants, a) or_return
			outputs[ci] = Table_Col_Def{name = cid, type = tr, cost = c.cost}
		}
		rows := make([]Table_Row_Def, len(t.rows), a) or_return
		for r, ri in t.rows {
			cells := make([]Expr_Id, len(r.cells), a) or_return
			for c, ci in r.cells {
				cells[ci] = lower_spec_expr(&ir, &exprs, &extra_exprs, c) or_return
			}
			outs := make([]Expr_Id, len(r.outputs), a) or_return
			for o, oi in r.outputs {
				outs[oi] = lower_spec_expr(&ir, &exprs, &extra_exprs, o) or_return
			}
			rows[ri] = Table_Row_Def{id = intern(&ir.interner, r.id) or_return, cells = cells, outputs = outs}
		}
		ir.tables[ti] = Table_Def{
			name         = intern(&ir.interner, t.name) or_return,
			version      = intern(&ir.interner, t.version) or_return,
			hit_policy   = t.hit_policy,
			verify_flags = t.verify_flags,
			inputs       = inputs,
			outputs      = outputs,
			rows         = rows,
		}
	}

	ir.rules = make([]Rule_Def, len(b.rules), a) or_return
	for r, ri in b.rules {
		acts := make([]Action_IR, len(r.then_actions), a) or_return
		for act, ai in r.then_actions {
			e_id := INVALID_EXPR
			a_id := INVALID_EXPR
			v_id := INVALID_EXPR
			if act.kind == .Retract || act.kind == .Assert_Eav {
				e_id = lower_spec_expr(&ir, &exprs, &extra_exprs, act.expr) or_return
			}
			if act.kind == .Assert_Eav {
				a_id = lower_spec_expr(&ir, &exprs, &extra_exprs, act.attr_expr) or_return
				v_id = lower_spec_expr(&ir, &exprs, &extra_exprs, act.val_expr) or_return
			}
			acts[ai] = Action_IR{
				kind          = act.kind,
				target        = intern(&ir.interner, act.target) or_return,
				unconditional = act.unconditional,
				fields        = lower_spec_field_bindings(&ir, &exprs, &extra_exprs, act.fields) or_return,
				expr          = e_id,
				attr_expr     = a_id,
				val_expr      = v_id,
			}
		}
		ir.rules[ri] = Rule_Def{
			name         = intern(&ir.interner, r.name) or_return,
			phase        = intern(&ir.interner, r.phase) or_return,
			salience     = r.salience,
			has_salience = r.has_salience,
			when_clauses = lower_spec_clauses(&ir, &exprs, &extra_exprs, r.when_clauses) or_return,
			then_actions = acts,
		}
	}

	ir.queries = make([]Query_Def, len(b.queries), a) or_return
	for q, qi in b.queries {
		params := make([]Query_Param_Def, len(q.params), a) or_return
		for p, pi in q.params {
			pid := intern(&ir.interner, p.name) or_return
			ptr := lower_spec_type_ref(&ir, &enums, pid, p.type, p.variants, a) or_return
			params[pi] = Query_Param_Def{name = pid, type = ptr}
		}
		ir.queries[qi] = Query_Def{
			name         = intern(&ir.interner, q.name) or_return,
			params       = params,
			when_clauses = lower_spec_clauses(&ir, &exprs, &extra_exprs, q.when_clauses) or_return,
		}
	}

	if len(enums) > 0 {
		ir.enums = make([]Enum_Def, len(enums), a) or_return
		copy(ir.enums, enums[:])
	}
	ir.exprs = make([]Expr_IR, len(exprs), a) or_return
	copy(ir.exprs, exprs[:])
	if len(extra_exprs) > 0 {
		ir.extra_exprs = make([]Expr_Id, len(extra_exprs), a) or_return
		copy(ir.extra_exprs, extra_exprs[:])
	}
	analyze_ir(&ir, diags, telemetry) or_return
	return ir, nil
}
