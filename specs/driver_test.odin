package forseti_specs

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "../forseti"

driver_record_bootstrap_telemetry :: proc(sink: ^forseti.Telemetry_Sink) {
	sc := forseti.telemetry_span_begin(sink, .Custom, "harness_bootstrap")
	forseti.telemetry_span_end(sink, sc)
}

driver_compile_external :: proc(
	src: string,
	filename: string,
	out_ir: ^forseti.Rulebase_IR,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
) -> mem.Allocator_Error {
	ir, err := forseti.compile_source(src, filename, diags, telemetry)
	if err != nil {
		return err
	}
	out_ir^ = ir
	return nil
}

driver_compile_internal :: proc(
	builder: ^forseti.Ir_Builder,
	out_ir: ^forseti.Rulebase_IR,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
) -> mem.Allocator_Error {
	ir, err := forseti.ir_builder_build(builder, diags, telemetry)
	if err != nil {
		return err
	}
	out_ir^ = ir
	return nil
}

driver_verify_table_with_budget :: proc(
	ir: ^forseti.Rulebase_IR,
	table_idx: u32,
	diags: ^forseti.Diagnostic_List,
	telemetry: ^forseti.Telemetry_Sink,
	max_budget: int,
) -> mem.Allocator_Error {
	return forseti.verify_decision_table(ir, table_idx, diags, telemetry, forseti.Verify_Options{max_budget = max_budget})
}

@(private = "file")
Lazy_Eval_Ctx :: struct {
	ct:          ^forseti.Compiled_Table,
	args:        []Table_Test_Arg,
	call_counts: ^[64]int,
}

@(private = "file")
test_arg_to_value :: proc(ct: ^forseti.Compiled_Table, arg: Table_Test_Arg) -> forseti.Value {
	switch v in arg {
	case bool:
		return v
	case i32:
		return v
	case i64:
		return v
	case f64:
		return v
	case string:
		return forseti.compiled_table_string_value(ct, v)
	}
	return {}
}

@(private = "file")
test_lazy_getter :: proc(col_idx: int, user_data: rawptr) -> forseti.Value {
	ctx := (^Lazy_Eval_Ctx)(user_data)
	ctx.call_counts[col_idx] += 1
	return test_arg_to_value(ctx.ct, ctx.args[col_idx])
}

driver_eval_table :: proc(
	ir: ^forseti.Rulebase_IR,
	table_name: string,
	args: []Table_Test_Arg,
	lazy: bool,
	telemetry: ^forseti.Telemetry_Sink,
) -> (run: Decision_Run, err_msg: string) {
	found := false
	table_idx := u32(0)
	for t, ti in ir.tables {
		if forseti.ir_string(ir, t.name) == table_name {
			table_idx = u32(ti)
			found = true
			break
		}
	}
	if !found {
		return {}, fmt.tprintf("unknown table %q", table_name)
	}

	ct, cerr := forseti.compile_table(ir, table_idx, telemetry)
	if cerr != nil {
		return {}, fmt.tprintf("compile_table error: %v", cerr)
	}
	run.table = ct

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	prev_alloc := context.allocator
	context.allocator = mem.tracking_allocator(&track)

	if lazy {
		lctx := Lazy_Eval_Ctx{
			ct          = &run.table,
			args        = args,
			call_counts = &run.call_counts,
		}
		run.result = forseti.decide_lazy(&run.table, test_lazy_getter, rawptr(&lctx))
	} else {
		vals: [64]forseti.Value
		for a, i in args {
			vals[i] = test_arg_to_value(&run.table, a)
		}
		run.result = forseti.decide_values(&run.table, vals[:len(args)])
	}

	context.allocator = prev_alloc
	run.alloc_count = len(track.allocation_map)
	mem.tracking_allocator_destroy(&track)
	return run, ""
}

driver_cleanup_cli_dir :: proc(ptr: rawptr) {
	p := (^string)(ptr)
	if p != nil {
		if len(p^) > 0 {
			_ = os.remove_all(p^)
			delete(p^)
		}
		free(p)
	}
}

driver_prepare_cli_binary :: proc(w: ^World) -> string {
	if len(w.cli_bin) > 0 {
		return ""
	}
	arena_alloc := vmem.arena_allocator(&w.arena)
	dir, dir_err := os.make_directory_temp("", "forseti_cli_*", context.allocator)
	if dir_err != nil {
		return fmt.tprintf("make_directory_temp failed: %v", dir_err)
	}
	cleanup_ptr := new(string)
	cleanup_ptr^ = dir
	testing.cleanup(w.t, driver_cleanup_cli_dir, rawptr(cleanup_ptr))

	w.cli_dir = dir

	bin_path, join_err := filepath.join({dir, "forseti"}, arena_alloc)
	if join_err != nil {
		return "filepath.join failed"
	}

	out_flag := fmt.tprintf("-out:%s", bin_path)
	cmd := []string{
		"odin",
		"build",
		"cmd/forseti",
		out_flag,
		"-collection:xitdb=../xitdb/xitdb",
		"-collection:hugi=../hugi/hugi",
		"-collection:obench=../hugi/deps/obench/obench",
	}
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
	if exec_err != nil {
		return fmt.tprintf("odin build exec failed: %v", exec_err)
	}
	if state.exit_code != 0 {
		return fmt.tprintf("odin build failed (%d): %s %s", state.exit_code, string(stdout), string(stderr))
	}
	w.cli_bin = bin_path
	return ""
}

driver_write_file :: proc(full_path, content: string) -> bool {
	return os.write_entire_file(full_path, content) == nil
}

driver_read_file :: proc(full_path: string, allocator := context.temp_allocator) -> (string, bool) {
	data, err := os.read_entire_file(full_path, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

driver_exec_cli :: proc(working_dir, bin_path: string, args: []string) -> (run: Cli_Run, err_msg: string) {
	cmd := make([]string, len(args) + 1, context.temp_allocator)
	cmd[0] = bin_path
	copy(cmd[1:], args)

	state, stdout, stderr, exec_err := os.process_exec(
		os.Process_Desc{working_dir = working_dir, command = cmd},
		context.allocator,
	)
	if exec_err != nil {
		delete(stdout)
		delete(stderr)
		return {}, fmt.tprintf("process_exec failed: %v", exec_err)
	}
	return Cli_Run{
		exit_code = state.exit_code,
		stdout    = string(stdout),
		stderr    = string(stderr),
	}, ""
}
