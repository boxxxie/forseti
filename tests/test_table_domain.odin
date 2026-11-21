package forseti_tests

import "core:testing"
import "../forseti"

@(test)
test_domain_bool_and_enum_partitions :: proc(t: ^testing.T) {
	src := `schema Item { tier: enum("gold", "silver", "bronze") }
table t version "1" hit First {
  inputs {
    flag: bool,
    tier: enum("gold", "silver", "bronze")
  }
  outputs { ok: bool }
  rows {
    r1: true | "gold" || true;
    r2: -    | "silver" || false;
  }
}`
	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, err := forseti.compile_source(src, "dom.forseti", &diags)
	testing.expect_value(t, err, nil)
	defer forseti.ir_destroy(&ir)

	tbl := ir.tables[0]
	dom_bool, err_b := forseti.build_column_domain(&ir, tbl, 0, context.temp_allocator)
	testing.expect_value(t, err_b, nil)
	testing.expect_value(t, dom_bool.kind, forseti.Domain_Kind.Bool)
	testing.expect_value(t, len(dom_bool.atoms), 2)

	mask_b := make([]u64, dom_bool.word_count, context.temp_allocator)
	testing.expect(t, forseti.eval_cell_mask(&ir, dom_bool, tbl.rows[0].cells[0], mask_b))
	testing.expect_value(t, mask_b[0], u64(0b10) if dom_bool.atoms[1].bool_val else u64(0b01))
	testing.expect(t, forseti.eval_cell_mask(&ir, dom_bool, tbl.rows[1].cells[0], mask_b))
	testing.expect_value(t, mask_b[0], u64(0b11))

	dom_enum, err_e := forseti.build_column_domain(&ir, tbl, 1, context.temp_allocator)
	testing.expect_value(t, err_e, nil)
	testing.expect_value(t, dom_enum.kind, forseti.Domain_Kind.Enum)
	testing.expect_value(t, len(dom_enum.atoms), 3)
}

@(test)
test_domain_int_and_float_interval_partitioning :: proc(t: ^testing.T) {
	src := `table num version "1" hit First {
  inputs {
    score: i64,
    conf: f64
  }
  outputs { tag: string }
  rows {
    r1: < 10             | < 0.5        || "low";
    r2: 10..20           | 0.5..0.9     || "mid";
    r3: > 20             | >= 0.9       || "high";
    r4: > 10 and < 5     | -            || "unsat_cmp";
    r5: 20..10           | -            || "unsat_rev";
    r6: 10..10           | -            || "unsat_half";
    r7: 10..=10          | -            || "exact_ten";
  }
}`
	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, err := forseti.compile_source(src, "num.forseti", &diags)
	testing.expect_value(t, err, nil)
	defer forseti.ir_destroy(&ir)

	tbl := ir.tables[0]
	dom_i, err_i := forseti.build_column_domain(&ir, tbl, 0, context.temp_allocator)
	testing.expect_value(t, err_i, nil)
	testing.expect_value(t, dom_i.kind, forseti.Domain_Kind.Int_Interval)

	mask_i := make([]u64, dom_i.word_count, context.temp_allocator)
	// r4 (>10 and <5), r5 (20..10), r6 (10..10) must all produce empty masks
	for row_idx in 3 ..< 6 {
		ok := forseti.eval_cell_mask(&ir, dom_i, tbl.rows[row_idx].cells[0], mask_i)
		testing.expect(t, ok)
		testing.expectf(t, mask_i[0] == 0, "row %d should have empty int mask, got %b", row_idx, mask_i[0])
	}
	// r7 (10..=10) matches exactly one atom containing 10
	testing.expect(t, forseti.eval_cell_mask(&ir, dom_i, tbl.rows[6].cells[0], mask_i))
	testing.expect(t, mask_i[0] != 0)

	// r1 (<10) | r2 (10..20) | r3 (>20) leaves integer 20 uncovered!
	union_mask: u64 = 0
	for row_idx in 0 ..< 3 {
		testing.expect(t, forseti.eval_cell_mask(&ir, dom_i, tbl.rows[row_idx].cells[0], mask_i))
		union_mask |= mask_i[0]
	}
	gap_found := false
	for atom, ai in dom_i.atoms {
		if (union_mask & (u64(1) << u64(ai))) == 0 && atom.int_lo <= 20 && 20 <= atom.int_hi {
			gap_found = true
		}
	}
	testing.expect(t, gap_found)

	dom_f, err_f := forseti.build_column_domain(&ir, tbl, 1, context.temp_allocator)
	testing.expect_value(t, err_f, nil)
	testing.expect_value(t, dom_f.kind, forseti.Domain_Kind.Float_Interval)

	found_mid := false
	for atom in dom_f.atoms {
		if !atom.lo_inc && !atom.hi_inc && atom.float_lo == 0.5 && atom.float_hi == 0.9 {
			testing.expect_value(t, atom.float_rep, 0.7)
			found_mid = true
		}
	}
	testing.expect(t, found_mid)
}

@(test)
test_domain_string_set_and_other_sentinel :: proc(t: ^testing.T) {
	src := `table str_t version "1" hit First verify(complete) {
  inputs { country: string }
  outputs { region: string }
  rows {
    r1: in ("US", "CA") || "NA";
    r2: "GB"            || "EMEA";
  }
}`
	diags: forseti.Diagnostic_List
	testing.expect_value(t, forseti.diag_list_init(&diags), nil)
	defer forseti.diag_list_destroy(&diags)

	ir, err := forseti.compile_source(src, "str.forseti", &diags)
	testing.expect_value(t, err, nil)
	defer forseti.ir_destroy(&ir)

	dom_s, err_s := forseti.build_column_domain(&ir, ir.tables[0], 0, context.temp_allocator)
	testing.expect_value(t, err_s, nil)
	testing.expect_value(t, dom_s.kind, forseti.Domain_Kind.String_Set)
	testing.expect_value(t, len(dom_s.atoms), 4) // "US", "CA", "GB", and <other>

	has_other := false
	for atom in dom_s.atoms {
		if atom.is_other {
			has_other = true
		}
	}
	testing.expect(t, has_other)
}
