package forseti_lsp

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../forseti"

Lsp_Diagnostic :: struct {
	code:     string,
	severity: forseti.Diagnostic_Severity,
	range:    Lsp_Range,
	message:  string,
	hint:     string,
}

Lsp_Doc :: struct {
	uri:         string,
	text:        string,
	version:     i64,
	line_starts: [dynamic]u32,
	diags:       [dynamic]Lsp_Diagnostic,
	index:       Lsp_Doc_Index,
}

Lsp_Server :: struct {
	docs:               map[string]^Lsp_Doc,
	shutdown_requested: bool,
	exit_code:          int,
	alloc:              mem.Allocator,
}

@(private)
_doc_destroy :: proc(doc: ^Lsp_Doc, alloc: mem.Allocator) {
	if doc == nil {
		return
	}
	delete(doc.uri, alloc)
	delete(doc.text, alloc)
	delete(doc.line_starts)
	for d in doc.diags {
		delete(d.message, alloc)
		delete(d.hint, alloc)
	}
	delete(doc.diags)
	doc_index_destroy(&doc.index)
	free(doc, alloc)
}

server_init :: proc(srv: ^Lsp_Server, allocator := context.allocator) {
	srv^ = {}
	srv.alloc = allocator
	srv.docs = make(map[string]^Lsp_Doc, 8, allocator)
}

server_destroy :: proc(srv: ^Lsp_Server) {
	if srv == nil {
		return
	}
	for _, doc in srv.docs {
		_doc_destroy(doc, srv.alloc)
	}
	delete(srv.docs)
	srv^ = {}
}

@(private)
_analyze_doc :: proc(doc: ^Lsp_Doc, alloc: mem.Allocator) -> mem.Allocator_Error {
	delete(doc.line_starts)
	doc.line_starts = compute_line_starts(doc.text, alloc) or_return

	for d in doc.diags {
		delete(d.message, alloc)
		delete(d.hint, alloc)
	}
	clear(&doc.diags)

	dlist: forseti.Diagnostic_List
	forseti.diag_list_init(&dlist, alloc) or_return
	defer forseti.diag_list_destroy(&dlist)

	ir, comp_err := forseti.compile_source(doc.text, doc.uri, &dlist, nil, alloc)
	defer forseti.ir_destroy(&ir)
	if comp_err == nil {
		doc_index_destroy(&doc.index)
		_ = forseti.verify_all_tables(&ir, &dlist, nil)
		strat, s_err := forseti.stratify_ir(&ir, &dlist, nil, alloc)
		defer forseti.stratification_plan_destroy(&strat)
		if s_err == nil {
			doc.index = build_doc_index(doc.text, doc.line_starts[:], &ir, &strat)
		} else {
			doc.index = build_doc_index(doc.text, doc.line_starts[:], &ir, nil)
		}
	} else {
		// Drop stale span/symbol locations on syntax errors while keeping cached schemas/tables/vars for completion.
		if len(doc.index.entries) > 0 { clear(&doc.index.entries) }
		if len(doc.index.symbols) > 0 { clear(&doc.index.symbols) }
		if len(doc.index.tables_meta) > 0 { clear(&doc.index.tables_meta) }
	}

	for item in dlist.items {
		rng := span_to_lsp_range(doc.text, doc.line_starts[:], item.span)
		append(&doc.diags, Lsp_Diagnostic{
			code     = forseti.diag_code_string(item.code),
			severity = item.severity,
			range    = rng,
			message  = strings.clone(item.message, alloc) or_return,
			hint     = strings.clone(item.hint, alloc) or_return,
		}) or_return
	}
	return nil
}

server_update_document :: proc(
	srv: ^Lsp_Server,
	uri: string,
	new_text: string,
	version: i64,
) -> (diags_copy: []Lsp_Diagnostic, err: mem.Allocator_Error) {
	doc, exists := srv.docs[uri]
	if !exists {
		doc = new(Lsp_Doc, srv.alloc)
		doc.uri = strings.clone(uri, srv.alloc) or_return
		doc.diags = make([dynamic]Lsp_Diagnostic, 0, 8, srv.alloc) or_return
		srv.docs[doc.uri] = doc
	}
	delete(doc.text, srv.alloc)
	doc.text = strings.clone(new_text, srv.alloc) or_return
	doc.version = version

	_analyze_doc(doc, srv.alloc) or_return
	diags_copy = make([]Lsp_Diagnostic, len(doc.diags), srv.alloc) or_return
	copy(diags_copy, doc.diags[:])
	return diags_copy, nil
}

server_close_document :: proc(srv: ^Lsp_Server, uri: string) {
	if doc, has := srv.docs[uri]; has {
		delete_key(&srv.docs, doc.uri)
		_doc_destroy(doc, srv.alloc)
	}
}

@(private)
_write_lsp_range :: proc(b: ^strings.Builder, r: Lsp_Range) {
	fmt.sbprintf(b, `{{"start":{{"line":%d,"character":%d}},"end":{{"line":%d,"character":%d}}}}`, r.start.line, r.start.character, r.end.line, r.end.character)
}

@(private)
_format_publish_diagnostics :: proc(uri: string, diags: []Lsp_Diagnostic, alloc: mem.Allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, alloc)
	strings.write_string(&b, `{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":`)
	write_json_escaped(&b, uri)
	strings.write_string(&b, `,"diagnostics":[`)
	for d, i in diags {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		sev := 1
		switch d.severity {
		case .Error:   sev = 1
		case .Warning: sev = 2
		case .Hint:    sev = 4
		}
		strings.write_string(&b, `{"range":`)
		_write_lsp_range(&b, d.range)
		fmt.sbprintf(&b, `,"severity":%d,"code":`, sev)
		write_json_escaped(&b, d.code)
		strings.write_string(&b, `,"source":"forseti","message":`)
		if len(d.hint) > 0 {
			full_msg := fmt.tprintf("%s (hint: %s)", d.message, d.hint)
			write_json_escaped(&b, full_msg)
		} else {
			write_json_escaped(&b, d.message)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}}`)
	return strings.to_string(b)
}

@(private)
_write_id_json :: proc(b: ^strings.Builder, id_val: json.Value) {
	switch v in id_val {
	case json.Integer: fmt.sbprintf(b, "%d", v)
	case json.Float:   fmt.sbprintf(b, "%v", v)
	case json.String:  write_json_escaped(b, string(v))
	case json.Null, json.Boolean, json.Array, json.Object:
		strings.write_string(b, "null")
	}
}

@(private)
_extract_uri_and_pos :: proc(params: json.Object) -> (uri: string, pos: Lsp_Pos, ok: bool) {
	td, has_td := params["textDocument"].(json.Object)
	if !has_td {
		return "", {}, false
	}
	u_val, has_u := td["uri"].(json.String)
	if !has_u {
		return "", {}, false
	}
	p_obj, has_p := params["position"].(json.Object)
	if !has_p {
		return string(u_val), {}, false
	}
	ln, has_ln := p_obj["line"].(json.Integer)
	ch, has_ch := p_obj["character"].(json.Integer)
	if !has_ln || !has_ch {
		return string(u_val), {}, false
	}
	return string(u_val), Lsp_Pos{line = u32(max(ln, 0)), character = u32(max(ch, 0))}, true
}

@(private)
_extract_doc_and_pos :: proc(srv: ^Lsp_Server, params_val: json.Value) -> (doc: ^Lsp_Doc, pos: Lsp_Pos, has_pos: bool) {
	params, is_obj := params_val.(json.Object)
	if !is_obj {
		return nil, {}, false
	}
	uri, p, p_ok := _extract_uri_and_pos(params)
	if len(uri) == 0 || !(uri in srv.docs) {
		return nil, p, p_ok
	}
	return srv.docs[uri], p, p_ok
}

@(private)
_parse_lsp_range :: proc(rng_obj: json.Object) -> (rng: Lsp_Range, ok: bool) {
	st_obj, has_st := rng_obj["start"].(json.Object)
	en_obj, has_en := rng_obj["end"].(json.Object)
	if !has_st || !has_en {
		return {}, false
	}
	st_ln, ok_sl := st_obj["line"].(json.Integer)
	st_ch, ok_sc := st_obj["character"].(json.Integer)
	en_ln, ok_el := en_obj["line"].(json.Integer)
	en_ch, ok_ec := en_obj["character"].(json.Integer)
	if !ok_sl || !ok_sc || !ok_el || !ok_ec || st_ln < 0 || st_ch < 0 || en_ln < 0 || en_ch < 0 {
		return {}, false
	}
	return Lsp_Range{
		start = Lsp_Pos{line = u32(st_ln), character = u32(st_ch)},
		end   = Lsp_Pos{line = u32(en_ln), character = u32(en_ch)},
	}, true
}

@(private)
_append_completion_item :: proc(b: ^strings.Builder, emitted: ^int, label: string, kind: int, detail: string) {
	if emitted^ > 0 {
		strings.write_byte(b, ',')
	}
	strings.write_string(b, `{"label":`)
	write_json_escaped(b, label)
	fmt.sbprintf(b, `,"kind":%d,"detail":`, kind)
	write_json_escaped(b, detail)
	strings.write_byte(b, '}')
	emitted^ += 1
}

@(private)
_completion_word_char :: proc "contextless" (c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '?'
}

@(private)
_emit_context_completions :: proc(doc: ^Lsp_Doc, pos: Lsp_Pos, has_pos: bool, b: ^strings.Builder) {
	emitted := 0
	if doc != nil && has_pos {
		off := min(int(lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], pos)), len(doc.text))
		// Strip partial identifier currently being typed.
		scan := off
		for scan > 0 && _completion_word_char(doc.text[scan - 1]) {
			scan -= 1
		}

		// Case 1: Dot access after `?var.`
		if scan > 0 && doc.text[scan - 1] == '.' {
			v_end := scan - 1
			v_start := v_end
			for v_start > 0 && _completion_word_char(doc.text[v_start - 1]) {
				v_start -= 1
			}
			vname := doc.text[v_start:v_end]
			if vc, has_vc := doc.index.var_completions[vname]; has_vc {
				if vc.is_table {
					if outs, has_o := doc.index.table_outputs[vc.target_name]; has_o {
						for ocol in outs {
							_append_completion_item(b, &emitted, ocol, 5, "table output")
						}
						return
					}
				} else if fields, has_f := doc.index.schema_fields[vc.target_name]; has_f {
					for fname in fields {
						_append_completion_item(b, &emitted, fname, 5, "schema field")
					}
					return
				}
			}
		}

		// Case 2: Enclosing `decide <table>(` or `<binding>(` field position.
		depth := 0
		open_idx := -1
		for k := scan - 1; k >= 0; k -= 1 {
			ch := doc.text[k]
			if ch == ')' {
				depth += 1
			} else if ch == '(' {
				if depth == 0 {
					open_idx = k
					break
				}
				depth -= 1
			} else if ch == '{' || ch == '}' {
				break
			}
		}
		if open_idx > 0 {
			c_end := open_idx
			for c_end > 0 && (doc.text[c_end - 1] == ' ' || doc.text[c_end - 1] == '\t') {
				c_end -= 1
			}
			c_start := c_end
			for c_start > 0 && _completion_word_char(doc.text[c_start - 1]) {
				c_start -= 1
			}
			callee := doc.text[c_start:c_end]
			if t_ins, is_tbl := doc.index.table_inputs[callee]; is_tbl {
				for col in t_ins {
					_append_completion_item(b, &emitted, col, 5, "table input")
				}
			} else if sname, is_bind := doc.index.binding_schemas[callee]; is_bind {
				if s_fields, has_sf := doc.index.schema_fields[sname]; has_sf {
					for sf in s_fields {
						_append_completion_item(b, &emitted, sf, 5, "schema field")
					}
				}
			}
		}
	}

	if doc != nil {
		for tname in doc.index.tables {
			_append_completion_item(b, &emitted, tname, 3, "table")
		}
		for bname in doc.index.bindings {
			_append_completion_item(b, &emitted, bname, 6, "binding")
		}
		for sname in doc.index.schemas {
			_append_completion_item(b, &emitted, sname, 22, "schema")
		}
	}
	kws := [?]string{"module", "schema", "source", "derived", "table", "rule", "query", "when", "then", "effect", "where", "decide", "assert", "assert!", "unconditional", "retract", "not", "exists", "from"}
	for kw in kws {
		_append_completion_item(b, &emitted, kw, 14, "keyword")
	}
}

@(private)
_default_output_literal :: proc "contextless" (type_str: string) -> string {
	switch type_str {
	case "bool":   return "false"
	case "i32", "i64": return "0"
	case "f64":    return "0.0"
	case "string": return `""`
	}
	return "-"
}

@(private)
_build_request_reply :: proc(
	srv: ^Lsp_Server,
	id_val: json.Value,
	method: string,
	params_val: json.Value,
	b: ^strings.Builder,
) {
	strings.write_string(b, `{"jsonrpc":"2.0","id":`)
	_write_id_json(b, id_val)
	strings.write_string(b, `,"result":`)

	switch method {
	case "initialize":
		strings.write_string(b, `{"capabilities":{"textDocumentSync":{"openClose":true,"change":2},"hoverProvider":true,"definitionProvider":true,"documentSymbolProvider":true,"completionProvider":{"triggerCharacters":[".",":","?","("]},"documentFormattingProvider":true,"codeActionProvider":true},"serverInfo":{"name":"forseti-lsp","version":"0.1.0"}}`)

	case "shutdown":
		srv.shutdown_requested = true
		strings.write_string(b, "null")

	case "textDocument/hover":
		doc, pos, ok := _extract_doc_and_pos(srv, params_val)
		if doc == nil || !ok {
			strings.write_string(b, "null")
		} else {
			off := lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], pos)
			entry, found := index_lookup_at(&doc.index, off)
			if !found {
				strings.write_string(b, "null")
			} else {
				rng := span_to_lsp_range(doc.text, doc.line_starts[:], entry.span)
				strings.write_string(b, `{"contents":{"kind":"markdown","value":`)
				write_json_escaped(b, entry.hover_md)
				strings.write_string(b, `},"range":`)
				_write_lsp_range(b, rng)
				strings.write_byte(b, '}')
			}
		}

	case "textDocument/definition":
		doc, pos, ok := _extract_doc_and_pos(srv, params_val)
		if doc == nil || !ok {
			strings.write_string(b, "null")
		} else {
			off := lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], pos)
			entry, found := index_lookup_at(&doc.index, off)
			if !found {
				strings.write_string(b, "null")
			} else {
				rng := span_to_lsp_range(doc.text, doc.line_starts[:], entry.target_span)
				strings.write_string(b, `{"uri":`)
				write_json_escaped(b, doc.uri)
				strings.write_string(b, `,"range":`)
				_write_lsp_range(b, rng)
				strings.write_byte(b, '}')
			}
		}

	case "textDocument/documentSymbol":
		doc, _, _ := _extract_doc_and_pos(srv, params_val)
		if doc == nil {
			strings.write_string(b, "[]")
		} else {
			strings.write_byte(b, '[')
			for sym, si in doc.index.symbols {
				if si > 0 {
					strings.write_byte(b, ',')
				}
				strings.write_string(b, `{"name":`)
				write_json_escaped(b, sym.name)
				strings.write_string(b, `,"detail":`)
				write_json_escaped(b, sym.detail)
				fmt.sbprintf(b, `,"kind":%d,"range":`, sym.kind)
				_write_lsp_range(b, sym.range)
				strings.write_string(b, `,"selectionRange":`)
				_write_lsp_range(b, sym.sel_range)
				strings.write_byte(b, '}')
			}
			strings.write_byte(b, ']')
		}

	case "textDocument/completion":
		doc, pos, has_pos := _extract_doc_and_pos(srv, params_val)
		strings.write_byte(b, '[')
		_emit_context_completions(doc, pos, has_pos, b)
		strings.write_byte(b, ']')

	case "textDocument/formatting":
		params, is_obj := params_val.(json.Object)
		uri := ""
		if is_obj {
			if td, has_td := params["textDocument"].(json.Object); has_td {
				if u, has_u := td["uri"].(json.String); has_u {
					uri = string(u)
				}
			}
		}
		doc := srv.docs[uri] if (len(uri) > 0 && uri in srv.docs) else nil
		if doc == nil {
			strings.write_string(b, "[]")
		} else {
			formatted, f_err := forseti.format_source(doc.text, srv.alloc)
			if f_err != nil {
				strings.write_string(b, "[]")
			} else {
				defer delete(formatted, srv.alloc)
				end_pos := byte_offset_to_lsp_pos(doc.text, doc.line_starts[:], u32(len(doc.text)))
				full_rng := Lsp_Range{start = Lsp_Pos{line = 0, character = 0}, end = end_pos}
				strings.write_string(b, `[{"range":`)
				_write_lsp_range(b, full_rng)
				strings.write_string(b, `,"newText":`)
				write_json_escaped(b, formatted)
				strings.write_string(b, `}]`)
			}
		}

	case "textDocument/codeAction":
		params, is_obj := params_val.(json.Object)
		uri := ""
		if is_obj {
			if td, has_td := params["textDocument"].(json.Object); has_td {
				if u, has_u := td["uri"].(json.String); has_u {
					uri = string(u)
				}
			}
		}
		doc := srv.docs[uri] if (len(uri) > 0 && uri in srv.docs) else nil
		strings.write_byte(b, '[')
		emitted := 0
		if doc != nil && is_obj {
			if ctx_obj, has_ctx := params["context"].(json.Object); has_ctx {
				if diag_arr, has_d := ctx_obj["diagnostics"].(json.Array); has_d {
					for item in diag_arr {
						d_obj, ok_d := item.(json.Object)
						if !ok_d {
							continue
						}
						code_val, _ := d_obj["code"].(json.String)
						code := string(code_val)
						rng_obj, has_rng := d_obj["range"].(json.Object)
						if !has_rng {
							continue
						}
						d_rng, ok_rng := _parse_lsp_range(rng_obj)
						if !ok_rng {
							continue
						}
						if code == "W2001" {
							s_off := int(lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], d_rng.start))
							e_off := int(lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], d_rng.end))
							if s_off >= 0 && e_off > s_off && e_off <= len(doc.text) && doc.text[s_off] == '?' {
								var_tok := doc.text[s_off:e_off]
								fixed_var := fmt.tprintf("?_%s", var_tok[1:])
								title := fmt.tprintf("Prefix unused variable with ?_ (%s)", fixed_var)
								if emitted > 0 { strings.write_byte(b, ',') }
								strings.write_string(b, `{"title":`)
								write_json_escaped(b, title)
								strings.write_string(b, `,"kind":"quickfix","edit":{"changes":{`)
								write_json_escaped(b, doc.uri)
								strings.write_string(b, `:[{"range":`)
								_write_lsp_range(b, d_rng)
								strings.write_string(b, `,"newText":`)
								write_json_escaped(b, fixed_var)
								strings.write_string(b, `}]}}}`)
								emitted += 1
							}
						} else if code == "W3001" {
							s_off := lsp_pos_to_byte_offset(doc.text, doc.line_starts[:], d_rng.start)
							for tm in doc.index.tables_meta {
								if tm.rows_close_off > 0 && s_off >= tm.span.offset && s_off <= tm.span.offset + tm.span.len {
									row_sb: strings.Builder
									strings.builder_init(&row_sb, context.temp_allocator)
									strings.write_string(&row_sb, "  r_fallback: ")
									for ci in 0 ..< max(tm.num_inputs, 1) {
										if ci > 0 { strings.write_string(&row_sb, " | ") }
										strings.write_byte(&row_sb, '-')
									}
									strings.write_string(&row_sb, " || ")
									for ot, oi in tm.output_types {
										if oi > 0 { strings.write_string(&row_sb, " | ") }
										strings.write_string(&row_sb, _default_output_literal(ot))
									}
									if len(tm.output_types) == 0 {
										strings.write_byte(&row_sb, '-')
									}
									strings.write_string(&row_sb, ";\n  ")
									ins_pos := byte_offset_to_lsp_pos(doc.text, doc.line_starts[:], tm.rows_close_off)
									ins_rng := Lsp_Range{start = ins_pos, end = ins_pos}
									if emitted > 0 { strings.write_byte(b, ',') }
									strings.write_string(b, `{"title":"Append fallback row to table","kind":"quickfix","edit":{"changes":{`)
									write_json_escaped(b, doc.uri)
									strings.write_string(b, `:[{"range":`)
									_write_lsp_range(b, ins_rng)
									strings.write_string(b, `,"newText":`)
									write_json_escaped(b, strings.to_string(row_sb))
									strings.write_string(b, `}]}}}`)
									emitted += 1
									break
								}
							}
						}
					}
				}
			}
		}
		strings.write_byte(b, ']')

	case:
		strings.write_string(b, "null")
	}

	strings.write_byte(b, '}')
}

@(private)
_handle_notification :: proc(
	srv: ^Lsp_Server,
	method: string,
	params_val: json.Value,
	out_alloc: mem.Allocator,
) -> (outbound_json: string, has_outbound: bool, should_exit: bool) {
	switch method {
	case "initialized":
		return "", false, false
	case "exit":
		srv.exit_code = 0 if srv.shutdown_requested else 1
		return "", false, true
	case "textDocument/didOpen":
		params, is_obj := params_val.(json.Object)
		if !is_obj { return "", false, false }
		td, has_td := params["textDocument"].(json.Object)
		if !has_td { return "", false, false }
		uri_v, has_u := td["uri"].(json.String)
		txt_v, has_t := td["text"].(json.String)
		ver_v, _ := td["version"].(json.Integer)
		if !has_u || !has_t { return "", false, false }
		uri := string(uri_v)
		diags, err := server_update_document(srv, uri, string(txt_v), ver_v)
		if err == nil {
			defer delete(diags, srv.alloc)
			note := _format_publish_diagnostics(uri, diags, out_alloc)
			return note, true, false
		}
	case "textDocument/didChange":
		params, is_obj := params_val.(json.Object)
		if !is_obj { return "", false, false }
		td, has_td := params["textDocument"].(json.Object)
		if !has_td { return "", false, false }
		uri_v, has_u := td["uri"].(json.String)
		ver_v, _ := td["version"].(json.Integer)
		changes, has_c := params["contentChanges"].(json.Array)
		if !has_u || !has_c { return "", false, false }
		uri := string(uri_v)
		doc := srv.docs[uri] if uri in srv.docs else nil
		cur_text, _ := strings.clone(doc.text if doc != nil else "", context.temp_allocator)
		for ch_val in changes {
			ch_obj, is_ch := ch_val.(json.Object)
			if !is_ch { continue }
			new_t, has_nt := ch_obj["text"].(json.String)
			if !has_nt { continue }
			if rng_obj, has_rng := ch_obj["range"].(json.Object); has_rng {
				rng, ok_rng := _parse_lsp_range(rng_obj)
				if !ok_rng { continue }
				applied, a_err := apply_lsp_edit(cur_text, rng, string(new_t), context.temp_allocator)
				if a_err == nil {
					cur_text = applied
				}
			} else {
				cur_text = string(new_t)
			}
		}
		diags, err := server_update_document(srv, uri, cur_text, ver_v)
		if err == nil {
			defer delete(diags, srv.alloc)
			note := _format_publish_diagnostics(uri, diags, out_alloc)
			return note, true, false
		}
	case "textDocument/didClose":
		params, is_obj := params_val.(json.Object)
		if !is_obj { return "", false, false }
		td, has_td := params["textDocument"].(json.Object)
		if !has_td { return "", false, false }
		uri_v, has_u := td["uri"].(json.String)
		if !has_u { return "", false, false }
		uri := string(uri_v)
		server_close_document(srv, uri)
		note := _format_publish_diagnostics(uri, nil, out_alloc)
		return note, true, false
	}
	return "", false, false
}

server_handle_json_message :: proc(
	srv: ^Lsp_Server,
	payload: string,
	out_alloc := context.allocator,
) -> (outbound_json: string, has_outbound: bool, should_exit: bool) {
	val, p_err := json.parse_string(payload, parse_integers = true, allocator = srv.alloc)
	if p_err != nil {
		return "", false, false
	}
	defer json.destroy_value(val, srv.alloc)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return "", false, false
	}
	m_val, has_m := obj["method"].(json.String)
	if !has_m {
		return "", false, false
	}
	method := string(m_val)
	params_val := obj["params"]
	if id_val, has_id := obj["id"]; has_id {
		b: strings.Builder
		strings.builder_init(&b, out_alloc)
		_build_request_reply(srv, id_val, method, params_val, &b)
		return strings.to_string(b), true, false
	}
	return _handle_notification(srv, method, params_val, out_alloc)
}

server_run_stdio :: proc(allocator := context.allocator) -> int {
	srv: Lsp_Server
	server_init(&srv, allocator)
	defer server_destroy(&srv)

	for {
		payload, eof, ok := read_lsp_frame(os.stdin, allocator)
		if !ok {
			if eof {
				return 0 if srv.shutdown_requested else 1
			}
			return 1
		}
		outbound, has_outbound, should_exit := server_handle_json_message(&srv, payload, allocator)
		delete(payload, allocator)
		if has_outbound {
			_ = write_lsp_frame(os.stdout, outbound)
			delete(outbound, allocator)
		}
		free_all(context.temp_allocator)
		if should_exit {
			return srv.exit_code
		}
	}
}
