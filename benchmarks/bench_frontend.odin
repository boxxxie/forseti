package main

import "core:fmt"
import "core:strings"
import hugi "hugi:."
import "../forseti"

@(private = "file")
_build_frontend_source :: proc(rule_count: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `module bench_frontend version "1.0"

schema Org {
  id: string,
  kind: string,
  bucket: i64,
  employees: i64,
  active: bool,
  score: f64
}
schema Flag { id: string, tier: string }

source Org : Org at .orgs.raw[?id]
derived Flag : Flag at .orgs.flags[?id]

table tier_gate version "1.0" hit Unique verify(complete, no_overlap, no_dead_rules) {
  inputs { active: bool cost 1, employees: i64 cost 2, score: f64 cost 5 }
  outputs { tier: string }
  rows {
    r_ent: true  | >= 200 | >= 0.80 || "enterprise";
    r_mid: true  | >= 200 | <  0.80 || "mid_review";
    r_smb: true  | <  200 | -       || "smb";
    r_off: false | -      | -       || "inactive";
  }
}
`)
	for i := 0; i < rule_count; i += 1 {
		fmt.sbprintf(&b, `rule r_%d {{
  when {{
    ?_o := Org(id: ?id, kind: "saas", bucket: %d, employees: ?emp, active: ?act, score: ?sc)
    ?g := decide tier_gate(active: ?act, employees: ?emp, score: ?sc)
    where ?g.tier != "inactive"
  }}
  then {{
    assert Flag(id: ?id, tier: ?g.tier)
  }}
}}
`, i, i)
	}
	return strings.to_string(b)
}

@(private = "file")
_build_verify_4col_source :: proc(row_count: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `module bench_verify_4col version "1.0"

table gate_4col version "1.0" hit Unique verify(complete, no_overlap, no_dead_rules) {
  inputs {
    active: bool cost 1,
    band:   i64  cost 2,
    region: string cost 3,
    conf:   f64  cost 4
  }
  outputs {
    score: i64
  }
  rows {
`)
	// Partition `band` disjointly across rows [i*10 .. i*10+9] so Unique verification has no overlaps.
	regions := [4]string{"us", "eu", "apac", "latam"}
	for i := 0; i < row_count; i += 1 {
		lo := i * 10
		hi := lo + 9
		fmt.sbprintf(
			&b,
			"    r%d: %s | %d..%d | %q | >= 0.0 || %d;\n",
			i,
			"true" if (i % 2 == 0) else "false",
			lo,
			hi,
			regions[i % len(regions)],
			i + 1,
		)
	}
	strings.write_string(&b, "  }\n}\n")
	return strings.to_string(b)
}

@(private = "file")
_build_verify_8col_source :: proc(row_count: int) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, `module bench_verify_8col version "1.0"

table gate_8col version "1.0" hit First verify(complete, no_dead_rules) {
  inputs {
    active:   bool   cost 1,
    band:     i64    cost 2,
    region:   string cost 3,
    conf:     f64    cost 4,
    tier:     string cost 5,
    verified: bool   cost 6,
    risk:     f64    cost 7,
    bucket:   i64    cost 8
  }
  outputs {
    score: i64
  }
  rows {
`)
	regions := [2]string{"us", "eu"}
	tiers := [2]string{"ent", "smb"}
	for i := 0; i < row_count; i += 1 {
		fmt.sbprintf(
			&b,
			"    r%d: %s | %d..%d | %q | >= 0.5 | %q | %s | <= 0.9 | == %d || %d;\n",
			i,
			"true" if (i % 2 == 0) else "-",
			i * 10,
			i * 10 + 9,
			regions[i % len(regions)],
			tiers[(i / 2) % len(tiers)],
			"true" if (i % 3 == 0) else "-",
			i,
			i + 1,
		)
	}
	strings.write_string(&b, "    r_fallback: - | - | - | - | - | - | - | - || 0;\n  }\n}\n")
	return strings.to_string(b)
}

@(private = "file")
_bench_parse_and_sema_source :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	src := _build_frontend_source(n)
	defer free_all(context.temp_allocator)

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		diags: forseti.Diagnostic_List
		_ = forseti.diag_list_init(&diags)
		ir, err := forseti.compile_source(src, "bench_frontend.forseti", &diags)
		_ = hugi.black_box(len(ir.rules) + int(diags.error_count))
		if err == nil {
			_ = hugi.black_box(len(ir.tables))
		}
		forseti.ir_destroy(&ir)
		forseti.diag_list_destroy(&diags)
	}
}

@(private = "file")
_bench_verify_table_4col :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	src := _build_verify_4col_source(n)
	defer free_all(context.temp_allocator)

	init_diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&init_diags)
	ir, c_err := forseti.compile_source(src, "bench_verify_4col.forseti", &init_diags)
	forseti.diag_list_destroy(&init_diags)
	defer forseti.ir_destroy(&ir)
	if c_err != nil || len(ir.tables) == 0 {
		return
	}

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		diags: forseti.Diagnostic_List
		_ = forseti.diag_list_init(&diags)
		_ = forseti.verify_decision_table(&ir, 0, &diags)
		_ = hugi.black_box(diags.error_count + diags.warning_count)
		forseti.diag_list_destroy(&diags)
	}
}

@(private = "file")
_bench_verify_table_8col_wide :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	src := _build_verify_8col_source(n)
	defer free_all(context.temp_allocator)

	init_diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&init_diags)
	ir, c_err := forseti.compile_source(src, "bench_verify_8col.forseti", &init_diags)
	forseti.diag_list_destroy(&init_diags)
	defer forseti.ir_destroy(&ir)
	if c_err != nil || len(ir.tables) == 0 {
		return
	}

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		diags: forseti.Diagnostic_List
		_ = forseti.diag_list_init(&diags)
		_ = forseti.verify_decision_table(&ir, 0, &diags)
		_ = hugi.black_box(diags.error_count + diags.warning_count)
		forseti.diag_list_destroy(&diags)
	}
}

@(private = "file")
_bench_codegen_aot_odin :: proc(b: ^hugi.Bencher) {
	n := max(hugi.param(b), 10)
	src := _build_verify_4col_source(n)
	defer free_all(context.temp_allocator)

	diags: forseti.Diagnostic_List
	_ = forseti.diag_list_init(&diags)
	ir, c_err := forseti.compile_source(src, "bench_aot_src.forseti", &diags)
	forseti.diag_list_destroy(&diags)
	defer forseti.ir_destroy(&ir)
	if c_err != nil || len(ir.tables) == 0 {
		return
	}

	hugi.set_items(b, u64(n))
	for hugi.step(b) {
		code, g_err := forseti.codegen_odin_module(&ir, "bench_generated")
		if g_err == nil {
			_ = hugi.black_box(len(code))
			delete(code)
		}
	}
}

register_frontend_benchmarks :: proc(suite: ^hugi.Suite) {
	g := hugi.group_add(suite, "frontend_and_verify")
	hugi.group_params(g, []int{10, 50, 128, 256})
	hugi.group_bench(g, "parse_and_sema_source", _bench_parse_and_sema_source)
	hugi.group_bench(g, "verify_table_4col", _bench_verify_table_4col)
	hugi.group_bench(g, "verify_table_8col_wide", _bench_verify_table_8col_wide)
	hugi.group_bench(g, "codegen_aot_odin", _bench_codegen_aot_odin)
}
