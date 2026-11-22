package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../forseti"

Lazy_Probe :: struct {
	calls: [3]int,
}

lazy_col_getter :: proc(col_idx: int, user_data: rawptr) -> forseti.Value {
	probe := (^Lazy_Probe)(user_data)
	probe.calls[col_idx] += 1
	switch col_idx {
	case 0:
		return i64(250)
	case 1:
		return true
	case 2:
		return f64(0.92)
	}
	return nil
}

run_example :: proc() -> bool {
	src := `module ex01_tables version "1.0"

table gate version "1.0" hit First verify(complete, no_dead_rules) {
  inputs { employees: i64 cost 1, active: bool cost 1, llm_conf: f64 cost 100 }
  outputs { action: string }
  rows {
    r_auto:   >= 200 | true  | -      || "auto_merge";
    r_review: >= 50  | true  | >= 0.8 || "steward_review";
    r_reject: -      | -     | -      || "reject";
  }
}

table risk_score version "1.0" hit Collect_Sum {
  inputs { vip: bool, stale: bool }
  outputs { pts: i64 }
  rows {
    r1: true | -    || 10;
    r2: -    | true || 25;
    r0: -    | -    || 0;
  }
}

table field_merge version "1.0" hit Merge {
  inputs { trusted: bool }
  outputs { source_tag: string, owner: string }
  rows {
    r1: true || "crm" | -;
    r2: -    || "erp" | "steward_pool";
  }
}

query check_tables() {
  ?_a := decide gate(employees: 250, active: true, llm_conf: 0.9)
  ?_b := decide risk_score(vip: true, stale: true)
  ?_c := decide field_merge(trusted: true)
}`

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "01_decision_tables.forseti", &diags)
	defer forseti.ir_destroy(&ir)
	if c_err != nil || diags.error_count != 0 || diags.warning_count != 0 {
		fmt.eprintfln("compile error(s): %d err, %d warn", diags.error_count, diags.warning_count)
		return false
	}

	ct_gate, g_err := forseti.compile_table(&ir, 0)
	if g_err != nil {
		return false
	}
	defer forseti.compiled_table_destroy(&ct_gate)

	probe: Lazy_Probe
	res_lazy := forseti.decide(&ct_gate, forseti.Table_Input{getter = lazy_col_getter, user_data = &probe})
	if !res_lazy.matched || probe.calls[2] != 0 || (res_lazy.trace.skipped_col_mask & (u64(1) << 2)) == 0 {
		fmt.eprintln("expected cost-100 column 2 to be lazily skipped")
		return false
	}
	row_id := forseti.compiled_table_winning_row_id(&ct_gate, res_lazy)
	action := forseti.compiled_table_output_string(&ct_gate, res_lazy.outputs[0])

	ct_sum, s_err := forseti.compile_table(&ir, 1)
	if s_err != nil {
		return false
	}
	defer forseti.compiled_table_destroy(&ct_sum)
	res_sum := forseti.decide(&ct_sum, forseti.Table_Input{values = {true, true}})
	sum_pts, sum_ok := res_sum.outputs[0].(i64)
	if !res_sum.matched || !sum_ok || sum_pts != 35 {
		fmt.eprintln("expected Collect_Sum result 35")
		return false
	}

	ct_merge, m_err := forseti.compile_table(&ir, 2)
	if m_err != nil {
		return false
	}
	defer forseti.compiled_table_destroy(&ct_merge)
	res_merge := forseti.decide(&ct_merge, forseti.Table_Input{values = {true}})
	tag := forseti.compiled_table_output_string(&ct_merge, res_merge.outputs[0])
	owner := forseti.compiled_table_output_string(&ct_merge, res_merge.outputs[1])
	if tag != "crm" || owner != "steward_pool" {
		fmt.eprintfln("unexpected Merge outputs: %q, %q", tag, owner)
		return false
	}

	aot_code, aot_err := forseti.codegen_odin_module(&ir, "ex01_aot")
	if aot_err != nil {
		return false
	}
	defer delete(aot_code)
	if !strings.contains(aot_code, `proc "contextless"`) {
		fmt.eprintln("expected contextless proc in generated Odin module")
		return false
	}

	fmt.printfln("[ex01] OK lazy_row=%s(%s) llm_calls=%d sum=%d merge=(%s,%s) aot_bytes=%d",
		row_id, action, probe.calls[2], sum_pts, tag, owner, len(aot_code))
	return true
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	ok := run_example()
	free_all(context.temp_allocator)

	leaks := len(track.allocation_map)
	bad_frees := len(track.bad_free_array)
	for _, entry in track.allocation_map {
		fmt.eprintfln("%v leaked %m", entry.location, entry.size)
	}
	mem.tracking_allocator_destroy(&track)
	if !ok || leaks > 0 || bad_frees > 0 {
		os.exit(1)
	}
}
