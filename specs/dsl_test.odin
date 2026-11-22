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

Mdm_Org_Input :: struct {
	id:            string,
	name:          string,
	country:       string,
	domain:        string,
	employees:     i64,
	active:        bool,
	locked_fields: []string,
}

Store_Handle :: struct {
	bridge:       forseti.Store_Bridge,
	syncer:       forseti.Delta_Syncer,
	interner:     forseti.String_Interner,
	sync_inited:  bool,
	attached_dir: string,
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
	stores:          map[string]^Store_Handle,
	forks:           map[string]^forseti.Fork_Handle,
	sync_runs:       map[string]forseti.Sync_Result,
	last_store_err:  forseti.Store_Error,
	rulebases:          map[string]^forseti.Rulebase,
	sessions:           map[string]^forseti.Session,
	query_runs:         map[string]forseti.Query_Result,
	fire_counts:        map[string]u64,
	explain_texts:      map[string]string,
	graph_exports:      map[string]string,
	impacts:            map[string]forseti.Impact_Report,
	semiring_runs:      map[string]forseti.Semiring_Result,
	diff_reports:       map[string]forseti.Diff_Replay_Report,
	effect_applied_ids: map[string][]forseti.Fact_Id,
	last_effect_jobs:   int,
	last_compile_err:   forseti.Compile_Error,
	aot_check_ok:       bool,
	aot_test_ok:        bool,
	aot_err_msg:        string,
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
	w.stores = make(map[string]^Store_Handle, 8)
	w.forks = make(map[string]^forseti.Fork_Handle, 8)
	w.sync_runs = make(map[string]forseti.Sync_Result, 8)
	w.rulebases = make(map[string]^forseti.Rulebase, 8)
	w.sessions = make(map[string]^forseti.Session, 8)
	w.query_runs = make(map[string]forseti.Query_Result, 8)
	w.fire_counts = make(map[string]u64, 8)
	w.explain_texts = make(map[string]string, 8)
	w.graph_exports = make(map[string]string, 8)
	w.impacts = make(map[string]forseti.Impact_Report, 8)
	w.semiring_runs = make(map[string]forseti.Semiring_Result, 8)
	w.diff_reports = make(map[string]forseti.Diff_Replay_Report, 8)
	w.effect_applied_ids = make(map[string][]forseti.Fact_Id, 8)
}

world_destroy :: proc(w: ^World) {
	vmem.arena_check_temp(&w.arena)
	for _, fids in w.effect_applied_ids {
		delete(fids)
	}
	delete(w.effect_applied_ids)
	for _, &dr in w.diff_reports {
		forseti.diff_replay_report_destroy(&dr)
	}
	delete(w.diff_reports)
	for _, &sr in w.semiring_runs {
		forseti.semiring_result_destroy(&sr)
	}
	delete(w.semiring_runs)
	for _, &imp in w.impacts {
		forseti.impact_report_destroy(&imp)
	}
	delete(w.impacts)
	delete(w.explain_texts)
	delete(w.graph_exports)
	for _, &qr in w.query_runs {
		forseti.query_result_destroy(&qr)
	}
	delete(w.query_runs)
	delete(w.fire_counts)
	for _, s in w.sessions {
		forseti.session_destroy(s)
		free(s)
	}
	delete(w.sessions)
	for _, rb in w.rulebases {
		forseti.rulebase_destroy(rb)
		free(rb)
	}
	delete(w.rulebases)
	for _, &sr in w.sync_runs {
		forseti.sync_result_destroy(&sr)
	}
	delete(w.sync_runs)
	for _, fh in w.forks {
		forseti.fork_destroy(fh)
		free(fh)
	}
	delete(w.forks)
	for _, sh in w.stores {
		if sh.sync_inited {
			forseti.delta_syncer_destroy(&sh.syncer)
		}
		forseti.store_bridge_destroy(&sh.bridge)
		forseti.interner_destroy(&sh.interner)
		free(sh)
	}
	delete(w.stores)
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

then_cli_json_stdout_parses :: proc(
	w: ^World,
	run_label: string,
	expected_keys: []string,
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
	for k in expected_keys {
		testing.expectf(w.t, k in obj, "expected JSON key %q in %q", k, res.stdout, loc = loc)
	}
}

then_cli_json_int_field_at_least :: proc(
	w: ^World,
	run_label: string,
	field: string,
	min_val: i64,
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
	fv, has := obj[field]
	if !testing.expectf(w.t, has, "missing JSON field %q in %q", field, res.stdout, loc = loc) {
		return
	}
	iv, is_int := fv.(json.Integer)
	testing.expectf(w.t, is_int && i64(iv) >= min_val, "expected %s >= %d, got %v", field, min_val, fv, loc = loc)
}

then_cli_json_int_field_equals :: proc(
	w: ^World,
	run_label: string,
	field: string,
	expected: i64,
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
	fv, has := obj[field]
	if !testing.expectf(w.t, has, "missing JSON field %q in %q", field, res.stdout, loc = loc) {
		return
	}
	iv, is_int := fv.(json.Integer)
	testing.expectf(w.t, is_int && i64(iv) == expected, "expected %s == %d, got %v", field, expected, fv, loc = loc)
}

then_workspace_file_contains :: proc(
	w: ^World,
	rel_path: string,
	needles: []string,
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
	if !testing.expectf(w.t, read_ok, "failed reading workspace file %q", rel_path, loc = loc) {
		return
	}
	for n in needles {
		testing.expectf(w.t, strings.contains(raw, n), "expected %q in file %q, got:\n%s", n, rel_path, raw, loc = loc)
	}
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

given_standalone_store :: proc(
	w: ^World,
	label: string,
	cfg := forseti.Xitdb_Config{},
	loc := #caller_location,
) {
	sh, err := driver_create_standalone_store(cfg, &w.telemetry)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		w.last_store_err = err
		return
	}
	if prev, has := w.stores[label]; has {
		driver_destroy_store_handle(prev)
	}
	w.stores[label] = sh
}

given_attached_file_store :: proc(
	w: ^World,
	label: string,
	rel_filename: string,
	cfg := forseti.Xitdb_Config{},
	loc := #caller_location,
) {
	sh, err := driver_open_file_store(w.t, rel_filename, cfg, &w.telemetry)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		w.last_store_err = err
		return
	}
	if prev, has := w.stores[label]; has {
		driver_destroy_store_handle(prev)
	}
	w.stores[label] = sh
}

upon_reopening_attached_file_store :: proc(
	w: ^World,
	old_label: string,
	new_label: string,
	rel_filename: string,
	cfg := forseti.Xitdb_Config{},
	loc := #caller_location,
) {
	old_sh, has := w.stores[old_label]
	if !testing.expectf(w.t, has, "unknown store %q", old_label, loc = loc) {
		return
	}
	dir := old_sh.attached_dir
	driver_destroy_store_handle(old_sh)
	delete_key(&w.stores, old_label)

	sh, err := driver_reopen_file_store_in_dir(dir, rel_filename, cfg, &w.telemetry)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		w.last_store_err = err
		return
	}
	w.stores[new_label] = sh
}

given_watched_collection :: proc(
	w: ^World,
	store_label: string,
	path: string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	err := forseti.delta_syncer_watch(&sh.syncer, path)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_committing_mdm_orgs :: proc(
	w: ^World,
	store_label: string,
	orgs: []Mdm_Org_Input,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	err := driver_commit_mdm_orgs(&sh.bridge, orgs)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_bulk_seeding_records :: proc(
	w: ^World,
	store_label: string,
	collection_path: string,
	count: int,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	err := driver_bulk_seed_records(&sh.bridge, collection_path, count)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_mutating_record_batch :: proc(
	w: ^World,
	store_label: string,
	collection_path: string,
	added: []string,
	updated: []string,
	removed: []string,
	new_val_offset: i64 = 1000,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	err := driver_mutate_record_batch(&sh.bridge, collection_path, added, updated, removed, new_val_offset)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_syncing_deltas :: proc(
	w: ^World,
	store_label: string,
	run_label: string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	if prev, had := &w.sync_runs[run_label]; had {
		forseti.sync_result_destroy(prev)
	}
	res: forseti.Sync_Result
	err := forseti.delta_syncer_sync(&sh.syncer, &sh.bridge, &res)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		forseti.sync_result_destroy(&res)
		return
	}
	w.sync_runs[run_label] = res
}

upon_compacting_store :: proc(
	w: ^World,
	store_label: string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	err := forseti.store_bridge_compact(&sh.bridge)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_creating_overlay_fork :: proc(
	w: ^World,
	parent_label: string,
	fork_label: string,
	loc := #caller_location,
) {
	sh, has := w.stores[parent_label]
	if !testing.expectf(w.t, has, "unknown store %q", parent_label, loc = loc) {
		return
	}
	fh := new(forseti.Fork_Handle)
	err := forseti.fork_create(fh, &sh.bridge)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		forseti.fork_destroy(fh)
		free(fh)
		return
	}
	if prev, had := w.forks[fork_label]; had {
		forseti.fork_destroy(prev)
		free(prev)
	}
	w.forks[fork_label] = fh
}

upon_mutating_overlay_fork_record :: proc(
	w: ^World,
	fork_label: string,
	collection_path: string,
	key: string,
	value: i64,
	loc := #caller_location,
) {
	fh, has := w.forks[fork_label]
	if !testing.expectf(w.t, has, "unknown fork %q", fork_label, loc = loc) {
		return
	}
	err := driver_mutate_record_batch(&fh.bridge, collection_path, nil, {key}, nil, value)
	testing.expect_value(w.t, err, nil, loc = loc)
}

upon_attempting_invalid_file_open :: proc(
	w: ^World,
	rel_filename: string,
	setup_cfg: forseti.Xitdb_Config,
	reopen_cfg: forseti.Xitdb_Config,
	reopen_existing: bool,
	loc := #caller_location,
) {
	err := driver_attempt_invalid_file_open(w.t, rel_filename, setup_cfg, reopen_cfg, reopen_existing)
	w.last_store_err = err
	if !testing.expect(w.t, err != nil, loc = loc) {
		return
	}
}

upon_attempting_invalid_memory_open :: proc(
	w: ^World,
	init_cfg: forseti.Xitdb_Config,
	reopen_cfg: forseti.Xitdb_Config,
	reopen_existing: bool,
	loc := #caller_location,
) {
	err := driver_attempt_invalid_memory_open(init_cfg, reopen_cfg, reopen_existing)
	w.last_store_err = err
	if !testing.expect(w.t, err != nil, loc = loc) {
		return
	}
}

then_lazy_field_equals :: proc(
	w: ^World,
	store_label: string,
	moment_idx: i64,
	collection_path: string,
	record_key: string,
	fields: []string,
	expected: Table_Test_Arg,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	val, found, err := driver_read_store_lazy_field(&sh.bridge, moment_idx, collection_path, record_key, fields, &sh.interner)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	if !testing.expectf(w.t, found, "expected lazy field at %s[%q] to exist", collection_path, record_key, loc = loc) {
		return
	}
	driver_expect_value_matches_arg(w.t, val, expected, &sh.interner, loc)
}

then_sorted_prefix_scan_returns :: proc(
	w: ^World,
	store_label: string,
	collection_path: string,
	prefix: string,
	expected_keys: []string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	actual, err := driver_read_sorted_prefix(&sh.bridge, collection_path, prefix, context.temp_allocator)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(actual), len(expected_keys), loc = loc)
	for i := 0; i < min(len(actual), len(expected_keys)); i += 1 {
		testing.expect_value(w.t, actual[i], expected_keys[i], loc = loc)
	}
}

then_eav_entity_attributes_match :: proc(
	w: ^World,
	store_label: string,
	collection_path: string,
	entity: string,
	expected_attrs: []string,
	expected_vals: []string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	attrs, vals, err := driver_scan_eav_entity(&sh.bridge, collection_path, entity, &sh.interner, context.temp_allocator)
	if !testing.expect_value(w.t, err, nil, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(attrs), len(expected_attrs), loc = loc)
	for i := 0; i < min(len(attrs), len(expected_attrs)); i += 1 {
		testing.expect_value(w.t, attrs[i], expected_attrs[i], loc = loc)
		testing.expect_value(w.t, vals[i], expected_vals[i], loc = loc)
	}
}

then_delta_sync_counts :: proc(
	w: ^World,
	run_label: string,
	expected_added: int,
	expected_removed: int,
	expected_changed_pairs: int,
	expect_compacted: bool,
	loc := #caller_location,
) {
	res, has := &w.sync_runs[run_label]
	if !testing.expectf(w.t, has, "unknown sync run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, res.was_compacted, expect_compacted, loc = loc)
	added, removed, changed_old, changed_new := 0, 0, 0, 0
	for d in res.deltas {
		switch d.kind {
		case .Added:       added += 1
		case .Removed:     removed += 1
		case .Changed_Old: changed_old += 1
		case .Changed_New: changed_new += 1
		}
	}
	testing.expect_value(w.t, added, expected_added, loc = loc)
	testing.expect_value(w.t, removed, expected_removed, loc = loc)
	testing.expect_value(w.t, changed_old, expected_changed_pairs, loc = loc)
	testing.expect_value(w.t, changed_new, expected_changed_pairs, loc = loc)
}

then_delta_sync_skipped_slots :: proc(
	w: ^World,
	run_label: string,
	min_slots_skipped: u64,
	max_blocks_compared: u64,
	max_keys_decoded: u64,
	loc := #caller_location,
) {
	res, has := &w.sync_runs[run_label]
	if !testing.expectf(w.t, has, "unknown sync run %q", run_label, loc = loc) {
		return
	}
	testing.expectf(w.t, res.slots_skipped >= min_slots_skipped, "expected slots_skipped >= %d, got %d", min_slots_skipped, res.slots_skipped, loc = loc)
	testing.expectf(w.t, res.blocks_compared <= max_blocks_compared, "expected blocks_compared <= %d, got %d", max_blocks_compared, res.blocks_compared, loc = loc)
	testing.expectf(w.t, res.keys_decoded <= max_keys_decoded, "expected keys_decoded <= %d, got %d", max_keys_decoded, res.keys_decoded, loc = loc)
}

then_telemetry_counter_at_least :: proc(
	w: ^World,
	counter: forseti.Telemetry_Counter,
	min_val: u64,
	loc := #caller_location,
) {
	actual := w.telemetry.counters[counter]
	testing.expectf(w.t, actual >= min_val, "expected counter %v >= %d, got %d", counter, min_val, actual, loc = loc)
}

then_overlay_fork_is_isolated :: proc(
	w: ^World,
	parent_label: string,
	fork_label: string,
	collection_path: string,
	key: string,
	expected_parent_val: Maybe(i64),
	expected_fork_val: Maybe(i64),
	max_owned_bytes: i64,
	loc := #caller_location,
) {
	sh, has_p := w.stores[parent_label]
	fh, has_f := w.forks[fork_label]
	if !testing.expectf(w.t, has_p && has_f, "missing store/fork", loc = loc) {
		return
	}
	p_val, p_found, p_err := driver_read_store_lazy_field(&sh.bridge, -1, collection_path, key, nil, &sh.interner)
	testing.expect_value(w.t, p_err, nil, loc = loc)
	if exp_p, ok := expected_parent_val.?; ok {
		testing.expect(w.t, p_found, loc = loc)
		testing.expect_value(w.t, p_val.(i64) or_else -999999, exp_p, loc = loc)
	} else {
		testing.expect_value(w.t, p_found, false, loc = loc)
	}

	f_val, f_found, f_err := driver_read_store_lazy_field(&fh.bridge, -1, collection_path, key, nil, &sh.interner)
	testing.expect_value(w.t, f_err, nil, loc = loc)
	if exp_f, ok := expected_fork_val.?; ok {
		testing.expect(w.t, f_found, loc = loc)
		testing.expect_value(w.t, f_val.(i64) or_else -999999, exp_f, loc = loc)
	} else {
		testing.expect_value(w.t, f_found, false, loc = loc)
	}

	owned := forseti.fork_owned_bytes(fh)
	testing.expectf(w.t, owned <= max_owned_bytes, "expected overlay owned bytes <= %d, got %d", max_owned_bytes, owned, loc = loc)
}

then_store_error_is :: proc(
	w: ^World,
	expected: forseti.Store_Error,
	loc := #caller_location,
) {
	testing.expect_value(w.t, w.last_store_err, expected, loc = loc)
}

upon_compiling_rulebase :: proc(
	w: ^World,
	policy_label: string,
	rb_label: string,
	loc := #caller_location,
) {
	slot, ok := &w.policies[policy_label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", policy_label, loc = loc) {
		return
	}
	rb, err := driver_compile_rulebase(&slot.ir, &w.telemetry)
	if !testing.expect_value(w.t, err, forseti.Compile_Error.None, loc = loc) {
		forseti.rulebase_destroy(rb)
		free(rb)
		return
	}
	if prev, had := w.rulebases[rb_label]; had {
		forseti.rulebase_destroy(prev)
		free(prev)
	}
	w.rulebases[rb_label] = rb
}

given_session :: proc(
	w: ^World,
	rb_label: string,
	sess_label: string,
	cfg := forseti.Session_Config{},
	loc := #caller_location,
) {
	rb, ok := w.rulebases[rb_label]
	if !testing.expectf(w.t, ok, "unknown rulebase %q", rb_label, loc = loc) {
		return
	}
	sess := new(forseti.Session)
	err := forseti.session_init(sess, rb, cfg, &w.telemetry)
	if !testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc) {
		forseti.session_destroy(sess)
		free(sess)
		return
	}
	if prev, had := w.sessions[sess_label]; had {
		forseti.session_destroy(prev)
		free(prev)
	}
	w.sessions[sess_label] = sess
}

given_session_phases :: proc(
	w: ^World,
	sess_label: string,
	phases: []string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	err := forseti.session_set_phases(sess, phases)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
}

upon_asserting_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	key: string,
	args: []Table_Test_Arg,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	err := driver_session_assert(sess, binding_name, key, args)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
}

upon_modifying_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	key: string,
	args: []Table_Test_Arg,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	err := driver_session_modify_by_key(sess, binding_name, key, args)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
}

upon_retracting_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	key: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	err := driver_session_retract_by_key(sess, binding_name, key)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
}

upon_firing_session :: proc(
	w: ^World,
	sess_label: string,
	run_label: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	cnt, err := forseti.session_fire(sess)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
	w.fire_counts[run_label] = cnt
}

upon_syncing_store_and_firing :: proc(
	w: ^World,
	store_label: string,
	sess_label: string,
	run_label: string,
	commit_derived := false,
	loc := #caller_location,
) {
	sh, sok := w.stores[store_label]
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, sok && ok, "unknown store/session", loc = loc) {
		return
	}
	cnt, err := forseti.session_sync_and_fire(sess, &sh.bridge, &sh.syncer, commit_derived)
	testing.expect_value(w.t, err, nil, loc = loc)
	w.fire_counts[run_label] = cnt
}

upon_running_query :: proc(
	w: ^World,
	sess_label: string,
	query_name: string,
	run_label: string,
	arg_names: []string,
	arg_vals: []Table_Test_Arg,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	if prev, had := &w.query_runs[run_label]; had {
		forseti.query_result_destroy(prev)
	}
	res, err := driver_run_query(sess, query_name, arg_names, arg_vals)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
	w.query_runs[run_label] = res
}

then_rules_fired_count_is :: proc(w: ^World, run_label: string, expected: u64, loc := #caller_location) {
	cnt, ok := w.fire_counts[run_label]
	if !testing.expectf(w.t, ok, "unknown fire run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, cnt, expected, loc = loc)
}

then_fired_rule_sequence_is :: proc(
	w: ^World,
	sess_label: string,
	expected_names: []string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(sess.fired_trace), len(expected_names), loc = loc)
	for i := 0; i < min(len(sess.fired_trace), len(expected_names)); i += 1 {
		actual := forseti.interner_get(&sess.rb.interner, sess.fired_trace[i])
		testing.expect_value(w.t, actual, expected_names[i], loc = loc)
	}
}

then_session_has_derived_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	found := driver_session_find_fact_matching(sess, binding_name, expected_fields)
	testing.expectf(w.t, found, "expected live fact in %q matching provided fields", binding_name, loc = loc)
}

then_query_matches_are :: proc(
	w: ^World,
	run_label: string,
	expected_count: int,
	var_name: string,
	expected_vals: []string,
	loc := #caller_location,
) {
	qr, ok := &w.query_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown query run %q", run_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(qr.rows), expected_count, loc = loc)
	for exp in expected_vals {
		found := driver_query_has_value(qr, var_name, exp)
		testing.expectf(w.t, found, "expected query variable %q to include %q", var_name, exp, loc = loc)
	}
}

then_session_telemetry_bounds :: proc(
	w: ^World,
	min_live_mem: u64,
	max_live_mem: u64,
	max_beta_joins: u64,
	min_unlinked_skipped: u64,
	loc := #caller_location,
) {
	live := w.telemetry.watermarks.live_session_memories
	joins := w.telemetry.counters[.Beta_Joins]
	skipped := w.telemetry.counters[.Segments_Skipped_Unlinked]
	testing.expectf(w.t, live >= min_live_mem && live <= max_live_mem, "live_memories=%d out of [%d..%d]", live, min_live_mem, max_live_mem, loc = loc)
	testing.expectf(w.t, joins <= max_beta_joins, "beta_joins=%d > %d", joins, max_beta_joins, loc = loc)
	testing.expectf(w.t, skipped >= min_unlinked_skipped, "segments_skipped_unlinked=%d < %d", skipped, min_unlinked_skipped, loc = loc)
}

then_store_collection_has_record_count_and_field :: proc(
	w: ^World,
	store_label: string,
	collection_path: string,
	expected_count: int,
	field_name: string,
	expected_str: string,
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	cnt, matched, err := driver_check_store_collection_entry(&sh.bridge, collection_path, field_name, expected_str, &sh.interner)
	testing.expect_value(w.t, err, nil, loc = loc)
	testing.expect_value(w.t, cnt, expected_count, loc = loc)
	testing.expectf(w.t, matched, "expected %s[%q == %q] in store %q", collection_path, field_name, expected_str, store_label, loc = loc)
}

upon_attempting_rulebase_compile :: proc(
	w: ^World,
	policy_label: string,
	loc := #caller_location,
) {
	slot, ok := &w.policies[policy_label]
	if !testing.expectf(w.t, ok && slot.compiled, "policy %q must be compiled", policy_label, loc = loc) {
		return
	}
	rb, err := driver_compile_rulebase(&slot.ir, &w.telemetry)
	w.last_compile_err = err
	if err == .None {
		forseti.rulebase_destroy(rb)
	}
	free(rb)
}

then_rulebase_compile_failed_with :: proc(
	w: ^World,
	expected: forseti.Compile_Error,
	loc := #caller_location,
) {
	testing.expect_value(w.t, w.last_compile_err, expected, loc = loc)
}

then_session_binding_count_is :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_count: int,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	total, _ := driver_session_count_binding_facts(sess, binding_name)
	testing.expect_value(w.t, total, expected_count, loc = loc)
}

then_session_lacks_derived_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	found := driver_session_find_fact_matching(sess, binding_name, expected_fields)
	testing.expectf(w.t, !found, "expected NO live fact in %q matching fields, but found one", binding_name, loc = loc)
}

then_derived_fact_proof_and_support :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
	expected_origin: forseti.Fact_Origin,
	expected_support: i32,
	expected_height: u32,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	fid, found := driver_session_find_matching_fact_id(sess, binding_name, expected_fields)
	if !testing.expectf(w.t, found, "expected fact in %q", binding_name, loc = loc) {
		return
	}
	f := sess.facts[fid]
	testing.expect_value(w.t, f.origin, expected_origin, loc = loc)
	testing.expect_value(w.t, f.support_count, expected_support, loc = loc)
	testing.expect_value(w.t, f.proof_height, expected_height, loc = loc)
}

upon_committing_session_audit :: proc(
	w: ^World,
	sess_label: string,
	store_label: string,
	loc := #caller_location,
) {
	sess, sok := w.sessions[sess_label]
	sh, st_ok := w.stores[store_label]
	if !testing.expectf(w.t, sok && st_ok, "unknown session/store", loc = loc) {
		return
	}
	_, err := forseti.session_commit_derived_and_audit(sess, &sh.bridge)
	testing.expect_value(w.t, err, nil, loc = loc)
}

then_store_audit_trail_is_complete :: proc(
	w: ^World,
	store_label: string,
	expected_module: string,
	min_decisions: int,
	rule_name: string,
	entity_key_hint: string = "",
	loc := #caller_location,
) {
	sh, has := w.stores[store_label]
	if !testing.expectf(w.t, has, "unknown store %q", store_label, loc = loc) {
		return
	}
	ok, msg := driver_check_audit_moment_integrity(&sh.bridge, expected_module, min_decisions, rule_name, entity_key_hint, &sh.interner)
	testing.expectf(w.t, ok, "audit trail check failed: %s", msg, loc = loc)
}

upon_explaining_derived_fact :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
	explain_label: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	fid, found := driver_session_find_matching_fact_id(sess, binding_name, expected_fields)
	if !testing.expectf(w.t, found, "cannot explain missing fact in %q", binding_name, loc = loc) {
		return
	}
	tree := forseti.explain(sess, fid)
	defer forseti.explain_tree_destroy(&tree)
	testing.expect(w.t, tree.found, loc = loc)
	formatted := forseti.explain_format(&tree, vmem.arena_allocator(&w.arena))
	w.explain_texts[explain_label] = formatted
}

then_explanation_contains :: proc(
	w: ^World,
	explain_label: string,
	substrs: []string,
	loc := #caller_location,
) {
	txt, ok := w.explain_texts[explain_label]
	if !testing.expectf(w.t, ok, "unknown explain %q", explain_label, loc = loc) {
		return
	}
	for s in substrs {
		testing.expectf(w.t, strings.contains(txt, s), "expected explanation to contain %q, got:\n%s", s, txt, loc = loc)
	}
}

upon_computing_rule_impact :: proc(
	w: ^World,
	sess_label: string,
	rule_name: string,
	impact_label: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	rid := max(u32)
	for r, i in sess.rb.rules {
		if forseti.interner_get(&sess.rb.interner, r.name) == rule_name {
			rid = u32(i)
			break
		}
	}
	if !testing.expectf(w.t, rid != max(u32), "unknown rule %q", rule_name, loc = loc) {
		return
	}
	if prev, had := &w.impacts[impact_label]; had {
		forseti.impact_report_destroy(prev)
	}
	w.impacts[impact_label] = forseti.impact(sess, rid)
}

then_impact_counts_at_least :: proc(
	w: ^World,
	impact_label: string,
	min_direct: int,
	min_transitive: int,
	min_derivs: int,
	loc := #caller_location,
) {
	rep, ok := &w.impacts[impact_label]
	if !testing.expectf(w.t, ok, "unknown impact %q", impact_label, loc = loc) {
		return
	}
	testing.expectf(w.t, len(rep.direct_facts) >= min_direct, "direct=%d < %d", len(rep.direct_facts), min_direct, loc = loc)
	testing.expectf(w.t, len(rep.transitive_facts) >= min_transitive, "transitive=%d < %d", len(rep.transitive_facts), min_transitive, loc = loc)
	testing.expectf(w.t, len(rep.derivations) >= min_derivs, "derivs=%d < %d", len(rep.derivations), min_derivs, loc = loc)
}

upon_evaluating_semiring :: proc(
	w: ^World,
	sess_label: string,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
	kind: forseti.Semiring_Kind,
	run_label: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	fid, found := driver_session_find_matching_fact_id(sess, binding_name, expected_fields)
	if !testing.expectf(w.t, found, "cannot evaluate semiring on missing fact in %q", binding_name, loc = loc) {
		return
	}
	if prev, had := &w.semiring_runs[run_label]; had {
		forseti.semiring_result_destroy(prev)
	}
	w.semiring_runs[run_label] = forseti.evaluate_semiring(sess, fid, kind)
}

then_semiring_result_satisfies :: proc(
	w: ^World,
	run_label: string,
	expect_bool: bool = true,
	min_why_sets: int = 0,
	how_substr: string = "",
	min_viterbi_score: f64 = 0.0,
	loc := #caller_location,
) {
	sr, ok := &w.semiring_runs[run_label]
	if !testing.expectf(w.t, ok, "unknown semiring run %q", run_label, loc = loc) {
		return
	}
	switch sr.kind {
	case .Boolean:
		testing.expect_value(w.t, sr.boolean_val, expect_bool, loc = loc)
	case .Why:
		testing.expectf(w.t, len(sr.why_sets) >= min_why_sets, "why_sets=%d < %d", len(sr.why_sets), min_why_sets, loc = loc)
	case .How:
		testing.expectf(w.t, len(sr.how_expr) > 0, "empty How expr", loc = loc)
		if len(how_substr) > 0 {
			testing.expectf(w.t, strings.contains(sr.how_expr, how_substr), "expected How %q to contain %q", sr.how_expr, how_substr, loc = loc)
		}
	case .Viterbi:
		testing.expectf(w.t, sr.viterbi_score >= min_viterbi_score && sr.viterbi_score <= 1.0, "viterbi=%v", sr.viterbi_score, loc = loc)
		testing.expect(w.t, len(sr.viterbi_path) >= 1, loc = loc)
	}
}

upon_running_diff_replay :: proc(
	w: ^World,
	baseline_sess_label: string,
	store_label: string,
	candidate_rb_label: string,
	watched_paths: []string,
	report_label: string,
	loc := #caller_location,
) {
	sess, sok := w.sessions[baseline_sess_label]
	sh, st_ok := w.stores[store_label]
	rb, r_ok := w.rulebases[candidate_rb_label]
	if !testing.expectf(w.t, sok && st_ok && r_ok, "unknown session/store/candidate rb", loc = loc) {
		return
	}
	if prev, had := &w.diff_reports[report_label]; had {
		forseti.diff_replay_report_destroy(prev)
	}
	rep, err := forseti.session_diff_replay(sess, &sh.bridge, rb, watched_paths)
	testing.expect_value(w.t, err, nil, loc = loc)
	w.diff_reports[report_label] = rep
}

then_diff_replay_reports :: proc(
	w: ^World,
	report_label: string,
	expected_added: int,
	expected_removed: int,
	expected_unchanged: int,
	loc := #caller_location,
) {
	rep, ok := &w.diff_reports[report_label]
	if !testing.expectf(w.t, ok, "unknown diff report %q", report_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, len(rep.added), expected_added, loc = loc)
	testing.expect_value(w.t, len(rep.removed), expected_removed, loc = loc)
	testing.expect_value(w.t, rep.unchanged_count, expected_unchanged, loc = loc)
	testing.expect_value(w.t, rep.parent_moments_after, rep.parent_moments_before, loc = loc)
}

then_provenance_has_zero_hot_crypto :: proc(
	w: ^World,
	sess_label: string,
	min_derivs: int,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, sess.provenance.hot_crypto_hashes, u64(0), loc = loc)
	if min_derivs > 0 {
		testing.expectf(w.t, len(sess.provenance.derivs) - 1 >= min_derivs, "expected >= %d derivs", min_derivs, loc = loc)
	} else {
		testing.expect_value(w.t, len(sess.provenance.derivs), 0, loc = loc)
	}
}

upon_executing_effects_in_parallel :: proc(
	w: ^World,
	sess_label: string,
	out_binding: string,
	batch_label: string,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	applied, cnt, err := driver_run_effects_in_parallel_threads(sess, out_binding)
	testing.expect_value(w.t, err, forseti.Session_Error.None, loc = loc)
	w.last_effect_jobs = cnt
	if prev, had := w.effect_applied_ids[batch_label]; had {
		delete(prev)
	}
	w.effect_applied_ids[batch_label] = applied
}

then_effect_batch_applied :: proc(
	w: ^World,
	batch_label: string,
	expected_count: int,
	loc := #caller_location,
) {
	applied, ok := w.effect_applied_ids[batch_label]
	if !testing.expectf(w.t, ok, "unknown effect batch %q", batch_label, loc = loc) {
		return
	}
	testing.expect_value(w.t, w.last_effect_jobs, expected_count, loc = loc)
	testing.expect_value(w.t, len(applied), expected_count, loc = loc)
}

Graph_Export_Format :: enum u8 {
	Dot,
	Mermaid,
}

upon_exporting_rulebase_graph :: proc(
	w: ^World,
	rb_label: string,
	fmt_kind: Graph_Export_Format,
	graph_label: string,
	loc := #caller_location,
) {
	rb, ok := w.rulebases[rb_label]
	if !testing.expectf(w.t, ok, "unknown rulebase %q", rb_label, loc = loc) {
		return
	}
	txt: string
	alloc := vmem.arena_allocator(&w.arena)
	if fmt_kind == .Dot {
		dot_txt, d_err := forseti.export_rulebase_dot(rb, alloc)
		testing.expect_value(w.t, d_err, nil, loc = loc)
		txt = dot_txt
	} else {
		mmd_txt, m_err := forseti.export_rulebase_mermaid(rb, alloc)
		testing.expect_value(w.t, m_err, nil, loc = loc)
		txt = mmd_txt
	}
	w.graph_exports[graph_label] = txt
}

upon_exporting_derivation_graph :: proc(
	w: ^World,
	sess_label: string,
	fmt_kind: Graph_Export_Format,
	graph_label: string,
	binding_name := "",
	match_fields: []Table_Test_Arg = nil,
	loc := #caller_location,
) {
	sess, ok := w.sessions[sess_label]
	if !testing.expectf(w.t, ok, "unknown session %q", sess_label, loc = loc) {
		return
	}
	focus := forseti.INVALID_FACT
	if len(binding_name) > 0 {
		fid, found := driver_session_find_matching_fact_id(sess, binding_name, match_fields)
		if !testing.expectf(w.t, found, "cannot focus derivation graph on missing %q fact", binding_name, loc = loc) {
			return
		}
		focus = fid
	}
	alloc := vmem.arena_allocator(&w.arena)
	if fmt_kind == .Dot {
		txt, d_err := forseti.export_derivations_dot(sess, focus, alloc)
		testing.expect_value(w.t, d_err, nil, loc = loc)
		w.graph_exports[graph_label] = txt
	} else {
		txt, m_err := forseti.export_derivations_mermaid(sess, focus, alloc)
		testing.expect_value(w.t, m_err, nil, loc = loc)
		w.graph_exports[graph_label] = txt
	}
}

then_graph_export_contains :: proc(
	w: ^World,
	graph_label: string,
	needles: []string,
	loc := #caller_location,
) {
	txt, ok := w.graph_exports[graph_label]
	if !testing.expectf(w.t, ok, "unknown graph export %q", graph_label, loc = loc) {
		return
	}
	for n in needles {
		testing.expectf(w.t, strings.contains(txt, n), "expected graph %q to contain %q, got:\n%s", graph_label, n, txt, loc = loc)
	}
}

Entity_Audit_View :: struct {
	w:            ^World,
	sess_label:   string,
	store_label:  string,
	binding_name: string,
	entity_key:   string,
	found:        bool,
	fid:          forseti.Fact_Id,
}

viewing_entity_audit :: proc(
	w: ^World,
	sess_label: string,
	store_label: string,
	binding_name: string,
	match_fields: []Table_Test_Arg,
	entity_key: string,
	loc := #caller_location,
) -> Entity_Audit_View {
	sess, sok := w.sessions[sess_label]
	_, st_ok := w.stores[store_label]
	testing.expectf(w.t, sok && st_ok, "unknown session %q or store %q", sess_label, store_label, loc = loc)
	fid := forseti.INVALID_FACT
	found := false
	resolved_key := entity_key
	if sok {
		fid, found = driver_session_find_matching_fact_id(sess, binding_name, match_fields)
		if found && len(resolved_key) == 0 {
			resolved_key = forseti.session_string(sess, sess.facts[fid].key)
		}
	}
	return Entity_Audit_View{
		w            = w,
		sess_label   = sess_label,
		store_label  = store_label,
		binding_name = binding_name,
		entity_key   = resolved_key,
		found        = found,
		fid          = fid,
	}
}

view_has_proof_support :: proc(
	v: Entity_Audit_View,
	expected_origin: forseti.Fact_Origin,
	expected_support: i32,
	expected_height: u32,
	loc := #caller_location,
) {
	if !testing.expectf(v.w.t, v.found, "expected alive %s fact in view", v.binding_name, loc = loc) {
		return
	}
	sess, sok := v.w.sessions[v.sess_label]
	if !testing.expectf(v.w.t, sok, "unknown session %q", v.sess_label, loc = loc) {
		return
	}
	f := &sess.facts[v.fid]
	testing.expect(v.w.t, f.alive, loc = loc)
	testing.expect_value(v.w.t, f.origin, expected_origin, loc = loc)
	testing.expect_value(v.w.t, f.support_count, expected_support, loc = loc)
	testing.expect_value(v.w.t, f.proof_height, expected_height, loc = loc)
}

view_explanation_mentions :: proc(
	v: Entity_Audit_View,
	rule_name: string,
	table_name := "",
	table_row := "",
	loc := #caller_location,
) {
	if !testing.expectf(v.w.t, v.found, "expected alive %s fact for explanation", v.binding_name, loc = loc) {
		return
	}
	sess := v.w.sessions[v.sess_label]
	tree := forseti.explain(sess, v.fid)
	defer forseti.explain_tree_destroy(&tree)
	testing.expect(v.w.t, tree.found, loc = loc)
	txt := forseti.explain_format(&tree)
	defer delete(txt)
	testing.expectf(v.w.t, strings.contains(txt, rule_name), "expected rule %q in explanation:\n%s", rule_name, txt, loc = loc)
	if len(table_name) > 0 {
		testing.expectf(v.w.t, strings.contains(txt, table_name), "expected table %q in explanation:\n%s", table_name, txt, loc = loc)
	}
	if len(table_row) > 0 {
		testing.expectf(v.w.t, strings.contains(txt, table_row), "expected row %q in explanation:\n%s", table_row, txt, loc = loc)
	}
}

view_semiring_how_contains :: proc(
	v: Entity_Audit_View,
	needle: string,
	loc := #caller_location,
) {
	if !testing.expectf(v.w.t, v.found, "expected alive %s fact for How semiring", v.binding_name, loc = loc) {
		return
	}
	sess := v.w.sessions[v.sess_label]
	sr := forseti.evaluate_semiring(sess, v.fid, .How)
	defer forseti.semiring_result_destroy(&sr)
	testing.expectf(v.w.t, strings.contains(sr.how_expr, needle), "expected %q in How expr %q", needle, sr.how_expr, loc = loc)
}

view_semiring_why_count_is :: proc(
	v: Entity_Audit_View,
	expected_count: int,
	loc := #caller_location,
) {
	if !testing.expectf(v.w.t, v.found, "expected alive %s fact for Why semiring", v.binding_name, loc = loc) {
		return
	}
	sess := v.w.sessions[v.sess_label]
	sr := forseti.evaluate_semiring(sess, v.fid, .Why)
	defer forseti.semiring_result_destroy(&sr)
	testing.expect_value(v.w.t, len(sr.why_sets), expected_count, loc = loc)
}

view_store_audit_indexes_entity :: proc(
	v: Entity_Audit_View,
	expected_module, expected_rule: string,
	expected_min_decisions: int,
	loc := #caller_location,
) {
	sh, st_ok := v.w.stores[v.store_label]
	if !testing.expectf(v.w.t, st_ok, "unknown store %q", v.store_label, loc = loc) {
		return
	}
	ok, msg := driver_check_audit_moment_integrity(&sh.bridge, expected_module, expected_min_decisions, expected_rule, v.entity_key, &sh.interner)
	testing.expectf(v.w.t, ok, "store audit index check failed: %s", msg, loc = loc)
}

view_is_retracted :: proc(v: Entity_Audit_View, loc := #caller_location) {
	testing.expectf(v.w.t, !v.found, "expected %s fact to be retracted/absent", v.binding_name, loc = loc)
}

@(test)
spec_harness_world_bootstrap_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	driver_record_bootstrap_telemetry(&w.telemetry)
	testing.expect_value(t, len(w.telemetry.events), 1)
}
