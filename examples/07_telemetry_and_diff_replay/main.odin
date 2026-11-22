package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import xitdb "xitdb:."
import "../../forseti"

seed_cb :: proc(wc: ^xitdb.Write_Cursor, _: rawptr) -> xitdb.Error {
	raw_m, err := forseti.store_write_path_ensure_map(wc, ".raw")
	if err != nil {
		return xitdb.Xitdb_Error.Write_Failed
	}
	orgs := [2]struct{ id: string, employees: i64 }{{"o1", 250}, {"o2", 75}}
	for o in orgs {
		rwc := xitdb.hash_map_put_cursor(&raw_m, o.id) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "id", o.id) or_return
		xitdb.hash_map_put(&rm, "employees", o.employees) or_return
	}
	return nil
}

run_example :: proc() -> bool {
	base_src := `module ex07 version "1.0"
schema Org { id: string, employees: i64 }
schema Flag { id: string }
source Raw : Org at .raw[?id]
derived Ent : Flag at .ent[?id]
rule mark_ent {
  when { ?_r := Raw(id: ?id, employees: ?emp); where ?emp >= 50 }
  then { assert Ent(id: ?id) }
}`

	cand_src := `module ex07 version "2.0"
schema Org { id: string, employees: i64 }
schema Flag { id: string }
source Raw : Org at .raw[?id]
derived Ent : Flag at .ent[?id]
rule mark_ent {
  when { ?_r := Raw(id: ?id, employees: ?emp); where ?emp >= 200 }
  then { assert Ent(id: ?id) }
}`

	tel: forseti.Telemetry_Sink
	if forseti.telemetry_init(&tel, enabled = true) != nil {
		return false
	}
	defer forseti.telemetry_destroy(&tel)

	d1, d2: forseti.Diagnostic_List
	if forseti.diag_list_init(&d1) != nil || forseti.diag_list_init(&d2) != nil {
		forseti.diag_list_destroy(&d1)
		forseti.diag_list_destroy(&d2)
		return false
	}
	defer forseti.diag_list_destroy(&d1)
	defer forseti.diag_list_destroy(&d2)

	ir1, e1 := forseti.compile_source(base_src, "v1.forseti", &d1, &tel)
	ir2, e2 := forseti.compile_source(cand_src, "v2.forseti", &d2, &tel)
	if e1 != nil || e2 != nil || d1.error_count != 0 || d2.error_count != 0 {
		forseti.ir_destroy(&ir1)
		forseti.ir_destroy(&ir2)
		return false
	}
	defer forseti.ir_destroy(&ir1)
	defer forseti.ir_destroy(&ir2)

	rb1, rbe1 := forseti.rulebase_compile(&ir1, &tel)
	rb2, rbe2 := forseti.rulebase_compile(&ir2, &tel)
	if rbe1 != .None || rbe2 != .None {
		forseti.rulebase_destroy(&rb1)
		forseti.rulebase_destroy(&rb2)
		return false
	}
	defer forseti.rulebase_destroy(&rb1)
	defer forseti.rulebase_destroy(&rb2)

	bridge: forseti.Store_Bridge
	if forseti.store_bridge_init_standalone(&bridge, forseti.Xitdb_Config{}, &tel) != nil {
		return false
	}
	defer forseti.store_bridge_destroy(&bridge)

	if _, m_err := forseti.store_bridge_commit_moment(&bridge, seed_cb); m_err != nil {
		return false
	}

	rep, dr_err := forseti.diff_replay(&bridge, &rb1, &rb2, {".raw"}, &tel)
	if dr_err != nil {
		return false
	}
	defer forseti.diff_replay_report_destroy(&rep)
	if len(rep.removed) != 1 || rep.unchanged_count != 1 || rep.parent_moments_before != rep.parent_moments_after {
		fmt.eprintfln("unexpected diff_replay result: rem=%d unch=%d", len(rep.removed), rep.unchanged_count)
		return false
	}

	jsonl, j_err := forseti.telemetry_export_jsonl(&tel)
	if j_err != nil {
		return false
	}
	defer delete(jsonl)

	chrome, c_err := forseti.telemetry_export_chrome_trace(&tel)
	if c_err != nil {
		return false
	}
	defer delete(chrome)

	mmd, m_err2 := forseti.export_rulebase_mermaid(&rb1)
	if m_err2 != nil {
		return false
	}
	defer delete(mmd)

	if !strings.contains(jsonl, `"type":"summary"`) || !strings.contains(chrome, `"traceEvents"`) || !strings.contains(mmd, "mark_ent") {
		return false
	}

	fmt.printfln("[ex07] OK diff_replay(rem=%d,unchanged=%d) telemetry_spans=%d mmd_bytes=%d",
		len(rep.removed), rep.unchanged_count, len(tel.events), len(mmd))
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
