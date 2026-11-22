package forseti

import "core:math"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"

Input_Getter_Proc :: #type proc(col_idx: int, user_data: rawptr) -> Value

Table_Input :: struct {
	values:    []Value,
	getter:    Input_Getter_Proc,
	user_data: rawptr,
}

Decision_Trace :: struct {
	evaluated_col_mask: u64,
	skipped_col_mask:   u64,
	winning_row_idx:    i32,
	matched_count:      u32,
}

MAX_TABLE_OUTPUTS :: 16
MAX_INLINE_HITS :: 64

Decision_Result :: struct {
	matched:           bool,
	table_name:        String_Id,
	table_version:     String_Id,
	hit_policy:        Hit_Policy,
	outputs:           [MAX_TABLE_OUTPUTS]Value,
	output_set:        [MAX_TABLE_OUTPUTS]bool,
	output_count:      u8,
	matched_rows:      [MAX_INLINE_HITS]u32,
	matched_row_count: u32,
	trace:             Decision_Trace,
}

DT_Edge :: struct {
	next_node: u32,
}

DT_Node :: struct {
	col_idx:       i16, // -1 for leaf
	winning_row:   i32, // -1 for no match; or index into ct.row_ids
	edge_start:    u32,
	edge_count:    u32,
	fallback_rows: []u32, // Used only if tree node cap triggers
}

Bitset_Matrix :: struct {
	word_count:        int,
	col_eval_order:    []int,
	col_nonwild_masks: [][]u64,   // [col][word]
	col_atom_masks:    [][][]u64, // [col][atom][word]
}

Compiled_Table :: struct {
	arena:          vmem.Arena,
	interner:       String_Interner,
	table_name:     String_Id,
	table_version:  String_Id,
	hit_policy:     Hit_Policy,
	col_count:      int,
	out_count:      int,
	row_count:      int,
	col_types:      []Type_Ref,
	col_costs:      []u32,
	col_domains:    []Column_Domain,
	row_ids:        []String_Id,
	row_outputs:    [][]Value,
	row_output_set: [][]bool,
	row_masks:      [][][]u64, // [row][col][word] (used in fallback / build)
	eval_order:     []u32,
	use_tree:       bool,
	dt_nodes:       []DT_Node,
	dt_edges:       []DT_Edge,
	bitset:         Bitset_Matrix,
}

compiled_table_destroy :: proc(ct: ^Compiled_Table) {
	vmem.arena_check_temp(&ct.arena)
	interner_destroy(&ct.interner)
	vmem.arena_destroy(&ct.arena)
	ct^ = {}
}

compiled_table_string :: proc "contextless" (ct: ^Compiled_Table, id: String_Id) -> string {
	return interner_get(&ct.interner, id)
}

compiled_table_string_value :: proc(ct: ^Compiled_Table, s: string) -> Value {
	if ct == nil {
		return String_Id(INVALID_ID)
	}
	if id, ok := ct.interner.lookup[s]; ok {
		return id
	}
	return String_Id(INVALID_ID)
}

compiled_table_output_string :: proc "contextless" (ct: ^Compiled_Table, v: Value) -> string {
	if ct == nil {
		return ""
	}
	if sid, ok := v.(String_Id); ok {
		return interner_get(&ct.interner, sid)
	}
	return ""
}

compiled_table_winning_row_id :: proc "contextless" (ct: ^Compiled_Table, res: Decision_Result) -> string {
	if ct == nil || res.trace.winning_row_idx < 0 || int(res.trace.winning_row_idx) >= len(ct.row_ids) {
		return ""
	}
	return interner_get(&ct.interner, ct.row_ids[res.trace.winning_row_idx])
}

@(private)
value_to_f64 :: proc "contextless" (v: Value) -> (f64, bool) {
	#partial switch x in v {
	case f64:
		return x, true
	case i64:
		return f64(x), true
	case i32:
		return f64(x), true
	}
	return 0, false
}

@(private)
value_to_i64 :: proc "contextless" (v: Value) -> (i64, bool) {
	#partial switch x in v {
	case i64:
		return x, true
	case i32:
		return i64(x), true
	}
	return 0, false
}

@(private)
classify_value_atom :: proc(ct: ^Compiled_Table, col_idx: int, val: Value) -> int {
	dom := ct.col_domains[col_idx]
	switch dom.kind {
	case .Bool:
		b, ok := val.(bool)
		if !ok {
			return -1
		}
		return 1 if b else 0

	case .Int_Interval:
		iv, ok := value_to_i64(val)
		if !ok || len(dom.atoms) == 0 {
			return -1
		}
		lo := 0
		hi := len(dom.atoms) - 1
		for lo <= hi {
			mid := lo + (hi - lo) / 2
			a := dom.atoms[mid]
			if iv < a.int_lo {
				hi = mid - 1
			} else if iv > a.int_hi {
				lo = mid + 1
			} else {
				return mid
			}
		}
		return -1

	case .Float_Interval:
		fv, ok := value_to_f64(val)
		if !ok || math.is_nan(fv) || len(dom.atoms) == 0 {
			return -1
		}
		lo := 0
		hi := len(dom.atoms) - 1
		for lo <= hi {
			mid := lo + (hi - lo) / 2
			a := dom.atoms[mid]
			if a.lo_inc && a.hi_inc {
				if fv < a.float_lo {
					hi = mid - 1
				} else if fv > a.float_hi {
					lo = mid + 1
				} else {
					return mid
				}
			} else {
				below := (mid > 0 || !math.is_inf(a.float_lo, -1)) && fv <= a.float_lo
				above := (mid < len(dom.atoms) - 1 || !math.is_inf(a.float_hi, 1)) && fv >= a.float_hi
				if below {
					hi = mid - 1
				} else if above {
					lo = mid + 1
				} else {
					return mid
				}
			}
		}
		return -1

	case .Enum:
		if sid, ok := val.(String_Id); ok {
			s := interner_get(&ct.interner, sid)
			for atom, ai in dom.atoms {
				if atom.str_id == sid || interner_get(&ct.interner, atom.str_id) == s {
					return ai
				}
			}
		} else if ev, eok := val.(Enum_Val); eok {
			if int(ev.variant) < len(dom.atoms) {
				return int(ev.variant)
			}
		}
		return -1

	case .String_Set:
		sid, ok := val.(String_Id)
		if !ok || len(dom.atoms) == 0 {
			return -1
		}
		if sid != String_Id(INVALID_ID) {
			for atom, ai in dom.atoms {
				if !atom.is_other && atom.str_id == sid {
					return ai
				}
			}
		}
		return len(dom.atoms) - 1 // <other> sentinel
	}
	return -1
}

@(private)
fetch_input_col :: proc(
	ct: ^Compiled_Table,
	input: Table_Input,
	col_idx: int,
	fetched_mask: ^u64,
	cached_vals: ^[64]Value,
	cached_atoms: ^[64]int,
) -> int {
	if col_idx < 0 || col_idx >= ct.col_count {
		return -1
	}
	if col_idx < 64 {
		bit := u64(1) << u64(col_idx)
		if (fetched_mask^ & bit) != 0 {
			return cached_atoms[col_idx]
		}
		fetched_mask^ |= bit
	}
	v: Value
	if input.getter != nil {
		v = input.getter(col_idx, input.user_data)
	} else if col_idx < len(input.values) {
		v = input.values[col_idx]
	}
	atom_idx := classify_value_atom(ct, col_idx, v)
	if col_idx < 64 {
		cached_vals[col_idx] = v
		cached_atoms[col_idx] = atom_idx
	}
	return atom_idx
}

@(private)
eval_const_output_value :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (val: Value, set: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return {}, false
	}
	e := ir.exprs[eid]
	#partial switch e.kind {
	case .Wildcard:
		return {}, false
	case .Lit_Bool:
		return e.bool_val, true
	case .Lit_Int:
		return e.int_val, true
	case .Lit_Float:
		return e.float_val, true
	case .Lit_String:
		return e.str_id, true
	case .Unary:
		if e.unary_op == .Neg && e.lhs != INVALID_EXPR {
			inner := ir.exprs[e.lhs]
			if inner.kind == .Lit_Int {
				return -inner.int_val, true
			}
			if inner.kind == .Lit_Float {
				return -inner.float_val, true
			}
		}
	}
	return {}, false
}

@(require_results)
compile_table :: proc(
	ir: ^Rulebase_IR,
	table_idx: u32,
	telemetry: ^Telemetry_Sink = nil,
	allocator := context.allocator,
) -> (ct: Compiled_Table, err: mem.Allocator_Error) {
	scope := telemetry_span_begin(telemetry, .Compile, "compile_table")
	defer telemetry_span_end(telemetry, scope)

	if ir == nil || int(table_idx) >= len(ir.tables) {
		return {}, nil
	}
	tbl := ir.tables[table_idx]

	vmem.arena_init_growing(&ct.arena) or_return
	defer if err != nil {
		compiled_table_destroy(&ct)
	}
	interner_init(&ct.interner, allocator) or_return
	if len(ir.interner.strings) > 1 {
		for s in ir.interner.strings[1:] {
			_ = intern(&ct.interner, s) or_return
		}
	}

	arena_alloc := vmem.arena_allocator(&ct.arena)
	ct.table_name = tbl.name
	ct.table_version = tbl.version
	ct.hit_policy = tbl.hit_policy
	ct.col_count = len(tbl.inputs)
	ct.out_count = len(tbl.outputs)
	ct.row_count = len(tbl.rows)

	ct.col_types = make([]Type_Ref, ct.col_count, arena_alloc) or_return
	ct.col_costs = make([]u32, ct.col_count, arena_alloc) or_return
	ct.col_domains = make([]Column_Domain, ct.col_count, arena_alloc) or_return

	max_frags := max(ct.row_count * 4 + 16, 1024)
	for c, ci in tbl.inputs {
		ct.col_types[ci] = c.type
		ct.col_costs[ci] = c.cost if c.cost > 0 else 1
		ct.col_domains[ci] = build_column_domain(ir, tbl, ci, arena_alloc, max_frags) or_return
	}

	ct.row_ids = make([]String_Id, ct.row_count, arena_alloc) or_return
	ct.row_outputs = make([][]Value, ct.row_count, arena_alloc) or_return
	ct.row_output_set = make([][]bool, ct.row_count, arena_alloc) or_return
	ct.row_masks = make([][][]u64, ct.row_count, arena_alloc) or_return

	for row, ri in tbl.rows {
		ct.row_ids[ri] = row.id
		ct.row_outputs[ri] = make([]Value, ct.out_count, arena_alloc) or_return
		ct.row_output_set[ri] = make([]bool, ct.out_count, arena_alloc) or_return
		for out_eid, oi in row.outputs {
			if oi < ct.out_count {
				ct.row_outputs[ri][oi], ct.row_output_set[ri][oi] = eval_const_output_value(ir, out_eid)
			}
		}

		ct.row_masks[ri] = make([][]u64, ct.col_count, arena_alloc) or_return
		for ci in 0 ..< ct.col_count {
			mask := make([]u64, ct.col_domains[ci].word_count, arena_alloc) or_return
			ct.row_masks[ri][ci] = mask
			if ci < len(row.cells) {
				_ = eval_cell_mask(ir, ct.col_domains[ci], row.cells[ci], mask)
			}
		}
	}

	// Build row evaluation order (Priority reorders by first enum output variant index)
	ct.eval_order = make([]u32, ct.row_count, arena_alloc) or_return
	for ri in 0 ..< ct.row_count {
		ct.eval_order[ri] = u32(ri)
	}
	if tbl.hit_policy == .Priority && ct.out_count > 0 && tbl.outputs[0].type.kind == .Enum && int(tbl.outputs[0].type.ref_id) < len(ir.enums) {
		edef := ir.enums[tbl.outputs[0].type.ref_id]
		ranks := make([]int, ct.row_count, context.temp_allocator)
		for ri in 0 ..< ct.row_count {
			ranks[ri] = len(edef.variants)
			if ct.row_output_set[ri][0] {
				if sid, sok := ct.row_outputs[ri][0].(String_Id); sok {
					s := ir_string(ir, sid)
					for v, vi in edef.variants {
						if ir_string(ir, v) == s {
							ranks[ri] = vi
							break
						}
					}
				}
			}
		}
		Sort_Pair :: struct {
			row_idx: u32,
			rank:    int,
		}
		pairs := make([]Sort_Pair, ct.row_count, context.temp_allocator)
		for ri in 0 ..< ct.row_count {
			pairs[ri] = Sort_Pair{row_idx = u32(ri), rank = ranks[ri]}
		}
		slice.sort_by(pairs, proc(a, b: Sort_Pair) -> bool {
			if a.rank != b.rank {
				return a.rank < b.rank
			}
			return a.row_idx < b.row_idx
		})
		for p, i in pairs {
			ct.eval_order[i] = p.row_idx
		}
	}

	if is_single_hit_policy(tbl.hit_policy) {
		ct.use_tree = true
		build_decision_tree(&ct, arena_alloc) or_return
	} else {
		ct.use_tree = false
		build_bitset_matrix(&ct, arena_alloc) or_return
	}

	return ct, nil
}

decide :: proc(ct: ^Compiled_Table, input: Table_Input, extra_hits: []u32 = nil) -> Decision_Result {
	if ct == nil {
		return Decision_Result{
			trace = Decision_Trace{
				winning_row_idx = -1,
			},
		}
	}
	res := Decision_Result{
		table_name    = ct.table_name,
		table_version = ct.table_version,
		hit_policy    = ct.hit_policy,
		output_count  = u8(min(ct.out_count, MAX_TABLE_OUTPUTS)),
		trace = Decision_Trace{
			winning_row_idx = -1,
		},
	}
	if ct.row_count == 0 {
		if ct.hit_policy == .Collect_Count {
			res.outputs[0] = i64(0)
			res.output_set[0] = true
		}
		return res
	}

	all_cols_mask: u64 = (~u64(0)) if ct.col_count >= 64 else ((u64(1) << u64(ct.col_count)) - 1)
	if ct.use_tree {
		eval_decision_tree(ct, input, &res)
	} else {
		eval_bitset_matrix(ct, input, &res, extra_hits)
	}
	res.trace.skipped_col_mask = all_cols_mask & ~res.trace.evaluated_col_mask
	return res
}

decide_values :: proc(ct: ^Compiled_Table, values: []Value, extra_hits: []u32 = nil) -> Decision_Result {
	return decide(ct, Table_Input{values = values}, extra_hits)
}

decide_lazy :: proc(ct: ^Compiled_Table, getter: Input_Getter_Proc, user_data: rawptr, extra_hits: []u32 = nil) -> Decision_Result {
	return decide(ct, Table_Input{getter = getter, user_data = user_data}, extra_hits)
}
