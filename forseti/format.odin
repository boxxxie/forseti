package forseti

import "core:mem"
import "core:strings"

@(private)
_Fmt_Item_Kind :: enum u8 {
	Token,
	Line_Comment,
	Block_Comment,
}

@(private)
_Fmt_Item :: struct {
	kind:      _Fmt_Item_Kind,
	tok:       Token,
	text:      string,
	same_line: bool,
	had_blank: bool,
}

@(private)
_Fmt_Row :: struct {
	is_comment:    bool,
	comment_text:  string,
	valid:         bool,
	row_id:        string,
	inputs:        [dynamic]string,
	outputs:       [dynamic]string,
	raw_fallback:  string,
	trailing_note: string,
}

@(private)
_count_newlines :: proc "contextless" (s: string) -> int {
	n := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			n += 1
		}
	}
	return n
}

@(private)
_extract_gap_trivia :: proc(
	items: ^[dynamic]_Fmt_Item,
	src: string,
	gap_start: int,
	gap_end: int,
) -> mem.Allocator_Error {
	if gap_start >= gap_end {
		return nil
	}
	i := gap_start
	seg_start := gap_start
	for i < gap_end {
		b := src[i]
		if b == '/' && i + 1 < gap_end && src[i + 1] == '/' {
			gap := src[seg_start:i]
			nls := _count_newlines(gap)
			c_start := i
			i += 2
			for i < gap_end && src[i] != '\n' {
				i += 1
			}
			ctext := strings.trim_right(src[c_start:i], "\r ")
			append(items, _Fmt_Item{
				kind      = .Line_Comment,
				text      = ctext,
				same_line = nls == 0 && len(items^) > 0,
				had_blank = nls >= 2,
			}) or_return
			seg_start = i
			continue
		}
		if b == '/' && i + 1 < gap_end && src[i + 1] == '*' {
			gap := src[seg_start:i]
			nls := _count_newlines(gap)
			c_start := i
			i += 2
			for i + 1 < gap_end && !(src[i] == '*' && src[i + 1] == '/') {
				i += 1
			}
			if i + 1 < gap_end {
				i += 2
			} else {
				i = gap_end
			}
			append(items, _Fmt_Item{
				kind      = .Block_Comment,
				text      = src[c_start:i],
				same_line = nls == 0 && len(items^) > 0,
				had_blank = nls >= 2,
			}) or_return
			seg_start = i
			continue
		}
		i += 1
	}
	return nil
}

@(private)
_itemize_source :: proc(src: string, alloc: mem.Allocator) -> (items: [dynamic]_Fmt_Item, err: mem.Allocator_Error) {
	diags: Diagnostic_List
	diag_list_init(&diags, alloc) or_return
	defer diag_list_destroy(&diags)

	toks := lex_all(src, alloc, &diags) or_return
	defer delete(toks)

	items = make([dynamic]_Fmt_Item, 0, len(toks) + 8, alloc) or_return
	defer if err != nil {
		delete(items)
	}

	prev_end := 0
	for tok in toks {
		tok_off := int(tok.span.offset)
		_extract_gap_trivia(&items, src, prev_end, tok_off) or_return
		if tok.kind == .EOF {
			break
		}
		tail_gap := src[prev_end:tok_off]
		// Check gap only after the last emitted trivia item in this gap.
		if len(items) > 0 && items[len(items) - 1].kind != .Token {
			// Find offset after last trivia item by scanning backwards from tok_off.
			last_txt := items[len(items) - 1].text
			last_end := int(uintptr(raw_data(last_txt)) - uintptr(raw_data(src))) + len(last_txt)
			if last_end >= prev_end && last_end <= tok_off {
				tail_gap = src[last_end:tok_off]
			}
		}
		nls := _count_newlines(tail_gap)
		append(&items, _Fmt_Item{
			kind      = .Token,
			tok       = tok,
			text      = src[tok_off:tok_off + int(tok.span.len)],
			same_line = nls == 0 && len(items) > 0,
			had_blank = nls >= 2,
		}) or_return
		prev_end = tok_off + int(tok.span.len)
	}
	return items, nil
}

@(private)
_is_value_like_token :: proc "contextless" (k: Token_Kind) -> bool {
	#partial switch k {
	case .Ident, .Var, .Int, .Float, .String, .RParen, .RBracket, .Kw_True, .Kw_False:
		return true
	}
	return false
}

@(private)
_is_top_decl_kw :: proc "contextless" (k: Token_Kind) -> bool {
	#partial switch k {
	case .Kw_Module, .Kw_Import, .Kw_Schema, .Kw_Enum, .Kw_Source, .Kw_Derived, .Kw_Table, .Kw_Rule, .Kw_Query:
		return true
	}
	return false
}

@(private)
_is_unary_minus :: proc "contextless" (prev: Token_Kind, has_prev: bool, next_tok: Token_Kind, has_next: bool) -> bool {
	if !has_prev || !_is_value_like_token(prev) {
		if has_next && (next_tok == .Int || next_tok == .Float || next_tok == .LParen || next_tok == .Var || next_tok == .Ident) {
			return true
		}
	}
	return false
}

@(private)
_needs_token_space :: proc "contextless" (
	prev: Token_Kind,
	cur: Token_Kind,
	prev_unary_minus: bool,
	in_binding_header: bool,
	prev_is_at_selector_dot: bool,
) -> bool {
	if prev == .EOF || cur == .EOF {
		return false
	}
	if prev_unary_minus {
		return false
	}
	if prev == .LParen || prev == .LBracket || prev == .Dot || prev == .Dot_Dot || prev == .Dot_Dot_Eq {
		return false
	}
	if prev == .Bang {
		return false
	}
	if cur == .Comma || cur == .Semicolon || cur == .RParen || cur == .RBracket || cur == .Dot_Dot || cur == .Dot_Dot_Eq {
		return false
	}
	if cur == .Dot {
		return prev == .Kw_At
	}
	if prev_is_at_selector_dot {
		return false
	}
	if cur == .Colon {
		return in_binding_header
	}
	if cur == .LParen {
		#partial switch prev {
		case .Ident, .Kw_Enum, .Kw_Verify, .Kw_Query:
			return false
		case .Kw_Module, .Kw_Version, .Kw_Schema, .Kw_Source, .Kw_Derived, .Kw_At, .Kw_Table, .Kw_Hit,
		     .Kw_Inputs, .Kw_Outputs, .Kw_Rows, .Kw_Cost, .Kw_Rule, .Kw_Phase, .Kw_Salience,
		     .Kw_When, .Kw_Then, .Kw_Effect, .Kw_Decide, .Kw_Unconditional, .Kw_From,
		     .Kw_True, .Kw_False:
			return false
		case:
			return true
		}
	}
	if cur == .LBracket {
		#partial switch prev {
		case .Ident, .RBracket:
			return false
		case:
			return true
		}
	}
	return true
}

@(private)
_format_inline_slice :: proc(items: []_Fmt_Item, alloc: mem.Allocator) -> (res: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, alloc) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	has_prev := false
	prev_was_comment := false
	prev_kind := Token_Kind.EOF
	prev_unary := false
	for item, idx in items {
		if item.kind == .Block_Comment {
			if has_prev {
				strings.write_byte(&b, ' ')
			}
			strings.write_string(&b, item.text)
			has_prev = true
			prev_was_comment = true
			continue
		}
		if item.kind != .Token {
			continue
		}
		cur := item.tok.kind
		if prev_was_comment {
			if cur != .Comma && cur != .Semicolon && cur != .RParen && cur != .RBracket {
				strings.write_byte(&b, ' ')
			}
		} else if has_prev && _needs_token_space(prev_kind, cur, prev_unary, false, false) {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, item.text)

		next_kind := Token_Kind.EOF
		has_next := false
		for ni := idx + 1; ni < len(items); ni += 1 {
			if items[ni].kind == .Token {
				next_kind = items[ni].tok.kind
				has_next = true
				break
			}
		}
		prev_unary = cur == .Minus && _is_unary_minus(prev_kind, has_prev && !prev_was_comment, next_kind, has_next)
		prev_kind = cur
		has_prev = true
		prev_was_comment = false
	}
	return strings.to_string(b), nil
}

@(private)
_find_matching_rbrace :: proc(items: []_Fmt_Item, lbrace_idx: int) -> int {
	depth := 0
	for i := lbrace_idx; i < len(items); i += 1 {
		if items[i].kind != .Token {
			continue
		}
		if items[i].tok.kind == .LBrace {
			depth += 1
		} else if items[i].tok.kind == .RBrace {
			depth -= 1
			if depth == 0 {
				return i
			}
		}
	}
	return len(items) - 1
}

@(private)
_block_has_comments_or_nested :: proc(items: []_Fmt_Item, start_idx, end_idx: int) -> (has_comments, has_nested, has_newlines: bool) {
	for i := start_idx + 1; i < end_idx; i += 1 {
		it := items[i]
		if it.kind != .Token {
			has_comments = true
		} else if it.tok.kind == .LBrace || it.tok.kind == .RBrace {
			has_nested = true
		}
		if !it.same_line {
			has_newlines = true
		}
	}
	return
}

@(private)
_write_indent :: proc(b: ^strings.Builder, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
}

@(private)
_write_padded :: proc(b: ^strings.Builder, s: string, width: int) {
	strings.write_string(b, s)
	for i := len(s); i < width; i += 1 {
		strings.write_byte(b, ' ')
	}
}

@(private)
_destroy_fmt_rows :: proc(rows: ^[dynamic]_Fmt_Row) {
	for &r in rows {
		delete(r.row_id)
		for s in r.inputs {
			delete(s)
		}
		delete(r.inputs)
		for s in r.outputs {
			delete(s)
		}
		delete(r.outputs)
		delete(r.raw_fallback)
	}
	delete(rows^)
}

@(private)
_parse_table_row :: proc(row_items: []_Fmt_Item, trailing: string, alloc: mem.Allocator) -> (row: _Fmt_Row, err: mem.Allocator_Error) {
	row.inputs = make([dynamic]string, 0, 4, alloc) or_return
	row.outputs = make([dynamic]string, 0, 2, alloc) or_return
	row.trailing_note = trailing

	// Expect: <row_id> : <inputs...> || <outputs...> ;
	colon_idx := -1
	dp_idx := -1
	semi_idx := -1
	for it, idx in row_items {
		if it.kind != .Token {
			continue
		}
		if colon_idx < 0 && it.tok.kind == .Colon {
			colon_idx = idx
		} else if colon_idx >= 0 && dp_idx < 0 && it.tok.kind == .Double_Pipe {
			dp_idx = idx
		} else if it.tok.kind == .Semicolon {
			semi_idx = idx
		}
	}

	if colon_idx <= 0 || dp_idx <= colon_idx || semi_idx <= dp_idx {
		row.valid = false
		row.raw_fallback = _format_inline_slice(row_items, alloc) or_return
		return row, nil
	}

	row.row_id = _format_inline_slice(row_items[:colon_idx], alloc) or_return
	cell_start := colon_idx + 1
	for i := colon_idx + 1; i <= dp_idx; i += 1 {
		is_sep := i == dp_idx || (row_items[i].kind == .Token && row_items[i].tok.kind == .Pipe)
		if is_sep {
			cell := _format_inline_slice(row_items[cell_start:i], alloc) or_return
			append(&row.inputs, cell) or_return
			cell_start = i + 1
		}
	}
	cell_start = dp_idx + 1
	for i := dp_idx + 1; i <= semi_idx; i += 1 {
		is_sep := i == semi_idx || (row_items[i].kind == .Token && row_items[i].tok.kind == .Pipe)
		if is_sep {
			cell := _format_inline_slice(row_items[cell_start:i], alloc) or_return
			append(&row.outputs, cell) or_return
			cell_start = i + 1
		}
	}
	row.valid = true
	return row, nil
}

@(private)
_format_rows_block :: proc(
	b: ^strings.Builder,
	items: []_Fmt_Item,
	lbrace_idx: int,
	rbrace_idx: int,
	depth: int,
	alloc: mem.Allocator,
) -> mem.Allocator_Error {
	strings.write_string(b, "{\n")
	rows := make([dynamic]_Fmt_Row, 0, 8, alloc)
	defer _destroy_fmt_rows(&rows)

	i := lbrace_idx + 1
	for i < rbrace_idx {
		it := items[i]
		if it.kind != .Token {
			append(&rows, _Fmt_Row{
				is_comment   = true,
				comment_text = it.text,
			}) or_return
			i += 1
			continue
		}
		row_start := i
		for i < rbrace_idx {
			if items[i].kind == .Line_Comment {
				// Preserve mid-row line comments cleanly above the formatted single-line row.
				append(&rows, _Fmt_Row{
					is_comment   = true,
					comment_text = items[i].text,
				}) or_return
			}
			if items[i].kind == .Token && items[i].tok.kind == .Semicolon {
				i += 1
				break
			}
			i += 1
		}
		row_end := i
		trailing := ""
		if i < rbrace_idx && items[i].kind == .Line_Comment && items[i].same_line {
			trailing = items[i].text
			i += 1
		}
		r := _parse_table_row(items[row_start:row_end], trailing, alloc) or_return
		append(&rows, r) or_return
	}

	max_id := 0
	max_in := make([dynamic]int, 0, 4, alloc)
	defer delete(max_in)
	max_out := make([dynamic]int, 0, 2, alloc)
	defer delete(max_out)

	for &r in rows {
		if r.is_comment || !r.valid {
			continue
		}
		if len(r.row_id) > max_id {
			max_id = len(r.row_id)
		}
		for c, ci in r.inputs {
			for len(max_in) <= ci {
				append(&max_in, 0) or_return
			}
			if len(c) > max_in[ci] {
				max_in[ci] = len(c)
			}
		}
		for c, ci in r.outputs {
			for len(max_out) <= ci {
				append(&max_out, 0) or_return
			}
			if len(c) > max_out[ci] {
				max_out[ci] = len(c)
			}
		}
	}

	for &r in rows {
		_write_indent(b, depth + 1)
		if r.is_comment {
			strings.write_string(b, r.comment_text)
			strings.write_byte(b, '\n')
			continue
		}
		if !r.valid {
			strings.write_string(b, r.raw_fallback)
			if len(r.trailing_note) > 0 {
				strings.write_byte(b, ' ')
				strings.write_string(b, r.trailing_note)
			}
			strings.write_byte(b, '\n')
			continue
		}
		strings.write_string(b, r.row_id)
		strings.write_byte(b, ':')
		for p := len(r.row_id); p < max_id + 1; p += 1 {
			strings.write_byte(b, ' ')
		}
		for c, ci in r.inputs {
			if ci > 0 {
				strings.write_string(b, " | ")
			}
			_write_padded(b, c, max_in[ci])
		}
		strings.write_string(b, " || ")
		for c, ci in r.outputs {
			if ci > 0 {
				strings.write_string(b, " | ")
			}
			if ci + 1 < len(r.outputs) {
				_write_padded(b, c, max_out[ci])
			} else {
				strings.write_string(b, c)
			}
		}
		strings.write_byte(b, ';')
		if len(r.trailing_note) > 0 {
			strings.write_byte(b, ' ')
			strings.write_string(b, r.trailing_note)
		}
		strings.write_byte(b, '\n')
	}

	_write_indent(b, depth)
	strings.write_byte(b, '}')
	return nil
}

@(private)
_next_token_kind :: proc(items: []_Fmt_Item, idx: int) -> (Token_Kind, bool) {
	for i := idx + 1; i < len(items); i += 1 {
		if items[i].kind == .Token {
			return items[i].tok.kind, true
		}
	}
	return .EOF, false
}

// Formats `.forseti` source text canonically, preserving comments and aligning DMN table pipes.
// Caller owns the returned string.
@(require_results)
format_source :: proc(
	src: string,
	allocator := context.allocator,
) -> (formatted: string, err: mem.Allocator_Error) {
	items := _itemize_source(src, allocator) or_return
	defer delete(items)

	if len(items) == 0 {
		return strings.clone("", allocator)
	}

	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	depth := 0
	at_line_start := true
	has_emitted := false
	need_top_sep := false
	in_binding_header := false
	in_module_header := false
	in_source_at := false
	prev_is_at_dot := false
	has_prev_tok := false
	prev_tok := Token_Kind.EOF
	prev_unary_minus := false
	inline_brace_depth := 0

	i := 0
	for i < len(items) {
		it := items[i]
		if it.kind != .Token {
			if it.same_line && !at_line_start {
				strings.write_byte(&b, ' ')
				strings.write_string(&b, it.text)
				strings.write_byte(&b, '\n')
				at_line_start = true
				has_emitted = true
				has_prev_tok = false
			} else {
				if !at_line_start {
					strings.write_byte(&b, '\n')
					at_line_start = true
				}
				if depth == 0 && need_top_sep && has_emitted {
					strings.write_byte(&b, '\n')
					need_top_sep = false
				}
				_write_indent(&b, depth)
				strings.write_string(&b, it.text)
				if it.kind == .Line_Comment || !it.same_line {
					strings.write_byte(&b, '\n')
					at_line_start = true
				} else {
					at_line_start = false
				}
				has_emitted = true
				has_prev_tok = false
			}
			i += 1
			continue
		}

		cur := it.tok.kind

		// Close module/source/derived header once the next top-level keyword or EOF starts.
		if depth == 0 && (in_module_header || in_binding_header || in_source_at) {
			if _is_top_decl_kw(cur) {
				if !at_line_start {
					strings.write_byte(&b, '\n')
					at_line_start = true
				}
				need_top_sep = true
				in_module_header = false
				in_binding_header = false
				in_source_at = false
				has_prev_tok = false
			}
		}

		if depth == 0 && need_top_sep && has_emitted && _is_top_decl_kw(cur) {
			if !at_line_start {
				strings.write_byte(&b, '\n')
				at_line_start = true
			}
			strings.write_byte(&b, '\n')
			need_top_sep = false
			has_prev_tok = false
		}

		if cur == .Kw_Module || cur == .Kw_Import {
			in_module_header = true
		} else if cur == .Kw_Source || cur == .Kw_Derived {
			in_binding_header = true
		} else if cur == .Kw_At && in_binding_header {
			in_binding_header = false
			in_source_at = true
		}

		if cur == .LBrace {
			rbrace := _find_matching_rbrace(items[:], i)
			if prev_tok == .Kw_Rows && has_prev_tok {
				if !at_line_start {
					strings.write_byte(&b, ' ')
				} else {
					_write_indent(&b, depth)
				}
				_format_rows_block(&b, items[:], i, rbrace, depth, allocator) or_return
				at_line_start = false
				has_emitted = true
				has_prev_tok = false
				prev_tok = .RBrace
				i = rbrace + 1
				if depth == 0 {
					need_top_sep = true
				} else {
					// Next sibling inside table/rule gets its own line.
					if i < len(items) && !(items[i].kind == .Line_Comment && items[i].same_line) {
						strings.write_byte(&b, '\n')
						at_line_start = true
					}
				}
				continue
			}

			has_comments, has_nested, has_newlines := _block_has_comments_or_nested(items[:], i, rbrace)
			is_always_multi := prev_tok == .Kw_Table || prev_tok == .Kw_Rule || has_nested || has_comments
			is_inline_block := !is_always_multi && (
				prev_tok == .Kw_Inputs || prev_tok == .Kw_Outputs ||
				prev_tok == .Ident && !has_newlines ||
				!has_newlines
			)
			if prev_tok == .Kw_Schema || prev_tok == .Kw_Enum {
				is_inline_block = !has_comments && !has_nested
			}

			if !at_line_start && has_prev_tok {
				strings.write_byte(&b, ' ')
			} else if at_line_start {
				_write_indent(&b, depth)
			}

			if is_inline_block {
				strings.write_string(&b, "{ ")
				inline_brace_depth += 1
				depth += 1
				at_line_start = false
				has_prev_tok = false
				prev_tok = .LBrace
				has_emitted = true
				i += 1
				continue
			}

			strings.write_string(&b, "{\n")
			depth += 1
			at_line_start = true
			has_prev_tok = false
			prev_tok = .LBrace
			has_emitted = true
			i += 1
			continue
		}

		if cur == .RBrace {
			if inline_brace_depth > 0 {
				inline_brace_depth -= 1
				depth = max(depth - 1, 0)
				if prev_tok != .LBrace {
					strings.write_byte(&b, ' ')
				}
				strings.write_byte(&b, '}')
				at_line_start = false
				has_prev_tok = true
				prev_tok = .RBrace
				prev_unary_minus = false
				has_emitted = true
				if depth == 0 {
					need_top_sep = true
				} else if i + 1 < len(items) && !(items[i + 1].kind == .Line_Comment && items[i + 1].same_line) {
					strings.write_byte(&b, '\n')
					at_line_start = true
					has_prev_tok = false
				}
				i += 1
				continue
			}

			depth = max(depth - 1, 0)
			if !at_line_start {
				strings.write_byte(&b, '\n')
				at_line_start = true
			}
			_write_indent(&b, depth)
			strings.write_byte(&b, '}')
			at_line_start = false
			has_prev_tok = true
			prev_tok = .RBrace
			prev_unary_minus = false
			has_emitted = true
			if depth == 0 {
				need_top_sep = true
			} else if i + 1 < len(items) && !(items[i + 1].kind == .Line_Comment && items[i + 1].same_line) &&
			          !(items[i + 1].kind == .Token && items[i + 1].tok.kind == .RBrace) {
				strings.write_byte(&b, '\n')
				at_line_start = true
				has_prev_tok = false
			}
			i += 1
			continue
		}

		// Multi-line statement break inside `when { ... }`, `then { ... }`, `query { ... }`, `table { ... }`, `rule { ... }`.
		if inline_brace_depth == 0 && depth > 0 && !at_line_start && !it.same_line {
			strings.write_byte(&b, '\n')
			at_line_start = true
			has_prev_tok = false
		}

		if at_line_start {
			_write_indent(&b, depth)
			at_line_start = false
		} else if has_prev_tok && _needs_token_space(prev_tok, cur, prev_unary_minus, in_binding_header, prev_is_at_dot) {
			strings.write_byte(&b, ' ')
		}

		strings.write_string(&b, it.text)
		has_emitted = true

		next_kind, has_next := _next_token_kind(items[:], i)
		prev_unary_minus = cur == .Minus && _is_unary_minus(prev_tok, has_prev_tok, next_kind, has_next)
		prev_is_at_dot = cur == .Dot && prev_tok == .Kw_At
		prev_tok = cur
		has_prev_tok = true

		if depth == 0 && (in_module_header || in_source_at) && has_next && _is_top_decl_kw(next_kind) {
			need_top_sep = true
			in_module_header = false
			in_source_at = false
			in_binding_header = false
		}

		i += 1
	}

	if has_emitted && !at_line_start {
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b), nil
}
