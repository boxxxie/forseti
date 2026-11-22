package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"

Dep_Edge :: struct {
	from_node: u32,
	to_node:   u32,
	from_pred: String_Id,
	to_pred:   String_Id,
	rule_id:   u32,
	rule_name: String_Id,
	is_neg:    bool,
	is_accum:  bool,
	span:      Span,
}

Scc_Info :: struct {
	id:                 u32,
	pred_names:         []String_Id,
	is_recursive:       bool,
	has_neg_or_accum:   bool,
}

Stratification_Plan :: struct {
	pred_names:             []String_Id,
	pred_to_node:           map[String_Id]u32,
	pred_scc:               []u32,
	pred_stratum:           []u32,
	sccs:                   [dynamic]Scc_Info,
	rule_stratum:           []u32,
	rule_recursive:         []bool,
	strata_count:           u32,
	stratum_recursive:      []bool,
	has_unstratified_cycle: bool,
	first_cycle_trace:      string,
	first_cycle_span:       Span,
	allocator:              mem.Allocator,
}

stratification_plan_destroy :: proc(p: ^Stratification_Plan) {
	if p == nil || p.allocator.procedure == nil {
		return
	}
	a := p.allocator
	delete(p.pred_names, a)
	delete(p.pred_to_node)
	delete(p.pred_scc, a)
	delete(p.pred_stratum, a)
	for s in p.sccs {
		delete(s.pred_names, a)
	}
	delete(p.sccs)
	delete(p.rule_stratum, a)
	delete(p.rule_recursive, a)
	delete(p.stratum_recursive, a)
	if len(p.first_cycle_trace) > 0 {
		delete(p.first_cycle_trace, a)
	}
	p^ = {}
}

@(private)
_Body_Pred_Ref :: struct {
	pred:     String_Id,
	is_neg:   bool,
	is_accum: bool,
	span:     Span,
}

@(private)
_collect_clause_deps :: proc(
	clauses: []Clause_IR,
	in_neg: bool,
	in_accum: bool,
	out: ^[dynamic]_Body_Pred_Ref,
) {
	for cl in clauses {
		#partial switch cl.kind {
		case .Pattern:
			if cl.target != EMPTY_STRING {
				append(out, _Body_Pred_Ref{
					pred     = cl.target,
					is_neg   = in_neg,
					is_accum = in_accum,
					span     = cl.span,
				})
			}
		case .Not:
			_collect_clause_deps(cl.children, true, in_accum, out)
		case .Exists:
			_collect_clause_deps(cl.children, in_neg, in_accum, out)
		case .Accum:
			_collect_clause_deps(cl.inner_pat, in_neg, true, out)
		}
	}
}

@(private)
_ensure_pred_node :: proc(
	name: String_Id,
	pred_names: ^[dynamic]String_Id,
	pred_to_node: ^map[String_Id]u32,
	adj: ^[dynamic][dynamic]Dep_Edge,
	alloc: mem.Allocator,
) -> u32 {
	if idx, ok := pred_to_node^[name]; ok {
		return idx
	}
	idx := u32(len(pred_names^))
	append(pred_names, name)
	pred_to_node^[name] = idx
	append(adj, make([dynamic]Dep_Edge, 0, 4, alloc))
	return idx
}

@(private)
_Tarjan_State :: struct {
	adj:      [][dynamic]Dep_Edge,
	index:    []i32,
	lowlink:  []i32,
	on_stack: []bool,
	stack:    [dynamic]u32,
	next_idx: i32,
	sccs:     ^[dynamic][dynamic]u32,
	alloc:    mem.Allocator,
}

@(private)
_tarjan_strongconnect :: proc(ts: ^_Tarjan_State, v: u32) {
	ts.index[v] = ts.next_idx
	ts.lowlink[v] = ts.next_idx
	ts.next_idx += 1
	append(&ts.stack, v)
	ts.on_stack[v] = true

	for e in ts.adj[v] {
		w := e.to_node
		if ts.index[w] < 0 {
			_tarjan_strongconnect(ts, w)
			if ts.lowlink[w] < ts.lowlink[v] {
				ts.lowlink[v] = ts.lowlink[w]
			}
		} else if ts.on_stack[w] {
			if ts.index[w] < ts.lowlink[v] {
				ts.lowlink[v] = ts.index[w]
			}
		}
	}

	if ts.lowlink[v] == ts.index[v] {
		comp := make([dynamic]u32, 0, 4, ts.alloc)
		for {
			w := pop(&ts.stack)
			ts.on_stack[w] = false
			append(&comp, w)
			if w == v {
				break
			}
		}
		append(ts.sccs, comp)
	}
}

@(private)
_format_unstratified_cycle :: proc(
	ir: ^Rulebase_IR,
	adj: [][dynamic]Dep_Edge,
	scc_id: []u32,
	target_scc: u32,
	bad_edge: Dep_Edge,
	alloc: mem.Allocator,
) -> string {
	b: strings.Builder
	strings.builder_init(&b, alloc)

	qual := "accum" if bad_edge.is_accum else "not"
	fmt.sbprintf(
		&b,
		"%s -[%s via %s]-> %s",
		ir_string(ir, bad_edge.from_pred),
		qual,
		ir_string(ir, bad_edge.rule_name),
		ir_string(ir, bad_edge.to_pred),
	)

	if bad_edge.to_node == bad_edge.from_node {
		return strings.to_string(b)
	}

	// Shortest path in SCC from bad_edge.to_node back to bad_edge.from_node to exhibit the full cycle.
	n := len(adj)
	prev_edge := make([]Dep_Edge, n, context.temp_allocator)
	visited := make([]bool, n, context.temp_allocator)
	queue := make([dynamic]u32, 0, n, context.temp_allocator)

	visited[bad_edge.to_node] = true
	append(&queue, bad_edge.to_node)
	found := false
	for qi := 0; qi < len(queue) && !found; qi += 1 {
		u := queue[qi]
		for e in adj[u] {
			if scc_id[e.to_node] != target_scc {
				continue
			}
			if !visited[e.to_node] {
				visited[e.to_node] = true
				prev_edge[e.to_node] = e
				if e.to_node == bad_edge.from_node {
					found = true
					break
				}
				append(&queue, e.to_node)
			}
		}
	}

	if found {
		rev := make([dynamic]Dep_Edge, 0, 8, context.temp_allocator)
		cur := bad_edge.from_node
		for cur != bad_edge.to_node {
			e := prev_edge[cur]
			append(&rev, e)
			cur = e.from_node
		}
		for i := len(rev) - 1; i >= 0; i -= 1 {
			e := rev[i]
			eq := "not" if e.is_neg else ("accum" if e.is_accum else "pos")
			fmt.sbprintf(&b, " -[%s via %s]-> %s", eq, ir_string(ir, e.rule_name), ir_string(ir, e.to_pred))
		}
	}
	return strings.to_string(b)
}

// Builds predicate dependency graph, runs Tarjan's SCC algorithm, validates stratification (E4001),
// and computes topological stratum assignments for rules and recursive strata.
@(require_results)
stratify_ir :: proc(
	ir: ^Rulebase_IR,
	diags: ^Diagnostic_List = nil,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (plan: Stratification_Plan, err: mem.Allocator_Error) {
	if ir == nil {
		return {}, nil
	}
	strat_scratch: vmem.Arena
	if vmem.arena_init_growing(&strat_scratch) != nil {
		return {}, .Out_Of_Memory
	}
	defer vmem.arena_destroy(&strat_scratch)
	sa := vmem.arena_allocator(&strat_scratch)

	plan.allocator = allocator
	defer if err != nil {
		stratification_plan_destroy(&plan)
	}
	plan.pred_to_node = make(map[String_Id]u32, len(ir.bindings) + 8, allocator)

	pred_names := make([dynamic]String_Id, 0, len(ir.bindings) + 8, allocator)
	adj := make([dynamic][dynamic]Dep_Edge, 0, len(ir.bindings) + 8, sa)

	for b in ir.bindings {
		_ = _ensure_pred_node(b.name, &pred_names, &plan.pred_to_node, &adj, sa)
	}

	_Dep_Edge_Key :: struct {
		from_node: u32,
		to_node:   u32,
		is_neg:    bool,
		is_accum:  bool,
	}
	seen_edges := make(map[_Dep_Edge_Key]bool, len(ir.bindings) * 4 + 16, sa)
	deps := make([dynamic]_Body_Pred_Ref, 0, 8, sa)

	for r, ri in ir.rules {
		clear(&deps)
		_collect_clause_deps(r.when_clauses, false, false, &deps)

		for act in r.then_actions {
			if act.kind == .Assert && act.target != EMPTY_STRING {
				h_node := _ensure_pred_node(act.target, &pred_names, &plan.pred_to_node, &adj, sa)
				for dep in deps {
					d_node := _ensure_pred_node(dep.pred, &pred_names, &plan.pred_to_node, &adj, sa)
					ek := _Dep_Edge_Key{
						from_node = h_node,
						to_node   = d_node,
						is_neg    = dep.is_neg,
						is_accum  = dep.is_accum,
					}
					if ek in seen_edges {
						continue
					}
					seen_edges[ek] = true
					append(&adj[h_node], Dep_Edge{
						from_node = h_node,
						to_node   = d_node,
						from_pred = act.target,
						to_pred   = dep.pred,
						rule_id   = u32(ri),
						rule_name = r.name,
						is_neg    = dep.is_neg,
						is_accum  = dep.is_accum,
						span      = dep.span,
					})
				}
			}
		}
		for dep in deps {
			_ = _ensure_pred_node(dep.pred, &pred_names, &plan.pred_to_node, &adj, sa)
		}
	}

	n := len(pred_names)
	plan.pred_names = pred_names[:]
	plan.pred_scc = make([]u32, n, allocator)
	plan.pred_stratum = make([]u32, n, allocator)

	raw_sccs := make([dynamic][dynamic]u32, 0, max(n, 4), sa)
	ts := _Tarjan_State{
		adj      = adj[:],
		index    = make([]i32, n, sa),
		lowlink  = make([]i32, n, sa),
		on_stack = make([]bool, n, sa),
		stack    = make([dynamic]u32, 0, n, sa),
		sccs     = &raw_sccs,
		alloc    = sa,
	}
	for i := 0; i < n; i += 1 {
		ts.index[i] = -1
	}
	for v := u32(0); v < u32(n); v += 1 {
		if ts.index[v] < 0 {
			_tarjan_strongconnect(&ts, v)
		}
	}

	num_scc := len(raw_sccs)
	for comp, si in raw_sccs {
		for node in comp {
			plan.pred_scc[node] = u32(si)
		}
	}

	plan.sccs = make([dynamic]Scc_Info, num_scc, allocator)
	scc_stratum := make([]u32, num_scc, sa)

	// Tarjan finishes dependencies first (adj = head -> body_dep), so iterate si = 0 ..< num_scc.
	for comp, si in raw_sccs {
		is_rec := false
		has_neg_acc := false
		first_bad: Dep_Edge
		has_bad := false

		// Sort nodes deterministically by ID for reproducible SCC reports.
		slice.sort(comp[:])
		pnames := make([]String_Id, len(comp), allocator)
		for node, ni in comp {
			pnames[ni] = pred_names[node]
			for e in adj[node] {
				if plan.pred_scc[e.to_node] == u32(si) {
					is_rec = true
					if e.is_neg || e.is_accum {
						has_neg_acc = true
						if !has_bad || e.span.offset < first_bad.span.offset {
							first_bad = e
							has_bad = true
						}
					}
				}
			}
		}

		plan.sccs[si] = Scc_Info{
			id               = u32(si),
			pred_names       = pnames,
			is_recursive     = is_rec,
			has_neg_or_accum = has_neg_acc,
		}

		if has_bad {
			cycle_str := _format_unstratified_cycle(ir, adj[:], plan.pred_scc, u32(si), first_bad, sa)
			if !plan.has_unstratified_cycle {
				plan.has_unstratified_cycle = true
				plan.first_cycle_trace = strings.clone(cycle_str, allocator) or_return
				plan.first_cycle_span = first_bad.span
			}
			if diags != nil {
				diag_add(
					diags,
					ir.line_starts,
					.E4001,
					.Error,
					first_bad.span,
					fmt.tprintf("unstratified negation/aggregation cycle: %s", cycle_str),
					"break the negative/aggregate cycle or separate predicates into stratified derived layers",
					telemetry,
				) or_return
			}
		}

		st := u32(0)
		for node in comp {
			for e in adj[node] {
				dep_scc := plan.pred_scc[e.to_node]
				if dep_scc == u32(si) {
					continue
				}
				dep_st := scc_stratum[dep_scc]
				need := dep_st
				if e.is_neg || e.is_accum || plan.sccs[dep_scc].is_recursive {
					need = dep_st + 1
				}
				if need > st {
					st = need
				}
			}
		}
		scc_stratum[si] = st
		for node in comp {
			plan.pred_stratum[node] = st
		}
	}

	plan.rule_stratum = make([]u32, len(ir.rules), allocator)
	plan.rule_recursive = make([]bool, len(ir.rules), allocator)
	max_stratum := u32(0)

	for r, ri in ir.rules {
		st := u32(0)
		is_rec := false
		has_head := false
		has_head_node := false
		for act in r.then_actions {
			if act.kind == .Assert && act.target != EMPTY_STRING {
				has_head = true
				if hnode, ok := plan.pred_to_node[act.target]; ok {
					hst := plan.pred_stratum[hnode]
					if !has_head_node || hst < st {
						st = hst
						has_head_node = true
					}
				}
			}
		}
		if has_head_node {
			for act in r.then_actions {
				if act.kind == .Assert && act.target != EMPTY_STRING {
					if hnode, ok := plan.pred_to_node[act.target]; ok && plan.pred_stratum[hnode] == st {
						if plan.sccs[plan.pred_scc[hnode]].is_recursive {
							is_rec = true
							break
						}
					}
				}
			}
		}
		if !has_head {
			clear(&deps)
			_collect_clause_deps(r.when_clauses, false, false, &deps)
			for dep in deps {
				if dnode, ok := plan.pred_to_node[dep.pred]; ok {
					dst := plan.pred_stratum[dnode]
					if dep.is_neg || dep.is_accum || plan.sccs[plan.pred_scc[dnode]].is_recursive {
						dst += 1
					}
					if dst > st {
						st = dst
					}
				}
			}
		}
		plan.rule_stratum[ri] = st
		plan.rule_recursive[ri] = is_rec
		if st > max_stratum {
			max_stratum = st
		}
	}

	plan.strata_count = max_stratum + 1
	plan.stratum_recursive = make([]bool, plan.strata_count, allocator)
	for rec, ri in plan.rule_recursive {
		if rec {
			plan.stratum_recursive[plan.rule_stratum[ri]] = true
		}
	}
	return plan, nil
}
