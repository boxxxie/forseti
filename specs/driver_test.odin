package forseti_specs

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import xitdb "xitdb:."
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

driver_strict_check_single_file :: proc(path: string) -> (ok: bool, err_msg: string) {
	cmd := []string{
		"odin",
		"check",
		path,
		"-file",
		"-no-entry-point",
		"-vet",
		"-vet-tabs",
		"-strict-style",
		"-disallow-do",
		"-warnings-as-errors",
	}
	state, stdout, stderr, exec_err := os.process_exec(os.Process_Desc{command = cmd}, context.temp_allocator)
	if exec_err != nil {
		return false, fmt.tprintf("exec failed: %v", exec_err)
	}
	if state.exit_code != 0 {
		return false, fmt.tprintf("%s %s", string(stdout), string(stderr))
	}
	return true, ""
}

driver_verify_aot_codegen :: proc(
	t: ^testing.T,
	ir: ^forseti.Rulebase_IR,
	pkg_name: string,
	test_src: string,
	arena: ^vmem.Arena,
) -> (check_ok: bool, test_ok: bool, err_msg: string) {
	gen_src, g_err := forseti.codegen_odin_module(ir, pkg_name, context.temp_allocator)
	if g_err != nil {
		return false, false, fmt.tprintf("codegen error: %v", g_err)
	}

	dir, d_err := os.make_directory_temp("", "forseti_aot_*", context.allocator)
	if d_err != nil {
		return false, false, fmt.tprintf("make_directory_temp error: %v", d_err)
	}
	cleanup_ptr := new(string)
	cleanup_ptr^ = dir
	testing.cleanup(t, driver_cleanup_cli_dir, rawptr(cleanup_ptr))

	gen_path, _ := filepath.join({dir, "tables_gen.odin"}, context.temp_allocator)
	test_path, _ := filepath.join({dir, "tables_gen_test.odin"}, context.temp_allocator)
	if os.write_entire_file(gen_path, gen_src) != nil || os.write_entire_file(test_path, test_src) != nil {
		return false, false, "failed writing generated files"
	}

	check_cmd := []string{
		"odin",
		"check",
		dir,
		"-no-entry-point",
		"-vet",
		"-vet-tabs",
		"-strict-style",
		"-disallow-do",
		"-warnings-as-errors",
	}
	c_state, c_out, c_err, c_exec := os.process_exec(os.Process_Desc{command = check_cmd}, context.temp_allocator)
	if c_exec != nil || c_state.exit_code != 0 {
		msg, _ := strings.clone(fmt.tprintf("odin check: %s %s\n--- SOURCE ---\n%s", string(c_out), string(c_err), gen_src), vmem.arena_allocator(arena))
		return false, false, msg
	}
	check_ok = true

	test_cmd := []string{
		"odin",
		"test",
		dir,
		"-vet",
		"-vet-tabs",
		"-strict-style",
		"-disallow-do",
		"-warnings-as-errors",
		"-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true",
		"-define:ODIN_TEST_FANCY=false",
	}
	t_state, t_out, t_err, t_exec := os.process_exec(os.Process_Desc{command = test_cmd}, context.temp_allocator)
	if t_exec != nil || t_state.exit_code != 0 {
		msg, _ := strings.clone(fmt.tprintf("odin test: %s %s", string(t_out), string(t_err)), vmem.arena_allocator(arena))
		return check_ok, false, msg
	}
	return true, true, ""
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

	bin_name := "forseti.exe" when ODIN_OS == .Windows else "forseti"
	bin_path, join_err := filepath.join({dir, bin_name}, arena_alloc)
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

Lsp_Diag_Item :: struct {
	code:       string,
	severity:   i64,
	start_line: u32,
	start_char: u32,
	end_line:   u32,
	end_char:   u32,
	message:    string,
}

Lsp_Client_Handle :: struct {
	proc_handle: os.Process,
	running:     bool,
	stdin_w:     ^os.File,
	stdout_r:    ^os.File,
	next_id:     i64,
	diags_by_uri: map[string][dynamic]Lsp_Diag_Item,
	last_exit:   int,
}

driver_lsp_read_frame :: proc(f: ^os.File) -> (payload: string, ok: bool) {
	hdr_buf: [dynamic]byte
	hdr_buf = make([dynamic]byte, 0, 128, context.temp_allocator)
	b: [1]byte
	content_len := -1
	for {
		n, err := os.read(f, b[:])
		if err != nil || n == 0 {
			return "", false
		}
		append(&hdr_buf, b[0])
		cur := string(hdr_buf[:])
		if strings.has_suffix(cur, "\r\n\r\n") || strings.has_suffix(cur, "\n\n") {
			for line in strings.split_lines(cur, context.temp_allocator) {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 {
					continue
				}
				lower := strings.to_lower(trimmed, context.temp_allocator)
				if strings.has_prefix(lower, "content-length:") {
					val_str := strings.trim_space(trimmed[len("content-length:"):])
					if v, pok := strconv.parse_int(val_str); pok && v >= 0 {
						content_len = v
					}
				}
			}
			break
		}
	}
	if content_len < 0 {
		return "", false
	}
	body := make([]byte, content_len, context.allocator)
	got := 0
	for got < content_len {
		n, err := os.read(f, body[got:])
		if err != nil || n == 0 {
			delete(body)
			return "", false
		}
		got += n
	}
	return string(body), true
}

driver_lsp_write_frame :: proc(f: ^os.File, payload: string) -> bool {
	hdr := fmt.tprintf("Content-Length: %d\r\n\r\n", len(payload))
	full := strings.concatenate({hdr, payload}, context.temp_allocator)
	raw := transmute([]byte)full
	written := 0
	for written < len(raw) {
		n, err := os.write(f, raw[written:])
		if err != nil || n <= 0 {
			return false
		}
		written += n
	}
	return true
}

driver_lsp_destroy_diags_for_uri :: proc(h: ^Lsp_Client_Handle, uri: string) {
	if list, has := h.diags_by_uri[uri]; has {
		stored_key := ""
		for k in h.diags_by_uri {
			if k == uri {
				stored_key = k
				break
			}
		}
		for item in list {
			delete(item.code)
			delete(item.message)
		}
		delete(list)
		delete_key(&h.diags_by_uri, uri)
		delete(stored_key)
	}
}

driver_lsp_store_publish_diags :: proc(h: ^Lsp_Client_Handle, params_obj: json.Object) {
	uri_val, has_uri := params_obj["uri"].(json.String)
	if !has_uri {
		return
	}
	uri := string(uri_val)
	driver_lsp_destroy_diags_for_uri(h, uri)
	items := make([dynamic]Lsp_Diag_Item, 0, 4)
	if arr, has_arr := params_obj["diagnostics"].(json.Array); has_arr {
		for elem in arr {
			dobj, is_obj := elem.(json.Object)
			if !is_obj {
				continue
			}
			item: Lsp_Diag_Item
			if c, ok := dobj["code"].(json.String); ok {
				item.code = strings.clone(string(c))
			}
			if sv, ok := dobj["severity"].(json.Integer); ok {
				item.severity = sv
			}
			if msg, ok := dobj["message"].(json.String); ok {
				item.message = strings.clone(string(msg))
			}
			if rng, ok := dobj["range"].(json.Object); ok {
				if st, ok2 := rng["start"].(json.Object); ok2 {
					if ln, ok3 := st["line"].(json.Integer); ok3 { item.start_line = u32(ln) }
					if ch, ok3 := st["character"].(json.Integer); ok3 { item.start_char = u32(ch) }
				}
				if en, ok2 := rng["end"].(json.Object); ok2 {
					if ln, ok3 := en["line"].(json.Integer); ok3 { item.end_line = u32(ln) }
					if ch, ok3 := en["character"].(json.Integer); ok3 { item.end_char = u32(ch) }
				}
			}
			append(&items, item)
		}
	}
	h.diags_by_uri[strings.clone(uri)] = items
}

driver_lsp_read_until_id :: proc(h: ^Lsp_Client_Handle, target_id: i64) -> (raw_msg: string, parsed: json.Value, ok: bool) {
	for _ in 0 ..< 64 {
		frame, f_ok := driver_lsp_read_frame(h.stdout_r)
		if !f_ok {
			return "", nil, false
		}
		val, p_err := json.parse_string(frame, parse_integers = true)
		if p_err != nil {
			delete(frame)
			return "", nil, false
		}
		obj, is_obj := val.(json.Object)
		if !is_obj {
			json.destroy_value(val)
			delete(frame)
			continue
		}
		if id_val, has_id := obj["id"].(json.Integer); has_id && id_val == target_id {
			return frame, val, true
		}
		if m_val, has_m := obj["method"].(json.String); has_m && string(m_val) == "textDocument/publishDiagnostics" {
			if p_obj, has_p := obj["params"].(json.Object); has_p {
				driver_lsp_store_publish_diags(h, p_obj)
			}
		}
		json.destroy_value(val)
		delete(frame)
	}
	return "", nil, false
}

driver_lsp_read_publish_diags :: proc(h: ^Lsp_Client_Handle, target_uri: string) -> bool {
	for _ in 0 ..< 32 {
		frame, f_ok := driver_lsp_read_frame(h.stdout_r)
		if !f_ok {
			return false
		}
		val, p_err := json.parse_string(frame, parse_integers = true)
		delete(frame)
		if p_err != nil {
			return false
		}
		defer json.destroy_value(val)
		obj, is_obj := val.(json.Object)
		if !is_obj {
			continue
		}
		if m_val, has_m := obj["method"].(json.String); has_m && string(m_val) == "textDocument/publishDiagnostics" {
			if p_obj, has_p := obj["params"].(json.Object); has_p {
				driver_lsp_store_publish_diags(h, p_obj)
				if u, has_u := p_obj["uri"].(json.String); has_u && string(u) == target_uri {
					return true
				}
			}
		}
	}
	return false
}

driver_lsp_start :: proc(working_dir, bin_path: string) -> (h: ^Lsp_Client_Handle, ok: bool) {
	in_r, in_w, err1 := os.pipe()
	if err1 != nil {
		return nil, false
	}
	out_r, out_w, err2 := os.pipe()
	if err2 != nil {
		_ = os.close(in_r)
		_ = os.close(in_w)
		return nil, false
	}
	p, p_err := os.process_start(os.Process_Desc{
		working_dir = working_dir,
		command     = {bin_path, "lsp"},
		stdin       = in_r,
		stdout      = out_w,
		stderr      = nil,
	})
	_ = os.close(in_r)
	_ = os.close(out_w)
	if p_err != nil {
		_ = os.close(in_w)
		_ = os.close(out_r)
		return nil, false
	}
	h = new(Lsp_Client_Handle)
	h.proc_handle = p
	h.running = true
	h.stdin_w = in_w
	h.stdout_r = out_r
	h.next_id = 1
	h.diags_by_uri = make(map[string][dynamic]Lsp_Diag_Item, 4)
	return h, true
}

driver_lsp_destroy :: proc(h: ^Lsp_Client_Handle) {
	if h == nil {
		return
	}
	if h.stdin_w != nil {
		_ = os.close(h.stdin_w)
		h.stdin_w = nil
	}
	if h.stdout_r != nil {
		_ = os.close(h.stdout_r)
		h.stdout_r = nil
	}
	if h.running {
		_ = os.process_kill(h.proc_handle)
		_, _ = os.process_wait(h.proc_handle)
		h.running = false
	}
	keys := make([dynamic]string, 0, len(h.diags_by_uri), context.temp_allocator)
	for k in h.diags_by_uri {
		append(&keys, k)
	}
	for k in keys {
		driver_lsp_destroy_diags_for_uri(h, k)
	}
	delete(h.diags_by_uri)
	free(h)
}

driver_create_standalone_store :: proc(cfg: forseti.Xitdb_Config, telemetry: ^forseti.Telemetry_Sink) -> (sh: ^Store_Handle, err: forseti.Store_Error) {
	sh = new(Store_Handle)
	err = forseti.store_bridge_init_standalone(&sh.bridge, cfg, telemetry)
	if err != nil {
		free(sh)
		return nil, err
	}
	if i_err := forseti.interner_init(&sh.interner); i_err != nil {
		forseti.store_bridge_destroy(&sh.bridge)
		free(sh)
		return nil, i_err
	}
	if s_err := forseti.delta_syncer_init(&sh.syncer, telemetry); s_err != nil {
		forseti.interner_destroy(&sh.interner)
		forseti.store_bridge_destroy(&sh.bridge)
		free(sh)
		return nil, s_err
	}
	sh.sync_inited = true
	return sh, nil
}

driver_open_file_store :: proc(
	t: ^testing.T,
	rel_filename: string,
	cfg: forseti.Xitdb_Config,
	telemetry: ^forseti.Telemetry_Sink,
) -> (sh: ^Store_Handle, err: forseti.Store_Error) {
	dir, dir_err := os.make_directory_temp("", "forseti_xitdb_*", context.allocator)
	if dir_err != nil {
		return nil, dir_err
	}
	cleanup_ptr := new(string)
	cleanup_ptr^ = dir
	testing.cleanup(t, driver_cleanup_cli_dir, rawptr(cleanup_ptr))

	sh, err = driver_reopen_file_store_in_dir(dir, rel_filename, cfg, telemetry)
	return sh, err
}

driver_reopen_file_store_in_dir :: proc(
	dir: string,
	rel_filename: string,
	cfg: forseti.Xitdb_Config,
	telemetry: ^forseti.Telemetry_Sink,
) -> (sh: ^Store_Handle, err: forseti.Store_Error) {
	full, j_err := filepath.join({dir, rel_filename}, context.temp_allocator)
	if j_err != nil {
		return nil, j_err
	}
	sh = new(Store_Handle)
	sh.attached_dir = dir
	err = forseti.store_bridge_open_file(&sh.bridge, full, cfg, telemetry)
	if err != nil {
		free(sh)
		return nil, err
	}
	if i_err := forseti.interner_init(&sh.interner); i_err != nil {
		forseti.store_bridge_destroy(&sh.bridge)
		free(sh)
		return nil, i_err
	}
	if s_err := forseti.delta_syncer_init(&sh.syncer, telemetry); s_err != nil {
		forseti.interner_destroy(&sh.interner)
		forseti.store_bridge_destroy(&sh.bridge)
		free(sh)
		return nil, s_err
	}
	sh.sync_inited = true
	return sh, nil
}

driver_destroy_store_handle :: proc(sh: ^Store_Handle) {
	if sh == nil {
		return
	}
	if sh.sync_inited {
		forseti.delta_syncer_destroy(&sh.syncer)
	}
	forseti.store_bridge_destroy(&sh.bridge)
	forseti.interner_destroy(&sh.interner)
	free(sh)
}

@(private = "file")
_Mdm_Orgs_Tx :: struct {
	orgs: []Mdm_Org_Input,
}

@(private = "file")
_mdm_orgs_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	payload := (^_Mdm_Orgs_Tx)(user_data)
	raw_map, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	by_domain, sm_err := forseti.store_write_path_ensure_sorted_map(moment_wc, ".orgs.by_domain")
	if sm_err != nil {
		return .Write_Failed
	}
	eav_map, eav_err := forseti.store_write_path_ensure_sorted_map(moment_wc, ".facts.eav")
	if eav_err != nil {
		return .Write_Failed
	}

	for org in payload.orgs {
		rec_wc := xitdb.hash_map_put_cursor(&raw_map, org.id) or_return
		rec_map, rm_err := xitdb.write_hash_map_init(rec_wc)
		if rm_err != nil {
			return rm_err
		}
		xitdb.hash_map_put(&rec_map, "name", org.name) or_return
		xitdb.hash_map_put(&rec_map, "domain", org.domain) or_return
		xitdb.hash_map_put(&rec_map, "employees", org.employees) or_return
		if b_err := forseti.write_bool_to_hash_map(&rec_map, "active", org.active); b_err != nil {
			return .Write_Failed
		}

		addr_wc := xitdb.hash_map_put_cursor(&rec_map, "address") or_return
		addr_map := xitdb.write_hash_map_init(addr_wc) or_return
		xitdb.hash_map_put(&addr_map, "country", org.country) or_return

		if len(org.locked_fields) > 0 {
			lf_wc := xitdb.hash_map_put_cursor(&rec_map, "locked_fields") or_return
			lf_set := xitdb.write_hash_set_init(lf_wc) or_return
			for f in org.locked_fields {
				xitdb.hash_set_put(&lf_set, f) or_return
			}
		}

		dom_buf: [256]u8 = ---
		dom_key := fmt.bprintf(dom_buf[:], "%s:%s", org.domain, org.id)
		xitdb.sorted_map_put(&by_domain, dom_key, org.id) or_return

		if se := forseti.store_eav_put_string(&eav_map, org.id, "name", org.name); se != nil {
			return .Write_Failed
		}
		if se2 := forseti.store_eav_put_string(&eav_map, org.id, "country", org.country); se2 != nil {
			return .Write_Failed
		}
	}
	return nil
}

driver_commit_mdm_orgs :: proc(bridge: ^forseti.Store_Bridge, orgs: []Mdm_Org_Input) -> forseti.Store_Error {
	payload := _Mdm_Orgs_Tx{orgs = orgs}
	_, err := forseti.store_bridge_commit_moment(bridge, _mdm_orgs_tx_cb, &payload)
	return err
}

@(private = "file")
_Bulk_Seed_Tx :: struct {
	path:  string,
	count: int,
}

@(private = "file")
_bulk_seed_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	p := (^_Bulk_Seed_Tx)(user_data)
	m, err := forseti.store_write_path_ensure_map(moment_wc, p.path)
	if err != nil {
		return .Write_Failed
	}
	key_buf: [32]u8 = ---
	for i := 0; i < p.count; i += 1 {
		key := fmt.bprintf(key_buf[:], "org:%06d", i)
		xitdb.hash_map_put(&m, key, i64(i)) or_return
	}
	return nil
}

driver_bulk_seed_records :: proc(bridge: ^forseti.Store_Bridge, path: string, count: int) -> forseti.Store_Error {
	payload := _Bulk_Seed_Tx{path = path, count = count}
	_, err := forseti.store_bridge_commit_moment(bridge, _bulk_seed_tx_cb, &payload)
	return err
}

@(private = "file")
_Mutate_Batch_Tx :: struct {
	path:           string,
	added:          []string,
	updated:        []string,
	removed:        []string,
	new_val_offset: i64,
}

@(private = "file")
_mutate_batch_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	p := (^_Mutate_Batch_Tx)(user_data)
	m, err := forseti.store_write_path_ensure_map(moment_wc, p.path)
	if err != nil {
		return .Write_Failed
	}
	for k, i in p.removed {
		_ = i
		_, _ = xitdb.hash_map_remove(&m, k)
	}
	for k, i in p.updated {
		xitdb.hash_map_put(&m, k, p.new_val_offset + i64(i)) or_return
	}
	for k, i in p.added {
		xitdb.hash_map_put(&m, k, p.new_val_offset + 500 + i64(i)) or_return
	}
	return nil
}

driver_mutate_record_batch :: proc(
	bridge: ^forseti.Store_Bridge,
	path: string,
	added: []string,
	updated: []string,
	removed: []string,
	new_val_offset: i64,
) -> forseti.Store_Error {
	payload := _Mutate_Batch_Tx{
		path           = path,
		added          = added,
		updated        = updated,
		removed        = removed,
		new_val_offset = new_val_offset,
	}
	_, err := forseti.store_bridge_commit_moment(bridge, _mutate_batch_tx_cb, &payload)
	return err
}

driver_attempt_invalid_file_open :: proc(
	t: ^testing.T,
	rel_filename: string,
	setup_cfg: forseti.Xitdb_Config,
	reopen_cfg: forseti.Xitdb_Config,
	reopen_existing: bool,
) -> forseti.Store_Error {
	context.logger = log.nil_logger()

	dir, dir_err := os.make_directory_temp("", "forseti_neg_file_*", context.allocator)
	if dir_err != nil {
		return dir_err
	}
	cleanup_ptr := new(string)
	cleanup_ptr^ = dir
	testing.cleanup(t, driver_cleanup_cli_dir, rawptr(cleanup_ptr))

	full, j_err := filepath.join({dir, rel_filename}, context.temp_allocator)
	if j_err != nil {
		return j_err
	}
	if reopen_existing {
		sb := new(forseti.Store_Bridge)
		defer {
			forseti.store_bridge_destroy(sb)
			free(sb)
		}
		if s_err := forseti.store_bridge_open_file(sb, full, setup_cfg, nil); s_err != nil {
			return s_err
		}
		forseti.store_bridge_destroy(sb)
		sb^ = {}
		return forseti.store_bridge_open_file(sb, full, reopen_cfg, nil)
	}
	sb := new(forseti.Store_Bridge)
	defer {
		forseti.store_bridge_destroy(sb)
		free(sb)
	}
	return forseti.store_bridge_open_file(sb, full, setup_cfg, nil)
}

driver_attempt_invalid_memory_open :: proc(
	init_cfg: forseti.Xitdb_Config,
	reopen_cfg: forseti.Xitdb_Config,
	reopen_existing: bool,
) -> forseti.Store_Error {
	context.logger = log.nil_logger()
	if !reopen_existing {
		sb := new(forseti.Store_Bridge)
		defer {
			forseti.store_bridge_destroy(sb)
			free(sb)
		}
		return forseti.store_bridge_init_standalone(sb, init_cfg, nil)
	}
	mem_core := xitdb.core_memory_init()
	defer _ = xitdb.core_destroy(&mem_core)

	init_hasher := init_cfg.custom_hasher if init_cfg.custom_hasher.hash_proc != nil else xitdb.sha1_hasher()
	_, err1 := xitdb.database_init(&mem_core, init_hasher)
	if err1 != nil {
		return forseti.xitdb_to_store_err(err1)
	}

	reopen_hasher := reopen_cfg.custom_hasher if reopen_cfg.custom_hasher.hash_proc != nil else xitdb.sha1_hasher()
	_, err2 := xitdb.database_init(&mem_core, reopen_hasher)
	return forseti.xitdb_to_store_err(err2)
}

driver_read_store_lazy_field :: proc(
	bridge: ^forseti.Store_Bridge,
	moment_idx: i64,
	collection_path: string,
	record_key: string,
	fields: []string,
	interner: ^forseti.String_Interner,
) -> (val: forseti.Value, found: bool, err: forseti.Store_Error) {
	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(bridge, moment_idx)
	if m_err != nil || !m_ok {
		return {}, false, m_err
	}
	col_cur, c_ok, c_err := forseti.store_resolve_path(m_cur, collection_path)
	if c_err != nil || !c_ok {
		return {}, false, c_err
	}
	rec_cur, r_ok, r_err := forseti.store_lookup_record(col_cur, record_key)
	if r_err != nil || !r_ok {
		return {}, false, r_err
	}
	if len(fields) == 0 {
		return forseti.cursor_read_value(rec_cur, interner)
	}
	return forseti.cursor_read_field_path(rec_cur, fields, interner)
}

driver_expect_value_matches_arg :: proc(
	t: ^testing.T,
	val: forseti.Value,
	expected: Table_Test_Arg,
	interner: ^forseti.String_Interner,
	loc: runtime.Source_Code_Location,
) {
	switch e in expected {
	case bool:
		b, ok := val.(bool)
		testing.expect(t, ok, loc = loc)
		if ok {
			testing.expect_value(t, b, e, loc = loc)
		}
	case i32:
		v, ok := val.(i32)
		testing.expect(t, ok, loc = loc)
		if ok {
			testing.expect_value(t, v, e, loc = loc)
		}
	case i64:
		v, ok := val.(i64)
		testing.expect(t, ok, loc = loc)
		if ok {
			testing.expect_value(t, v, e, loc = loc)
		}
	case f64:
		v, ok := val.(f64)
		testing.expect(t, ok, loc = loc)
		if ok {
			testing.expect_value(t, v, e, loc = loc)
		}
	case string:
		sid, ok := val.(forseti.String_Id)
		testing.expect(t, ok, loc = loc)
		if ok {
			testing.expect_value(t, forseti.interner_get(interner, sid), e, loc = loc)
		}
	}
}

@(private = "file")
_Sorted_Collect_Ctx :: struct {
	keys: ^[dynamic]string,
	alloc: mem.Allocator,
}

@(private = "file")
_sorted_collect_cb :: proc(key: []u8, _val: xitdb.Read_Cursor, user_data: rawptr) -> bool {
	c := (^_Sorted_Collect_Ctx)(user_data)
	append(c.keys, strings.clone(string(key), c.alloc))
	return true
}

driver_read_sorted_prefix :: proc(
	bridge: ^forseti.Store_Bridge,
	collection_path: string,
	prefix: string,
	alloc: mem.Allocator,
) -> (keys: []string, err: forseti.Store_Error) {
	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(bridge, -1)
	if m_err != nil || !m_ok {
		return nil, m_err
	}
	col_cur, c_ok, c_err := forseti.store_resolve_path(m_cur, collection_path)
	if c_err != nil || !c_ok {
		return nil, c_err
	}
	out := make([dynamic]string, 0, 8, alloc)
	sctx := _Sorted_Collect_Ctx{keys = &out, alloc = alloc}
	s_err := forseti.store_sorted_prefix_scan(col_cur, transmute([]u8)prefix, _sorted_collect_cb, &sctx)
	return out[:], s_err
}

@(private = "file")
_Eav_Collect_Ctx :: struct {
	attrs:    ^[dynamic]string,
	vals:     ^[dynamic]string,
	interner: ^forseti.String_Interner,
	alloc:    mem.Allocator,
}

@(private = "file")
_eav_collect_cb :: proc(attr: string, val_cur: xitdb.Read_Cursor, user_data: rawptr) -> bool {
	c := (^_Eav_Collect_Ctx)(user_data)
	append(c.attrs, strings.clone(attr, c.alloc))
	v, ok, err := forseti.cursor_read_value(val_cur, c.interner)
	if err != nil || !ok {
		append(c.vals, "")
		return true
	}
	if sid, is_s := v.(forseti.String_Id); is_s {
		append(c.vals, forseti.interner_get(c.interner, sid))
	} else {
		append(c.vals, fmt.tprintf("%v", v))
	}
	return true
}

driver_scan_eav_entity :: proc(
	bridge: ^forseti.Store_Bridge,
	collection_path: string,
	entity: string,
	interner: ^forseti.String_Interner,
	alloc: mem.Allocator,
) -> (attrs: []string, vals: []string, err: forseti.Store_Error) {
	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(bridge, -1)
	if m_err != nil || !m_ok {
		return nil, nil, m_err
	}
	col_cur, c_ok, c_err := forseti.store_resolve_path(m_cur, collection_path)
	if c_err != nil || !c_ok {
		return nil, nil, c_err
	}
	a_out := make([dynamic]string, 0, 8, alloc)
	v_out := make([dynamic]string, 0, 8, alloc)
	ectx := _Eav_Collect_Ctx{attrs = &a_out, vals = &v_out, interner = interner, alloc = alloc}
	s_err := forseti.store_eav_scan_entity(col_cur, entity, _eav_collect_cb, &ectx)
	return a_out[:], v_out[:], s_err
}

driver_compile_rulebase :: proc(
	ir: ^forseti.Rulebase_IR,
	tel: ^forseti.Telemetry_Sink,
) -> (rb: ^forseti.Rulebase, err: forseti.Compile_Error) {
	rb = new(forseti.Rulebase)
	res, c_err := forseti.rulebase_compile(ir, tel)
	rb^ = res
	return rb, c_err
}

driver_args_to_values :: proc(sess: ^forseti.Session, args: []Table_Test_Arg) -> []forseti.Value {
	vals := make([]forseti.Value, len(args), context.temp_allocator)
	for a, i in args {
		switch x in a {
		case bool:
			vals[i] = x
		case i32:
			vals[i] = x
		case i64:
			vals[i] = x
		case f64:
			vals[i] = x
		case string:
			sid, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, x)
			vals[i] = sid
		}
	}
	return vals
}

driver_session_assert :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	key: string,
	args: []Table_Test_Arg,
) -> forseti.Session_Error {
	vals := driver_args_to_values(sess, args)
	defer free_all(context.temp_allocator)
	_, err := forseti.session_insert_fact(sess, binding_name, key, vals)
	return err
}

driver_session_modify_by_key :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	key: string,
	args: []Table_Test_Arg,
) -> forseti.Session_Error {
	vals := driver_args_to_values(sess, args)
	defer free_all(context.temp_allocator)
	return forseti.session_modify_fact_by_key(sess, binding_name, key, vals)
}

driver_session_retract_by_key :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	key: string,
) -> forseti.Session_Error {
	return forseti.session_retract_fact_by_key(sess, binding_name, key)
}

driver_run_query :: proc(
	sess: ^forseti.Session,
	query_name: string,
	arg_names: []string,
	arg_vals: []Table_Test_Arg,
) -> (res: forseti.Query_Result, err: forseti.Session_Error) {
	vals := driver_args_to_values(sess, arg_vals)
	qargs := make([]forseti.Query_Arg, len(arg_names), context.temp_allocator)
	for i := 0; i < len(arg_names); i += 1 {
		qargs[i] = forseti.Query_Arg{name = arg_names[i], value = vals[i]}
	}
	err = forseti.session_query(sess, query_name, qargs, &res)
	free_all(context.temp_allocator)
	return res, err
}

driver_session_find_fact_matching :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
) -> bool {
	bid, has_b := forseti.session_find_binding(sess, binding_name)
	if !has_b {
		return false
	}
	exp_vals := driver_args_to_values(sess, expected_fields)
	defer free_all(context.temp_allocator)

	for &f in sess.facts {
		if !f.alive || f.binding_idx != bid || len(f.fields) < len(exp_vals) {
			continue
		}
		match := true
		for ev, fi in exp_vals {
			if f.fields[fi] != ev {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

driver_query_has_value :: proc(qr: ^forseti.Query_Result, var_name: string, expected: string) -> bool {
	for &row in qr.rows {
		for k, vi in row.var_names {
			if k == var_name {
				if row.var_strings[vi] == expected {
					return true
				}
			}
		}
	}
	return false
}

driver_check_store_collection_entry :: proc(
	bridge: ^forseti.Store_Bridge,
	collection_path: string,
	field_name: string,
	expected_str: string,
	interner: ^forseti.String_Interner,
) -> (count: int, matched: bool, err: forseti.Store_Error) {
	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(bridge, -1)
	if m_err != nil || !m_ok {
		return 0, false, m_err
	}
	col_cur, c_ok, c_err := forseti.store_resolve_path(m_cur, collection_path)
	if c_err != nil || !c_ok {
		return 0, false, c_err
	}
	it, it_err := xitdb.cursor_iterator(col_cur)
	if it_err != nil {
		return 0, false, forseti.xitdb_to_store_err(it_err)
	}
	path := [1]string{field_name}
	for {
		item, n_err := xitdb.cursor_iterator_next(&it)
		if n_err != nil {
			return count, matched, forseti.xitdb_to_store_err(n_err)
		}
		entry, ok := item.?
		if !ok {
			break
		}
		count += 1
		_, vc, kv_err := xitdb.cursor_read_kv_pair_slots(entry)
		if kv_err != nil {
			continue
		}
		val, found, _ := forseti.cursor_read_field_path(vc, path[:], interner, .String)
		if found {
			if sid, is_s := val.(forseti.String_Id); is_s && forseti.interner_get(interner, sid) == expected_str {
				matched = true
			}
		}
	}
	return count, matched, nil
}

driver_session_count_binding_facts :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	expected_fields: []Table_Test_Arg = nil,
) -> (total: int, matching: int) {
	bid, has_b := forseti.session_find_binding(sess, binding_name)
	if !has_b {
		return 0, 0
	}
	exp_vals := driver_args_to_values(sess, expected_fields) if len(expected_fields) > 0 else nil
	defer free_all(context.temp_allocator)

	for &f in sess.facts {
		if !f.alive || f.binding_idx != bid {
			continue
		}
		total += 1
		if len(exp_vals) > 0 && len(f.fields) >= len(exp_vals) {
			ok := true
			for ev, fi in exp_vals {
				if f.fields[fi] != ev {
					ok = false
					break
				}
			}
			if ok {
				matching += 1
			}
		}
	}
	return total, matching
}

driver_session_find_matching_fact_id :: proc(
	sess: ^forseti.Session,
	binding_name: string,
	expected_fields: []Table_Test_Arg,
) -> (fid: forseti.Fact_Id, ok: bool) {
	bid, has_b := forseti.session_find_binding(sess, binding_name)
	if !has_b {
		return forseti.INVALID_FACT, false
	}
	exp_vals := driver_args_to_values(sess, expected_fields)
	defer free_all(context.temp_allocator)

	for &f in sess.facts {
		if !f.alive || f.binding_idx != bid || len(f.fields) < len(exp_vals) {
			continue
		}
		match := true
		for ev, fi in exp_vals {
			if f.fields[fi] != ev {
				match = false
				break
			}
		}
		if match {
			return f.id, true
		}
	}
	return forseti.INVALID_FACT, false
}

driver_check_audit_moment_integrity :: proc(
	bridge: ^forseti.Store_Bridge,
	expected_module: string,
	min_decisions: int,
	rule_name: string,
	entity_key_hint: string,
	interner: ^forseti.String_Interner,
) -> (ok: bool, msg: string) {
	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(bridge, -1)
	if m_err != nil || !m_ok {
		return false, fmt.tprintf("missing moment: %v", m_err)
	}

	dec_cur, dec_ok, dec_err := forseti.store_resolve_path(m_cur, ".decisions")
	if dec_err != nil || !dec_ok {
		return false, "missing .decisions collection"
	}
	dec_sp, _ := xitdb.cursor_resolved(dec_cur)
	if dec_sp.slot.tag != .Hash_Map && dec_sp.slot.tag != .Counted_Hash_Map {
		return false, ".decisions is not a map"
	}
	it, _ := xitdb.cursor_iterator(dec_cur)
	dec_cnt := 0
	for {
		item, _ := xitdb.cursor_iterator_next(&it)
		if _, has := item.?; !has {
			break
		}
		dec_cnt += 1
	}
	if dec_cnt < min_decisions {
		return false, fmt.tprintf("expected >= %d decisions, got %d", min_decisions, dec_cnt)
	}

	by_rule_cur, br_ok, _ := forseti.store_resolve_path(m_cur, ".idx.decisions_by_rule")
	if !br_ok {
		return false, "missing .idx.decisions_by_rule"
	}
	rset_cur, r_found, _ := forseti.store_lookup_record(by_rule_cur, rule_name)
	if !r_found {
		return false, fmt.tprintf("missing idx.decisions_by_rule[%q]", rule_name)
	}
	rit, _ := xitdb.cursor_iterator(rset_cur)
	rcnt := 0
	for {
		item, _ := xitdb.cursor_iterator_next(&rit)
		if _, has := item.?; !has {
			break
		}
		rcnt += 1
	}
	if rcnt == 0 {
		return false, fmt.tprintf("empty decision index for rule %q", rule_name)
	}

	if len(entity_key_hint) > 0 {
		by_ent_cur, be_ok, _ := forseti.store_resolve_path(m_cur, ".idx.decisions_by_entity")
		if !be_ok {
			return false, "missing .idx.decisions_by_entity"
		}
		eset_cur, e_found, _ := forseti.store_lookup_record(by_ent_cur, entity_key_hint)
		if !e_found {
			return false, fmt.tprintf("missing idx.decisions_by_entity[%q]", entity_key_hint)
		}
		eit, _ := xitdb.cursor_iterator(eset_cur)
		ecnt := 0
		for {
			item, _ := xitdb.cursor_iterator_next(&eit)
			if _, has := item.?; !has {
				break
			}
			ecnt += 1
		}
		if ecnt == 0 {
			return false, fmt.tprintf("empty entity index for %q", entity_key_hint)
		}
	}

	tx_cur, tx_ok, _ := forseti.store_resolve_path(m_cur, ".__tx")
	if !tx_ok {
		return false, "missing .__tx metadata"
	}
	mod_val, mod_found, _ := forseti.cursor_read_field_path(tx_cur, {"module"}, interner, .String)
	if !mod_found {
		return false, "missing __tx.module"
	}
	mod_sid, is_s := mod_val.(forseti.String_Id)
	if !is_s || forseti.interner_get(interner, mod_sid) != expected_module {
		return false, fmt.tprintf("unexpected __tx.module %v", mod_val)
	}

	tx_ids_cur, ids_ok, _ := forseti.store_resolve_path(tx_cur, ".decision_ids")
	if !ids_ok {
		return false, "missing __tx.decision_ids"
	}
	tx_it, _ := xitdb.cursor_iterator(tx_ids_cur)
	tx_cnt := 0
	for {
		item, _ := xitdb.cursor_iterator_next(&tx_it)
		if _, has := item.?; !has {
			break
		}
		tx_cnt += 1
	}
	if tx_cnt < min_decisions {
		return false, fmt.tprintf("expected >= %d __tx.decision_ids, got %d", min_decisions, tx_cnt)
	}

	rver_cur, rv_ok, _ := forseti.store_resolve_path(tx_cur, ".rule_versions")
	if !rv_ok {
		return false, "missing __tx.rule_versions"
	}
	_, rv_has, _ := forseti.store_lookup_record(rver_cur, rule_name)
	if !rv_has {
		return false, fmt.tprintf("missing __tx.rule_versions[%q]", rule_name)
	}
	return true, ""
}

@(private = "file")
_Parallel_Effect_Task :: struct {
	job:          ^forseti.Effect_Job,
	sess:         ^forseti.Session,
	out_binding:  string,
	out_score:    i64,
	out_country:  string,
	res_key:      string,
	res_org_id:   string,
	res_fields:   []forseti.Value,
}

@(private = "file")
_parallel_effect_worker :: proc(data: rawptr) {
	task := (^_Parallel_Effect_Task)(data)
	org_id := ""
	for f in task.job.fields {
		if f.name == "org_id" {
			org_id = f.str
			break
		}
	}
	task.res_org_id = org_id
	task.out_score = 90 if org_id == "org:1" else 95
}

driver_run_effects_in_parallel_threads :: proc(
	sess: ^forseti.Session,
	out_binding: string,
) -> (applied: []forseti.Fact_Id, job_count: int, err: forseti.Session_Error) {
	jobs := forseti.session_prepare_effects(sess)
	defer forseti.effects_jobs_destroy(jobs)
	job_count = len(jobs)
	if job_count == 0 {
		return nil, 0, .None
	}

	tasks := make([]_Parallel_Effect_Task, job_count)
	threads := make([]^thread.Thread, job_count)
	defer {
		for &tk in tasks {
			delete(tk.res_key)
			delete(tk.res_fields)
		}
		delete(tasks)
		delete(threads)
	}

	for &j, i in jobs {
		tasks[i] = _Parallel_Effect_Task{
			job         = &j,
			sess        = sess,
			out_binding = out_binding,
			out_country = "DE" if i % 2 == 0 else "US",
		}
		threads[i] = thread.create_and_start_with_data(&tasks[i], _parallel_effect_worker)
	}

	for th in threads {
		if th != nil {
			thread.join(th)
			thread.destroy(th)
		}
	}

	// Build Effect_Results back on engine thread using session interner safely.
	results := make([]forseti.Effect_Result, job_count)
	fact_vecs := make([][1]forseti.Effect_Result_Fact, job_count)
	defer {
		delete(results)
		delete(fact_vecs)
	}

	for &tk, i in tasks {
		tk.res_key = fmt.aprintf("enrich:%s:%d", tk.res_org_id, tk.job.job_id)
		oid_sid, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, tk.res_org_id)
		ctry_sid, _ := forseti.intern_session_string(&sess.rb.interner, &sess.interner, tk.out_country)
		tk.res_fields = make([]forseti.Value, 3)
		tk.res_fields[0] = oid_sid
		tk.res_fields[1] = tk.out_score
		tk.res_fields[2] = ctry_sid
		fact_vecs[i][0] = forseti.Effect_Result_Fact{
			binding_name = out_binding,
			key          = tk.res_key,
			fields       = tk.res_fields,
		}
		results[i] = forseti.Effect_Result{
			job_id = tk.job.job_id,
			facts  = fact_vecs[i][:],
		}
	}

	applied, err = forseti.session_apply_effects(sess, results)
	return applied, job_count, err
}
