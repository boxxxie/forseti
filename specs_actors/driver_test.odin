package forseti_actors_specs

import "core:fmt"
import xitdb "xitdb:."
import "../forseti"

@(private = "file")
_Seed_Orgs_Payload :: struct {
	orgs: []Snapshot_Org_Seed,
}

@(private = "file")
_seed_orgs_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	p := (^_Seed_Orgs_Payload)(user_data)
	m, err := forseti.store_write_path_ensure_map(moment_wc, ".orgs.raw")
	if err != nil {
		return .Write_Failed
	}
	for o in p.orgs {
		rwc := xitdb.hash_map_put_cursor(&m, o.org_id) or_return
		rm := xitdb.write_hash_map_init(rwc) or_return
		xitdb.hash_map_put(&rm, "org_id", o.org_id) or_return
		xitdb.hash_map_put(&rm, "employees", o.employees) or_return
	}
	return nil
}

driver_create_frozen_org_store :: proc(orgs: []Snapshot_Org_Seed) -> (sb: ^forseti.Store_Bridge, ok: bool, msg: string) {
	sb = new(forseti.Store_Bridge)
	if err := forseti.store_bridge_init_standalone(sb); err != nil {
		free(sb)
		return nil, false, fmt.tprintf("store_bridge_init_standalone err=%v", err)
	}
	payload := _Seed_Orgs_Payload{orgs = orgs}
	if _, m_err := forseti.store_bridge_commit_moment(sb, _seed_orgs_tx_cb, &payload); m_err != nil {
		forseti.store_bridge_destroy(sb)
		free(sb)
		return nil, false, fmt.tprintf("store_bridge_commit_moment err=%v", m_err)
	}
	return sb, true, ""
}

driver_compile_policy :: proc(src: string) -> (entry: Policy_Entry, ok: bool, msg: string) {
	if forseti.diag_list_init(&entry.diags) != nil {
		return {}, false, "diag_list_init failed"
	}
	ir, c_err := forseti.compile_source(src, "policy.forseti", &entry.diags)
	if c_err != nil || entry.diags.error_count > 0 {
		forseti.ir_destroy(&ir)
		forseti.diag_list_destroy(&entry.diags)
		return {}, false, fmt.tprintf("compile_source errors=%d err=%v", entry.diags.error_count, c_err)
	}
	entry.ir = ir

	rb := new(forseti.Rulebase)
	rb_val, rb_err := forseti.rulebase_compile(&entry.ir)
	if rb_err != .None {
		forseti.rulebase_destroy(&rb_val)
		free(rb)
		forseti.ir_destroy(&entry.ir)
		forseti.diag_list_destroy(&entry.diags)
		return {}, false, fmt.tprintf("rulebase_compile err=%v", rb_err)
	}
	rb^ = rb_val
	entry.rb = rb
	return entry, true, ""
}
