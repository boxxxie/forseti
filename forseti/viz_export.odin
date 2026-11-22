package forseti

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

@(private)
_write_dot_escaped :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			strings.write_byte(b, ch)
		}
	}
}

@(private)
_write_mermaid_escaped :: proc(b: ^strings.Builder, s: string) {
	for i := 0; i < len(s); i += 1 {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(b, `'`)
		case '|':
			strings.write_string(b, "&#124;")
		case '\n', '\r':
			strings.write_byte(b, ' ')
		case '`':
			strings.write_byte(b, '\'')
		case:
			strings.write_byte(b, ch)
		}
	}
}

@(private)
_Viz_Eq_Entry :: struct {
	key:   Value_Key,
	child: u32,
}

@(private)
_sort_eq_entries :: proc(buckets: ^map[Value_Key]u32, alloc: mem.Allocator) -> (out: []_Viz_Eq_Entry, err: mem.Allocator_Error) {
	if buckets == nil || len(buckets^) == 0 {
		return nil, nil
	}
	list := make([dynamic]_Viz_Eq_Entry, 0, len(buckets^), alloc) or_return
	for k, child in buckets^ {
		append(&list, _Viz_Eq_Entry{key = k, child = child})
	}
	slice.sort_by(list[:], proc(a, b: _Viz_Eq_Entry) -> bool {
		if a.key.kind != b.key.kind {
			return u8(a.key.kind) < u8(b.key.kind)
		}
		return a.key.raw < b.key.raw
	})
	return list[:], nil
}

@(private)
_write_value_key_label :: proc(b: ^strings.Builder, rb: ^Rulebase, k: Value_Key, for_mermaid: bool) {
	switch k.kind {
	case .Bool:
		strings.write_string(b, "true" if k.raw != 0 else "false")
	case .I32, .I64:
		fmt.sbprintf(b, "%d", i64(k.raw))
	case .F64:
		fmt.sbprintf(b, "%v", transmute(f64)k.raw)
	case .String:
		strings.write_byte(b, '\'')
		s := interner_get(&rb.interner, String_Id(u32(k.raw)))
		if for_mermaid {
			_write_mermaid_escaped(b, s)
		} else {
			_write_dot_escaped(b, s)
		}
		strings.write_byte(b, '\'')
	case .Entity:
		fmt.sbprintf(b, "entity:%d", k.raw)
	case .Time:
		fmt.sbprintf(b, "time:%d", i64(k.raw))
	case .Enum:
		fmt.sbprintf(b, "enum:%d:%d", k.raw >> 32, k.raw & 0xffffffff)
	case .Unknown, .Fact, .Table_Result:
		fmt.sbprintf(b, "raw:%d", k.raw)
	}
}

@(private)
_op_symbol :: proc "contextless" (op: Binary_Op) -> string {
	switch op {
	case .Eq:  return "=="
	case .Neq: return "!="
	case .Lt:  return "<"
	case .Lte: return "<="
	case .Gt:  return ">"
	case .Gte: return ">="
	case .And: return "and"
	case .Or:  return "or"
	case .Add: return "+"
	case .Sub: return "-"
	case .Mul: return "*"
	case .Div: return "/"
	case .Mod: return "%"
	}
	return "?"
}

// Exports the compiled PHREAK / Rete-UL rulebase network in deterministic Graphviz DOT format.
@(require_results)
export_rulebase_dot :: proc(
	rb: ^Rulebase,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, "digraph forseti_rulebase {\n")
	strings.write_string(&b, "  rankdir=LR;\n")
	if rb == nil {
		strings.write_string(&b, "}\n")
		return strings.to_string(b), nil
	}

	for ar in rb.alpha_roots {
		bname := interner_get(&rb.interner, rb.bindings[ar.binding_idx].name)
		fmt.sbprintf(&b, `  bind_%d [shape=box,label="`, ar.binding_idx)
		_write_dot_escaped(&b, bname)
		strings.write_string(&b, "\"];\n")
		fmt.sbprintf(&b, "  bind_%d -> an_%d;\n", ar.binding_idx, ar.root_node)
	}

	for &an in rb.alpha_nodes {
		if an.eq_field >= 0 {
			fmt.sbprintf(&b, `  an_%d [shape=ellipse,label="alpha #%d (field %d)"];`, an.id, an.id, an.eq_field)
		} else {
			fmt.sbprintf(&b, `  an_%d [shape=ellipse,label="alpha #%d"];`, an.id, an.id)
		}
		strings.write_byte(&b, '\n')

		eqs := _sort_eq_entries(an.eq_buckets, allocator) or_return
		for e in eqs {
			fmt.sbprintf(&b, `  an_%d -> an_%d [label="= `, an.id, e.child)
			_write_value_key_label(&b, rb, e.key, for_mermaid = false)
			strings.write_string(&b, "\"];\n")
		}
		delete(eqs, allocator)

		for re in an.range_edges {
			fmt.sbprintf(&b, `  an_%d -> an_%d [label="f%d %s"];`, an.id, re.child, re.field_idx, _op_symbol(re.op))
			strings.write_byte(&b, '\n')
		}
		for ge in an.guard_edges {
			fmt.sbprintf(&b, `  an_%d -> an_%d [label="guard #%d"];`, an.id, ge.child, ge.prog_idx)
			strings.write_byte(&b, '\n')
		}
		if an.terminal_id >= 0 {
			fmt.sbprintf(&b, "  an_%d -> at_%d;\n", an.id, an.terminal_id)
		}
	}

	for &at in rb.alpha_terminals {
		bname := interner_get(&rb.interner, rb.bindings[at.binding_idx].name)
		fmt.sbprintf(&b, `  at_%d [shape=diamond,label="mem #%d (`, at.id, at.id)
		_write_dot_escaped(&b, bname)
		strings.write_string(&b, ")\"];\n")
		for sub in at.subscribers {
			if sub.notify_only {
				fmt.sbprintf(&b, `  at_%d -> seg_%d [style=dotted,label="notify"];`, at.id, sub.seg_id)
			} else {
				fmt.sbprintf(&b, "  at_%d -> seg_%d;\n", at.id, sub.seg_id)
				continue
			}
			strings.write_byte(&b, '\n')
		}
	}

	for &seg in rb.segments {
		fmt.sbprintf(&b, `  seg_%d [shape=component,label="seg #%d (nodes=%d)"];`, seg.id, seg.id, seg.node_count)
		strings.write_byte(&b, '\n')
		fmt.sbprintf(&b, "  seg_%d -> rule_%d;\n", seg.id, seg.rule_id)
	}

	for &tbl, ti in rb.tables {
		tname := compiled_table_string(&tbl, tbl.table_name)
		fmt.sbprintf(&b, `  tbl_%d [shape=note,label="table `, ti)
		_write_dot_escaped(&b, tname)
		fmt.sbprintf(&b, ` (%v, %d rows)"];`, tbl.hit_policy, tbl.row_count)
		strings.write_byte(&b, '\n')
	}

	for &rc in rb.rules {
		rname := interner_get(&rb.interner, rc.name)
		pname := interner_get(&rb.interner, rc.phase)
		fmt.sbprintf(&b, `  rule_%d [shape=doubleoctagon,label="`, rc.id)
		_write_dot_escaped(&b, rname)
		if len(pname) > 0 {
			fmt.sbprintf(&b, `\nphase=`)
			_write_dot_escaped(&b, pname)
			fmt.sbprintf(&b, ` sal=%d str=%d`, rc.salience, rc.stratum)
		} else {
			fmt.sbprintf(&b, `\nsal=%d str=%d`, rc.salience, rc.stratum)
		}
		if rc.is_recursive {
			strings.write_string(&b, " rec")
		}
		strings.write_string(&b, "\"];\n")
		if rc.decide_table_idx != INVALID_TABLE_IDX && int(rc.decide_table_idx) < len(rb.tables) {
			fmt.sbprintf(&b, `  rule_%d -> tbl_%d [style=dashed,label="decide"];`, rc.id, rc.decide_table_idx)
			strings.write_byte(&b, '\n')
		}
	}

	strings.write_string(&b, "}\n")
	return strings.to_string(b), nil
}

// Exports the compiled rulebase topology in deterministic Mermaid flowchart LR format.
@(require_results)
export_rulebase_mermaid :: proc(
	rb: ^Rulebase,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, "flowchart LR\n")
	if rb == nil {
		return strings.to_string(b), nil
	}

	for ar in rb.alpha_roots {
		bname := interner_get(&rb.interner, rb.bindings[ar.binding_idx].name)
		fmt.sbprintf(&b, `  bind_%d["`, ar.binding_idx)
		_write_mermaid_escaped(&b, bname)
		strings.write_string(&b, "\"]\n")
		fmt.sbprintf(&b, "  bind_%d --> an_%d\n", ar.binding_idx, ar.root_node)
	}

	for &an in rb.alpha_nodes {
		fmt.sbprintf(&b, `  an_%d(("alpha #%d"))`, an.id, an.id)
		strings.write_byte(&b, '\n')
		eqs := _sort_eq_entries(an.eq_buckets, allocator) or_return
		for e in eqs {
			fmt.sbprintf(&b, `  an_%d -->|"= `, an.id)
			_write_value_key_label(&b, rb, e.key, for_mermaid = true)
			fmt.sbprintf(&b, `"| an_%d`, e.child)
			strings.write_byte(&b, '\n')
		}
		delete(eqs, allocator)

		for re in an.range_edges {
			fmt.sbprintf(&b, `  an_%d -->|"f%d %s"| an_%d`, an.id, re.field_idx, _op_symbol(re.op), re.child)
			strings.write_byte(&b, '\n')
		}
		for ge in an.guard_edges {
			fmt.sbprintf(&b, `  an_%d -->|"guard #%d"| an_%d`, an.id, ge.prog_idx, ge.child)
			strings.write_byte(&b, '\n')
		}
		if an.terminal_id >= 0 {
			fmt.sbprintf(&b, "  an_%d --> at_%d\n", an.id, an.terminal_id)
		}
	}

	for &at in rb.alpha_terminals {
		bname := interner_get(&rb.interner, rb.bindings[at.binding_idx].name)
		fmt.sbprintf(&b, "  at_%d", at.id)
		strings.write_string(&b, `{"mem #`)
		fmt.sbprintf(&b, "%d ", at.id)
		_write_mermaid_escaped(&b, bname)
		strings.write_string(&b, "\"}\n")
		for sub in at.subscribers {
			if sub.notify_only {
				fmt.sbprintf(&b, "  at_%d -. notify .-> seg_%d\n", at.id, sub.seg_id)
			} else {
				fmt.sbprintf(&b, "  at_%d --> seg_%d\n", at.id, sub.seg_id)
			}
		}
	}

	for &seg in rb.segments {
		fmt.sbprintf(&b, `  seg_%d["seg #%d (%d nodes)"]`, seg.id, seg.id, seg.node_count)
		strings.write_byte(&b, '\n')
		fmt.sbprintf(&b, "  seg_%d --> rule_%d\n", seg.id, seg.rule_id)
	}

	for &tbl, ti in rb.tables {
		tname := compiled_table_string(&tbl, tbl.table_name)
		fmt.sbprintf(&b, `  tbl_%d["table `, ti)
		_write_mermaid_escaped(&b, tname)
		fmt.sbprintf(&b, ` (%v)"]`, tbl.hit_policy)
		strings.write_byte(&b, '\n')
	}

	for &rc in rb.rules {
		rname := interner_get(&rb.interner, rc.name)
		fmt.sbprintf(&b, `  rule_%d[["`, rc.id)
		_write_mermaid_escaped(&b, rname)
		fmt.sbprintf(&b, ` (stratum=%d)"]]`, rc.stratum)
		strings.write_byte(&b, '\n')
		if rc.decide_table_idx != INVALID_TABLE_IDX && int(rc.decide_table_idx) < len(rb.tables) {
			fmt.sbprintf(&b, "  rule_%d -. decide .-> tbl_%d\n", rc.id, rc.decide_table_idx)
		}
	}

	return strings.to_string(b), nil
}

@(private)
_collect_derivation_subgraph :: proc(
	s: ^Session,
	focus_fact: Fact_Id,
	alloc: mem.Allocator,
) -> (fact_ids: []Fact_Id, deriv_ids: []Derivation_Id, err: mem.Allocator_Error) {
	if s == nil || s.rb == nil {
		return nil, nil, nil
	}
	fset := make(map[Fact_Id]bool, 16, alloc) or_return
	defer delete(fset)
	dset := make(map[Derivation_Id]bool, 16, alloc) or_return
	defer delete(dset)

	if focus_fact != INVALID_FACT {
		if int(focus_fact) >= len(s.facts) || !s.facts[focus_fact].alive {
			return nil, nil, nil
		}
		queue := make([dynamic]Fact_Id, 0, 16, alloc) or_return
		defer delete(queue)
		fset[focus_fact] = true
		append(&queue, focus_fact)
		for qi := 0; qi < len(queue); qi += 1 {
			cur := queue[qi]
			if s.provenance.mode != .Audit_Full {
				continue
			}
			if flist, has := s.provenance.fact_derivs[cur]; has {
				for did in flist {
					if int(did) >= len(s.provenance.derivs) || !s.provenance.derivs[did].alive {
						continue
					}
					parents := provenance_parents(&s.provenance, did)
					all_alive := true
					for pf in parents {
						if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
							all_alive = false
							break
						}
					}
					if !all_alive {
						continue
					}
					dset[did] = true
					for pf in parents {
						if !(pf in fset) {
							fset[pf] = true
							append(&queue, pf)
						}
					}
				}
			}
		}
	} else {
		for &f in s.facts {
			if f.id != INVALID_FACT && f.alive {
				fset[f.id] = true
			}
		}
		if s.provenance.mode == .Audit_Full {
			for di := 1; di < len(s.provenance.derivs); di += 1 {
				d := s.provenance.derivs[di]
				if !d.alive || d.derived_fact == INVALID_FACT || int(d.derived_fact) >= len(s.facts) || !s.facts[d.derived_fact].alive {
					continue
				}
				parents := provenance_parents(&s.provenance, Derivation_Id(di))
				all_alive := true
				for pf in parents {
					if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
						all_alive = false
						break
					}
				}
				if all_alive {
					dset[Derivation_Id(di)] = true
				}
			}
		}
	}

	flist := make([]Fact_Id, len(fset), alloc) or_return
	defer if err != nil {
		delete(flist, alloc)
	}
	fi := 0
	for fid in fset {
		flist[fi] = fid
		fi += 1
	}
	slice.sort(flist)

	dlist := make([]Derivation_Id, len(dset), alloc) or_return
	di := 0
	for did in dset {
		dlist[di] = did
		di += 1
	}
	slice.sort(dlist)
	return flist, dlist, nil
}

// Exports the alive causal derivation DAG in deterministic Graphviz DOT format.
@(require_results)
export_derivations_dot :: proc(
	s: ^Session,
	focus_fact: Fact_Id = INVALID_FACT,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, "digraph forseti_derivations {\n")
	strings.write_string(&b, "  rankdir=TB;\n")

	fids, dids := _collect_derivation_subgraph(s, focus_fact, allocator) or_return
	defer {
		delete(fids, allocator)
		delete(dids, allocator)
	}

	for fid in fids {
		f := &s.facts[fid]
		sum := _format_fact_summary(s, fid, allocator)
		fmt.sbprintf(&b, `  f_%d [shape=box,label="`, u32(fid))
		_write_dot_escaped(&b, sum)
		if len(sum) > 0 {
			delete(sum, allocator)
		}
		fmt.sbprintf(&b, `\nh=%d %v"];`, f.proof_height, f.origin)
		strings.write_byte(&b, '\n')
	}

	for did in dids {
		d := s.provenance.derivs[did]
		rname := interner_get(&s.rb.interner, s.rb.rules[d.rule_id].name) if int(d.rule_id) < len(s.rb.rules) else "rule"
		fmt.sbprintf(&b, `  d_%d [shape=ellipse,label="dec:%d `, u32(did), u32(did))
		_write_dot_escaped(&b, rname)
		if d.table_idx != INVALID_TABLE_IDX && int(d.table_idx) < len(s.rb.tables) {
			ct := &s.rb.tables[d.table_idx]
			tname := compiled_table_string(ct, ct.table_name)
			strings.write_string(&b, `\n`)
			_write_dot_escaped(&b, tname)
			if d.table_row_id != INVALID_ROW_ID && int(d.table_row_id) < len(ct.row_ids) {
				strings.write_byte(&b, ':')
				_write_dot_escaped(&b, compiled_table_string(ct, ct.row_ids[d.table_row_id]))
			}
		}
		strings.write_string(&b, "\"];\n")
		parents := provenance_parents(&s.provenance, did)
		for pf in parents {
			fmt.sbprintf(&b, "  f_%d -> d_%d;\n", u32(pf), u32(did))
		}
		fmt.sbprintf(&b, "  d_%d -> f_%d;\n", u32(did), u32(d.derived_fact))
	}

	strings.write_string(&b, "}\n")
	return strings.to_string(b), nil
}

// Exports the alive causal derivation DAG in deterministic Mermaid flowchart TD format.
@(require_results)
export_derivations_mermaid :: proc(
	s: ^Session,
	focus_fact: Fact_Id = INVALID_FACT,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	strings.write_string(&b, "flowchart TD\n")

	fids, dids := _collect_derivation_subgraph(s, focus_fact, allocator) or_return
	defer {
		delete(fids, allocator)
		delete(dids, allocator)
	}

	for fid in fids {
		f := &s.facts[fid]
		sum := _format_fact_summary(s, fid, allocator)
		fmt.sbprintf(&b, `  f_%d["`, u32(fid))
		_write_mermaid_escaped(&b, sum)
		if len(sum) > 0 {
			delete(sum, allocator)
		}
		fmt.sbprintf(&b, ` (h=%d, %v)"]`, f.proof_height, f.origin)
		strings.write_byte(&b, '\n')
	}

	for did in dids {
		d := s.provenance.derivs[did]
		rname := interner_get(&s.rb.interner, s.rb.rules[d.rule_id].name) if int(d.rule_id) < len(s.rb.rules) else "rule"
		fmt.sbprintf(&b, `  d_%d(["dec:%d `, u32(did), u32(did))
		_write_mermaid_escaped(&b, rname)
		if d.table_idx != INVALID_TABLE_IDX && int(d.table_idx) < len(s.rb.tables) {
			ct := &s.rb.tables[d.table_idx]
			tname := compiled_table_string(ct, ct.table_name)
			strings.write_byte(&b, ' ')
			_write_mermaid_escaped(&b, tname)
			if d.table_row_id != INVALID_ROW_ID && int(d.table_row_id) < len(ct.row_ids) {
				strings.write_byte(&b, ':')
				_write_mermaid_escaped(&b, compiled_table_string(ct, ct.row_ids[d.table_row_id]))
			}
		}
		strings.write_string(&b, "\"])\n")
		parents := provenance_parents(&s.provenance, did)
		for pf in parents {
			fmt.sbprintf(&b, "  f_%d --> d_%d\n", u32(pf), u32(did))
		}
		fmt.sbprintf(&b, "  d_%d --> f_%d\n", u32(did), u32(d.derived_fact))
	}

	return strings.to_string(b), nil
}
