package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import xitdb "xitdb:."
import "../../forseti"

Org_Seed :: struct {
	id:        string,
	name:      string,
	domain:    string,
	employees: i64,
	active:    bool,
}

seed_orgs_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	orgs := (^([]Org_Seed))(user_data)^
	raw_m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return xitdb.Xitdb_Error.Write_Failed
	}
	for o in orgs {
		rwc := xitdb.hash_map_put_cursor(&raw_m, o.id) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "name", o.name) or_return
		xitdb.hash_map_put(&rm, "domain", o.domain) or_return
		xitdb.hash_map_put(&rm, "employees", o.employees) or_return
		if berr := forseti.write_bool_to_hash_map(&rm, "active", o.active); berr != nil {
			return xitdb.Xitdb_Error.Write_Failed
		}
	}
	return nil
}

run_example :: proc() -> bool {
	src := `module ex02_mdm version "1.0"
schema RawOrg { name: string, domain: string, employees: i64, active: bool }
schema CanonOrg { name: string, domain: string, tier: string }
source Raw : RawOrg at .orgs.raw[?id]
derived Canon : CanonOrg at .orgs.canon[?id]

rule canonicalize {
  when { ?_r := Raw(name: ?nm, domain: ?dom, employees: ?emp, active: true); where ?emp >= 100 }
  then { assert Canon(name: ?nm, domain: ?dom, tier: "enterprise") }
}`

	diags: forseti.Diagnostic_List
	if forseti.diag_list_init(&diags) != nil {
		return false
	}
	defer forseti.diag_list_destroy(&diags)

	ir, c_err := forseti.compile_source(src, "02_mdm_xitdb.forseti", &diags)
	if c_err != nil {
		return false
	}
	defer forseti.ir_destroy(&ir)
	if diags.error_count != 0 {
		return false
	}

	rb, rb_err := forseti.rulebase_compile(&ir)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb)
		return false
	}
	defer forseti.rulebase_destroy(&rb)

	dir, d_err := os.make_directory_temp("", "forseti_ex02_*", context.allocator)
	if d_err != nil {
		return false
	}
	defer {
		_ = os.remove_all(dir)
		delete(dir)
	}
	db_path, j_err := filepath.join({dir, "mdm.xit"}, context.allocator)
	if j_err != nil {
		return false
	}
	defer delete(db_path)

	{
		bridge: forseti.Store_Bridge
		if forseti.store_bridge_open_file(&bridge, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
			return false
		}
		defer forseti.store_bridge_destroy(&bridge)

		orgs := []Org_Seed{
			{id = "org:1", name = "Acme Corp", domain = "acme.com", employees = 250, active = true},
			{id = "org:2", name = "Small LLC", domain = "small.io", employees = 15, active = true},
		}
		if _, m_err := forseti.store_bridge_commit_moment(&bridge, seed_orgs_cb, &orgs); m_err != nil {
			return false
		}

		sess := new(forseti.Session)
		if forseti.session_init(sess, &rb) != .None {
			forseti.session_destroy(sess)
			free(sess)
			return false
		}
		defer {
			forseti.session_destroy(sess)
			free(sess)
		}

		syncer: forseti.Delta_Syncer
		if forseti.delta_syncer_init(&syncer) != nil {
			return false
		}
		defer forseti.delta_syncer_destroy(&syncer)
		if forseti.delta_syncer_watch(&syncer, ".orgs.raw") != nil {
			return false
		}

		fired, s_err := forseti.session_sync_and_fire(sess, &bridge, &syncer, commit_derived = true)
		if s_err != nil || fired != 1 {
			fmt.eprintfln("expected 1 rule firing, got %d (err=%v)", fired, s_err)
			return false
		}
	}

	// Reopen persisted Safe_V2 xitdb file and verify .orgs.canon + .decisions + .__tx!
	reopened: forseti.Store_Bridge
	if forseti.store_bridge_open_file(&reopened, db_path, forseti.Xitdb_Config{mode = .Safe_V2}) != nil {
		return false
	}
	defer forseti.store_bridge_destroy(&reopened)

	m_cur, m_ok, m_err := forseti.store_bridge_moment_cursor(&reopened, -1)
	if m_err != nil || !m_ok {
		return false
	}
	canon_cur, c_ok, _ := forseti.store_resolve_path(m_cur, ".orgs.canon")
	dec_cur, d_ok, _ := forseti.store_resolve_path(m_cur, ".decisions")
	by_ent, e_ok, _ := forseti.store_resolve_path(m_cur, ".idx.decisions_by_entity")
	tx_cur, t_ok, _ := forseti.store_resolve_path(m_cur, ".__tx")
	if !c_ok || !d_ok || !e_ok || !t_ok {
		return false
	}
	_, has_ent, _ := forseti.store_lookup_record(by_ent, "org:1")
	_ = canon_cur
	_ = dec_cur
	_ = tx_cur
	if !has_ent {
		fmt.eprintln("expected persisted entity index for org:1")
		return false
	}

	fmt.println("[ex02] OK persisted Safe_V2 MDM moment verified")
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
