package forseti

import "core:mem"

MAX_DT_BUILD_NODES :: 16384

@(private)
DT_Build_Ctx :: struct {
	ct:    ^Compiled_Table,
	nodes: [dynamic]DT_Node,
	edges: [dynamic]DT_Edge,
	alloc: mem.Allocator,
}

@(private)
row_covers_region :: proc(ct: ^Compiled_Table, orig_row: u32, region: [][]u64) -> bool {
	for ci in 0 ..< ct.col_count {
		rmask := ct.row_masks[orig_row][ci]
		reg := region[ci]
		for w in 0 ..< len(reg) {
			if (reg[w] & ~rmask[w]) != 0 {
				return false
			}
		}
	}
	return true
}

@(private)
row_intersects_region :: proc(ct: ^Compiled_Table, orig_row: u32, region: [][]u64) -> bool {
	for ci in 0 ..< ct.col_count {
		rmask := ct.row_masks[orig_row][ci]
		reg := region[ci]
		has := false
		for w in 0 ..< len(reg) {
			if (reg[w] & rmask[w]) != 0 {
				has = true
				break
			}
		}
		if !has {
			return false
		}
	}
	return true
}

@(private)
region_has_single_atom :: proc(reg: []u64) -> bool {
	bits := 0
	for w in reg {
		x := w
		for x != 0 {
			bits += 1
			if bits > 1 {
				return false
			}
			x &= x - 1
		}
	}
	return bits <= 1
}

@(private)
build_tree_rec :: proc(
	ctx: ^DT_Build_Ctx,
	active: []u32, // Indices into ct.eval_order
	region: [][]u64,
	branched_mask: u64,
) -> (node_idx: u32, err: mem.Allocator_Error) {
	ct := ctx.ct

	if len(active) == 0 {
		node_idx = u32(len(ctx.nodes))
		append(&ctx.nodes, DT_Node{col_idx = -1, winning_row = -1}) or_return
		return node_idx, nil
	}

	top_eval_pos := active[0]
	top_orig_row := ct.eval_order[top_eval_pos]
	if row_covers_region(ct, top_orig_row, region) {
		node_idx = u32(len(ctx.nodes))
		append(&ctx.nodes, DT_Node{col_idx = -1, winning_row = i32(top_orig_row)}) or_return
		return node_idx, nil
	}

	if len(ctx.nodes) >= MAX_DT_BUILD_NODES {
		fb := make([]u32, len(active), ctx.alloc) or_return
		for pos, i in active {
			fb[i] = ct.eval_order[pos]
		}
		node_idx = u32(len(ctx.nodes))
		append(&ctx.nodes, DT_Node{col_idx = -1, winning_row = -1, fallback_rows = fb}) or_return
		return node_idx, nil
	}

	// Pick best splitting column: lowest cost among columns that are non-trivial on region & active rows
	best_col := -1
	best_cost := max(u64)
	best_score := max(u64)

	for ci in 0 ..< ct.col_count {
		if ci < 64 && (branched_mask & (u64(1) << u64(ci))) != 0 {
			continue
		}
		if region_has_single_atom(region[ci]) {
			continue
		}
		// Check if any active row discriminates on column ci
		has_split := false
		for pos in active {
			orig := ct.eval_order[pos]
			rmask := ct.row_masks[orig][ci]
			reg := region[ci]
			for w in 0 ..< len(reg) {
				if (reg[w] & ~rmask[w]) != 0 {
					has_split = true
					break
				}
			}
			if has_split {
				break
			}
		}
		if !has_split {
			continue
		}

		col_cost := u64(ct.col_costs[ci])
		// Prefer columns that test the top row first when costs tie
		top_tests_ci := false
		for w in 0 ..< len(region[ci]) {
			if (region[ci][w] & ~ct.row_masks[top_orig_row][ci][w]) != 0 {
				top_tests_ci = true
				break
			}
		}
		tie_penalty := u64(0) if top_tests_ci else u64(1)
		atom_cnt := u64(len(ct.col_domains[ci].atoms))
		score := tie_penalty * 10000 + atom_cnt

		if col_cost < best_cost || (col_cost == best_cost && score < best_score) {
			best_col = ci
			best_cost = col_cost
			best_score = score
		}
	}

	if best_col < 0 {
		fb := make([]u32, len(active), ctx.alloc) or_return
		for pos, i in active {
			fb[i] = ct.eval_order[pos]
		}
		node_idx = u32(len(ctx.nodes))
		append(&ctx.nodes, DT_Node{col_idx = -1, winning_row = -1, fallback_rows = fb}) or_return
		return node_idx, nil
	}

	node_idx = u32(len(ctx.nodes))
	atom_count := len(ct.col_domains[best_col].atoms)
	edge_start := u32(len(ctx.edges))
	append(&ctx.nodes, DT_Node{
		col_idx     = i16(best_col),
		winning_row = -1,
		edge_start  = edge_start,
		edge_count  = u32(atom_count),
	}) or_return

	for _ in 0 ..< atom_count {
		append(&ctx.edges, DT_Edge{}) or_return
	}

	next_branched := branched_mask
	if best_col < 64 {
		next_branched |= u64(1) << u64(best_col)
	}

	child_col_mask := make([]u64, ct.col_domains[best_col].word_count, context.temp_allocator)
	child_region := make([][]u64, ct.col_count, context.temp_allocator)
	for ci in 0 ..< ct.col_count {
		child_region[ci] = child_col_mask if ci == best_col else region[ci]
	}

	for ai in 0 ..< atom_count {
		if (region[best_col][ai / 64] & (u64(1) << u64(ai % 64))) == 0 {
			miss_node := u32(len(ctx.nodes))
			append(&ctx.nodes, DT_Node{col_idx = -1, winning_row = -1}) or_return
			ctx.edges[edge_start + u32(ai)].next_node = miss_node
			continue
		}
		for w in 0 ..< len(child_col_mask) {
			child_col_mask[w] = 0
		}
		child_col_mask[ai / 64] = u64(1) << u64(ai % 64)

		child_active := make([dynamic]u32, 0, len(active), context.temp_allocator)
		for pos in active {
			orig := ct.eval_order[pos]
			if (ct.row_masks[orig][best_col][ai / 64] & (u64(1) << u64(ai % 64))) != 0 {
				append(&child_active, pos)
			}
		}

		child_idx := build_tree_rec(ctx, child_active[:], child_region, next_branched) or_return
		ctx.edges[edge_start + u32(ai)].next_node = child_idx
	}

	return node_idx, nil
}

@(private, require_results)
build_decision_tree :: proc(ct: ^Compiled_Table, alloc: mem.Allocator) -> (err: mem.Allocator_Error) {
	if ct.row_count == 0 {
		return nil
	}
	ctx := DT_Build_Ctx{
		ct    = ct,
		nodes = make([dynamic]DT_Node, 0, max(ct.row_count * 2, 16), context.temp_allocator),
		edges = make([dynamic]DT_Edge, 0, max(ct.row_count * 4, 32), context.temp_allocator),
		alloc = alloc,
	}

	active := make([]u32, ct.row_count, context.temp_allocator)
	for i in 0 ..< ct.row_count {
		active[i] = u32(i)
	}

	full_region := make([][]u64, ct.col_count, context.temp_allocator)
	for ci in 0 ..< ct.col_count {
		full_region[ci] = make([]u64, ct.col_domains[ci].word_count, context.temp_allocator)
		mask_set_all(full_region[ci], len(ct.col_domains[ci].atoms))
	}

	_ = build_tree_rec(&ctx, active, full_region, 0) or_return

	ct.dt_nodes = make([]DT_Node, len(ctx.nodes), alloc) or_return
	copy(ct.dt_nodes, ctx.nodes[:])
	if len(ctx.edges) > 0 {
		ct.dt_edges = make([]DT_Edge, len(ctx.edges), alloc) or_return
		copy(ct.dt_edges, ctx.edges[:])
	}
	return nil
}

@(private)
apply_single_hit_winner :: proc(ct: ^Compiled_Table, orig_row: u32, res: ^Decision_Result) {
	res.matched = true
	res.matched_rows[0] = orig_row
	res.matched_row_count = 1
	res.trace.winning_row_idx = i32(orig_row)
	res.trace.matched_count = 1
	for oi in 0 ..< int(res.output_count) {
		if ct.row_output_set[orig_row][oi] {
			res.outputs[oi] = ct.row_outputs[orig_row][oi]
			res.output_set[oi] = true
		}
	}
}

@(private)
eval_decision_tree :: proc(ct: ^Compiled_Table, input: Table_Input, res: ^Decision_Result) {
	if len(ct.dt_nodes) == 0 {
		return
	}

	fetched_mask: u64 = 0
	cached_vals: [64]Value
	cached_atoms: [64]int

	node_idx := u32(0)
	for {
		node := ct.dt_nodes[node_idx]
		if node.col_idx < 0 {
			if node.winning_row >= 0 {
				apply_single_hit_winner(ct, u32(node.winning_row), res)
				break
			}
			if len(node.fallback_rows) > 0 {
				for orig_row in node.fallback_rows {
					row_ok := true
					for ci in 0 ..< ct.col_count {
						atom_idx := fetch_input_col(ct, input, ci, &fetched_mask, &cached_vals, &cached_atoms)
						if atom_idx < 0 || (ct.row_masks[orig_row][ci][atom_idx / 64] & (u64(1) << u64(atom_idx % 64))) == 0 {
							row_ok = false
							break
						}
					}
					if row_ok {
						apply_single_hit_winner(ct, orig_row, res)
						break
					}
				}
			}
			break
		}

		ci := int(node.col_idx)
		atom_idx := fetch_input_col(ct, input, ci, &fetched_mask, &cached_vals, &cached_atoms)
		if atom_idx < 0 || u32(atom_idx) >= node.edge_count {
			break
		}
		node_idx = ct.dt_edges[node.edge_start + u32(atom_idx)].next_node
	}

	res.trace.evaluated_col_mask = fetched_mask
}
