package forseti_lsp

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"
import "../forseti"

Lsp_Symbol :: struct {
	name:      string,
	detail:    string,
	kind:      int,
	range:     Lsp_Range,
	sel_range: Lsp_Range,
}

Lsp_Def_Entry :: struct {
	span:        forseti.Span,
	target_span: forseti.Span,
	hover_md:    string,
}

Lsp_Table_Meta :: struct {
	name:           string,
	span:           forseti.Span,
	rows_close_off: u32,
	num_inputs:     int,
	output_types:   []string,
}

Lsp_Var_Completion :: struct {
	is_table:    bool,
	target_name: string,
}

Lsp_Completion_Item :: struct {
	label:  string,
	kind:   int,
	detail: string,
}

Lsp_Doc_Index :: struct {
	arena:           vmem.Arena,
	symbols:         [dynamic]Lsp_Symbol,
	entries:         [dynamic]Lsp_Def_Entry,
	tables_meta:     [dynamic]Lsp_Table_Meta,
	schemas:         [dynamic]string,
	bindings:        [dynamic]string,
	tables:          [dynamic]string,
	schema_fields:   map[string][]string,
	binding_schemas: map[string]string,
	table_inputs:    map[string][]string,
	table_outputs:   map[string][]string,
	var_completions: map[string]Lsp_Var_Completion,
}

doc_index_destroy :: proc(idx: ^Lsp_Doc_Index) {
	if idx == nil {
		return
	}
	vmem.arena_check_temp(&idx.arena)
	vmem.arena_destroy(&idx.arena)
	idx^ = {}
}

@(private)
_is_word_char :: proc "contextless" (b: byte) -> bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '?'
}

@(private)
_find_word_span :: proc(src: string, region: forseti.Span, word: string, start_at := u32(0)) -> (span: forseti.Span, ok: bool) {
	if len(word) == 0 {
		return {}, false
	}
	r_start := max(int(region.offset), int(start_at))
	r_end := min(int(region.offset + region.len), len(src))
	if r_start >= r_end {
		return {}, false
	}
	pos := r_start
	for pos < r_end {
		found := strings.index(src[pos:r_end], word)
		if found < 0 {
			return {}, false
		}
		abs := pos + found
		end := abs + len(word)
		left_ok := abs == 0 || !_is_word_char(src[abs - 1])
		right_ok := end >= len(src) || !_is_word_char(src[end])
		if left_ok && right_ok {
			return forseti.Span{offset = u32(abs), len = u32(len(word))}, true
		}
		pos = abs + 1
	}
	return {}, false
}

@(private)
_type_ref_str :: proc(ir: ^forseti.Rulebase_IR, tr: forseti.Type_Ref, alloc: mem.Allocator) -> string {
	switch tr.kind {
	case .Unknown:      return "unknown"
	case .Bool:         return "bool"
	case .I32:          return "i32"
	case .I64:          return "i64"
	case .F64:          return "f64"
	case .String:       return "string"
	case .Entity:       return "entity"
	case .Time:         return "time"
	case .Enum:
		if int(tr.ref_id) < len(ir.enums) {
			return fmt.aprintf("enum %s", forseti.ir_string(ir, ir.enums[tr.ref_id].name), allocator = alloc)
		}
		return "enum"
	case .Fact:         return "fact"
	case .Table_Result:
		if int(tr.ref_id) < len(ir.tables) {
			return fmt.aprintf("decide(%s)", forseti.ir_string(ir, ir.tables[tr.ref_id].name), allocator = alloc)
		}
		return "table_result"
	}
	return "unknown"
}

@(private)
_hit_policy_str :: proc "contextless" (hp: forseti.Hit_Policy) -> string {
	switch hp {
	case .First:         return "First"
	case .Unique:        return "Unique"
	case .Any:           return "Any"
	case .Priority:      return "Priority"
	case .Collect:       return "Collect"
	case .Collect_Sum:   return "Collect_Sum"
	case .Collect_Min:   return "Collect_Min"
	case .Collect_Max:   return "Collect_Max"
	case .Collect_Count: return "Collect_Count"
	case .Merge:         return "Merge"
	case .Reverse_Merge: return "Reverse_Merge"
	}
	return "First"
}

@(private)
_binding_selector_str :: proc(ir: ^forseti.Rulebase_IR, b: forseti.Binding_Def, alloc: mem.Allocator) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, alloc)
	for seg in b.segments {
		switch seg.kind {
		case .Field:
			strings.write_byte(&sb, '.')
			strings.write_string(&sb, forseti.ir_string(ir, seg.text))
		case .Var_Key:
			strings.write_byte(&sb, '[')
			strings.write_string(&sb, forseti.ir_string(ir, seg.text))
			strings.write_byte(&sb, ']')
		case .Lit_Key:
			strings.write_string(&sb, `["`)
			strings.write_string(&sb, forseti.ir_string(ir, seg.text))
			strings.write_string(&sb, `"]`)
		case .Wildcard:
			strings.write_string(&sb, "[*]")
		}
	}
	return strings.to_string(sb)
}

@(private)
_find_rows_close_offset :: proc(src: string, table_span: forseti.Span) -> u32 {
	t_start := min(int(table_span.offset), len(src))
	t_end := min(int(table_span.offset + table_span.len), len(src))
	if t_start >= t_end {
		return 0
	}
	sub := src[t_start:t_end]
	rows_idx := strings.index(sub, "rows")
	if rows_idx < 0 {
		return 0
	}
	open_idx := strings.index_byte(sub[rows_idx:], '{')
	if open_idx < 0 {
		return 0
	}
	depth := 0
	for i := rows_idx + open_idx; i < len(sub); i += 1 {
		if sub[i] == '{' {
			depth += 1
		} else if sub[i] == '}' {
			depth -= 1
			if depth == 0 {
				return u32(t_start + i)
			}
		}
	}
	return 0
}

@(private)
_Var_Binder :: struct {
	span:     forseti.Span,
	type_str: string,
	hover_md: string,
}

@(private)
_walk_expr_vars :: proc(
	ir: ^forseti.Rulebase_IR,
	eid: forseti.Expr_Id,
	vars: ^map[string]_Var_Binder,
	entries: ^[dynamic]Lsp_Def_Entry,
	alloc: mem.Allocator,
) {
	if eid == forseti.INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return
	}
	e := ir.exprs[eid]
	switch e.kind {
	case .Var:
		vname := forseti.ir_string(ir, e.str_id)
		if vb, has := vars[vname]; has {
			append(entries, Lsp_Def_Entry{
				span        = e.span,
				target_span = vb.span,
				hover_md    = vb.hover_md,
			})
		} else {
			hv := fmt.aprintf("`%s`: unknown", vname, allocator = alloc)
			vars[vname] = _Var_Binder{span = e.span, type_str = "unknown", hover_md = hv}
			append(entries, Lsp_Def_Entry{
				span        = e.span,
				target_span = e.span,
				hover_md    = hv,
			})
		}
	case .Field_Access:
		_walk_expr_vars(ir, e.lhs, vars, entries, alloc)
		if e.lhs != forseti.INVALID_EXPR && int(e.lhs) < len(ir.exprs) {
			lhs_e := ir.exprs[e.lhs]
			if lhs_e.kind == .Var {
				vname := forseti.ir_string(ir, lhs_e.str_id)
				fname := forseti.ir_string(ir, e.str_id)
				if vb, has := vars[vname]; has {
					hv := fmt.aprintf("`%s.%s` (from %s)", vname, fname, vb.type_str, allocator = alloc)
					append(entries, Lsp_Def_Entry{
						span        = e.span,
						target_span = vb.span,
						hover_md    = hv,
					})
				}
			}
		}
	case .Unary, .Cell_Cmp:
		_walk_expr_vars(ir, e.lhs, vars, entries, alloc)
	case .Binary, .Range:
		_walk_expr_vars(ir, e.lhs, vars, entries, alloc)
		_walk_expr_vars(ir, e.rhs, vars, entries, alloc)
	case .In_List, .Call:
		_walk_expr_vars(ir, e.lhs, vars, entries, alloc)
		start := int(e.extra_span.start)
		end := min(start + int(e.extra_span.count), len(ir.extra_exprs))
		for k := start; k < end; k += 1 {
			_walk_expr_vars(ir, ir.extra_exprs[k], vars, entries, alloc)
		}
	case .Invalid, .Lit_Bool, .Lit_Int, .Lit_Float, .Lit_String, .Ident, .Wildcard:
	}
}

@(private)
_record_var_binder :: proc(
	ir: ^forseti.Rulebase_IR,
	vname: string,
	span: forseti.Span,
	type_str: string,
	vars: ^map[string]_Var_Binder,
	entries: ^[dynamic]Lsp_Def_Entry,
	alloc: mem.Allocator,
) {
	if len(vname) == 0 {
		return
	}
	if vb, has := vars[vname]; has {
		append(entries, Lsp_Def_Entry{
			span        = span,
			target_span = vb.span,
			hover_md    = vb.hover_md,
		})
		return
	}
	hv := fmt.aprintf("`%s`: `%s`", vname, type_str, allocator = alloc)
	vars[vname] = _Var_Binder{span = span, type_str = type_str, hover_md = hv}
	append(entries, Lsp_Def_Entry{
		span        = span,
		target_span = span,
		hover_md    = hv,
	})
}

@(private)
_lookup_schema_field_type :: proc(ir: ^forseti.Rulebase_IR, schema_id: forseti.Schema_Id, fname: string, alloc: mem.Allocator) -> string {
	if int(schema_id) >= len(ir.schemas) {
		return "unknown"
	}
	s := ir.schemas[schema_id]
	for f in s.fields {
		if forseti.ir_string(ir, f.name) == fname {
			return _type_ref_str(ir, f.type, alloc)
		}
	}
	return "unknown"
}

@(private)
_walk_clauses_index :: proc(
	src: string,
	ir: ^forseti.Rulebase_IR,
	clauses: []forseti.Clause_IR,
	binding_map: ^map[string]int,
	table_map: ^map[string]int,
	binding_hovers: []string,
	table_hovers: []string,
	vars: ^map[string]_Var_Binder,
	entries: ^[dynamic]Lsp_Def_Entry,
	var_completions: ^map[string]Lsp_Var_Completion,
	alloc: mem.Allocator,
) {
	for cl in clauses {
		switch cl.kind {
		case .Pattern:
			bname := forseti.ir_string(ir, cl.target)
			schema_id := forseti.Schema_Id(forseti.INVALID_ID)
			if bi, has_b := binding_map[bname]; has_b {
				schema_id = ir.bindings[bi].schema_id
				if bsp, ok := _find_word_span(src, cl.span, bname); ok {
					append(entries, Lsp_Def_Entry{
						span        = bsp,
						target_span = ir.bindings[bi].span,
						hover_md    = binding_hovers[bi],
					})
				}
			}
			if cl.bind_var != forseti.EMPTY_STRING {
				bv := forseti.ir_string(ir, cl.bind_var)
				if int(schema_id) < len(ir.schemas) {
					var_completions[strings.clone(bv, alloc)] = Lsp_Var_Completion{
						is_table    = false,
						target_name = strings.clone(forseti.ir_string(ir, ir.schemas[schema_id].name), alloc),
					}
				}
				if vsp, ok := _find_word_span(src, cl.span, bv); ok {
					_record_var_binder(ir, bv, vsp, fmt.aprintf("fact(%s)", bname, allocator = alloc), vars, entries, alloc)
				}
			}
			for fb in cl.fields {
				if fb.expr != forseti.INVALID_EXPR && int(fb.expr) < len(ir.exprs) {
					fe := ir.exprs[fb.expr]
					if fe.kind == .Var {
						fname := forseti.ir_string(ir, fb.name)
						vname := forseti.ir_string(ir, fe.str_id)
						tstr := _lookup_schema_field_type(ir, schema_id, fname, alloc)
						_record_var_binder(ir, vname, fe.span, tstr, vars, entries, alloc)
					} else {
						_walk_expr_vars(ir, fb.expr, vars, entries, alloc)
					}
				}
			}
		case .Decide:
			tname := forseti.ir_string(ir, cl.target)
			if ti, has_t := table_map[tname]; has_t {
				if tsp, ok := _find_word_span(src, cl.span, tname); ok {
					append(entries, Lsp_Def_Entry{
						span        = tsp,
						target_span = ir.tables[ti].span,
						hover_md    = table_hovers[ti],
					})
				}
			}
			if cl.bind_var != forseti.EMPTY_STRING {
				bv := forseti.ir_string(ir, cl.bind_var)
				var_completions[strings.clone(bv, alloc)] = Lsp_Var_Completion{
					is_table    = true,
					target_name = strings.clone(tname, alloc),
				}
				if vsp, ok := _find_word_span(src, cl.span, bv); ok {
					_record_var_binder(ir, bv, vsp, fmt.aprintf("decide(%s)", tname, allocator = alloc), vars, entries, alloc)
				}
			}
			for fb in cl.fields {
				_walk_expr_vars(ir, fb.expr, vars, entries, alloc)
			}
		case .Not, .Exists:
			_walk_clauses_index(src, ir, cl.children, binding_map, table_map, binding_hovers, table_hovers, vars, entries, var_completions, alloc)
		case .Accum:
			if cl.bind_var != forseti.EMPTY_STRING {
				bv := forseti.ir_string(ir, cl.bind_var)
				if vsp, ok := _find_word_span(src, cl.span, bv); ok {
					tstr := "i64" if (cl.accum_op == .Count || cl.accum_op == .Distinct) else "f64"
					_record_var_binder(ir, bv, vsp, tstr, vars, entries, alloc)
				}
			}
			_walk_clauses_index(src, ir, cl.inner_pat, binding_map, table_map, binding_hovers, table_hovers, vars, entries, var_completions, alloc)
			_walk_expr_vars(ir, cl.expr, vars, entries, alloc)
			_walk_expr_vars(ir, cl.guard_expr, vars, entries, alloc)
		case .Where, .Let:
			if cl.kind == .Let && cl.bind_var != forseti.EMPTY_STRING {
				bv := forseti.ir_string(ir, cl.bind_var)
				if vsp, ok := _find_word_span(src, cl.span, bv); ok {
					_record_var_binder(ir, bv, vsp, "value", vars, entries, alloc)
				}
			}
			_walk_expr_vars(ir, cl.expr, vars, entries, alloc)
		case .Eav:
			_walk_expr_vars(ir, cl.expr, vars, entries, alloc)
			_walk_expr_vars(ir, cl.guard_expr, vars, entries, alloc)
			_walk_expr_vars(ir, cl.extra_expr, vars, entries, alloc)
		}
	}
}

build_doc_index :: proc(
	src: string,
	line_starts: []u32,
	ir: ^forseti.Rulebase_IR,
	strat: ^forseti.Stratification_Plan,
) -> (idx: Lsp_Doc_Index) {
	if vmem.arena_init_growing(&idx.arena) != nil {
		return idx
	}
	a := vmem.arena_allocator(&idx.arena)
	idx.symbols = make([dynamic]Lsp_Symbol, 0, 16, a)
	idx.entries = make([dynamic]Lsp_Def_Entry, 0, 64, a)
	idx.tables_meta = make([dynamic]Lsp_Table_Meta, 0, 8, a)
	idx.schemas = make([dynamic]string, 0, 8, a)
	idx.bindings = make([dynamic]string, 0, 8, a)
	idx.tables = make([dynamic]string, 0, 8, a)
	idx.schema_fields = make(map[string][]string, 8, a)
	idx.binding_schemas = make(map[string]string, 8, a)
	idx.table_inputs = make(map[string][]string, 8, a)
	idx.table_outputs = make(map[string][]string, 8, a)
	idx.var_completions = make(map[string]Lsp_Var_Completion, 8, a)

	if ir == nil {
		return idx
	}

	schema_map := make(map[string]int, len(ir.schemas) + 4, a)
	schema_hovers := make([]string, len(ir.schemas), a)
	for s, si in ir.schemas {
		sname := strings.clone(forseti.ir_string(ir, s.name), a)
		schema_map[sname] = si
		append(&idx.schemas, sname)

		sb: strings.Builder
		strings.builder_init(&sb, a)
		fmt.sbprintf(&sb, "```forseti\nschema %s {{ ", sname)
		fnames := make([]string, len(s.fields), a)
		for f, fi in s.fields {
			fn := strings.clone(forseti.ir_string(ir, f.name), a)
			fnames[fi] = fn
			if fi > 0 {
				strings.write_string(&sb, ", ")
			}
			fmt.sbprintf(&sb, "%s: %s", fn, _type_ref_str(ir, f.type, a))
		}
		strings.write_string(&sb, " }\n```")
		schema_hovers[si] = strings.to_string(sb)
		idx.schema_fields[sname] = fnames

		rng := span_to_lsp_range(src, line_starts, s.span)
		sel := rng
		if nsp, ok := _find_word_span(src, s.span, sname); ok {
			sel = span_to_lsp_range(src, line_starts, nsp)
			append(&idx.entries, Lsp_Def_Entry{span = nsp, target_span = s.span, hover_md = schema_hovers[si]})
		}
		append(&idx.symbols, Lsp_Symbol{name = sname, detail = "schema", kind = 23, range = rng, sel_range = sel})
	}

	binding_map := make(map[string]int, len(ir.bindings) + 4, a)
	binding_hovers := make([]string, len(ir.bindings), a)
	for b, bi in ir.bindings {
		bname := strings.clone(forseti.ir_string(ir, b.name), a)
		sname := strings.clone(forseti.ir_string(ir, b.schema_name), a)
		kind_kw := "source" if b.kind == .Source else "derived"
		sel_path := _binding_selector_str(ir, b, a)
		binding_map[bname] = bi
		append(&idx.bindings, bname)
		idx.binding_schemas[bname] = sname
		binding_hovers[bi] = fmt.aprintf("```forseti\n%s %s : %s at %s\n```", kind_kw, bname, sname, sel_path, allocator = a)

		rng := span_to_lsp_range(src, line_starts, b.span)
		sel := rng
		if nsp, ok := _find_word_span(src, b.span, bname); ok {
			sel = span_to_lsp_range(src, line_starts, nsp)
			append(&idx.entries, Lsp_Def_Entry{span = nsp, target_span = b.span, hover_md = binding_hovers[bi]})
			if si, has_s := schema_map[sname]; has_s {
				if ssp, s_ok := _find_word_span(src, b.span, sname, nsp.offset + nsp.len); s_ok {
					append(&idx.entries, Lsp_Def_Entry{span = ssp, target_span = ir.schemas[si].span, hover_md = schema_hovers[si]})
				}
			}
		}
		append(&idx.symbols, Lsp_Symbol{name = bname, detail = fmt.aprintf("%s : %s", kind_kw, sname, allocator = a), kind = 13, range = rng, sel_range = sel})
	}

	table_map := make(map[string]int, len(ir.tables) + 4, a)
	table_hovers := make([]string, len(ir.tables), a)
	for t, ti in ir.tables {
		tname := strings.clone(forseti.ir_string(ir, t.name), a)
		ver := forseti.ir_string(ir, t.version)
		table_map[tname] = ti
		append(&idx.tables, tname)

		sb: strings.Builder
		strings.builder_init(&sb, a)
		fmt.sbprintf(&sb, "```forseti\ntable %s version %q hit %s\ninputs: ", tname, ver, _hit_policy_str(t.hit_policy))
		in_names := make([]string, len(t.inputs), a)
		for col, ci in t.inputs {
			if ci > 0 {
				strings.write_string(&sb, ", ")
			}
			in_names[ci] = strings.clone(forseti.ir_string(ir, col.name), a)
			fmt.sbprintf(&sb, "%s: %s", in_names[ci], _type_ref_str(ir, col.type, a))
		}
		idx.table_inputs[tname] = in_names
		strings.write_string(&sb, "\noutputs: ")
		out_names := make([]string, len(t.outputs), a)
		out_types := make([]string, len(t.outputs), a)
		for col, ci in t.outputs {
			if ci > 0 {
				strings.write_string(&sb, ", ")
			}
			out_names[ci] = strings.clone(forseti.ir_string(ir, col.name), a)
			out_types[ci] = strings.clone(_type_ref_str(ir, col.type, a), a)
			fmt.sbprintf(&sb, "%s: %s", out_names[ci], out_types[ci])
		}
		strings.write_string(&sb, "\n```")
		table_hovers[ti] = strings.to_string(sb)
		idx.table_outputs[tname] = out_names

		append(&idx.tables_meta, Lsp_Table_Meta{
			name           = tname,
			span           = t.span,
			rows_close_off = _find_rows_close_offset(src, t.span),
			num_inputs     = len(t.inputs),
			output_types   = out_types,
		})

		rng := span_to_lsp_range(src, line_starts, t.span)
		sel := rng
		if nsp, ok := _find_word_span(src, t.span, tname); ok {
			sel = span_to_lsp_range(src, line_starts, nsp)
			append(&idx.entries, Lsp_Def_Entry{span = nsp, target_span = t.span, hover_md = table_hovers[ti]})
		}
		append(&idx.symbols, Lsp_Symbol{name = tname, detail = _hit_policy_str(t.hit_policy), kind = 12, range = rng, sel_range = sel})
	}

	for r, ri in ir.rules {
		rname := strings.clone(forseti.ir_string(ir, r.name), a)
		stratum := u32(0)
		if strat != nil && ri < len(strat.rule_stratum) {
			stratum = strat.rule_stratum[ri]
		}
		sb: strings.Builder
		strings.builder_init(&sb, a)
		fmt.sbprintf(&sb, "```forseti\nrule %s", rname)
		if r.phase != forseti.EMPTY_STRING {
			fmt.sbprintf(&sb, " phase %q", forseti.ir_string(ir, r.phase))
		}
		if r.has_salience {
			fmt.sbprintf(&sb, " salience %d", r.salience)
		}
		fmt.sbprintf(&sb, "\n```\nstratum %d", stratum)
		r_hover := strings.to_string(sb)

		rng := span_to_lsp_range(src, line_starts, r.span)
		sel := rng
		if nsp, ok := _find_word_span(src, r.span, rname); ok {
			sel = span_to_lsp_range(src, line_starts, nsp)
			append(&idx.entries, Lsp_Def_Entry{span = nsp, target_span = r.span, hover_md = r_hover})
		}
		append(&idx.symbols, Lsp_Symbol{name = rname, detail = fmt.aprintf("stratum %d", stratum, allocator = a), kind = 12, range = rng, sel_range = sel})

		vars := make(map[string]_Var_Binder, 16, a)
		_walk_clauses_index(src, ir, r.when_clauses, &binding_map, &table_map, binding_hovers, table_hovers, &vars, &idx.entries, &idx.var_completions, a)
		for act in r.then_actions {
			tname := forseti.ir_string(ir, act.target)
			if bi, has_b := binding_map[tname]; has_b {
				if bsp, ok := _find_word_span(src, act.span, tname); ok {
					append(&idx.entries, Lsp_Def_Entry{span = bsp, target_span = ir.bindings[bi].span, hover_md = binding_hovers[bi]})
				}
			}
			for fb in act.fields {
				_walk_expr_vars(ir, fb.expr, &vars, &idx.entries, a)
			}
			_walk_expr_vars(ir, act.expr, &vars, &idx.entries, a)
			_walk_expr_vars(ir, act.attr_expr, &vars, &idx.entries, a)
			_walk_expr_vars(ir, act.val_expr, &vars, &idx.entries, a)
		}
	}

	for q in ir.queries {
		qname := strings.clone(forseti.ir_string(ir, q.name), a)
		q_hover := fmt.aprintf("```forseti\nquery %s(%d params)\n```", qname, len(q.params), allocator = a)
		rng := span_to_lsp_range(src, line_starts, q.span)
		sel := rng
		if nsp, ok := _find_word_span(src, q.span, qname); ok {
			sel = span_to_lsp_range(src, line_starts, nsp)
			append(&idx.entries, Lsp_Def_Entry{span = nsp, target_span = q.span, hover_md = q_hover})
		}
		append(&idx.symbols, Lsp_Symbol{name = qname, detail = "query", kind = 12, range = rng, sel_range = sel})

		vars := make(map[string]_Var_Binder, 8, a)
		for qp in q.params {
			pname := forseti.ir_string(ir, qp.name)
			vname := fmt.aprintf("?%s", pname, allocator = a)
			_record_var_binder(ir, vname, qp.span, _type_ref_str(ir, qp.type, a), &vars, &idx.entries, a)
		}
		_walk_clauses_index(src, ir, q.when_clauses, &binding_map, &table_map, binding_hovers, table_hovers, &vars, &idx.entries, &idx.var_completions, a)
	}
	return idx
}

index_lookup_at :: proc(idx: ^Lsp_Doc_Index, byte_off: u32) -> (entry: Lsp_Def_Entry, ok: bool) {
	if idx == nil {
		return {}, false
	}
	best_len := max(u32)
	found := false
	for e in idx.entries {
		start := e.span.offset
		end := e.span.offset + e.span.len
		if byte_off >= start && byte_off <= end {
			if e.span.len <= best_len {
				best_len = e.span.len
				entry = e
				found = true
			}
		}
	}
	return entry, found
}
