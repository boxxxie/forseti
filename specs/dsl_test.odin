package forseti_specs

import "core:encoding/json"
import "core:path/filepath"
import "core:strings"
import vmem "core:mem/virtual"
import "core:testing"
import "../forseti"

Policy_Kind :: enum u8 {
	External,
	Internal,
}

Policy_Slot :: struct {
	kind:     Policy_Kind,
	source:   string,
	filename: string,
	builder:  ^forseti.Ir_Builder,
	ir:       forseti.Rulebase_IR,
	diags:    forseti.Diagnostic_List,
	compiled: bool,
}

Cli_Run :: struct {
	exit_code: int,
	stdout:    string,
	stderr:    string,
}

Table_Test_Arg :: union {
	bool,
	i32,
	i64,
	f64,
	string,
}

Decision_Run :: struct {
	table:       forseti.Compiled_Table,
	result:      forseti.Decision_Result,
	call_counts: [64]int,
	alloc_count: int,
}

World :: struct {
	t:               ^testing.T,
	arena:           vmem.Arena,
	telemetry:       forseti.Telemetry_Sink,
	policies:        map[string]Policy_Slot,
	cli_dir:         string,
	cli_bin:         string,
	cli_runs:        map[string]Cli_Run,
	decision_runs:   map[string]Decision_Run,
	aot_check_ok:    bool,
	aot_test_ok:     bool,
	aot_err_msg:     string,
}

world_init :: proc(w: ^World, t: ^testing.T, loc := #caller_location) {
	w^ = {}
	w.t = t
	arena_err := vmem.arena_init_growing(&w.arena)
	testing.expect_value(t, arena_err, nil, loc = loc)

	tel_err := forseti.telemetry_init(&w.telemetry, enabled = true)
	testing.expect_value(t, tel_err, nil, loc = loc)

	w.policies = make(map[string]Policy_Slot, 8)
	w.cli_runs = make(map[string]Cli_Run, 8)
	w.decision_runs = make(map[string]Decision_Run, 8)
}

world_destroy :: proc(w: ^World) {
	vmem.arena_check_temp(&w.arena)
	for _, &dr in w.decision_runs {
		forseti.compiled_table_destroy(&dr.table)
	}
	delete(w.decision_runs)
	for _, &slot in w.policies {
		if slot.compiled {
			forseti.ir_destroy(&slot.ir)
			forseti.diag_list_destroy(&slot.diags)
		}
	}
	delete(w.policies)
	for _, run in w.cli_runs {
		delete(run.stdout)
		delete(run.stderr)
	}
	delete(w.cli_runs)
	forseti.telemetry_destroy(&w.telemetry)
	vmem.arena_destroy(&w.arena)
	w^ = {}
}

given_external_policy :: proc(
	w: ^World,
	label: string,
	source: string,
	filename: string = "policy.forseti",
	loc := #caller_location,
) {
	arena_alloc := vmem.arena_allocator(&w.arena)
	cloned_src, err1 := strings.clone(source, arena_alloc)
	testing.expect_value(w.t, err1, nil, loc = loc)
	cloned_file, err2 := strings.clone(filename, arena_alloc)
	testing.expect_value(w.t, err2, nil, loc = loc)
	w.policies[label] = Policy_Slot{
		kind     = .External,
		source   = cloned_src,
		filename = cloned_file,
	}
}

given_internal_policy :: proc(
	w: ^World,
	label: string,
	builder: ^forseti.Ir_Builder,
) {
	w.policies[label] = Policy_Slot{
		kind    = .Internal,
		builder = builder,
	}
}

upon_compiling_policy :: proc(w: ^World, label: string, loc := #caller_location) {
	slot, ok := &w.policies[label]
	if !testing.expectf(w.t, ok, "unknown policy label %q", label, loc = loc) {
		return
	}
	if slot.compiled {
		forseti.ir_destroy(&slot.ir)
		forseti.diag_list_destroy(&slot.diags)
		slot.compiled = false
	}

	d_err := forseti.diag_list_init(&slot.diags)
	if !testing.expect_value(w.t, d_err, nil, loc = loc) {
		return
	}

	switch slot.kind {
	case .External:
		err := driver_compile_external(slot.source, slot.filename, &slot.ir, &slot.diags, &w.telemetry)
		if !testing.expect_value(w.t, err, nil, loc = loc) {
			forseti.diag_list_destroy(&slot.diags)
			return
		}
	case .Internal:
		err := driver_compile_internal(slot.builder, &slot.ir, &slot.diags, &w.telemetry)
		if !testing.expect_value(w.t, err, nil, loc = loc) {
			forseti.diag_list_destroy(&slot.diags)
			return
		}
	}
	slot.compiled = true
}

then_compilation_has_zero_diagnostics :: proc(w: ^World, label: string, loc := #caller_location) {
	slot, ok := &w.policies[label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", label, loc = loc) {
		return
	}
	if len(slot.diags.items) != 0 {
		for d in slot.diags.items {
			testing.expectf(w.t, false, "unexpected diagnostic %s at %d:%d: %s", forseti.diag_code_string(d.code), d.line, d.col, d.message, loc = loc)
		}
		return
	}
	testing.expect_value(w.t, len(slot.diags.items), 0, loc = loc)
}

then_policy_emits_diagnostic :: proc(
	w: ^World,
	label: string,
	code: forseti.Diag_Code,
	sev: forseti.Diagnostic_Severity,
	line: u32,
	col: u32,
	substr: string = "",
	loc := #caller_location,
) {
	slot, ok := &w.policies[label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", label, loc = loc) {
		return
	}
	for d in slot.diags.items {
		if d.code == code && d.severity == sev && d.line == line && d.col == col {
			if len(substr) == 0 || strings.contains(d.message, substr) {
				return
			}
		}
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for d in slot.diags.items {
		strings.write_string(&b, forseti.diag_code_string(d.code))
		strings.write_string(&b, " (")
		strings.write_string(&b, d.message)
		strings.write_string(&b, "); ")
	}
	testing.expectf(
		w.t,
		false,
		"expected %s %v at %d:%d, got %d diagnostics: [%s]",
		forseti.diag_code_string(code),
		sev,
		line,
		col,
		len(slot.diags.items),
		strings.to_string(b),
		loc = loc,
	)
}

then_external_and_internal_ir_match :: proc(w: ^World, label_a, label_b: string, loc := #caller_location) {
	slot_a, ok_a := &w.policies[label_a]
	slot_b, ok_b := &w.policies[label_b]
	if !testing.expectf(w.t, ok_a && slot_a.compiled, "policy %q must be compiled", label_a, loc = loc) {
		return
	}
	if !testing.expectf(w.t, ok_b && slot_b.compiled, "policy %q must be compiled", label_b, loc = loc) {
		return
	}
	testing.expect(w.t, forseti.ir_structurally_equal(&slot_a.ir, &slot_b.ir), loc = loc)
}

upon_verifying_table_with_budget :: proc(
	w: ^World,
	label: string,
	table_idx: u32,
	max_budget: int,
	loc := #caller_location,
) {
	upon_compiling_policy(w, label, loc = loc)
	slot, ok := &w.policies[label]
	if !ok || !slot.compiled {
		return
	}
	err := driver_verify_table_with_budget(&slot.ir, table_idx, &slot.diags, &w.telemetry, max_budget)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_deciding_table :: proc(
	w: ^World,
	policy_label: string,
	table_name: string,
	run_label: string,
	args: []Table_Test_Arg,
	loc := #caller_location,
) {
	slot, ok := &w.policies[policy_label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", policy_label, loc = loc) {
		return
	}
	if prev, has := &w.decision_runs[run_label]; has {
		forseti.compiled_table_destroy(&prev.table)
	}
	run, err_msg := driver_eval_table(&slot.ir, table_name, args, lazy = false, telemetry = &w.telemetry)
	if !testing.expectf(w.t, err_msg == "", "failed evaluating table %q: %s", table_name, err_msg, loc = loc) {
		forseti.compiled_table_destroy(&run.table)
		return
	}
	w.decision_runs[run_label] = run
}

upon_deciding_table_lazily :: proc(
	w: ^World,
	policy_label: string,
	table_name: string,
	run_label: string,
	args: []Table_Test_Arg,
	loc := #caller_location,
) {
	slot, ok := &w.policies[policy_label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", policy_label, loc = loc) {
		return
	}
	if prev, has := &w.decision_runs[run_label]; has {
		forseti.compiled_table_destroy(&prev.table)
	}
	run, err_msg := driver_eval_table(&slot.ir, table_name, args, lazy = true, telemetry = &w.telemetry)
	if !testing.expectf(w.t, err_msg == "", "failed lazy evaluating table %q: %s", table_name, err_msg, loc = loc) {
		forseti.compiled_table_destroy(&run.table)
		return
	}
	w.decision_runs[run_label] = run
}

then_decision_result_is :: proc(
	w: ^World,
	run_label: string,
	expected_match: bool,
	expected_out0: string,
	expected_row: string,
	loc := #caller_location,
) {
	run, ok := &w.decision_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown decision run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, run.result.matched, expected_match, loc = loc)
	if expected_match {
		actual_out0 := forseti.compiled_table_output_string(&run.table, run.result.outputs[0])
		testing.expect_value(w.t, actual_out0, expected_out0, loc = loc)
		actual_row := forseti.compiled_table_winning_row_id(&run.table, run.result)
		testing.expect_value(w.t, actual_row, expected_row, loc = loc)
	}
}

then_decision_column_eval_counts :: proc(
	w: ^World,
	run_label: string,
	col: int,
	expected_calls: int,
	expect_skipped_bit: bool,
	loc := #caller_location,
) {
	run, ok := &w.decision_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown decision run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, run.call_counts[col], expected_calls, loc = loc)
	bit := u64(1) << u64(col)
	testing.expect_value(w.t, (run.result.trace.skipped_col_mask & bit) != 0, expect_skipped_bit, loc = loc)
}

then_decision_allocated_zero_bytes :: proc(w: ^World, run_label: string, loc := #caller_location) {
	run, ok := &w.decision_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown decision run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, run.alloc_count, 0, loc = loc)
}

then_decision_int_output_is :: proc(
	w: ^World,
	run_label: string,
	col: int,
	expected: i64,
	expected_hits: u32,
	loc := #caller_location,
) {
	run, ok := &w.decision_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown decision run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, run.result.matched_row_count, expected_hits, loc = loc)
	testing.expect_value(w.t, run.result.output_set[col], true, loc = loc)
	val, is_i64 := run.result.outputs[col].(i64)
	testing.expect(w.t, is_i64, loc = loc)
	if is_i64 {
		testing.expect_value(w.t, val, expected, loc = loc)
	}
}

then_decision_outputs_are :: proc(
	w: ^World,
	run_label: string,
	expected_outs: []string,
	expected_hits: u32,
	loc := #caller_location,
) {
	run, ok := &w.decision_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown decision run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, run.result.matched_row_count, expected_hits, loc = loc)
	for exp, i in expected_outs {
		testing.expect_value(w.t, run.result.output_set[i], true, loc = loc)
		actual := forseti.compiled_table_output_string(&run.table, run.result.outputs[i])
		testing.expect_value(w.t, actual, exp, loc = loc)
	}
}

upon_generating_and_verifying_aot_odin :: proc(
	w: ^World,
	policy_label: string,
	pkg_name: string,
	test_src: string,
	loc := #caller_location,
) {
	slot, ok := &w.policies[policy_label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", policy_label, loc = loc) {
		return
	}
	check_ok, test_ok, err_msg := driver_verify_aot_codegen(w.t, &slot.ir, pkg_name, test_src, &w.arena)
	w.aot_check_ok = check_ok
	w.aot_test_ok = test_ok
	w.aot_err_msg = err_msg
}

then_aot_odin_checks_and_passes_tests :: proc(w: ^World, loc := #caller_location) {
	testing.expectf(w.t, w.aot_check_ok, "AOT strict odin check failed: %s", w.aot_err_msg, loc = loc)
	testing.expectf(w.t, w.aot_test_ok, "AOT odin test failed: %s", w.aot_err_msg, loc = loc)
}

then_workspace_odin_file_passes_strict_check :: proc(w: ^World, rel_path: string, loc := #caller_location) {
	if !testing.expect(w.t, len(w.cli_dir) > 0, loc = loc) {
		return
	}
	full, j_err := filepath.join({w.cli_dir, rel_path}, context.temp_allocator)
	if !testing.expect_value(w.t, j_err, nil, loc = loc) {
		return
	}
	ok, err_msg := driver_strict_check_single_file(full)
	testing.expectf(w.t, ok, "strict odin check on %q failed: %s", rel_path, err_msg, loc = loc)
}

given_cli_binary :: proc(w: ^World, loc := #caller_location) {
	err := driver_prepare_cli_binary(w)
	testing.expectf(w.t, err == "", "failed to build cmd/forseti CLI: %s", err, loc = loc)
}

given_workspace_file :: proc(w: ^World, rel_path: string, content: string, loc := #caller_location) {
	if !testing.expect(w.t, len(w.cli_dir) > 0, loc = loc) {
		return
	}
	full, j_err := filepath.join({w.cli_dir, rel_path}, context.temp_allocator)
	if !testing.expect_value(w.t, j_err, nil, loc = loc) {
		return
	}
	ok := driver_write_file(full, content)
	testing.expectf(w.t, ok, "failed writing workspace file %q", rel_path, loc = loc)
}

upon_running_cli :: proc(w: ^World, run_label: string, args: []string, loc := #caller_location) {
	if !testing.expect(w.t, len(w.cli_bin) > 0, loc = loc) {
		return
	}
	if prev, has := w.cli_runs[run_label]; has {
		delete(prev.stdout)
		delete(prev.stderr)
	}
	res, err_msg := driver_exec_cli(w.cli_dir, w.cli_bin, args)
	if !testing.expectf(w.t, err_msg == "", "failed executing CLI: %s", err_msg, loc = loc) {
		delete(res.stdout)
		delete(res.stderr)
		return
	}
	w.cli_runs[run_label] = res
}

then_cli_exits_with :: proc(w: ^World, run_label: string, expected_code: int, loc := #caller_location) {
	res, ok := w.cli_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown CLI run %q", run_label, loc = loc) {
		return
	}
	testing.expectf(
		w.t,
		res.exit_code == expected_code,
		"expected exit %d, got %d; stdout=%q stderr=%q",
		expected_code,
		res.exit_code,
		res.stdout,
		res.stderr,
		loc = loc,
	)
}

then_cli_output_contains :: proc(w: ^World, run_label: string, needle: string, loc := #caller_location) {
	res, ok := w.cli_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown CLI run %q", run_label, loc = loc) {
		return
	}
	combined := strings.concatenate({res.stdout, "\n", res.stderr}, context.temp_allocator)
	testing.expectf(w.t, strings.contains(combined, needle), "expected output to contain %q, got stdout=%q stderr=%q", needle, res.stdout, res.stderr, loc = loc)
}

then_cli_json_reports_diagnostic :: proc(
	w: ^World,
	run_label: string,
	code: string,
	line: i64,
	col: i64,
	loc := #caller_location,
) {
	res, ok := w.cli_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown CLI run %q", run_label, loc = loc) {
		return
	}
	val, p_err := json.parse_string(strings.trim_space(res.stdout), parse_integers = true)
	if !testing.expectf(w.t, p_err == nil, "invalid CLI JSON err=%v stdout=%q", p_err, res.stdout, loc = loc) {
		return
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !testing.expect(w.t, is_obj, loc = loc) {
		return
	}
	diags_val, has_diags := obj["diagnostics"]
	if !testing.expect(w.t, has_diags, loc = loc) {
		return
	}
	diags_arr, is_arr := diags_val.(json.Array)
	if !testing.expect(w.t, is_arr, loc = loc) {
		return
	}
	for elem in diags_arr {
		dobj, dobj_ok := elem.(json.Object)
		if !dobj_ok {
			continue
		}
		if (dobj["code"].(json.String) or_else "") == code &&
			(dobj["line"].(json.Integer) or_else 0) == line &&
			(dobj["col"].(json.Integer) or_else 0) == col {
			return
		}
	}
	testing.expectf(w.t, false, "expected JSON diagnostic %s at %d:%d, got %q", code, line, col, res.stdout, loc = loc)
}

then_workspace_telemetry_trace_has_phases :: proc(
	w: ^World,
	rel_path: string,
	phases: []string,
	loc := #caller_location,
) {
	if !testing.expect(w.t, len(w.cli_dir) > 0, loc = loc) {
		return
	}
	full, j_err := filepath.join({w.cli_dir, rel_path}, context.temp_allocator)
	if !testing.expect_value(w.t, j_err, nil, loc = loc) {
		return
	}
	raw, read_ok := driver_read_file(full, context.temp_allocator)
	if !testing.expectf(w.t, read_ok, "failed reading telemetry trace %q", rel_path, loc = loc) {
		return
	}
	val, p_err := json.parse_string(raw, parse_integers = true)
	if !testing.expectf(w.t, p_err == nil, "invalid trace JSON err=%v", p_err, loc = loc) {
		return
	}
	defer json.destroy_value(val)

	root, is_obj := val.(json.Object)
	if !testing.expect(w.t, is_obj, loc = loc) {
		return
	}
	events_val, has_ev := root["traceEvents"]
	if !testing.expect(w.t, has_ev, loc = loc) {
		return
	}
	events_arr, is_arr := events_val.(json.Array)
	if !testing.expect(w.t, is_arr, loc = loc) {
		return
	}
	for ph in phases {
		found := false
		for ev in events_arr {
			eobj, eok := ev.(json.Object)
			if !eok {
				continue
			}
			if (eobj["cat"].(json.String) or_else "") == ph {
				found = true
				break
			}
		}
		testing.expectf(w.t, found, "expected telemetry trace phase %q in %q", ph, rel_path, loc = loc)
	}
}

@(test)
spec_harness_world_bootstrap_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	driver_record_bootstrap_telemetry(&w.telemetry)
	testing.expect_value(t, len(w.telemetry.events), 1)
}
