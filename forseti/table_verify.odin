package forseti

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:strings"

Verify_Options :: struct {
	max_fragments: int,
	max_budget:    int,
}

MAX_VERIFY_ROWS :: #config(MAX_VERIFY_ROWS, 128)

@(private)
Verify_Ctx :: struct {
	ir:              ^Rulebase_IR,
	tbl:             Table_Def,
	doms:            []Column_Domain,
	row_masks:       [][][]u64, // [row][col][word]
	row_has_unsat:   []bool,
	reachable:       []bool,
	gap_witnesses:   [dynamic]string,
	budget:          int,
	budget_exceeded: bool,
	alloc:           mem.Allocator,
}

@(private)
row_outputs_equal :: proc(ir: ^Rulebase_IR, a, b: Table_Row_Def) -> bool {
	if len(a.outputs) != len(b.outputs) {
		return false
	}
	for i in 0 ..< len(a.outputs) {
		if !expr_ir_equal(ir, a.outputs[i], ir, b.outputs[i]) {
			return false
		}
	}
	return true
}

@(private)
is_single_hit_policy :: proc "contextless" (hp: Hit_Policy) -> bool {
	switch hp {
	case .First, .Unique, .Any, .Priority:
		return true
	case .Collect, .Collect_Sum, .Collect_Min, .Collect_Max, .Collect_Count, .Merge, .Reverse_Merge:
		return false
	}
	return true
}

@(private)
verify_region_dfs :: proc(ctx: ^Verify_Ctx, row_idx: int, region: [][]u64) -> mem.Allocator_Error {
	if ctx.budget <= 0 {
		ctx.budget_exceeded = true
		return nil
	}
	ctx.budget -= 1

	col_count := len(ctx.doms)
	if row_idx >= len(ctx.tbl.rows) {
		if len(ctx.gap_witnesses) < 3 {
			w := format_witness(ctx.ir, ctx.tbl, ctx.doms, region, ctx.alloc) or_return
			append(&ctx.gap_witnesses, w)
		}
		return nil
	}

	if ctx.row_has_unsat[row_idx] {
		return verify_region_dfs(ctx, row_idx + 1, region)
	}

	hit := make([][]u64, col_count, context.temp_allocator)
	all_nonempty := true
	for c in 0 ..< col_count {
		hit[c] = make([]u64, ctx.doms[c].word_count, context.temp_allocator)
		mask_and(hit[c], region[c], ctx.row_masks[row_idx][c])
		if mask_is_empty(hit[c]) {
			all_nonempty = false
			break
		}
	}

	if !all_nonempty {
		return verify_region_dfs(ctx, row_idx + 1, region)
	}

	ctx.reachable[row_idx] = true

	// Partition region \ hit into up to col_count disjoint sub-boxes
	for k in 0 ..< col_count {
		rem := make([]u64, ctx.doms[k].word_count, context.temp_allocator)
		mask_and_not(rem, region[k], hit[k])
		if mask_is_empty(rem) {
			continue
		}
		child := make([][]u64, col_count, context.temp_allocator)
		for c in 0 ..< col_count {
			if c < k {
				child[c] = hit[c]
			} else if c == k {
				child[c] = rem
			} else {
				child[c] = region[c]
			}
		}
		verify_region_dfs(ctx, row_idx + 1, child) or_return
		if ctx.budget_exceeded {
			return nil
		}
	}
	return nil
}

@(require_results)
verify_decision_table :: proc(
	ir: ^Rulebase_IR,
	table_idx: u32,
	diags: ^Diagnostic_List,
	telemetry: ^Telemetry_Sink = nil,
	opts := Verify_Options{},
) -> (err: mem.Allocator_Error) {
	if ir == nil || diags == nil || int(table_idx) >= len(ir.tables) {
		return nil
	}
	tbl := ir.tables[table_idx]
	if len(tbl.inputs) == 0 || len(tbl.rows) == 0 {
		return nil
	}
	if len(tbl.rows) > MAX_VERIFY_ROWS && tbl.verify_flags == {} {
		diag_add(
			diags,
			ir.line_starts,
			.W3006,
			.Warning,
			tbl.span,
			fmt.tprintf("verification skipped on large %d-row decision table %q (exceeds MAX_VERIFY_ROWS=%d)", len(tbl.rows), ir_string(ir, tbl.name), MAX_VERIFY_ROWS),
			"add verify(...) explicitly or increase MAX_VERIFY_ROWS",
			telemetry,
		) or_return
		return nil
	}

	// Ensure row arities are structurally sound before domain partitioning
	for row in tbl.rows {
		if len(row.cells) != len(tbl.inputs) || len(row.outputs) != len(tbl.outputs) {
			return nil
		}
	}

	arena: vmem.Arena
	vmem.arena_init_growing(&arena) or_return
	defer vmem.arena_destroy(&arena)
	arena_alloc := vmem.arena_allocator(&arena)

	col_count := len(tbl.inputs)
	row_count := len(tbl.rows)

	doms := make([]Column_Domain, col_count, arena_alloc) or_return
	any_truncated := false
	for ci in 0 ..< col_count {
		doms[ci] = build_column_domain(ir, tbl, ci, arena_alloc, opts.max_fragments) or_return
		if doms[ci].truncated {
			any_truncated = true
		}
	}

	row_masks := make([][][]u64, row_count, arena_alloc) or_return
	row_has_unsat := make([]bool, row_count, arena_alloc) or_return

	for ri in 0 ..< row_count {
		row := tbl.rows[ri]
		row_masks[ri] = make([][]u64, col_count, arena_alloc) or_return
		for ci in 0 ..< col_count {
			mask := make([]u64, doms[ci].word_count, arena_alloc) or_return
			row_masks[ri][ci] = mask
			cell_id := row.cells[ci]
			cell_expr := ir.exprs[cell_id]
			ok := eval_cell_mask(ir, doms[ci], cell_id, mask)
			if !ok {
				row_has_unsat[ri] = true
				continue
			}
			if mask_is_empty(mask) {
				row_has_unsat[ri] = true
				diag_add(
					diags,
					ir.line_starts,
					.E3002,
					.Error,
					cell_expr.span,
					fmt.tprintf(
						"unsatisfiable cell in table %q row %q column %q",
						ir_string(ir, tbl.name),
						ir_string(ir, row.id),
						ir_string(ir, tbl.inputs[ci].name),
					),
					"relax contradictory bounds or remove unreachable rule",
					telemetry,
				) or_return
			} else if cell_expr.kind != .Wildcard && mask_is_full(mask, len(doms[ci].atoms)) {
				diag_add(
					diags,
					ir.line_starts,
					.W3004,
					.Warning,
					cell_expr.span,
					fmt.tprintf(
						"cell in table %q row %q column %q covers entire domain",
						ir_string(ir, tbl.name),
						ir_string(ir, row.id),
						ir_string(ir, tbl.inputs[ci].name),
					),
					"simplify to '-' wildcard",
					telemetry,
				) or_return
			}
		}
	}

	// Pairwise overlap (E3001) and duplicate/adjacent mergeable rule detection (W3003)
	budget := opts.max_budget if opts.max_budget > 0 else MAX_VERIFY_BUDGET
	pair_steps := 0
	pair_budget_exceeded := false
	check_unique := tbl.hit_policy == .Unique || .No_Overlap in tbl.verify_flags || .Strict in tbl.verify_flags
	check_any := tbl.hit_policy == .Any
	overlap_box := make([][]u64, col_count, arena_alloc) or_return
	for ci in 0 ..< col_count {
		overlap_box[ci] = make([]u64, doms[ci].word_count, arena_alloc) or_return
	}

	pair_outer: for i in 0 ..< row_count {
		if row_has_unsat[i] {
			continue
		}
		for j in i + 1 ..< row_count {
			if row_has_unsat[j] {
				continue
			}
			pair_steps += 1
			if pair_steps > budget {
				pair_budget_exceeded = true
				break pair_outer
			}

			if check_unique || check_any {
				overlaps := true
				for ci in 0 ..< col_count {
					mask_and(overlap_box[ci], row_masks[i][ci], row_masks[j][ci])
					if mask_is_empty(overlap_box[ci]) {
						overlaps = false
						break
					}
				}
				if overlaps {
					if check_unique || (check_any && !row_outputs_equal(ir, tbl.rows[i], tbl.rows[j])) {
						witness := format_witness(ir, tbl, doms, overlap_box, context.temp_allocator) or_return
						diag_add(
							diags,
							ir.line_starts,
							.E3001,
							.Error,
							tbl.rows[j].span,
							fmt.tprintf(
								"overlapping rules %q and %q in table %q at witness %s",
								ir_string(ir, tbl.rows[i].id),
								ir_string(ir, tbl.rows[j].id),
								ir_string(ir, tbl.name),
								witness,
							),
							"make rule predicates disjoint or use First/Priority hit policy",
							telemetry,
						) or_return
					}
				}
			}

			if row_outputs_equal(ir, tbl.rows[i], tbl.rows[j]) {
				diff_cols := 0
				for ci in 0 ..< col_count {
					if !mask_equal(row_masks[i][ci], row_masks[j][ci]) {
						diff_cols += 1
						if diff_cols > 1 {
							break
						}
					}
				}
				if diff_cols <= 1 {
					diag_add(
						diags,
						ir.line_starts,
						.W3003,
						.Warning,
						tbl.rows[j].span,
						fmt.tprintf(
							"rows %q and %q in table %q produce identical outputs and are mergeable",
							ir_string(ir, tbl.rows[i].id),
							ir_string(ir, tbl.rows[j].id),
							ir_string(ir, tbl.name),
						),
						"combine matching cells into a single rule",
						telemetry,
					) or_return
				}
			}
		}
	}

	// Bounded disjoint-remainder DFS for dead/shadowed rules (W3002), completeness gaps (W3001), and budget limit (W3006)
	ctx := Verify_Ctx{
		ir              = ir,
		tbl             = tbl,
		doms            = doms,
		row_masks       = row_masks,
		row_has_unsat   = row_has_unsat,
		reachable       = make([]bool, row_count, arena_alloc) or_return,
		gap_witnesses   = make([dynamic]string, 0, 4, arena_alloc),
		budget          = budget,
		budget_exceeded = pair_budget_exceeded,
		alloc           = arena_alloc,
	}

	full_region := make([][]u64, col_count, arena_alloc) or_return
	for ci in 0 ..< col_count {
		full_region[ci] = make([]u64, doms[ci].word_count, arena_alloc) or_return
		mask_set_all(full_region[ci], len(doms[ci].atoms))
	}

	if !ctx.budget_exceeded {
		verify_region_dfs(&ctx, 0, full_region) or_return
	}

	if ctx.budget_exceeded || any_truncated {
		diag_add(
			diags,
			ir.line_starts,
			.W3006,
			.Warning,
			tbl.span,
			fmt.tprintf("verification budget exceeded on decision table %q (checks incomplete)", ir_string(ir, tbl.name)),
			"increase MAX_VERIFY_BUDGET or simplify open predicates",
			telemetry,
		) or_return
	} else {
		if is_single_hit_policy(tbl.hit_policy) {
			for ri in 0 ..< row_count {
				if !ctx.reachable[ri] && !row_has_unsat[ri] {
					shadow_b: strings.Builder
					strings.builder_init(&shadow_b, context.temp_allocator)
					for pi in 0 ..< ri {
						if row_has_unsat[pi] {
							continue
						}
						inter := true
						for ci in 0 ..< col_count {
							mask_and(overlap_box[ci], row_masks[pi][ci], row_masks[ri][ci])
							if mask_is_empty(overlap_box[ci]) {
								inter = false
								break
							}
						}
						if inter {
							if strings.builder_len(shadow_b) > 0 {
								strings.write_string(&shadow_b, ", ")
							}
							strings.write_string(&shadow_b, ir_string(ir, tbl.rows[pi].id))
						}
					}
					diag_add(
						diags,
						ir.line_starts,
						.W3002,
						.Warning,
						tbl.rows[ri].span,
						fmt.tprintf(
							"row %q in table %q is unreachable/shadowed by earlier row(s): %s",
							ir_string(ir, tbl.rows[ri].id),
							ir_string(ir, tbl.name),
							strings.to_string(shadow_b),
						),
						"reorder more specific rules above general rules or tighten earlier cells",
						telemetry,
					) or_return
				}
			}
		}

		if len(ctx.gap_witnesses) > 0 {
			gb: strings.Builder
			strings.builder_init(&gb, context.temp_allocator)
			for gw, gi in ctx.gap_witnesses {
				if gi > 0 {
					strings.write_string(&gb, "; ")
				}
				strings.write_string(&gb, gw)
			}
			diag_add(
				diags,
				ir.line_starts,
				.W3001,
				.Warning,
				tbl.span,
				fmt.tprintf("completeness gap in table %q; uncovered witness(es): %s", ir_string(ir, tbl.name), strings.to_string(gb)),
				"add missing cases or a fallback '-' row",
				telemetry,
			) or_return
		}
	}

	// Check unused declared output enum variants (W3005)
	for out_col, oi in tbl.outputs {
		if out_col.type.kind != .Enum {
			continue
		}
		edef := ir.enums[out_col.type.ref_id]
		for variant in edef.variants {
			vstr := ir_string(ir, variant)
			produced := false
			for ri in 0 ..< row_count {
				if row_has_unsat[ri] || (is_single_hit_policy(tbl.hit_policy) && !ctx.budget_exceeded && !ctx.reachable[ri]) {
					continue
				}
				if sval, sok := extract_string_const(ir, tbl.rows[ri].outputs[oi]); sok {
					if ir_string(ir, sval) == vstr {
						produced = true
						break
					}
				}
			}
			if !produced {
				diag_add(
					diags,
					ir.line_starts,
					.W3005,
					.Warning,
					tbl.span,
					fmt.tprintf(
						"output enum variant %q on column %q of table %q is never produced by any reachable row",
						vstr,
						ir_string(ir, out_col.name),
						ir_string(ir, tbl.name),
					),
					"",
					telemetry,
				) or_return
			}
		}
	}

	return nil
}

@(require_results)
verify_all_tables :: proc(
	ir: ^Rulebase_IR,
	diags: ^Diagnostic_List,
	telemetry: ^Telemetry_Sink = nil,
	opts := Verify_Options{},
) -> mem.Allocator_Error {
	if ir == nil || len(ir.tables) == 0 {
		return nil
	}
	scope := telemetry_span_begin(telemetry, .Table_Verify, "table_verify")
	defer telemetry_span_end(telemetry, scope)

	for _, ti in ir.tables {
		verify_decision_table(ir, u32(ti), diags, telemetry, opts) or_return
	}
	return nil
}
