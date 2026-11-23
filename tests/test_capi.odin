package forseti_tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_capi_smoke :: proc(t: ^testing.T) {
	tmp_dir, t_err := os.make_directory_temp("", "forseti_capi_*", context.allocator)
	testing.expect_value(t, t_err, nil)
	if t_err != nil {
		return
	}
	defer {
		_ = os.remove_all(tmp_dir)
		delete(tmp_dir)
	}

	when ODIN_OS == .Windows {
		lib_name := "forseti.dll"
		exe_name := "capi_smoke.exe"
	} else when ODIN_OS == .Darwin {
		lib_name := "libforseti.dylib"
		exe_name := "capi_smoke"
	} else {
		lib_name := "libforseti.so"
		exe_name := "capi_smoke"
	}

	lib_path, _ := filepath.join({tmp_dir, lib_name}, context.temp_allocator)
	exe_path, _ := filepath.join({tmp_dir, exe_name}, context.temp_allocator)

	build_lib_cmd := make([dynamic]string, 0, 12, context.temp_allocator)
	append(
		&build_lib_cmd,
		"odin",
		"build",
		"capi",
		"-build-mode:shared",
		"-collection:xitdb=../xitdb/xitdb",
		"-vet",
		"-vet-tabs",
		"-strict-style",
		"-warnings-as-errors",
	)
	when ODIN_OS == .Windows {
		append(&build_lib_cmd, "-linker:lld")
	}
	append(&build_lib_cmd, fmt.tprintf("-out:%s", lib_path))
	bs, bout, berr, bex := os.process_exec(os.Process_Desc{command = build_lib_cmd[:]}, context.temp_allocator)
	testing.expectf(
		t,
		bex == nil && bs.exit_code == 0,
		"odin build capi failed (%d): %s %s",
		bs.exit_code,
		string(bout),
		string(berr),
	)
	if bex != nil || bs.exit_code != 0 {
		return
	}

	when ODIN_OS == .Windows {
		implib_path, _ := filepath.join({tmp_dir, "forseti.lib"}, context.temp_allocator)
		cc_cmd := []string{
			"cl",
			"/nologo",
			"/W4",
			"/WX",
			"/Iinclude",
			"tests/capi_smoke.c",
			implib_path,
			fmt.tprintf("/Fe:%s", exe_path),
		}
	} else {
		cc := "cc"
		cc_cmd := make([dynamic]string, 0, 12, context.temp_allocator)
		append(&cc_cmd, cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-Iinclude")
		when ODIN_OS == .Linux {
			append(&cc_cmd, "-fsanitize=address,leak", "-fno-omit-frame-pointer")
		}
		append(&cc_cmd, "tests/capi_smoke.c", lib_path, fmt.tprintf("-Wl,-rpath,%s", tmp_dir), "-o", exe_path)
	}

	cs, cout, cerr, cex := os.process_exec(os.Process_Desc{command = cc_cmd[:]}, context.temp_allocator)
	testing.expectf(
		t,
		cex == nil && cs.exit_code == 0,
		"C compiler failed (%d): %s %s",
		cs.exit_code,
		string(cout),
		string(cerr),
	)
	if cex != nil || cs.exit_code != 0 {
		return
	}

	rs, rout, rerr, rex := os.process_exec(os.Process_Desc{command = {exe_path}}, context.temp_allocator)
	testing.expectf(
		t,
		rex == nil && rs.exit_code == 0,
		"capi_smoke failed (%d): %s %s",
		rs.exit_code,
		string(rout),
		string(rerr),
	)
	testing.expect(t, strings.contains(string(rout), "CAPI_SMOKE_OK"))
}
