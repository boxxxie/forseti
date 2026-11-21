package forseti

import "core:mem"

Node_Span :: struct {
	start: u32,
	count: u32,
}

Ast_Lit_Bool :: struct {
	val: bool,
}

Ast_Lit_Int :: struct {
	val: i64,
}

Ast_Lit_Float :: struct {
	val: f64,
}

Ast_Lit_String :: struct {
	str: String_Id,
}

Ast_Var :: struct {
	name: String_Id,
}

Ast_Ident :: struct {
	name: String_Id,
}

Ast_Wildcard :: struct {}

Ast_Unary :: struct {
	op:      Unary_Op,
	operand: Node_Id,
}

Ast_Binary :: struct {
	op:  Binary_Op,
	lhs: Node_Id,
	rhs: Node_Id,
}

Ast_Field_Access :: struct {
	base:  Node_Id,
	field: String_Id,
}

Ast_Range :: struct {
	inclusive: bool,
	lo:        Node_Id,
	hi:        Node_Id,
}

Ast_In_List :: struct {
	items: Node_Span,
}

Ast_Cell_Cmp :: struct {
	op:  Binary_Op,
	rhs: Node_Id,
}

Ast_Call :: struct {
	callee: String_Id,
	args:   Node_Span,
}

Ast_Error :: struct {}

Ast_Payload :: union {
	Ast_Lit_Bool,
	Ast_Lit_Int,
	Ast_Lit_Float,
	Ast_Lit_String,
	Ast_Var,
	Ast_Ident,
	Ast_Wildcard,
	Ast_Unary,
	Ast_Binary,
	Ast_Field_Access,
	Ast_Range,
	Ast_In_List,
	Ast_Cell_Cmp,
	Ast_Call,
	Ast_Error,
}

Ast_Node :: struct {
	span:    Span,
	payload: Ast_Payload,
}
#assert(size_of(Ast_Node) <= 32)

Ast_Type_Spec :: struct {
	kind:          Type_Kind,
	enum_variants: Node_Span, // Slice into pool.enum_variants
	span:          Span,
}

Ast_Schema_Field :: struct {
	name: String_Id,
	type: Ast_Type_Spec,
	span: Span,
}

Ast_Schema_Decl :: struct {
	name:   String_Id,
	fields: Node_Span, // Slice into pool.schema_fields
	span:   Span,
}

Ast_Selector_Seg_Kind :: enum u8 {
	Field,
	Var_Key,
	Lit_Key,
	Wildcard,
}

Ast_Selector_Seg :: struct {
	kind: Ast_Selector_Seg_Kind,
	text: String_Id,
	span: Span,
}

Ast_Binding_Decl :: struct {
	kind:        Binding_Kind,
	name:        String_Id,
	schema_name: String_Id,
	segs:        Node_Span, // Slice into pool.selector_segs
	span:        Span,
}

Ast_Table_Col :: struct {
	name: String_Id,
	type: Ast_Type_Spec,
	cost: u32,
	span: Span,
}

Ast_Table_Row :: struct {
	id:      String_Id,
	cells:   Node_Span, // Slice into pool.extra_children
	outputs: Node_Span, // Slice into pool.extra_children
	span:    Span,
}

Ast_Table_Decl :: struct {
	name:         String_Id,
	version:      String_Id,
	hit_policy:   Hit_Policy,
	verify_flags: Table_Verify_Flags,
	inputs:       Node_Span, // Slice into pool.table_cols
	outputs:      Node_Span, // Slice into pool.table_cols
	rows:         Node_Span, // Slice into pool.table_rows
	span:         Span,
}

Ast_Field_Assign :: struct {
	name: String_Id,
	expr: Node_Id,
	span: Span,
}

Ast_Clause_Kind :: enum u8 {
	Pattern,
	Eav,
	Not,
	Exists,
	Accum,
	Decide,
	Where,
	Let,
	Error,
}

Ast_Clause :: struct {
	kind:       Ast_Clause_Kind,
	bind_var:   String_Id,
	target:     String_Id,
	fields:     Node_Span, // Slice into pool.field_assigns (Pattern/Decide)
	children:   Node_Span, // Slice into pool.clauses (Not/Exists)
	expr:       Node_Id,   // Where/Let/Accum expr or EAV entity
	guard_expr: Node_Id,   // Accum where guard, or EAV attr
	extra_expr: Node_Id,   // EAV value
	accum_op:   Accum_Op,
	inner_pat:  Node_Span, // Slice (0 or 1) into pool.clauses for Accum source pattern
	span:       Span,
}

Ast_Action_Kind :: enum u8 {
	Assert,
	Assert_Eav,
	Retract,
	Effect,
	Error,
}

Ast_Action :: struct {
	kind:          Ast_Action_Kind,
	target:        String_Id, // Schema/Binding name or Effect kind
	unconditional: bool,
	fields:        Node_Span, // Slice into pool.field_assigns
	expr:          Node_Id,   // Retract var or EAV entity
	attr_expr:     Node_Id,   // EAV attr
	val_expr:      Node_Id,   // EAV value
	span:          Span,
}

Ast_Rule_Decl :: struct {
	name:         String_Id,
	phase:        String_Id,
	salience:     i32,
	has_salience: bool,
	when_clauses: Node_Span, // Slice into pool.clauses
	then_actions: Node_Span, // Slice into pool.actions
	span:         Span,
}

Ast_Query_Decl :: struct {
	name:         String_Id,
	params:       Node_Span, // Slice into pool.query_params
	when_clauses: Node_Span, // Slice into pool.clauses
	span:         Span,
}

Ast_Pool :: struct {
	module_name:    String_Id,
	module_version: String_Id,
	module_span:    Span,

	nodes:          [dynamic]Ast_Node,
	extra_children: [dynamic]Node_Id,
	enum_variants:  [dynamic]String_Id,
	schema_fields:  [dynamic]Ast_Schema_Field,
	schemas:        [dynamic]Ast_Schema_Decl,
	selector_segs:  [dynamic]Ast_Selector_Seg,
	bindings:       [dynamic]Ast_Binding_Decl,
	table_cols:     [dynamic]Ast_Table_Col,
	table_rows:     [dynamic]Ast_Table_Row,
	tables:         [dynamic]Ast_Table_Decl,
	field_assigns:  [dynamic]Ast_Field_Assign,
	clauses:        [dynamic]Ast_Clause,
	actions:        [dynamic]Ast_Action,
	rules:          [dynamic]Ast_Rule_Decl,
	query_params:   [dynamic]Ast_Schema_Field,
	queries:        [dynamic]Ast_Query_Decl,
}

@(require_results)
ast_pool_init :: proc(
	pool: ^Ast_Pool,
	allocator := context.allocator,
) -> (err: mem.Allocator_Error) {
	pool^ = {}
	defer if err != nil {
		ast_pool_destroy(pool)
	}

	pool.nodes = make([dynamic]Ast_Node, 0, 256, allocator) or_return
	pool.extra_children = make([dynamic]Node_Id, 0, 128, allocator) or_return
	pool.enum_variants = make([dynamic]String_Id, 0, 16, allocator) or_return
	pool.schema_fields = make([dynamic]Ast_Schema_Field, 0, 32, allocator) or_return
	pool.schemas = make([dynamic]Ast_Schema_Decl, 0, 16, allocator) or_return
	pool.selector_segs = make([dynamic]Ast_Selector_Seg, 0, 32, allocator) or_return
	pool.bindings = make([dynamic]Ast_Binding_Decl, 0, 16, allocator) or_return
	pool.table_cols = make([dynamic]Ast_Table_Col, 0, 32, allocator) or_return
	pool.table_rows = make([dynamic]Ast_Table_Row, 0, 64, allocator) or_return
	pool.tables = make([dynamic]Ast_Table_Decl, 0, 16, allocator) or_return
	pool.field_assigns = make([dynamic]Ast_Field_Assign, 0, 64, allocator) or_return
	pool.clauses = make([dynamic]Ast_Clause, 0, 64, allocator) or_return
	pool.actions = make([dynamic]Ast_Action, 0, 32, allocator) or_return
	pool.rules = make([dynamic]Ast_Rule_Decl, 0, 32, allocator) or_return
	pool.query_params = make([dynamic]Ast_Schema_Field, 0, 16, allocator) or_return
	pool.queries = make([dynamic]Ast_Query_Decl, 0, 16, allocator) or_return

	append(&pool.nodes, Ast_Node{}) or_return // Index 0 = INVALID_NODE
	return nil
}

ast_pool_destroy :: proc(pool: ^Ast_Pool) {
	delete(pool.queries)
	delete(pool.query_params)
	delete(pool.rules)
	delete(pool.actions)
	delete(pool.clauses)
	delete(pool.field_assigns)
	delete(pool.tables)
	delete(pool.table_rows)
	delete(pool.table_cols)
	delete(pool.bindings)
	delete(pool.selector_segs)
	delete(pool.schemas)
	delete(pool.schema_fields)
	delete(pool.enum_variants)
	delete(pool.extra_children)
	delete(pool.nodes)
	pool^ = {}
}

@(require_results)
ast_add_node :: proc(pool: ^Ast_Pool, node: Ast_Node) -> (id: Node_Id, err: mem.Allocator_Error) {
	id = Node_Id(len(pool.nodes))
	append(&pool.nodes, node) or_return
	return id, nil
}

@(require_results)
ast_add_children :: proc(pool: ^Ast_Pool, children: []Node_Id) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.extra_children))
	append(&pool.extra_children, ..children) or_return
	return Node_Span{start = start, count = u32(len(children))}, nil
}

@(private)
ast_add_enum_variants :: proc(pool: ^Ast_Pool, items: []String_Id) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.enum_variants))
	append(&pool.enum_variants, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_schema_fields :: proc(pool: ^Ast_Pool, items: []Ast_Schema_Field) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.schema_fields))
	append(&pool.schema_fields, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_selector_segs :: proc(pool: ^Ast_Pool, items: []Ast_Selector_Seg) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.selector_segs))
	append(&pool.selector_segs, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_table_cols :: proc(pool: ^Ast_Pool, items: []Ast_Table_Col) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.table_cols))
	append(&pool.table_cols, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_table_rows :: proc(pool: ^Ast_Pool, items: []Ast_Table_Row) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.table_rows))
	append(&pool.table_rows, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_field_assigns :: proc(pool: ^Ast_Pool, items: []Ast_Field_Assign) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.field_assigns))
	append(&pool.field_assigns, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_clauses :: proc(pool: ^Ast_Pool, items: []Ast_Clause) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.clauses))
	append(&pool.clauses, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_actions :: proc(pool: ^Ast_Pool, items: []Ast_Action) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.actions))
	append(&pool.actions, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}

@(private)
ast_add_query_params :: proc(pool: ^Ast_Pool, items: []Ast_Schema_Field) -> (span: Node_Span, err: mem.Allocator_Error) {
	start := u32(len(pool.query_params))
	append(&pool.query_params, ..items) or_return
	return Node_Span{start = start, count = u32(len(items))}, nil
}
