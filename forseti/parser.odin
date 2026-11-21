package forseti

import "core:mem"
import "core:strconv"
import "core:strings"

MAX_PARSE_DEPTH :: #config(MAX_PARSE_DEPTH, 256)

Parsed_Ast :: struct {
	pool:        Ast_Pool,
	interner:    String_Interner,
	line_starts: [dynamic]u32,
	src:         string,
}

parsed_ast_destroy :: proc(pa: ^Parsed_Ast) {
	delete(pa.line_starts)
	interner_destroy(&pa.interner)
	ast_pool_destroy(&pa.pool)
	pa^ = {}
}

@(private)
Binding_Power :: struct {
	left:  u8,
	right: u8,
}

@(rodata, private)
infix_bp := #partial [Token_Kind]Binding_Power{
	.Kw_Or       = {10, 11},
	.Kw_And      = {20, 21},
	.Eq_Eq       = {30, 31},
	.Bang_Eq     = {30, 31},
	.Lt          = {40, 41},
	.Lt_Eq       = {40, 41},
	.Gt          = {40, 41},
	.Gt_Eq       = {40, 41},
	.Dot_Dot     = {45, 46},
	.Dot_Dot_Eq  = {45, 46},
	.Plus        = {50, 51},
	.Minus       = {50, 51},
	.Star        = {60, 61},
	.Slash       = {60, 61},
	.Percent     = {60, 61},
}

@(private)
Parser :: struct {
	src:         string,
	tokens:      []Token,
	pos:         int,
	depth:       int,
	line_starts: []u32,
	pool:        ^Ast_Pool,
	interner:    ^String_Interner,
	diags:       ^Diagnostic_List,
	telemetry:   ^Telemetry_Sink,
}

@(private)
peek :: proc "contextless" (p: ^Parser, offset := 0) -> Token {
	idx := p.pos + offset
	if idx >= len(p.tokens) {
		return p.tokens[len(p.tokens) - 1]
	}
	return p.tokens[idx]
}

@(private)
advance :: proc "contextless" (p: ^Parser) -> Token {
	tok := peek(p)
	if tok.kind != .EOF {
		p.pos += 1
	}
	return tok
}

@(private)
lexeme :: proc "contextless" (p: ^Parser, tok: Token) -> string {
	start := int(tok.span.offset)
	end := start + int(tok.span.len)
	if start < 0 || end > len(p.src) || start > end {
		return ""
	}
	return p.src[start:end]
}

@(private)
report_parse_error :: proc(
	p: ^Parser,
	span: Span,
	code: Diag_Code,
	msg: string,
	hint: string = "",
) -> mem.Allocator_Error {
	return diag_add(p.diags, p.line_starts, code, .Error, span, msg, hint, p.telemetry)
}

@(private)
expect_token :: proc(p: ^Parser, kind: Token_Kind, msg: string) -> (tok: Token, ok: bool, err: mem.Allocator_Error) {
	cur := peek(p)
	if cur.kind == kind {
		return advance(p), true, nil
	}
	report_parse_error(p, cur.span, .E1002, msg) or_return
	return cur, false, nil
}

@(private)
is_decl_start :: proc "contextless" (kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Kw_Module, .Kw_Schema, .Kw_Source, .Kw_Derived, .Kw_Table, .Kw_Rule, .Kw_Query:
		return true
	}
	return false
}

@(private)
sync_to_top_level :: proc "contextless" (p: ^Parser) {
	for {
		k := peek(p).kind
		if k == .EOF || is_decl_start(k) {
			return
		}
		if k == .RBrace {
			_ = advance(p)
			if is_decl_start(peek(p).kind) || peek(p).kind == .EOF {
				return
			}
			continue
		}
		_ = advance(p)
	}
}

@(private)
sync_in_block :: proc "contextless" (p: ^Parser) {
	for {
		k := peek(p).kind
		if k == .EOF || k == .RBrace || is_decl_start(k) {
			return
		}
		if k == .Semicolon {
			_ = advance(p)
			return
		}
		_ = advance(p)
	}
}

@(private)
decode_string_token :: proc(p: ^Parser, tok: Token) -> (id: String_Id, err: mem.Allocator_Error) {
	raw := lexeme(p, tok)
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"' {
		inner := raw[1:len(raw) - 1]
		if !strings.contains_any(inner, `\`) {
			return intern(p.interner, inner)
		}
		b: strings.Builder
		strings.builder_init(&b, context.temp_allocator) or_return
		for i := 0; i < len(inner); i += 1 {
			if inner[i] == '\\' && i + 1 < len(inner) {
				i += 1
				switch inner[i] {
				case '"':
					strings.write_byte(&b, '"')
				case '\\':
					strings.write_byte(&b, '\\')
				case 'n':
					strings.write_byte(&b, '\n')
				case 't':
					strings.write_byte(&b, '\t')
				case 'r':
					strings.write_byte(&b, '\r')
				case '0':
					strings.write_byte(&b, 0)
				case:
					strings.write_byte(&b, inner[i])
				}
			} else {
				strings.write_byte(&b, inner[i])
			}
		}
		return intern(p.interner, strings.to_string(b))
	}
	return EMPTY_STRING, nil
}

@(private)
parse_int_literal :: proc(p: ^Parser, tok: Token) -> (val: i64, ok: bool) {
	raw := lexeme(p, tok)
	clean, _ := strings.remove_all(raw, "_", context.temp_allocator)
	return strconv.parse_i64(clean)
}

@(private)
parse_float_literal :: proc(p: ^Parser, tok: Token) -> (val: f64, ok: bool) {
	raw := lexeme(p, tok)
	clean, _ := strings.remove_all(raw, "_", context.temp_allocator)
	return strconv.parse_f64(clean)
}

@(private)
token_to_binop :: proc "contextless" (kind: Token_Kind) -> Binary_Op {
	#partial switch kind {
	case .Plus:
		return .Add
	case .Minus:
		return .Sub
	case .Star:
		return .Mul
	case .Slash:
		return .Div
	case .Percent:
		return .Mod
	case .Eq_Eq:
		return .Eq
	case .Bang_Eq:
		return .Neq
	case .Lt:
		return .Lt
	case .Lt_Eq:
		return .Lte
	case .Gt:
		return .Gt
	case .Gt_Eq:
		return .Gte
	case .Kw_And:
		return .And
	case .Kw_Or:
		return .Or
	}
	return .Add
}

@(private)
parse_prefix :: proc(p: ^Parser) -> (id: Node_Id, err: mem.Allocator_Error) {
	tok := peek(p)
	#partial switch tok.kind {
	case .LParen:
		_ = advance(p)
		inner := parse_expr(p, 0) or_return
		if peek(p).kind == .RParen {
			close_tok := advance(p)
			p.pool.nodes[inner].span = merge_spans(tok.span, close_tok.span)
		} else {
			report_parse_error(p, peek(p).span, .E1002, "expected ')' after expression") or_return
		}
		return inner, nil
	case .Minus, .Kw_Not, .Bang:
		_ = advance(p)
		operand := parse_expr(p, 55) or_return
		op := Unary_Op.Neg if tok.kind == .Minus else Unary_Op.Not
		span := merge_spans(tok.span, p.pool.nodes[operand].span)
		return ast_add_node(p.pool, Ast_Node{span = span, payload = Ast_Unary{op = op, operand = operand}})
	case .Kw_True:
		_ = advance(p)
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Lit_Bool{val = true}})
	case .Kw_False:
		_ = advance(p)
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Lit_Bool{val = false}})
	case .Int:
		_ = advance(p)
		val, ok := parse_int_literal(p, tok)
		if !ok {
			report_parse_error(p, tok.span, .E1002, "invalid integer literal") or_return
			return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Error{}})
		}
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Lit_Int{val = val}})
	case .Float:
		_ = advance(p)
		val, ok := parse_float_literal(p, tok)
		if !ok {
			report_parse_error(p, tok.span, .E1002, "invalid float literal") or_return
			return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Error{}})
		}
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Lit_Float{val = val}})
	case .String:
		_ = advance(p)
		str_id := decode_string_token(p, tok) or_return
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Lit_String{str = str_id}})
	case .Var:
		_ = advance(p)
		name_id := intern(p.interner, lexeme(p, tok)) or_return
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Var{name = name_id}})
	case .Ident:
		_ = advance(p)
		name_id := intern(p.interner, lexeme(p, tok)) or_return
		if peek(p).kind == .LParen {
			_ = advance(p)
			args := make([dynamic]Node_Id, 0, 8, context.temp_allocator)
			for peek(p).kind != .RParen && peek(p).kind != .EOF {
				arg := parse_expr(p, 0) or_return
				append(&args, arg)
				if peek(p).kind == .Comma {
					_ = advance(p)
				} else {
					break
				}
			}
			end_span := tok.span
			if peek(p).kind == .RParen {
				end_span = advance(p).span
			} else {
				report_parse_error(p, peek(p).span, .E1002, "expected ')' after call arguments") or_return
			}
			args_span := ast_add_children(p.pool, args[:]) or_return
			return ast_add_node(p.pool, Ast_Node{
				span    = merge_spans(tok.span, end_span),
				payload = Ast_Call{callee = name_id, args = args_span},
			})
		}
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Ident{name = name_id}})
	case:
		if tok.kind != .EOF {
			_ = advance(p)
		}
		report_parse_error(p, tok.span, .E1002, "expected expression") or_return
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Error{}})
	}
}

@(private)
parse_postfix :: proc(p: ^Parser, lhs_in: Node_Id) -> (id: Node_Id, err: mem.Allocator_Error) {
	lhs := lhs_in
	for peek(p).kind == .Dot {
		_ = advance(p)
		field_tok := peek(p)
		if field_tok.kind == .Ident {
			_ = advance(p)
			field_id := intern(p.interner, lexeme(p, field_tok)) or_return
			span := merge_spans(p.pool.nodes[lhs].span, field_tok.span)
			lhs = ast_add_node(p.pool, Ast_Node{
				span    = span,
				payload = Ast_Field_Access{base = lhs, field = field_id},
			}) or_return
		} else {
			report_parse_error(p, field_tok.span, .E1002, "expected field name after '.'") or_return
			if field_tok.kind != .EOF {
				_ = advance(p)
			}
			return ast_add_node(p.pool, Ast_Node{span = field_tok.span, payload = Ast_Error{}})
		}
	}
	return lhs, nil
}

@(private)
parse_expr :: proc(p: ^Parser, min_bp: u8 = 0) -> (id: Node_Id, err: mem.Allocator_Error) {
	if p.depth >= MAX_PARSE_DEPTH {
		tok := peek(p)
		if tok.kind != .EOF {
			_ = advance(p)
		}
		report_parse_error(p, tok.span, .E1003, "maximum expression nesting depth exceeded") or_return
		return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Error{}})
	}
	p.depth += 1
	defer p.depth -= 1

	lhs := parse_prefix(p) or_return
	lhs = parse_postfix(p, lhs) or_return

	for {
		op_tok := peek(p)
		bp := infix_bp[op_tok.kind]
		if bp.left == 0 || bp.left < min_bp {
			break
		}
		_ = advance(p)
		rhs := parse_expr(p, bp.right) or_return
		span := merge_spans(p.pool.nodes[lhs].span, p.pool.nodes[rhs].span)
		if op_tok.kind == .Dot_Dot || op_tok.kind == .Dot_Dot_Eq {
			lhs = ast_add_node(p.pool, Ast_Node{
				span    = span,
				payload = Ast_Range{inclusive = op_tok.kind == .Dot_Dot_Eq, lo = lhs, hi = rhs},
			}) or_return
		} else {
			lhs = ast_add_node(p.pool, Ast_Node{
				span    = span,
				payload = Ast_Binary{op = token_to_binop(op_tok.kind), lhs = lhs, rhs = rhs},
			}) or_return
		}
	}
	return lhs, nil
}

@(private)
parse_type_spec :: proc(p: ^Parser) -> (spec: Ast_Type_Spec, ok: bool, err: mem.Allocator_Error) {
	tok := peek(p)
	if tok.kind == .Kw_Enum {
		_ = advance(p)
		_, lp_ok := expect_token(p, .LParen, "expected '(' after 'enum'") or_return
		if !lp_ok {
			return {}, false, nil
		}
		variants := make([dynamic]String_Id, 0, 8, context.temp_allocator)
		for peek(p).kind != .RParen && peek(p).kind != .EOF {
			vtok := peek(p)
			if vtok.kind == .String {
				_ = advance(p)
				vid := decode_string_token(p, vtok) or_return
				append(&variants, vid)
			} else if vtok.kind == .Ident {
				_ = advance(p)
				vid := intern(p.interner, lexeme(p, vtok)) or_return
				append(&variants, vid)
			} else {
				report_parse_error(p, vtok.span, .E1002, "expected enum variant string or identifier") or_return
				if vtok.kind != .EOF {
					_ = advance(p)
				}
				break
			}
			if peek(p).kind == .Comma {
				_ = advance(p)
			} else {
				break
			}
		}
		end_span := tok.span
		if peek(p).kind == .RParen {
			end_span = advance(p).span
		} else {
			report_parse_error(p, peek(p).span, .E1002, "expected ')' after enum variants") or_return
		}
		ev_span := ast_add_enum_variants(p.pool, variants[:]) or_return
		return Ast_Type_Spec{kind = .Enum, enum_variants = ev_span, span = merge_spans(tok.span, end_span)}, true, nil
	}

	if tok.kind != .Ident {
		report_parse_error(p, tok.span, .E1002, "expected type name") or_return
		return {}, false, nil
	}
	_ = advance(p)
	name := lexeme(p, tok)
	kind: Type_Kind
	switch name {
	case "bool":
		kind = .Bool
	case "i32":
		kind = .I32
	case "i64":
		kind = .I64
	case "f64":
		kind = .F64
	case "string":
		kind = .String
	case "entity":
		kind = .Entity
	case "time":
		kind = .Time
	case:
		report_parse_error(p, tok.span, .E1002, "unknown schema field type", "supported types: bool, i32, i64, f64, string, entity, time, enum(...)") or_return
		return {}, false, nil
	}
	return Ast_Type_Spec{kind = kind, span = tok.span}, true, nil
}

@(private)
parse_module_decl :: proc(p: ^Parser) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected module name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	p.pool.module_name = intern(p.interner, lexeme(p, name_tok)) or_return
	end_span := name_tok.span
	if peek(p).kind == .Kw_Version {
		_ = advance(p)
		ver_tok, ver_ok := expect_token(p, .String, "expected version string after 'version'") or_return
		if ver_ok {
			p.pool.module_version = decode_string_token(p, ver_tok) or_return
			end_span = ver_tok.span
		}
	}
	p.pool.module_span = merge_spans(kw.span, end_span)
	return nil
}

@(private)
parse_schema_decl :: proc(p: ^Parser) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected schema name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	name_id := intern(p.interner, lexeme(p, name_tok)) or_return
	_, lb_ok := expect_token(p, .LBrace, "expected '{' after schema name") or_return
	if !lb_ok {
		sync_to_top_level(p)
		return nil
	}

	fields := make([dynamic]Ast_Schema_Field, 0, 8, context.temp_allocator)
	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		ftok := peek(p)
		if ftok.kind != .Ident {
			report_parse_error(p, ftok.span, .E1002, "expected field name in schema") or_return
			_ = advance(p)
			continue
		}
		_ = advance(p)
		_, col_ok := expect_token(p, .Colon, "expected ':' after field name") or_return
		if !col_ok {
			sync_in_block(p)
			continue
		}
		tspec, t_ok := parse_type_spec(p) or_return
		if t_ok {
			fid := intern(p.interner, lexeme(p, ftok)) or_return
			append(&fields, Ast_Schema_Field{
				name = fid,
				type = tspec,
				span = merge_spans(ftok.span, tspec.span),
			})
		}
		if peek(p).kind == .Comma || peek(p).kind == .Semicolon {
			_ = advance(p)
		}
	}

	end_span := name_tok.span
	if peek(p).kind == .RBrace {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing schema") or_return
	}

	fspan := ast_add_schema_fields(p.pool, fields[:]) or_return
	append(&p.pool.schemas, Ast_Schema_Decl{
		name   = name_id,
		fields = fspan,
		span   = merge_spans(kw.span, end_span),
	}) or_return
	return nil
}

@(private)
parse_binding_decl :: proc(p: ^Parser, kind: Binding_Kind) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected binding name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	name_id := intern(p.interner, lexeme(p, name_tok)) or_return
	schema_id := name_id
	if peek(p).kind == .Colon {
		_ = advance(p)
		sc_tok, sc_ok := expect_token(p, .Ident, "expected schema name after ':'") or_return
		if sc_ok {
			schema_id = intern(p.interner, lexeme(p, sc_tok)) or_return
		}
	}
	_, at_ok := expect_token(p, .Kw_At, "expected 'at' in binding declaration") or_return
	if !at_ok {
		sync_to_top_level(p)
		return nil
	}

	segs := make([dynamic]Ast_Selector_Seg, 0, 4, context.temp_allocator)
	end_span := name_tok.span
	for {
		cur := peek(p)
		if cur.kind == .Dot {
			_ = advance(p)
			ftok := peek(p)
			if ftok.kind == .Ident {
				_ = advance(p)
				tid := intern(p.interner, lexeme(p, ftok)) or_return
				seg_span := merge_spans(cur.span, ftok.span)
				append(&segs, Ast_Selector_Seg{kind = .Field, text = tid, span = seg_span})
				end_span = seg_span
			} else {
				report_parse_error(p, ftok.span, .E1002, "expected identifier after '.' in selector") or_return
				break
			}
		} else if cur.kind == .LBracket {
			_ = advance(p)
			inner := peek(p)
			seg := Ast_Selector_Seg{span = cur.span}
			#partial switch inner.kind {
			case .Var:
				_ = advance(p)
				seg.kind = .Var_Key
				seg.text = intern(p.interner, lexeme(p, inner)) or_return
			case .String:
				_ = advance(p)
				seg.kind = .Lit_Key
				seg.text = decode_string_token(p, inner) or_return
			case .Star:
				_ = advance(p)
				seg.kind = .Wildcard
			case:
				report_parse_error(p, inner.span, .E1002, "expected ?var, string literal, or '*' inside selector [...]") or_return
				if inner.kind != .EOF && inner.kind != .RBracket {
					_ = advance(p)
				}
			}
			rb := peek(p)
			if rb.kind == .RBracket {
				end_span = advance(p).span
				seg.span = merge_spans(cur.span, end_span)
			} else {
				report_parse_error(p, rb.span, .E1002, "expected ']' closing selector segment") or_return
			}
			append(&segs, seg)
		} else {
			break
		}
	}

	if len(segs) == 0 {
		report_parse_error(p, peek(p).span, .E1002, "expected xitdb selector path starting with '.' or '['") or_return
	}

	sspan := ast_add_selector_segs(p.pool, segs[:]) or_return
	append(&p.pool.bindings, Ast_Binding_Decl{
		kind        = kind,
		name        = name_id,
		schema_name = schema_id,
		segs        = sspan,
		span        = merge_spans(kw.span, end_span),
	}) or_return
	return nil
}

@(private)
parse_hit_policy :: proc(word: string) -> (policy: Hit_Policy, ok: bool) {
	switch word {
	case "First", "F":
		return .First, true
	case "Unique", "U":
		return .Unique, true
	case "Any", "A":
		return .Any, true
	case "Priority", "P":
		return .Priority, true
	case "Collect", "C":
		return .Collect, true
	case "Collect_Sum", "CollectSum":
		return .Collect_Sum, true
	case "Collect_Min", "CollectMin":
		return .Collect_Min, true
	case "Collect_Max", "CollectMax":
		return .Collect_Max, true
	case "Collect_Count", "CollectCount":
		return .Collect_Count, true
	case "Merge", "M":
		return .Merge, true
	case "Reverse_Merge", "ReverseMerge", "R":
		return .Reverse_Merge, true
	}
	return .First, false
}

@(private)
is_cell_delim :: proc "contextless" (kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Pipe, .Double_Pipe, .Semicolon, .RBrace, .EOF:
		return true
	}
	return false
}

@(private)
parse_table_cell_atom :: proc(p: ^Parser) -> (id: Node_Id, err: mem.Allocator_Error) {
	tok := peek(p)
	if tok.kind == .Minus {
		next := peek(p, 1)
		if is_cell_delim(next.kind) || next.kind == .Kw_And || next.kind == .Kw_Or {
			_ = advance(p)
			return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Wildcard{}})
		}
	}

	#partial switch tok.kind {
	case .Eq_Eq, .Bang_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		_ = advance(p)
		rhs := parse_expr(p, 25) or_return
		return ast_add_node(p.pool, Ast_Node{
			span    = merge_spans(tok.span, p.pool.nodes[rhs].span),
			payload = Ast_Cell_Cmp{op = token_to_binop(tok.kind), rhs = rhs},
		})
	case .Kw_In:
		_ = advance(p)
		_, lp_ok := expect_token(p, .LParen, "expected '(' after 'in'") or_return
		if !lp_ok {
			return ast_add_node(p.pool, Ast_Node{span = tok.span, payload = Ast_Error{}})
		}
		items := make([dynamic]Node_Id, 0, 8, context.temp_allocator)
		for peek(p).kind != .RParen && peek(p).kind != .EOF {
			item := parse_expr(p, 0) or_return
			append(&items, item)
			if peek(p).kind == .Comma {
				_ = advance(p)
			} else {
				break
			}
		}
		end_span := tok.span
		if peek(p).kind == .RParen {
			end_span = advance(p).span
		} else {
			report_parse_error(p, peek(p).span, .E1002, "expected ')' after 'in' list") or_return
		}
		ispan := ast_add_children(p.pool, items[:]) or_return
		return ast_add_node(p.pool, Ast_Node{
			span    = merge_spans(tok.span, end_span),
			payload = Ast_In_List{items = ispan},
		})
	}

	return parse_expr(p, 25)
}

@(private)
parse_table_cell :: proc(p: ^Parser) -> (id: Node_Id, err: mem.Allocator_Error) {
	lhs := parse_table_cell_atom(p) or_return
	for peek(p).kind == .Kw_And || peek(p).kind == .Kw_Or {
		op_tok := advance(p)
		rhs := parse_table_cell_atom(p) or_return
		span := merge_spans(p.pool.nodes[lhs].span, p.pool.nodes[rhs].span)
		lhs = ast_add_node(p.pool, Ast_Node{
			span    = span,
			payload = Ast_Binary{op = token_to_binop(op_tok.kind), lhs = lhs, rhs = rhs},
		}) or_return
	}
	return lhs, nil
}

@(private)
parse_table_cols_block :: proc(p: ^Parser, is_input: bool) -> (cols: [dynamic]Ast_Table_Col, err: mem.Allocator_Error) {
	cols = make([dynamic]Ast_Table_Col, 0, 8, context.temp_allocator)
	_, lb_ok := expect_token(p, .LBrace, "expected '{' in table column block") or_return
	if !lb_ok {
		return cols, nil
	}
	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		ntok := peek(p)
		if ntok.kind != .Ident {
			report_parse_error(p, ntok.span, .E1002, "expected column name") or_return
			_ = advance(p)
			continue
		}
		_ = advance(p)
		_, col_ok := expect_token(p, .Colon, "expected ':' after column name") or_return
		if !col_ok {
			sync_in_block(p)
			continue
		}
		tspec, t_ok := parse_type_spec(p) or_return
		cost: u32 = 1
		end_span := tspec.span
		if is_input && peek(p).kind == .Kw_Cost {
			_ = advance(p)
			ctok := peek(p)
			if ctok.kind == .Int {
				_ = advance(p)
				cval, cok := parse_int_literal(p, ctok)
				if cok && cval >= 0 {
					cost = u32(cval)
				} else {
					report_parse_error(p, ctok.span, .E1002, "cost must be a non-negative integer") or_return
				}
				end_span = ctok.span
			} else {
				report_parse_error(p, ctok.span, .E1002, "expected integer after 'cost'") or_return
			}
		}
		if t_ok {
			cid := intern(p.interner, lexeme(p, ntok)) or_return
			append(&cols, Ast_Table_Col{
				name = cid,
				type = tspec,
				cost = cost,
				span = merge_spans(ntok.span, end_span),
			})
		}
		if peek(p).kind == .Comma || peek(p).kind == .Semicolon {
			_ = advance(p)
		}
	}
	if peek(p).kind == .RBrace {
		_ = advance(p)
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing table column block") or_return
	}
	return cols, nil
}

@(private)
parse_table_rows_block :: proc(p: ^Parser) -> (rows: [dynamic]Ast_Table_Row, err: mem.Allocator_Error) {
	rows = make([dynamic]Ast_Table_Row, 0, 16, context.temp_allocator)
	_, lb_ok := expect_token(p, .LBrace, "expected '{' after 'rows'") or_return
	if !lb_ok {
		return rows, nil
	}

	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		row_start := peek(p)
		row_id := EMPTY_STRING
		if row_start.kind == .Ident && peek(p, 1).kind == .Colon {
			_ = advance(p)
			_ = advance(p)
			row_id = intern(p.interner, lexeme(p, row_start)) or_return
		} else {
			report_parse_error(
				p,
				row_start.span,
				.E1005,
				"decision table row must begin with '<row_id>:'",
				"example: r1: >= 100 | true || \"approve\";",
			) or_return
		}

		cells := make([dynamic]Node_Id, 0, 8, context.temp_allocator)
		outs := make([dynamic]Node_Id, 0, 4, context.temp_allocator)

		for peek(p).kind != .RBrace && peek(p).kind != .EOF && peek(p).kind != .Semicolon {
			cell := parse_table_cell(p) or_return
			append(&cells, cell)
			if peek(p).kind == .Pipe {
				_ = advance(p)
				continue
			}
			break
		}

		if peek(p).kind == .Double_Pipe {
			_ = advance(p)
			for peek(p).kind != .RBrace && peek(p).kind != .EOF && peek(p).kind != .Semicolon {
				out_expr: Node_Id
				cur := peek(p)
				next := peek(p, 1)
				if cur.kind == .Minus && (next.kind == .Pipe || next.kind == .Semicolon || next.kind == .RBrace || next.kind == .EOF) {
					_ = advance(p)
					out_expr = ast_add_node(p.pool, Ast_Node{span = cur.span, payload = Ast_Wildcard{}}) or_return
				} else {
					out_expr = parse_expr(p, 0) or_return
				}
				append(&outs, out_expr)
				if peek(p).kind == .Pipe {
					_ = advance(p)
					continue
				}
				break
			}
		} else if peek(p).kind != .Semicolon && peek(p).kind != .RBrace && peek(p).kind != .EOF {
			report_parse_error(p, peek(p).span, .E1002, "expected '||' separating inputs from outputs in table row") or_return
			sync_in_block(p)
		}

		end_span := row_start.span
		if peek(p).kind == .Semicolon {
			end_span = advance(p).span
		} else if len(outs) > 0 {
			end_span = p.pool.nodes[outs[len(outs) - 1]].span
		} else if len(cells) > 0 {
			end_span = p.pool.nodes[cells[len(cells) - 1]].span
		}

		cspan := ast_add_children(p.pool, cells[:]) or_return
		ospan := ast_add_children(p.pool, outs[:]) or_return
		append(&rows, Ast_Table_Row{
			id      = row_id,
			cells   = cspan,
			outputs = ospan,
			span    = merge_spans(row_start.span, end_span),
		})

		if peek(p).kind != .RBrace && peek(p).kind != .EOF && peek(p).kind != .Ident {
			if peek(p).kind == .Semicolon {
				_ = advance(p)
			}
		}
	}

	if peek(p).kind == .RBrace {
		_ = advance(p)
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing table rows") or_return
	}
	return rows, nil
}

@(private)
parse_table_decl :: proc(p: ^Parser) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected table name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	name_id := intern(p.interner, lexeme(p, name_tok)) or_return
	ver_id := EMPTY_STRING
	hit_policy := Hit_Policy.First
	verify_flags: Table_Verify_Flags

	if peek(p).kind == .Kw_Version {
		_ = advance(p)
		vtok, vok := expect_token(p, .String, "expected table version string") or_return
		if vok {
			ver_id = decode_string_token(p, vtok) or_return
		}
	}

	if peek(p).kind == .Kw_Hit {
		_ = advance(p)
		htok := peek(p)
		if htok.kind == .Ident {
			_ = advance(p)
			hp, hok := parse_hit_policy(lexeme(p, htok))
			if hok {
				hit_policy = hp
			} else {
				report_parse_error(p, htok.span, .E1004, "unknown decision table hit policy", "supported: First, Unique, Any, Priority, Collect, Merge, Reverse_Merge") or_return
			}
		} else {
			report_parse_error(p, htok.span, .E1004, "expected hit policy name after 'hit'") or_return
		}
	}

	if peek(p).kind == .Kw_Verify {
		_ = advance(p)
		_, lp_ok := expect_token(p, .LParen, "expected '(' after 'verify'") or_return
		if lp_ok {
			for peek(p).kind != .RParen && peek(p).kind != .EOF {
				ftok := peek(p)
				if ftok.kind == .Ident {
					_ = advance(p)
					switch lexeme(p, ftok) {
					case "complete":
						verify_flags += {.Complete}
					case "no_overlap":
						verify_flags += {.No_Overlap}
					case "no_dead_rules":
						verify_flags += {.No_Dead_Rules}
					case "strict":
						verify_flags += {.Strict}
					case:
						report_parse_error(p, ftok.span, .E1002, "unknown table verify option") or_return
					}
				} else {
					report_parse_error(p, ftok.span, .E1002, "expected verify option name") or_return
					_ = advance(p)
				}
				if peek(p).kind == .Comma {
					_ = advance(p)
				} else {
					break
				}
			}
			if peek(p).kind == .RParen {
				_ = advance(p)
			} else {
				report_parse_error(p, peek(p).span, .E1002, "expected ')' after verify options") or_return
			}
		}
	}

	_, lb_ok := expect_token(p, .LBrace, "expected '{' opening table body") or_return
	if !lb_ok {
		sync_to_top_level(p)
		return nil
	}

	in_cols := make([dynamic]Ast_Table_Col, 0, 8, context.temp_allocator)
	out_cols := make([dynamic]Ast_Table_Col, 0, 4, context.temp_allocator)
	rows := make([dynamic]Ast_Table_Row, 0, 16, context.temp_allocator)

	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		sec := peek(p)
		#partial switch sec.kind {
		case .Kw_Inputs:
			_ = advance(p)
			parsed_in := parse_table_cols_block(p, true) or_return
			append(&in_cols, ..parsed_in[:])
		case .Kw_Outputs:
			_ = advance(p)
			parsed_out := parse_table_cols_block(p, false) or_return
			append(&out_cols, ..parsed_out[:])
		case .Kw_Rows:
			_ = advance(p)
			parsed_rows := parse_table_rows_block(p) or_return
			append(&rows, ..parsed_rows[:])
		case:
			report_parse_error(p, sec.span, .E1002, "expected 'inputs', 'outputs', or 'rows' in table body") or_return
			_ = advance(p)
		}
	}

	end_span := name_tok.span
	if peek(p).kind == .RBrace {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing table declaration") or_return
	}

	in_span := ast_add_table_cols(p.pool, in_cols[:]) or_return
	out_span := ast_add_table_cols(p.pool, out_cols[:]) or_return
	r_span := ast_add_table_rows(p.pool, rows[:]) or_return
	append(&p.pool.tables, Ast_Table_Decl{
		name         = name_id,
		version      = ver_id,
		hit_policy   = hit_policy,
		verify_flags = verify_flags,
		inputs       = in_span,
		outputs      = out_span,
		rows         = r_span,
		span         = merge_spans(kw.span, end_span),
	}) or_return
	return nil
}

@(private)
parse_field_assigns :: proc(p: ^Parser, open_kind, close_kind: Token_Kind) -> (span: Node_Span, end_span: Span, ok: bool, err: mem.Allocator_Error) {
	open_tok := peek(p)
	if open_tok.kind != open_kind {
		report_parse_error(p, open_tok.span, .E1002, "expected opening delimiter for field list") or_return
		return {}, open_tok.span, false, nil
	}
	_ = advance(p)

	assigns := make([dynamic]Ast_Field_Assign, 0, 8, context.temp_allocator)
	for peek(p).kind != close_kind && peek(p).kind != .EOF {
		ftok := peek(p)
		if ftok.kind != .Ident {
			report_parse_error(p, ftok.span, .E1002, "expected field name") or_return
			_ = advance(p)
			continue
		}
		_ = advance(p)
		_, col_ok := expect_token(p, .Colon, "expected ':' after field name") or_return
		if !col_ok {
			if peek(p).kind != close_kind && peek(p).kind != .EOF {
				_ = advance(p)
			}
			continue
		}
		val := parse_expr(p, 0) or_return
		fid := intern(p.interner, lexeme(p, ftok)) or_return
		append(&assigns, Ast_Field_Assign{
			name = fid,
			expr = val,
			span = merge_spans(ftok.span, p.pool.nodes[val].span),
		})
		if peek(p).kind == .Comma {
			_ = advance(p)
		} else {
			break
		}
	}

	end_span = open_tok.span
	if peek(p).kind == close_kind {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected closing delimiter for field list") or_return
	}
	fspan := ast_add_field_assigns(p.pool, assigns[:]) or_return
	return fspan, end_span, true, nil
}

@(private)
parse_accum_op :: proc(word: string) -> (op: Accum_Op, ok: bool) {
	switch word {
	case "count":
		return .Count, true
	case "sum":
		return .Sum, true
	case "min":
		return .Min, true
	case "max":
		return .Max, true
	case "avg":
		return .Avg, true
	case "distinct":
		return .Distinct, true
	case "collect":
		return .Collect, true
	}
	return .Count, false
}

@(private)
parse_eav_triple :: proc(p: ^Parser) -> (e, a, v: Node_Id, end_span: Span, err: mem.Allocator_Error) {
	lb := advance(p) // '['
	e = parse_expr(p, 0) or_return
	_, _ = expect_token(p, .Comma, "expected ',' after EAV entity") or_return
	a = parse_expr(p, 0) or_return
	_, _ = expect_token(p, .Comma, "expected ',' after EAV attribute") or_return
	v = parse_expr(p, 0) or_return
	end_span = lb.span
	if peek(p).kind == .RBracket {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected ']' closing EAV triple") or_return
	}
	return e, a, v, end_span, nil
}

@(private)
parse_clause :: proc(p: ^Parser) -> (cl: Ast_Clause, err: mem.Allocator_Error) {
	if p.depth >= MAX_PARSE_DEPTH {
		tok := peek(p)
		if tok.kind != .EOF {
			_ = advance(p)
		}
		report_parse_error(p, tok.span, .E1003, "maximum clause nesting depth exceeded") or_return
		return Ast_Clause{kind = .Error, span = tok.span}, nil
	}
	p.depth += 1
	defer p.depth -= 1

	first := peek(p)

	if first.kind == .Var && peek(p, 1).kind == .Colon_Eq {
		var_tok := advance(p)
		_ = advance(p) // ':='
		bind_id := intern(p.interner, lexeme(p, var_tok)) or_return

		rhs := peek(p)
		if rhs.kind == .Kw_Decide {
			_ = advance(p)
			t_tok, t_ok := expect_token(p, .Ident, "expected decision table name after 'decide'") or_return
			if !t_ok {
				return Ast_Clause{kind = .Error, span = merge_spans(var_tok.span, t_tok.span)}, nil
			}
			fspan, end_span, _ := parse_field_assigns(p, .LParen, .RParen) or_return
			tid := intern(p.interner, lexeme(p, t_tok)) or_return
			return Ast_Clause{
				kind     = .Decide,
				bind_var = bind_id,
				target   = tid,
				fields   = fspan,
				span     = merge_spans(var_tok.span, end_span),
			}, nil
		}

		if rhs.kind == .Ident {
			if acc_op, is_acc := parse_accum_op(lexeme(p, rhs)); is_acc && peek(p, 1).kind == .LParen {
				_ = advance(p) // op
				_ = advance(p) // '('
				agg_expr := parse_expr(p, 0) or_return
				if peek(p).kind == .RParen {
					_ = advance(p)
				} else {
					report_parse_error(p, peek(p).span, .E1002, "expected ')' after accumulator expression") or_return
				}
				_, from_ok := expect_token(p, .Kw_From, "expected 'from' after accumulator") or_return
				inner_pat := make([dynamic]Ast_Clause, 0, 1, context.temp_allocator)
				end_span := rhs.span
				if from_ok {
					pat_cl := parse_clause(p) or_return
					append(&inner_pat, pat_cl)
					end_span = pat_cl.span
				}
				guard := INVALID_NODE
				if peek(p).kind == .Kw_Where {
					_ = advance(p)
					guard = parse_expr(p, 0) or_return
					end_span = p.pool.nodes[guard].span
				}
				ip_span := ast_add_clauses(p.pool, inner_pat[:]) or_return
				return Ast_Clause{
					kind       = .Accum,
					bind_var   = bind_id,
					accum_op   = acc_op,
					expr       = agg_expr,
					inner_pat  = ip_span,
					guard_expr = guard,
					span       = merge_spans(var_tok.span, end_span),
				}, nil
			}

			if peek(p, 1).kind == .LParen {
				t_tok := advance(p)
				fspan, end_span, _ := parse_field_assigns(p, .LParen, .RParen) or_return
				tid := intern(p.interner, lexeme(p, t_tok)) or_return
				return Ast_Clause{
					kind     = .Pattern,
					bind_var = bind_id,
					target   = tid,
					fields   = fspan,
					span     = merge_spans(var_tok.span, end_span),
				}, nil
			}
		}

		if rhs.kind == .LBracket {
			e, a, v, end_span := parse_eav_triple(p) or_return
			return Ast_Clause{
				kind       = .Eav,
				bind_var   = bind_id,
				expr       = e,
				guard_expr = a,
				extra_expr = v,
				span       = merge_spans(var_tok.span, end_span),
			}, nil
		}

		let_expr := parse_expr(p, 0) or_return
		return Ast_Clause{
			kind     = .Let,
			bind_var = bind_id,
			expr     = let_expr,
			span     = merge_spans(var_tok.span, p.pool.nodes[let_expr].span),
		}, nil
	}

	#partial switch first.kind {
	case .Kw_Where:
		_ = advance(p)
		wexpr := parse_expr(p, 0) or_return
		return Ast_Clause{
			kind = .Where,
			expr = wexpr,
			span = merge_spans(first.span, p.pool.nodes[wexpr].span),
		}, nil
	case .Kw_Not, .Kw_Exists:
		_ = advance(p)
		ckind := Ast_Clause_Kind.Not if first.kind == .Kw_Not else Ast_Clause_Kind.Exists
		children := make([dynamic]Ast_Clause, 0, 4, context.temp_allocator)
		end_span := first.span
		if peek(p).kind == .LBrace || peek(p).kind == .LParen {
			open_k := peek(p).kind
			close_k := Token_Kind.RBrace if open_k == .LBrace else Token_Kind.RParen
			_ = advance(p)
			for peek(p).kind != close_k && peek(p).kind != .EOF {
				child := parse_clause(p) or_return
				append(&children, child)
				if peek(p).kind == .Comma || peek(p).kind == .Semicolon {
					_ = advance(p)
				}
			}
			if peek(p).kind == close_k {
				end_span = advance(p).span
			} else {
				report_parse_error(p, peek(p).span, .E1002, "expected closing delimiter in negation/exists block") or_return
			}
		} else {
			child := parse_clause(p) or_return
			append(&children, child)
			end_span = child.span
		}
		cspan := ast_add_clauses(p.pool, children[:]) or_return
		return Ast_Clause{
			kind     = ckind,
			children = cspan,
			span     = merge_spans(first.span, end_span),
		}, nil
	case .Kw_Decide:
		_ = advance(p)
		t_tok, t_ok := expect_token(p, .Ident, "expected decision table name after 'decide'") or_return
		if !t_ok {
			return Ast_Clause{kind = .Error, span = merge_spans(first.span, t_tok.span)}, nil
		}
		fspan, end_span, _ := parse_field_assigns(p, .LParen, .RParen) or_return
		tid := intern(p.interner, lexeme(p, t_tok)) or_return
		return Ast_Clause{
			kind   = .Decide,
			target = tid,
			fields = fspan,
			span   = merge_spans(first.span, end_span),
		}, nil
	case .LBracket:
		e, a, v, end_span := parse_eav_triple(p) or_return
		return Ast_Clause{
			kind       = .Eav,
			expr       = e,
			guard_expr = a,
			extra_expr = v,
			span       = merge_spans(first.span, end_span),
		}, nil
	case .Ident:
		if peek(p, 1).kind == .LParen {
			t_tok := advance(p)
			fspan, end_span, _ := parse_field_assigns(p, .LParen, .RParen) or_return
			tid := intern(p.interner, lexeme(p, t_tok)) or_return
			return Ast_Clause{
				kind   = .Pattern,
				target = tid,
				fields = fspan,
				span   = merge_spans(first.span, end_span),
			}, nil
		}
	}

	if first.kind != .EOF {
		_ = advance(p)
	}
	report_parse_error(p, first.span, .E1002, "expected rule 'when' clause") or_return
	return Ast_Clause{kind = .Error, span = first.span}, nil
}

@(private)
parse_clause_block :: proc(p: ^Parser) -> (span: Node_Span, end_span: Span, err: mem.Allocator_Error) {
	lb, lb_ok := expect_token(p, .LBrace, "expected '{' opening clause block") or_return
	if !lb_ok {
		return {}, lb.span, nil
	}
	clauses := make([dynamic]Ast_Clause, 0, 8, context.temp_allocator)
	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		cl := parse_clause(p) or_return
		append(&clauses, cl)
		if peek(p).kind == .Comma || peek(p).kind == .Semicolon {
			_ = advance(p)
		}
	}
	end_span = lb.span
	if peek(p).kind == .RBrace {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing clause block") or_return
	}
	cspan := ast_add_clauses(p.pool, clauses[:]) or_return
	return cspan, end_span, nil
}

@(private)
parse_effect_action :: proc(p: ^Parser) -> (act: Ast_Action, err: mem.Allocator_Error) {
	kw := advance(p) // 'effect'
	kind_tok, kind_ok := expect_token(p, .String, "expected effect kind string after 'effect'") or_return
	kind_id := EMPTY_STRING
	if kind_ok {
		kind_id = decode_string_token(p, kind_tok) or_return
	}
	fspan, end_span, _ := parse_field_assigns(p, .LBrace, .RBrace) or_return
	return Ast_Action{
		kind   = .Effect,
		target = kind_id,
		fields = fspan,
		span   = merge_spans(kw.span, end_span),
	}, nil
}

@(private)
parse_rule_decl :: proc(p: ^Parser) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected rule name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	name_id := intern(p.interner, lexeme(p, name_tok)) or_return
	phase_id := EMPTY_STRING
	salience: i32 = 0
	has_salience := false

	for peek(p).kind == .Kw_Phase || peek(p).kind == .Kw_Salience {
		if peek(p).kind == .Kw_Phase {
			_ = advance(p)
			ptok, pok := expect_token(p, .String, "expected phase string after 'phase'") or_return
			if pok {
				phase_id = decode_string_token(p, ptok) or_return
			}
		} else {
			_ = advance(p)
			neg := false
			if peek(p).kind == .Minus {
				_ = advance(p)
				neg = true
			}
			stok := peek(p)
			if stok.kind == .Int {
				_ = advance(p)
				sval, sok := parse_int_literal(p, stok)
				if sok {
					salience = i32(-sval if neg else sval)
					has_salience = true
				} else {
					report_parse_error(p, stok.span, .E1002, "invalid salience integer") or_return
				}
			} else {
				report_parse_error(p, stok.span, .E1002, "expected integer after 'salience'") or_return
			}
		}
	}

	_, lb_ok := expect_token(p, .LBrace, "expected '{' opening rule body") or_return
	if !lb_ok {
		sync_to_top_level(p)
		return nil
	}

	when_span: Node_Span
	actions := make([dynamic]Ast_Action, 0, 8, context.temp_allocator)
	for peek(p).kind != .RBrace && peek(p).kind != .EOF {
		sec := peek(p)
		#partial switch sec.kind {
		case .Kw_When:
			_ = advance(p)
			when_span, _ = parse_clause_block(p) or_return
		case .Kw_Then:
			_ = advance(p)
			_, tb_ok := expect_token(p, .LBrace, "expected '{' after 'then'") or_return
			if !tb_ok {
				continue
			}
			for peek(p).kind != .RBrace && peek(p).kind != .EOF {
				ak := peek(p)
				#partial switch ak.kind {
				case .Kw_Assert, .Kw_Assert_Bang:
					_ = advance(p)
					uncond := ak.kind == .Kw_Assert_Bang
					if peek(p).kind == .LBracket {
						e, a, v, end_span := parse_eav_triple(p) or_return
						if peek(p).kind == .Kw_Unconditional {
							_ = advance(p)
							uncond = true
						}
						append(&actions, Ast_Action{
							kind          = .Assert_Eav,
							unconditional = uncond,
							expr          = e,
							attr_expr     = a,
							val_expr      = v,
							span          = merge_spans(ak.span, end_span),
						})
					} else {
						t_tok, t_ok := expect_token(p, .Ident, "expected schema or derived name after 'assert'") or_return
						if !t_ok {
							sync_in_block(p)
							continue
						}
						fspan, end_span, _ := parse_field_assigns(p, .LParen, .RParen) or_return
						if peek(p).kind == .Kw_Unconditional {
							end_span = advance(p).span
							uncond = true
						}
						tid := intern(p.interner, lexeme(p, t_tok)) or_return
						append(&actions, Ast_Action{
							kind          = .Assert,
							target        = tid,
							unconditional = uncond,
							fields        = fspan,
							span          = merge_spans(ak.span, end_span),
						})
					}
				case .Kw_Retract:
					_ = advance(p)
					rexpr := parse_expr(p, 0) or_return
					append(&actions, Ast_Action{
						kind = .Retract,
						expr = rexpr,
						span = merge_spans(ak.span, p.pool.nodes[rexpr].span),
					})
				case .Kw_Effect:
					eff := parse_effect_action(p) or_return
					append(&actions, eff)
				case:
					report_parse_error(p, ak.span, .E1002, "expected 'assert', 'assert!', 'retract', or 'effect' inside 'then'") or_return
					_ = advance(p)
				}
				if peek(p).kind == .Semicolon {
					_ = advance(p)
				}
			}
			if peek(p).kind == .RBrace {
				_ = advance(p)
			} else {
				report_parse_error(p, peek(p).span, .E1002, "expected '}' closing 'then' block") or_return
			}
		case .Kw_Effect:
			eff := parse_effect_action(p) or_return
			append(&actions, eff)
		case:
			report_parse_error(p, sec.span, .E1002, "expected 'when', 'then', or 'effect' in rule body") or_return
			_ = advance(p)
		}
	}

	end_span := name_tok.span
	if peek(p).kind == .RBrace {
		end_span = advance(p).span
	} else {
		report_parse_error(p, peek(p).span, .E1002, "expected '}' closing rule declaration") or_return
	}

	aspan := ast_add_actions(p.pool, actions[:]) or_return
	append(&p.pool.rules, Ast_Rule_Decl{
		name         = name_id,
		phase        = phase_id,
		salience     = salience,
		has_salience = has_salience,
		when_clauses = when_span,
		then_actions = aspan,
		span         = merge_spans(kw.span, end_span),
	}) or_return
	return nil
}

@(private)
parse_query_decl :: proc(p: ^Parser) -> mem.Allocator_Error {
	kw := advance(p)
	name_tok, name_ok := expect_token(p, .Ident, "expected query name") or_return
	if !name_ok {
		sync_to_top_level(p)
		return nil
	}
	name_id := intern(p.interner, lexeme(p, name_tok)) or_return

	params := make([dynamic]Ast_Schema_Field, 0, 4, context.temp_allocator)
	if peek(p).kind == .LParen {
		_ = advance(p)
		for peek(p).kind != .RParen && peek(p).kind != .EOF {
			ptok := peek(p)
			if ptok.kind != .Ident && ptok.kind != .Var {
				report_parse_error(p, ptok.span, .E1002, "expected query parameter name") or_return
				_ = advance(p)
				continue
			}
			_ = advance(p)
			_, col_ok := expect_token(p, .Colon, "expected ':' after query parameter") or_return
			if !col_ok {
				break
			}
			tspec, t_ok := parse_type_spec(p) or_return
			if t_ok {
				pname := lexeme(p, ptok)
				if strings.has_prefix(pname, "?") {
					pname = pname[1:]
				}
				pid := intern(p.interner, pname) or_return
				append(&params, Ast_Schema_Field{
					name = pid,
					type = tspec,
					span = merge_spans(ptok.span, tspec.span),
				})
			}
			if peek(p).kind == .Comma {
				_ = advance(p)
			} else {
				break
			}
		}
		if peek(p).kind == .RParen {
			_ = advance(p)
		} else {
			report_parse_error(p, peek(p).span, .E1002, "expected ')' after query parameters") or_return
		}
	}

	when_span, end_span := parse_clause_block(p) or_return
	pspan := ast_add_query_params(p.pool, params[:]) or_return
	append(&p.pool.queries, Ast_Query_Decl{
		name         = name_id,
		params       = pspan,
		when_clauses = when_span,
		span         = merge_spans(kw.span, end_span),
	}) or_return
	return nil
}

@(require_results)
parse_source_to_ast :: proc(
	src: string,
	source_name: string = "",
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (pa: Parsed_Ast, err: mem.Allocator_Error) {
	_ = source_name
	pa.src = src
	ast_pool_init(&pa.pool, allocator) or_return
	defer if err != nil {
		parsed_ast_destroy(&pa)
	}
	interner_init(&pa.interner, allocator) or_return

	tokens := lex_all(src, allocator, diags, telemetry, &pa.line_starts) or_return
	defer delete(tokens)

	scope := telemetry_span_begin(telemetry, .Parse, "parse")
	defer telemetry_span_end(telemetry, scope)

	p := Parser{
		src         = src,
		tokens      = tokens[:],
		line_starts = pa.line_starts[:],
		pool        = &pa.pool,
		interner    = &pa.interner,
		diags       = diags,
		telemetry   = telemetry,
	}

	for peek(&p).kind != .EOF {
		tok := peek(&p)
		#partial switch tok.kind {
		case .Kw_Module:
			parse_module_decl(&p) or_return
		case .Kw_Schema:
			parse_schema_decl(&p) or_return
		case .Kw_Source:
			parse_binding_decl(&p, .Source) or_return
		case .Kw_Derived:
			parse_binding_decl(&p, .Derived) or_return
		case .Kw_Table:
			parse_table_decl(&p) or_return
		case .Kw_Rule:
			parse_rule_decl(&p) or_return
		case .Kw_Query:
			parse_query_decl(&p) or_return
		case:
			_ = advance(&p)
			report_parse_error(&p, tok.span, .E1002, "expected top-level declaration ('module', 'schema', 'source', 'derived', 'table', 'rule', 'query')") or_return
			sync_to_top_level(&p)
		}
	}

	telemetry_count_add(telemetry, .Ast_Nodes, u64(len(pa.pool.nodes)))
	return pa, nil
}
