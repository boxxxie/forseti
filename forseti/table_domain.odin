package forseti

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

MAX_TABLE_FRAGMENTS :: #config(MAX_TABLE_FRAGMENTS, 64)
MAX_VERIFY_BUDGET :: #config(MAX_VERIFY_BUDGET, 65536)

Domain_Kind :: enum u8 {
	Bool,
	Enum,
	Int_Interval,
	Float_Interval,
	String_Set,
}

Domain_Atom :: struct {
	kind:      Domain_Kind,
	bool_val:  bool,
	str_id:    String_Id,
	is_other:  bool,
	int_lo:    i64,
	int_hi:    i64,
	int_rep:   i64,
	float_lo:  f64,
	float_hi:  f64,
	lo_inc:    bool,
	hi_inc:    bool,
	float_rep: f64,
}

Column_Domain :: struct {
	col_idx:    int,
	kind:       Domain_Kind,
	atoms:      []Domain_Atom,
	word_count: int,
	truncated:  bool,
}

@(private)
extract_bool_const :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (val: bool, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return false, false
	}
	e := ir.exprs[eid]
	if e.kind == .Lit_Bool {
		return e.bool_val, true
	}
	return false, false
}

@(private)
extract_int_const :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (val: i64, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return 0, false
	}
	e := ir.exprs[eid]
	if e.kind == .Lit_Int {
		return e.int_val, true
	}
	if e.kind == .Unary && e.unary_op == .Neg && e.lhs != INVALID_EXPR {
		inner := ir.exprs[e.lhs]
		if inner.kind == .Lit_Int {
			return -inner.int_val, true
		}
	}
	return 0, false
}

@(private)
extract_float_const :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (val: f64, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return 0, false
	}
	e := ir.exprs[eid]
	if e.kind == .Lit_Float {
		return e.float_val, true
	}
	if e.kind == .Lit_Int {
		return f64(e.int_val), true
	}
	if e.kind == .Unary && e.unary_op == .Neg && e.lhs != INVALID_EXPR {
		inner := ir.exprs[e.lhs]
		if inner.kind == .Lit_Float {
			return -inner.float_val, true
		}
		if inner.kind == .Lit_Int {
			return -f64(inner.int_val), true
		}
	}
	return 0, false
}

@(private)
extract_string_const :: proc(ir: ^Rulebase_IR, eid: Expr_Id) -> (val: String_Id, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return EMPTY_STRING, false
	}
	e := ir.exprs[eid]
	if e.kind == .Lit_String {
		return e.str_id, true
	}
	return EMPTY_STRING, false
}

@(private)
collect_int_cuts :: proc(ir: ^Rulebase_IR, eid: Expr_Id, cuts: ^[dynamic]i64, lo_bound, hi_bound: i64) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return
	}
	add_cut :: proc(cuts: ^[dynamic]i64, v, lo_b, hi_b: i64) {
		if v >= lo_b && v <= hi_b {
			append(cuts, v)
		}
	}
	add_after :: proc(cuts: ^[dynamic]i64, v, lo_b, hi_b: i64) {
		if v < hi_b && v + 1 >= lo_b {
			append(cuts, v + 1)
		}
	}

	e := ir.exprs[eid]
	#partial switch e.kind {
	case .Lit_Int, .Unary:
		if v, ok := extract_int_const(ir, eid); ok {
			add_cut(cuts, v, lo_bound, hi_bound)
			add_after(cuts, v, lo_bound, hi_bound)
		}
	case .Cell_Cmp:
		if v, ok := extract_int_const(ir, e.rhs); ok {
			#partial switch e.binary_op {
			case .Eq, .Neq:
				add_cut(cuts, v, lo_bound, hi_bound)
				add_after(cuts, v, lo_bound, hi_bound)
			case .Lt, .Gte:
				add_cut(cuts, v, lo_bound, hi_bound)
			case .Lte, .Gt:
				add_after(cuts, v, lo_bound, hi_bound)
			}
		}
	case .Range:
		if lo, ok_lo := extract_int_const(ir, e.lhs); ok_lo {
			add_cut(cuts, lo, lo_bound, hi_bound)
		}
		if hi, ok_hi := extract_int_const(ir, e.rhs); ok_hi {
			if e.inclusive {
				add_after(cuts, hi, lo_bound, hi_bound)
			} else {
				add_cut(cuts, hi, lo_bound, hi_bound)
			}
		}
	case .In_List:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			collect_int_cuts(ir, ir.extra_exprs[i], cuts, lo_bound, hi_bound)
		}
	case .Binary:
		if e.binary_op == .And || e.binary_op == .Or {
			collect_int_cuts(ir, e.lhs, cuts, lo_bound, hi_bound)
			collect_int_cuts(ir, e.rhs, cuts, lo_bound, hi_bound)
		}
	}
}

@(private)
collect_float_cuts :: proc(ir: ^Rulebase_IR, eid: Expr_Id, cuts: ^[dynamic]f64) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return
	}
	e := ir.exprs[eid]
	#partial switch e.kind {
	case .Lit_Float, .Lit_Int, .Unary:
		if v, ok := extract_float_const(ir, eid); ok {
			append(cuts, v)
		}
	case .Cell_Cmp:
		if v, ok := extract_float_const(ir, e.rhs); ok {
			append(cuts, v)
		}
	case .Range:
		if lo, ok_lo := extract_float_const(ir, e.lhs); ok_lo {
			append(cuts, lo)
		}
		if hi, ok_hi := extract_float_const(ir, e.rhs); ok_hi {
			append(cuts, hi)
		}
	case .In_List:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			collect_float_cuts(ir, ir.extra_exprs[i], cuts)
		}
	case .Binary:
		if e.binary_op == .And || e.binary_op == .Or {
			collect_float_cuts(ir, e.lhs, cuts)
			collect_float_cuts(ir, e.rhs, cuts)
		}
	}
}

@(private)
collect_string_literals :: proc(ir: ^Rulebase_IR, eid: Expr_Id, out: ^[dynamic]String_Id, seen: ^map[String_Id]bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return
	}
	e := ir.exprs[eid]
	#partial switch e.kind {
	case .Lit_String:
		if !(e.str_id in seen^) {
			seen^[e.str_id] = true
			append(out, e.str_id)
		}
	case .Cell_Cmp:
		collect_string_literals(ir, e.rhs, out, seen)
	case .In_List:
		for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
			collect_string_literals(ir, ir.extra_exprs[i], out, seen)
		}
	case .Binary:
		if e.binary_op == .And || e.binary_op == .Or {
			collect_string_literals(ir, e.lhs, out, seen)
			collect_string_literals(ir, e.rhs, out, seen)
		}
	}
}

@(require_results)
build_column_domain :: proc(
	ir: ^Rulebase_IR,
	tbl: Table_Def,
	col_idx: int,
	allocator := context.allocator,
	max_fragments := MAX_TABLE_FRAGMENTS,
) -> (dom: Column_Domain, err: mem.Allocator_Error) {
	dom.col_idx = col_idx
	col := tbl.inputs[col_idx]
	frag_cap := max_fragments if max_fragments > 0 else MAX_TABLE_FRAGMENTS

	switch col.type.kind {
	case .Bool:
		dom.kind = .Bool
		dom.atoms = make([]Domain_Atom, 2, allocator) or_return
		dom.atoms[0] = Domain_Atom{kind = .Bool, bool_val = false}
		dom.atoms[1] = Domain_Atom{kind = .Bool, bool_val = true}

	case .Enum:
		dom.kind = .Enum
		edef := ir.enums[col.type.ref_id]
		dom.atoms = make([]Domain_Atom, len(edef.variants), allocator) or_return
		for v, i in edef.variants {
			dom.atoms[i] = Domain_Atom{kind = .Enum, str_id = v}
		}

	case .I32, .I64:
		dom.kind = .Int_Interval
		lo_bound := i64(min(i32)) if col.type.kind == .I32 else min(i64)
		hi_bound := i64(max(i32)) if col.type.kind == .I32 else max(i64)
		cuts := make([dynamic]i64, 0, 16, context.temp_allocator)
		append(&cuts, lo_bound)
		for row in tbl.rows {
			if col_idx < len(row.cells) {
				collect_int_cuts(ir, row.cells[col_idx], &cuts, lo_bound, hi_bound)
			}
		}
		slice.sort(cuts[:])
		uniq := make([dynamic]i64, 0, len(cuts), context.temp_allocator)
		for v in cuts {
			if len(uniq) == 0 || uniq[len(uniq) - 1] != v {
				append(&uniq, v)
			}
		}
		if len(uniq) > frag_cap {
			dom.truncated = true
			resize(&uniq, frag_cap)
		}
		dom.atoms = make([]Domain_Atom, len(uniq), allocator) or_return
		for i in 0 ..< len(uniq) {
			lo := uniq[i]
			hi := uniq[i + 1] - 1 if i + 1 < len(uniq) else hi_bound
			rep: i64
			if lo <= 0 && 0 <= hi {
				rep = 0
			} else if lo == lo_bound {
				rep = hi
			} else if hi == hi_bound {
				rep = lo
			} else {
				rep = lo + (hi - lo) / 2
			}
			dom.atoms[i] = Domain_Atom{
				kind    = .Int_Interval,
				int_lo  = lo,
				int_hi  = hi,
				int_rep = rep,
			}
		}

	case .F64:
		dom.kind = .Float_Interval
		cuts := make([dynamic]f64, 0, 16, context.temp_allocator)
		for row in tbl.rows {
			if col_idx < len(row.cells) {
				collect_float_cuts(ir, row.cells[col_idx], &cuts)
			}
		}
		slice.sort(cuts[:])
		uniq := make([dynamic]f64, 0, len(cuts), context.temp_allocator)
		for v in cuts {
			if len(uniq) == 0 || uniq[len(uniq) - 1] != v {
				append(&uniq, v)
			}
		}
		max_pts := max((frag_cap - 1) / 2, 1)
		if len(uniq) > max_pts {
			dom.truncated = true
			resize(&uniq, max_pts)
		}
		if len(uniq) == 0 {
			dom.atoms = make([]Domain_Atom, 1, allocator) or_return
			dom.atoms[0] = Domain_Atom{kind = .Float_Interval, float_rep = 0.0}
		} else {
			atoms := make([dynamic]Domain_Atom, 0, len(uniq) * 2 + 1, allocator) or_return
			append(&atoms, Domain_Atom{
				kind      = .Float_Interval,
				float_hi  = uniq[0],
				float_rep = uniq[0] - 1.0,
			})
			for i in 0 ..< len(uniq) {
				v := uniq[i]
				append(&atoms, Domain_Atom{
					kind      = .Float_Interval,
					float_lo  = v,
					float_hi  = v,
					lo_inc    = true,
					hi_inc    = true,
					float_rep = v,
				})
				if i + 1 < len(uniq) {
					nxt := uniq[i + 1]
					append(&atoms, Domain_Atom{
						kind      = .Float_Interval,
						float_lo  = v,
						float_hi  = nxt,
						float_rep = 0.5 * (v + nxt),
					})
				}
			}
			last := uniq[len(uniq) - 1]
			append(&atoms, Domain_Atom{
				kind      = .Float_Interval,
				float_lo  = last,
				float_rep = last + 1.0,
			})
			dom.atoms = atoms[:]
		}

	case .String, .Entity, .Time, .Unknown, .Fact, .Table_Result:
		dom.kind = .String_Set
		lits := make([dynamic]String_Id, 0, 16, context.temp_allocator)
		seen := make(map[String_Id]bool, 16, context.temp_allocator)
		for row in tbl.rows {
			if col_idx < len(row.cells) {
				collect_string_literals(ir, row.cells[col_idx], &lits, &seen)
			}
		}
		max_lits := max(frag_cap - 1, 1)
		if len(lits) > max_lits {
			dom.truncated = true
			resize(&lits, max_lits)
		}
		dom.atoms = make([]Domain_Atom, len(lits) + 1, allocator) or_return
		for sid, i in lits {
			dom.atoms[i] = Domain_Atom{kind = .String_Set, str_id = sid}
		}
		dom.atoms[len(lits)] = Domain_Atom{kind = .String_Set, is_other = true}
	}

	dom.word_count = max((len(dom.atoms) + 63) / 64, 1)
	return dom, nil
}

@(private)
atom_matches_expr :: proc(ir: ^Rulebase_IR, atom: Domain_Atom, eid: Expr_Id) -> (matched: bool, ok: bool) {
	if eid == INVALID_EXPR || int(eid) >= len(ir.exprs) {
		return false, false
	}
	e := ir.exprs[eid]
	if e.kind == .Wildcard {
		return true, true
	}
	if e.kind == .Binary && (e.binary_op == .And || e.binary_op == .Or) {
		lm, lok := atom_matches_expr(ir, atom, e.lhs)
		rm, rok := atom_matches_expr(ir, atom, e.rhs)
		if !lok || !rok {
			return false, false
		}
		return (lm && rm) if e.binary_op == .And else (lm || rm), true
	}

	switch atom.kind {
	case .Bool:
		if bval, bok := extract_bool_const(ir, eid); bok {
			return atom.bool_val == bval, true
		}
		if e.kind == .Cell_Cmp {
			if bval, bok := extract_bool_const(ir, e.rhs); bok {
				if e.binary_op == .Eq {
					return atom.bool_val == bval, true
				}
				if e.binary_op == .Neq {
					return atom.bool_val != bval, true
				}
			}
		}
		return false, false

	case .Enum, .String_Set:
		target_match := proc(ir: ^Rulebase_IR, atom: Domain_Atom, target_id: String_Id) -> bool {
			if atom.is_other {
				return false
			}
			return ir_string(ir, atom.str_id) == ir_string(ir, target_id)
		}
		if sval, sok := extract_string_const(ir, eid); sok {
			return target_match(ir, atom, sval), true
		}
		if e.kind == .Cell_Cmp {
			if sval, sok := extract_string_const(ir, e.rhs); sok {
				eq := target_match(ir, atom, sval)
				if e.binary_op == .Eq {
					return eq, true
				}
				if e.binary_op == .Neq {
					return !eq, true
				}
			}
		}
		if e.kind == .In_List {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				m, mok := atom_matches_expr(ir, atom, ir.extra_exprs[i])
				if !mok {
					return false, false
				}
				if m {
					return true, true
				}
			}
			return false, true
		}
		return false, false

	case .Int_Interval:
		v := atom.int_lo
		if cval, cok := extract_int_const(ir, eid); cok {
			return v == cval, true
		}
		if e.kind == .Cell_Cmp {
			if rhs, rok := extract_int_const(ir, e.rhs); rok {
				#partial switch e.binary_op {
				case .Eq:
					return v == rhs, true
				case .Neq:
					return v != rhs, true
				case .Lt:
					return v < rhs, true
				case .Lte:
					return v <= rhs, true
				case .Gt:
					return v > rhs, true
				case .Gte:
					return v >= rhs, true
				}
			}
		}
		if e.kind == .Range {
			lo, lok := extract_int_const(ir, e.lhs)
			hi, hok := extract_int_const(ir, e.rhs)
			if lok && hok {
				if e.inclusive {
					return v >= lo && v <= hi, true
				}
				return v >= lo && v < hi, true
			}
		}
		if e.kind == .In_List {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				m, mok := atom_matches_expr(ir, atom, ir.extra_exprs[i])
				if !mok {
					return false, false
				}
				if m {
					return true, true
				}
			}
			return false, true
		}
		return false, false

	case .Float_Interval:
		v := atom.float_rep
		if cval, cok := extract_float_const(ir, eid); cok {
			return v == cval, true
		}
		if e.kind == .Cell_Cmp {
			if rhs, rok := extract_float_const(ir, e.rhs); rok {
				#partial switch e.binary_op {
				case .Eq:
					return v == rhs, true
				case .Neq:
					return v != rhs, true
				case .Lt:
					return v < rhs, true
				case .Lte:
					return v <= rhs, true
				case .Gt:
					return v > rhs, true
				case .Gte:
					return v >= rhs, true
				}
			}
		}
		if e.kind == .Range {
			lo, lok := extract_float_const(ir, e.lhs)
			hi, hok := extract_float_const(ir, e.rhs)
			if lok && hok {
				if e.inclusive {
					return v >= lo && v <= hi, true
				}
				return v >= lo && v < hi, true
			}
		}
		if e.kind == .In_List {
			for i in e.extra_span.start ..< e.extra_span.start + e.extra_span.count {
				m, mok := atom_matches_expr(ir, atom, ir.extra_exprs[i])
				if !mok {
					return false, false
				}
				if m {
					return true, true
				}
			}
			return false, true
		}
		return false, false
	}

	return false, false
}

eval_cell_mask :: proc(ir: ^Rulebase_IR, dom: Column_Domain, eid: Expr_Id, out_mask: []u64) -> bool {
	for i in 0 ..< len(out_mask) {
		out_mask[i] = 0
	}
	for atom, ai in dom.atoms {
		m, ok := atom_matches_expr(ir, atom, eid)
		if !ok {
			return false
		}
		if m {
			out_mask[ai / 64] |= u64(1) << u64(ai % 64)
		}
	}
	return true
}

@(private)
mask_set_all :: proc "contextless" (mask: []u64, atom_count: int) {
	for i in 0 ..< len(mask) {
		mask[i] = 0
	}
	for i in 0 ..< atom_count {
		mask[i / 64] |= u64(1) << u64(i % 64)
	}
}

@(private)
mask_is_empty :: proc "contextless" (mask: []u64) -> bool {
	for w in mask {
		if w != 0 {
			return false
		}
	}
	return true
}

@(private)
mask_is_full :: proc "contextless" (mask: []u64, atom_count: int) -> bool {
	for i in 0 ..< atom_count {
		if (mask[i / 64] & (u64(1) << u64(i % 64))) == 0 {
			return false
		}
	}
	return true
}

@(private)
mask_equal :: proc "contextless" (a, b: []u64) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

@(private)
mask_and :: proc "contextless" (dst, a, b: []u64) {
	for i in 0 ..< len(dst) {
		dst[i] = a[i] & b[i]
	}
}

@(private)
mask_and_not :: proc "contextless" (dst, a, b: []u64) {
	for i in 0 ..< len(dst) {
		dst[i] = a[i] & ~b[i]
	}
}

@(private)
mask_first_bit :: proc "contextless" (mask: []u64) -> int {
	for w, wi in mask {
		if w != 0 {
			for b in 0 ..< 64 {
				if (w & (u64(1) << u64(b))) != 0 {
					return wi * 64 + b
				}
			}
		}
	}
	return 0
}

@(private)
format_witness :: proc(
	ir: ^Rulebase_IR,
	tbl: Table_Def,
	doms: []Column_Domain,
	region: [][]u64,
	allocator := context.allocator,
) -> (out: string, err: mem.Allocator_Error) {
	b: strings.Builder
	strings.builder_init(&b, allocator) or_return
	defer if err != nil {
		strings.builder_destroy(&b)
	}
	strings.write_byte(&b, '(')
	for ci in 0 ..< len(doms) {
		if ci > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, ir_string(ir, tbl.inputs[ci].name))
		strings.write_byte(&b, '=')
		ai := mask_first_bit(region[ci])
		atom := doms[ci].atoms[ai]
		switch atom.kind {
		case .Bool:
			strings.write_string(&b, "true" if atom.bool_val else "false")
		case .Enum:
			fmt.sbprintf(&b, "%q", ir_string(ir, atom.str_id))
		case .Int_Interval:
			fmt.sbprintf(&b, "%d", atom.int_rep)
		case .Float_Interval:
			fmt.sbprintf(&b, "%g", atom.float_rep)
		case .String_Set:
			if atom.is_other {
				strings.write_string(&b, `"<other>"`)
			} else {
				fmt.sbprintf(&b, "%q", ir_string(ir, atom.str_id))
			}
		}
	}
	strings.write_byte(&b, ')')
	return strings.to_string(b), nil
}
