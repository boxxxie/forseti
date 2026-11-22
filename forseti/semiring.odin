package forseti

import "core:fmt"
import "core:mem"
import "core:strings"

Explain_Node :: struct {
	fact_id:      Fact_Id,
	binding_name: string,
	fact_key:     string,
	fact_summary: string,
	rule_name:    string,
	rule_version: string,
	table_name:   string,
	table_row:    string,
	origin:       Fact_Origin,
	proof_height: u32,
	children:     []Explain_Node,
}

Explain_Tree :: struct {
	root:      Explain_Node,
	found:     bool,
	allocator: mem.Allocator,
}

Impact_Report :: struct {
	rule_id:          u32,
	rule_name:        string,
	direct_facts:     []Fact_Id,
	transitive_facts: []Fact_Id,
	derivations:      []Derivation_Id,
	allocator:        mem.Allocator,
}

Semiring_Kind :: enum u8 {
	Boolean,
	Why,
	How,
	Viterbi,
}

Why_Provenance_Set :: struct {
	fact_ids: []Fact_Id,
}

Semiring_Result :: struct {
	kind:           Semiring_Kind,
	boolean_val:    bool,
	why_sets:       []Why_Provenance_Set,
	how_expr:       string,
	viterbi_score:  f64,
	viterbi_height: u32,
	viterbi_path:   []Fact_Id,
	allocator:      mem.Allocator,
}

@(private)
_explain_node_destroy :: proc(n: ^Explain_Node, alloc: mem.Allocator) {
	if len(n.binding_name) > 0 {
		delete(n.binding_name, alloc)
	}
	if len(n.fact_key) > 0 {
		delete(n.fact_key, alloc)
	}
	if len(n.fact_summary) > 0 {
		delete(n.fact_summary, alloc)
	}
	if len(n.rule_name) > 0 {
		delete(n.rule_name, alloc)
	}
	if len(n.rule_version) > 0 {
		delete(n.rule_version, alloc)
	}
	if len(n.table_name) > 0 {
		delete(n.table_name, alloc)
	}
	if len(n.table_row) > 0 {
		delete(n.table_row, alloc)
	}
	for &c in n.children {
		_explain_node_destroy(&c, alloc)
	}
	delete(n.children, alloc)
}

explain_tree_destroy :: proc(tree: ^Explain_Tree) {
	if tree == nil || tree.allocator.procedure == nil {
		return
	}
	_explain_node_destroy(&tree.root, tree.allocator)
	tree^ = {}
}

impact_report_destroy :: proc(rep: ^Impact_Report) {
	if rep == nil || rep.allocator.procedure == nil {
		return
	}
	a := rep.allocator
	if len(rep.rule_name) > 0 {
		delete(rep.rule_name, a)
	}
	delete(rep.direct_facts, a)
	delete(rep.transitive_facts, a)
	delete(rep.derivations, a)
	rep^ = {}
}

semiring_result_destroy :: proc(res: ^Semiring_Result) {
	if res == nil || res.allocator.procedure == nil {
		return
	}
	a := res.allocator
	for ws in res.why_sets {
		delete(ws.fact_ids, a)
	}
	delete(res.why_sets, a)
	if len(res.how_expr) > 0 {
		delete(res.how_expr, a)
	}
	delete(res.viterbi_path, a)
	res^ = {}
}

@(private)
_format_fact_summary :: proc(s: ^Session, fid: Fact_Id, alloc: mem.Allocator) -> string {
	if fid == INVALID_FACT || int(fid) >= len(s.facts) {
		return ""
	}
	f := &s.facts[fid]
	bdef := s.rb.bindings[f.binding_idx]
	schema := s.rb.schemas[bdef.schema_id]
	bname := interner_get(&s.rb.interner, bdef.name)

	b: strings.Builder
	strings.builder_init(&b, alloc)
	fmt.sbprintf(&b, "%s(", bname)
	for sf, i in schema.fields {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fname := interner_get(&s.rb.interner, sf.name)
		fmt.sbprintf(&b, "%s=", fname)
		val, found := fact_get_field(s, f, i16(i))
		if !found || val == nil {
			strings.write_byte(&b, '?')
			continue
		}
		switch x in val {
		case bool:
			strings.write_string(&b, "true" if x else "false")
		case i32:
			fmt.sbprintf(&b, "%d", x)
		case i64:
			fmt.sbprintf(&b, "%d", x)
		case f64:
			fmt.sbprintf(&b, "%v", x)
		case String_Id:
			fmt.sbprintf(&b, "%q", session_string(s, x))
		case Entity_Id:
			fmt.sbprintf(&b, "%d", u64(x))
		case Time_Ns:
			fmt.sbprintf(&b, "%d", i64(x))
		case Enum_Val:
			fmt.sbprintf(&b, "%d:%d", x.enum_id, x.variant)
		}
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b)
}

@(private)
_pick_best_alive_derivation :: proc(s: ^Session, fid: Fact_Id) -> (did: Derivation_Id, ok: bool) {
	if s.provenance.mode != .Audit_Full {
		return INVALID_DERIVATION, false
	}
	f := &s.facts[fid]
	if f.best_derivation != INVALID_DERIVATION && int(f.best_derivation) < len(s.provenance.derivs) {
		bd := s.provenance.derivs[f.best_derivation]
		if bd.alive {
			parents_alive := true
			for pf in provenance_parents(&s.provenance, f.best_derivation) {
				if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
					parents_alive = false
					break
				}
			}
			if parents_alive {
				return f.best_derivation, true
			}
		}
	}

	flist, has := s.provenance.fact_derivs[fid]
	if !has {
		return INVALID_DERIVATION, false
	}
	best_h := max(u32)
	for cand_did in flist {
		d := s.provenance.derivs[cand_did]
		if !d.alive {
			continue
		}
		parents_alive := true
		for pf in provenance_parents(&s.provenance, cand_did) {
			if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
				parents_alive = false
				break
			}
		}
		if parents_alive && d.proof_height < best_h {
			best_h = d.proof_height
			did = cand_did
			ok = true
		}
	}
	return did, ok
}

@(private)
_build_explain_node :: proc(
	s: ^Session,
	fid: Fact_Id,
	visited: ^map[Fact_Id]bool,
	alloc: mem.Allocator,
) -> Explain_Node {
	f := &s.facts[fid]
	bdef := s.rb.bindings[f.binding_idx]
	bname := interner_get(&s.rb.interner, bdef.name)
	fkey := session_string(s, f.key)

	node := Explain_Node{
		fact_id      = fid,
		binding_name = strings.clone(bname, alloc),
		fact_key     = strings.clone(fkey, alloc),
		fact_summary = _format_fact_summary(s, fid, alloc),
		origin       = f.origin,
		proof_height = f.proof_height,
	}

	if fid in visited^ {
		return node
	}
	visited^[fid] = true
	defer delete_key(visited, fid)

	if did, has_d := _pick_best_alive_derivation(s, fid); has_d {
		d := s.provenance.derivs[did]
		node.proof_height = d.proof_height
		if int(d.rule_id) < len(s.rb.rules) {
			rc := s.rb.rules[d.rule_id]
			node.rule_name = strings.clone(interner_get(&s.rb.interner, rc.name), alloc)
			node.rule_version = strings.clone(interner_get(&s.rb.interner, rc.version), alloc)
		}
		if d.table_idx != INVALID_TABLE_IDX && int(d.table_idx) < len(s.rb.tables) {
			ct := &s.rb.tables[d.table_idx]
			node.table_name = strings.clone(compiled_table_string(ct, ct.table_name), alloc)
			if d.table_row_id != INVALID_ROW_ID && int(d.table_row_id) < len(ct.row_ids) {
				node.table_row = strings.clone(compiled_table_string(ct, ct.row_ids[d.table_row_id]), alloc)
			}
		}
		parents := provenance_parents(&s.provenance, did)
		children := make([]Explain_Node, len(parents), alloc)
		for pf, i in parents {
			children[i] = _build_explain_node(s, pf, visited, alloc)
		}
		node.children = children
	}
	return node
}

// Reconstructs a finite minimal acyclic proof tree for an alive derived (or base) fact.
explain :: proc(
	s: ^Session,
	fid: Fact_Id,
	allocator := context.allocator,
) -> Explain_Tree {
	if s == nil || s.rb == nil || fid == INVALID_FACT || int(fid) >= len(s.facts) || !s.facts[fid].alive {
		return Explain_Tree{found = false, allocator = allocator}
	}
	visited := make(map[Fact_Id]bool, 16, context.temp_allocator)
	root := _build_explain_node(s, fid, &visited, allocator)
	return Explain_Tree{
		root      = root,
		found     = true,
		allocator = allocator,
	}
}

@(private)
_explain_write_indent :: proc(b: ^strings.Builder, n: ^Explain_Node, depth: int) {
	for _ in 0 ..< depth {
		strings.write_string(b, "  ")
	}
	fmt.sbprintf(b, "- %s [h=%d, origin=%v]", n.fact_summary, n.proof_height, n.origin)
	if len(n.rule_name) > 0 {
		fmt.sbprintf(b, " via rule=%s", n.rule_name)
	}
	if len(n.table_name) > 0 {
		fmt.sbprintf(b, " table=%s row=%s", n.table_name, n.table_row)
	}
	strings.write_byte(b, '\n')
	for &c in n.children {
		_explain_write_indent(b, &c, depth + 1)
	}
}

explain_format :: proc(tree: ^Explain_Tree, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	if tree == nil || !tree.found {
		strings.write_string(&b, "<no explanation>\n")
		return strings.to_string(b)
	}
	_explain_write_indent(&b, &tree.root, 0)
	return strings.to_string(b)
}

@(private)
_origin_string :: proc "contextless" (o: Fact_Origin) -> string {
	switch o {
	case .External:      return "External"
	case .Logical:       return "Logical"
	case .Unconditional: return "Unconditional"
	}
	return "External"
}

@(private)
_write_explain_node_json :: proc(b: ^strings.Builder, n: ^Explain_Node) {
	strings.write_string(b, `{"fact_id":`)
	fmt.sbprintf(b, "%d", u32(n.fact_id))
	strings.write_string(b, `,"binding":`)
	write_json_escaped_string(b, n.binding_name)
	strings.write_string(b, `,"key":`)
	write_json_escaped_string(b, n.fact_key)
	strings.write_string(b, `,"summary":`)
	write_json_escaped_string(b, n.fact_summary)
	strings.write_string(b, `,"origin":`)
	write_json_escaped_string(b, _origin_string(n.origin))
	fmt.sbprintf(b, `,"proof_height":%d`, n.proof_height)
	strings.write_string(b, `,"rule":`)
	write_json_escaped_string(b, n.rule_name)
	strings.write_string(b, `,"rule_version":`)
	write_json_escaped_string(b, n.rule_version)
	strings.write_string(b, `,"table":`)
	write_json_escaped_string(b, n.table_name)
	strings.write_string(b, `,"table_row":`)
	write_json_escaped_string(b, n.table_row)
	strings.write_string(b, `,"children":[`)
	for &c, i in n.children {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		_write_explain_node_json(b, &c)
	}
	strings.write_string(b, "]}")
}

@(require_results)
explain_format_json :: proc(
	tree: ^Explain_Tree,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	if tree == nil || !tree.found {
		strings.write_string(&b, `{"found":false,"root":null}`)
		return strings.to_string(b), nil
	}
	strings.write_string(&b, `{"found":true,"root":`)
	_write_explain_node_json(&b, &tree.root)
	strings.write_byte(&b, '}')
	return strings.to_string(b), nil
}

@(private)
_write_impact_fact_entry :: proc(b: ^strings.Builder, s: ^Session, fid: Fact_Id, alloc: mem.Allocator, as_json: bool) {
	bname := ""
	fkey := ""
	summary := ""
	if s != nil && s.rb != nil && fid != INVALID_FACT && int(fid) < len(s.facts) {
		f := &s.facts[fid]
		bname = interner_get(&s.rb.interner, s.rb.bindings[f.binding_idx].name)
		fkey = session_string(s, f.key)
		summary = _format_fact_summary(s, fid, alloc)
	}
	defer if len(summary) > 0 {
		delete(summary, alloc)
	}

	if as_json {
		strings.write_string(b, `{"fact_id":`)
		fmt.sbprintf(b, "%d", u32(fid))
		strings.write_string(b, `,"binding":`)
		write_json_escaped_string(b, bname)
		strings.write_string(b, `,"key":`)
		write_json_escaped_string(b, fkey)
		strings.write_string(b, `,"summary":`)
		write_json_escaped_string(b, summary)
		strings.write_byte(b, '}')
	} else if len(summary) > 0 {
		fmt.sbprintf(b, "  - [%d] %s key=%s\n", u32(fid), summary, fkey)
	} else {
		fmt.sbprintf(b, "  - [%d]\n", u32(fid))
	}
}

@(require_results)
impact_format_human :: proc(
	s: ^Session,
	rep: ^Impact_Report,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	if rep == nil {
		strings.write_string(&b, "<no impact report>\n")
		return strings.to_string(b), nil
	}
	fmt.sbprintf(
		&b,
		"Impact rule=%s (id=%d): direct=%d transitive=%d derivations=%d\n",
		rep.rule_name,
		rep.rule_id,
		len(rep.direct_facts),
		len(rep.transitive_facts),
		len(rep.derivations),
	)
	if len(rep.direct_facts) > 0 {
		strings.write_string(&b, "Direct:\n")
		for fid in rep.direct_facts {
			_write_impact_fact_entry(&b, s, fid, allocator, as_json = false)
		}
	}
	if len(rep.transitive_facts) > 0 {
		strings.write_string(&b, "Transitive:\n")
		for fid in rep.transitive_facts {
			_write_impact_fact_entry(&b, s, fid, allocator, as_json = false)
		}
	}
	return strings.to_string(b), nil
}

@(require_results)
impact_format_json :: proc(
	s: ^Session,
	rep: ^Impact_Report,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	if rep == nil {
		strings.write_string(&b, `{"rule_id":0,"rule_name":"","direct_count":0,"transitive_count":0,"derivation_count":0,"direct_facts":[],"transitive_facts":[],"derivations":[]}`)
		return strings.to_string(b), nil
	}

	strings.write_string(&b, `{"rule_id":`)
	fmt.sbprintf(&b, "%d", rep.rule_id)
	strings.write_string(&b, `,"rule_name":`)
	write_json_escaped_string(&b, rep.rule_name)
	fmt.sbprintf(
		&b,
		`,"direct_count":%d,"transitive_count":%d,"derivation_count":%d,"direct_facts":[`,
		len(rep.direct_facts),
		len(rep.transitive_facts),
		len(rep.derivations),
	)
	for fid, i in rep.direct_facts {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		_write_impact_fact_entry(&b, s, fid, allocator, as_json = true)
	}
	strings.write_string(&b, `],"transitive_facts":[`)
	for fid, i in rep.transitive_facts {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		_write_impact_fact_entry(&b, s, fid, allocator, as_json = true)
	}
	strings.write_string(&b, `],"derivations":[`)
	for did, i in rep.derivations {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		fmt.sbprintf(&b, "%d", u32(did))
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), nil
}

@(private)
_write_json_fact_field_value :: proc(b: ^strings.Builder, s: ^Session, val: Value) {
	if val == nil {
		strings.write_string(b, "null")
		return
	}
	switch v in val {
	case bool:
		strings.write_string(b, "true" if v else "false")
	case i32:
		fmt.sbprintf(b, "%d", v)
	case i64:
		fmt.sbprintf(b, "%d", v)
	case f64:
		fmt.sbprintf(b, "%v", v)
	case String_Id:
		write_json_escaped_string(b, session_string(s, v))
	case Entity_Id:
		fmt.sbprintf(b, "%d", u64(v))
	case Time_Ns:
		fmt.sbprintf(b, "%d", i64(v))
	case Enum_Val:
		fmt.sbprintf(b, `"%d:%d"`, v.enum_id, v.variant)
	}
}

@(require_results)
session_format_run_output :: proc(
	s: ^Session,
	fired: u64,
	committed_moment: i64,
	as_json: bool,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}

	derived_count := 0
	if s != nil && s.rb != nil {
		for &f in s.facts {
			if f.alive && s.rb.bindings[f.binding_idx].kind == .Derived {
				derived_count += 1
			}
		}
	}

	if as_json {
		strings.write_string(&b, `{"fired":`)
		fmt.sbprintf(&b, "%d", fired)
		strings.write_string(&b, `,"derived_count":`)
		fmt.sbprintf(&b, "%d", derived_count)
		strings.write_string(&b, `,"committed_moment":`)
		fmt.sbprintf(&b, "%d", committed_moment)
		strings.write_string(&b, `,"derived":[`)
		emitted := 0
		if s != nil && s.rb != nil {
			for &f in s.facts {
				if !f.alive || s.rb.bindings[f.binding_idx].kind != .Derived {
					continue
				}
				if emitted > 0 {
					strings.write_byte(&b, ',')
				}
				emitted += 1
				bdef := s.rb.bindings[f.binding_idx]
				schema := s.rb.schemas[bdef.schema_id]
				bname := interner_get(&s.rb.interner, bdef.name)
				fkey := session_string(s, f.key)
				strings.write_string(&b, `{"fact_id":`)
				fmt.sbprintf(&b, "%d", u32(f.id))
				strings.write_string(&b, `,"binding":`)
				write_json_escaped_string(&b, bname)
				strings.write_string(&b, `,"key":`)
				write_json_escaped_string(&b, fkey)
				fmt.sbprintf(&b, `,"proof_height":%d`, f.proof_height)
				strings.write_string(&b, `,"fields":{`)
				for sf, sfi in schema.fields {
					if sfi > 0 {
						strings.write_byte(&b, ',')
					}
					fname := interner_get(&s.rb.interner, sf.name)
					write_json_escaped_string(&b, fname)
					strings.write_byte(&b, ':')
					val, found := fact_get_field(s, &f, i16(sfi))
					if found {
						_write_json_fact_field_value(&b, s, val)
					} else {
						strings.write_string(&b, "null")
					}
				}
				strings.write_string(&b, "}}")
			}
		}
		strings.write_string(&b, "]}\n")
	} else {
		fmt.sbprintf(&b, "Fired %d rule activation(s); %d derived fact(s) alive", fired, derived_count)
		if committed_moment >= 0 {
			fmt.sbprintf(&b, " (committed moment %d)", committed_moment)
		}
		strings.write_byte(&b, '\n')
		if s != nil && s.rb != nil {
			for &f in s.facts {
				if !f.alive || s.rb.bindings[f.binding_idx].kind != .Derived {
					continue
				}
				bdef := s.rb.bindings[f.binding_idx]
				bname := interner_get(&s.rb.interner, bdef.name)
				fkey := session_string(s, f.key)
				fmt.sbprintf(&b, "  - [%d] %s[%s] h=%d\n", u32(f.id), bname, fkey, f.proof_height)
			}
		}
	}
	return strings.to_string(b), nil
}

// Computes all direct and transitive alive facts and derivations affected by `rule_id` (optionally filtered by version).
impact :: proc(
	s: ^Session,
	rule_id: u32,
	version: string = "",
	allocator := context.allocator,
) -> Impact_Report {
	if s == nil || s.rb == nil || int(rule_id) >= len(s.rb.rules) {
		return Impact_Report{rule_id = rule_id, allocator = allocator}
	}
	rname := interner_get(&s.rb.interner, s.rb.rules[rule_id].name)
	rver := interner_get(&s.rb.interner, s.rb.rules[rule_id].version)

	rep := Impact_Report{
		rule_id   = rule_id,
		rule_name = strings.clone(rname, allocator),
		allocator = allocator,
	}
	if len(version) > 0 && version != rver {
		return rep
	}

	direct_set := make(map[Fact_Id]bool, 8, context.temp_allocator)
	direct_list := make([dynamic]Fact_Id, 0, 8, allocator)
	deriv_list := make([dynamic]Derivation_Id, 0, 8, allocator)

	if rderivs, has := s.provenance.rule_derivs[rule_id]; has {
		for did in rderivs {
			d := s.provenance.derivs[did]
			if !d.alive {
				continue
			}
			append(&deriv_list, did)
			if d.derived_fact != INVALID_FACT && int(d.derived_fact) < len(s.facts) && s.facts[d.derived_fact].alive {
				if !(d.derived_fact in direct_set) {
					direct_set[d.derived_fact] = true
					append(&direct_list, d.derived_fact)
				}
			}
		}
	}

	// Transitively follow downstream alive logical dependents via jtms.premise_to_justs.
	trans_set := make(map[Fact_Id]bool, 16, context.temp_allocator)
	trans_list := make([dynamic]Fact_Id, 0, len(direct_list), allocator)
	for df in direct_list {
		trans_set[df] = true
		append(&trans_list, df)
	}
	for i := 0; i < len(trans_list); i += 1 {
		cur := trans_list[i]
		if pjusts, has_pj := s.jtms.premise_to_justs[cur]; has_pj {
			for jid in pjusts {
				j := s.jtms.justs[jid]
				if !j.alive {
					continue
				}
				nxt := j.derived_fact
				if nxt != INVALID_FACT && int(nxt) < len(s.facts) && s.facts[nxt].alive {
					if !(nxt in trans_set) {
						trans_set[nxt] = true
						append(&trans_list, nxt)
					}
					if j.deriv_id != INVALID_DERIVATION {
						already := false
						for pd in deriv_list {
							if pd == j.deriv_id {
								already = true
								break
							}
						}
						if !already {
							append(&deriv_list, j.deriv_id)
						}
					}
				}
			}
		}
	}

	rep.direct_facts = direct_list[:]
	rep.transitive_facts = trans_list[:]
	rep.derivations = deriv_list[:]
	return rep
}

@(private)
_is_base_or_uncond :: proc(s: ^Session, fid: Fact_Id) -> bool {
	f := &s.facts[fid]
	if f.origin != .Logical {
		return true
	}
	if flist, has := s.provenance.fact_derivs[fid]; has {
		for did in flist {
			if s.provenance.derivs[did].alive {
				return false
			}
		}
	}
	return true
}

@(private)
_merge_why_sets :: proc(
	a: [dynamic][dynamic]Fact_Id,
	b: [dynamic][dynamic]Fact_Id,
) -> [dynamic][dynamic]Fact_Id {
	out := make([dynamic][dynamic]Fact_Id, 0, len(a) * len(b), context.temp_allocator)
	for sa in a {
		for sb in b {
			comb := make([dynamic]Fact_Id, 0, len(sa) + len(sb), context.temp_allocator)
			for x in sa {
				append(&comb, x)
			}
			for y in sb {
				dup := false
				for x in comb {
					if x == y {
						dup = true
						break
					}
				}
				if !dup {
					append(&comb, y)
				}
			}
			append(&out, comb)
			if len(out) >= 64 {
				return out
			}
		}
	}
	return out
}

@(private)
_eval_why_sets :: proc(
	s: ^Session,
	fid: Fact_Id,
	visited: ^map[Fact_Id]bool,
) -> [dynamic][dynamic]Fact_Id {
	out := make([dynamic][dynamic]Fact_Id, 0, 4, context.temp_allocator)
	if fid == INVALID_FACT || int(fid) >= len(s.facts) || !s.facts[fid].alive {
		return out
	}
	if _is_base_or_uncond(s, fid) {
		unit := make([dynamic]Fact_Id, 1, 1, context.temp_allocator)
		unit[0] = fid
		append(&out, unit)
		return out
	}
	if fid in visited^ {
		return out
	}
	visited^[fid] = true
	defer delete_key(visited, fid)

	if flist, has := s.provenance.fact_derivs[fid]; has {
		for did in flist {
			d := s.provenance.derivs[did]
			if !d.alive {
				continue
			}
			parents := provenance_parents(&s.provenance, did)
			if len(parents) == 0 {
				unit := make([dynamic]Fact_Id, 1, 1, context.temp_allocator)
				unit[0] = fid
				append(&out, unit)
				continue
			}
			// Check all parents alive
			all_ok := true
			for pf in parents {
				if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
					all_ok = false
					break
				}
			}
			if !all_ok {
				continue
			}

			prod := make([dynamic][dynamic]Fact_Id, 1, 4, context.temp_allocator)
			prod[0] = make([dynamic]Fact_Id, 0, 2, context.temp_allocator)
			valid_d := true
			for pf in parents {
				sub := _eval_why_sets(s, pf, visited)
				if len(sub) == 0 {
					valid_d = false
					break
				}
				prod = _merge_why_sets(prod, sub)
			}
			if valid_d {
				for ps in prod {
					if len(out) < 64 {
						append(&out, ps)
					}
				}
			}
		}
	}
	return out
}

@(private)
_eval_how_expr :: proc(
	s: ^Session,
	fid: Fact_Id,
	visited: ^map[Fact_Id]bool,
) -> string {
	f := &s.facts[fid]
	if _is_base_or_uncond(s, fid) {
		return fmt.tprintf("%s[%s]", interner_get(&s.rb.interner, s.rb.bindings[f.binding_idx].name), session_string(s, f.key))
	}
	if fid in visited^ {
		return fmt.tprintf("<cycle:%d>", u32(fid))
	}
	visited^[fid] = true
	defer delete_key(visited, fid)

	terms := make([dynamic]string, 0, 4, context.temp_allocator)
	if flist, has := s.provenance.fact_derivs[fid]; has {
		for did in flist {
			d := s.provenance.derivs[did]
			if !d.alive {
				continue
			}
			parents := provenance_parents(&s.provenance, did)
			all_ok := true
			for pf in parents {
				if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
					all_ok = false
					break
				}
			}
			if !all_ok {
				continue
			}
			rname := interner_get(&s.rb.interner, s.rb.rules[d.rule_id].name) if int(d.rule_id) < len(s.rb.rules) else "rule"
			if len(parents) == 0 {
				append(&terms, rname)
			} else {
				pb := strings.builder_make(context.temp_allocator)
				fmt.sbprintf(&pb, "%s(", rname)
				for pf, i in parents {
					if i > 0 {
						strings.write_string(&pb, " * ")
					}
					strings.write_string(&pb, _eval_how_expr(s, pf, visited))
				}
				strings.write_byte(&pb, ')')
				append(&terms, strings.to_string(pb))
			}
		}
	}
	if len(terms) == 0 {
		return "0"
	}
	if len(terms) == 1 {
		return terms[0]
	}
	return strings.join(terms[:], " + ", context.temp_allocator)
}

@(private)
_eval_viterbi :: proc(
	s: ^Session,
	fid: Fact_Id,
	visited: ^map[Fact_Id]bool,
) -> (score: f64, height: u32, path: [dynamic]Fact_Id) {
	path = make([dynamic]Fact_Id, 0, 4, context.temp_allocator)
	if _is_base_or_uncond(s, fid) {
		append(&path, fid)
		return 1.0, 0, path
	}
	if fid in visited^ {
		return 0.0, max(u32), path
	}
	visited^[fid] = true
	defer delete_key(visited, fid)

	best_score := -1.0
	best_h := max(u32)
	best_path: [dynamic]Fact_Id

	if flist, has := s.provenance.fact_derivs[fid]; has {
		for did in flist {
			d := s.provenance.derivs[did]
			if !d.alive {
				continue
			}
			parents := provenance_parents(&s.provenance, did)
			all_ok := true
			for pf in parents {
				if pf == INVALID_FACT || int(pf) >= len(s.facts) || !s.facts[pf].alive {
					all_ok = false
					break
				}
			}
			if !all_ok {
				continue
			}
			cand_score := 0.9
			cand_h := u32(0)
			cand_path := make([dynamic]Fact_Id, 0, 4, context.temp_allocator)
			valid := true
			for pf in parents {
				ps, ph, pp := _eval_viterbi(s, pf, visited)
				if ps <= 0.0 {
					valid = false
					break
				}
				cand_score *= ps
				if ph > cand_h {
					cand_h = ph
				}
				for x in pp {
					append(&cand_path, x)
				}
			}
			if !valid {
				continue
			}
			cand_h += 1
			append(&cand_path, fid)
			if cand_score > best_score {
				best_score = cand_score
				best_h = cand_h
				best_path = cand_path
			}
		}
	}

	if best_score < 0.0 {
		return 0.0, max(u32), path
	}
	return best_score, best_h, best_path
}

// Evaluates algebraic provenance semiring (Boolean, Why, How, Viterbi) over stored derivation DAG.
evaluate_semiring :: proc(
	s: ^Session,
	fid: Fact_Id,
	kind: Semiring_Kind,
	allocator := context.allocator,
) -> Semiring_Result {
	res := Semiring_Result{
		kind      = kind,
		allocator = allocator,
	}
	if s == nil || s.rb == nil || fid == INVALID_FACT || int(fid) >= len(s.facts) || !s.facts[fid].alive {
		return res
	}
	res.boolean_val = true
	visited := make(map[Fact_Id]bool, 16, context.temp_allocator)

	switch kind {
	case .Boolean:
		return res

	case .Why:
		raw_sets := _eval_why_sets(s, fid, &visited)
		// Prune subsumed supersets (keep minimal Why witnesses).
		minimal := make([dynamic][dynamic]Fact_Id, 0, len(raw_sets), context.temp_allocator)
		for cand in raw_sets {
			if len(cand) == 0 {
				continue
			}
			subsumed := false
			for other in raw_sets {
				if len(other) == 0 || len(other) >= len(cand) {
					continue
				}
				// Check if other is a strict subset of cand.
				is_sub := true
				for x in other {
					found_x := false
					for y in cand {
						if x == y {
							found_x = true
							break
						}
					}
					if !found_x {
						is_sub = false
						break
					}
				}
				if is_sub {
					subsumed = true
					break
				}
			}
			if subsumed {
				continue
			}
			// Deduplicate identical sets
			dup := false
			for prev in minimal {
				if len(prev) != len(cand) {
					continue
				}
				same := true
				for x in prev {
					has_x := false
					for y in cand {
						if x == y {
							has_x = true
							break
						}
					}
					if !has_x {
						same = false
						break
					}
				}
				if same {
					dup = true
					break
				}
			}
			if !dup {
				append(&minimal, cand)
			}
		}
		res.why_sets = make([]Why_Provenance_Set, len(minimal), allocator)
		for ms, i in minimal {
			arr := make([]Fact_Id, len(ms), allocator)
			copy(arr, ms[:])
			res.why_sets[i] = Why_Provenance_Set{fact_ids = arr}
		}

	case .How:
		txt := _eval_how_expr(s, fid, &visited)
		res.how_expr = strings.clone(txt, allocator)

	case .Viterbi:
		sc, h, p := _eval_viterbi(s, fid, &visited)
		res.viterbi_score = sc
		res.viterbi_height = h
		arr := make([]Fact_Id, len(p), allocator)
		copy(arr, p[:])
		res.viterbi_path = arr
	}

	return res
}
