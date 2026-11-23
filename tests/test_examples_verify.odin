package forseti_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
_verify_example_dir :: proc(t: ^testing.T, rel_dir: string, expected_marker: string) {
	main_path, _ := filepath.join({rel_dir, "main.odin"}, context.temp_allocator)
	raw, r_err := os.read_entire_file(main_path, context.allocator)
	testing.expectf(t, r_err == nil, "unable to read %q: %v", main_path, r_err)
	if r_err != nil {
		return
	}
	defer delete(raw)

	// Confirm example source introduces no `do` keyword statements.
	for raw_line, idx in strings.split_lines(string(raw), context.temp_allocator) {
		trimmed := strings.trim_space(raw_line)
		if strings.has_prefix(trimmed, "//") {
			continue
		}
		if strings.contains(raw_line, " do ") || strings.contains(raw_line, "\tdo ") ||
		   strings.has_suffix(trimmed, " do") || strings.has_suffix(trimmed, ")do") {
			testing.expectf(t, false, "%s:%d contains forbidden 'do' keyword", main_path, idx + 1)
		}
	}

	check_cmd := []string{
		"odin",
		"check",
		rel_dir,
		"-collection:xitdb=../xitdb/xitdb",
		"-vet",
		"-vet-tabs",
		"-strict-style",
		"-warnings-as-errors",
	}
	cs, cout, cerr, cex := os.process_exec(os.Process_Desc{command = check_cmd}, context.temp_allocator)
	testing.expectf(
		t,
		cex == nil && cs.exit_code == 0,
		"odin check %s failed (%d): %s %s",
		rel_dir,
		cs.exit_code,
		string(cout),
		string(cerr),
	)

	tmp_dir, t_err := os.make_directory_temp("", "forseti_ex_bin_*", context.allocator)
	testing.expect_value(t, t_err, nil)
	if t_err != nil {
		return
	}
	defer {
		_ = os.remove_all(tmp_dir)
		delete(tmp_dir)
	}

	bin_name := "example_bin.exe" when ODIN_OS == .Windows else "example_bin"
	bin_path, _ := filepath.join({tmp_dir, bin_name}, context.temp_allocator)
	out_flag := fmt.tprintf("-out:%s", bin_path)
	build_cmd := []string{
		"odin",
		"build",
		rel_dir,
		out_flag,
		"-collection:xitdb=../xitdb/xitdb",
	}
	bs, bout, berr, bex := os.process_exec(os.Process_Desc{command = build_cmd}, context.temp_allocator)
	testing.expectf(
		t,
		bex == nil && bs.exit_code == 0,
		"odin build %s failed (%d): %s %s",
		rel_dir,
		bs.exit_code,
		string(bout),
		string(berr),
	)
	if bex != nil || bs.exit_code != 0 {
		return
	}

	rs, rout, rerr, rex := os.process_exec(os.Process_Desc{command = {bin_path}}, context.temp_allocator)
	out_str := string(rout)
	testing.expectf(
		t,
		rex == nil && rs.exit_code == 0,
		"running %s failed (%d): stdout=%q stderr=%q",
		rel_dir,
		rs.exit_code,
		out_str,
		string(rerr),
	)
	testing.expectf(t, strings.contains(out_str, expected_marker), "expected %q in stdout of %s, got %q", expected_marker, rel_dir, out_str)
}

@(test)
test_example_01_decision_tables :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/01_decision_tables", "[ex01] OK")
}

@(test)
test_example_02_mdm_xitdb_pipeline :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/02_mdm_xitdb_pipeline", "[ex02] OK")
}

@(test)
test_example_03_jtms_steward_overrides :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/03_jtms_steward_overrides", "[ex03] OK")
}

@(test)
test_example_04_cyclic_hierarchies :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/04_cyclic_hierarchies", "[ex04] OK")
}

@(test)
test_example_05_accumulators_and_effects :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/05_accumulators_and_effects", "[ex05] OK")
}

@(test)
test_example_06_internal_odin_dsl_and_aot :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/06_internal_odin_dsl_and_aot", "[ex06] OK")
}

@(test)
test_example_07_telemetry_and_diff_replay :: proc(t: ^testing.T) {
	_verify_example_dir(t, "examples/07_telemetry_and_diff_replay", "[ex07] OK")
}
