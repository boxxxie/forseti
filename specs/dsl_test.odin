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
	w.stores = make(map[string]^Store_Handle, 8)
	w.forks = make(map[string]^forseti.Fork_Handle, 8)
	w.sync_runs = make(map[string]forseti.Sync_Result, 8)
}

world_destroy :: proc(w: ^World) {
	vmem.arena_check_temp(&w.arena)
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

@(test)
spec_harness_world_bootstrap_sanity :: proc(t: ^testing.T) {
	w: World
	world_init(&w, t)
	defer world_destroy(&w)

	driver_record_bootstrap_telemetry(&w.telemetry)
	testing.expect_value(t, len(w.telemetry.events), 1)
}
