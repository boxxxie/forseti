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
