package forseti

import "core:fmt"
import xitdb "xitdb:."

@(private)
_Commit_Audit_Ctx :: struct {
	sess: ^Session,
}

@(private)
_commit_derived_and_audit_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Commit_Audit_Ctx)(user_data)
	s := ctx.sess
	id_buf: [64]u8 = ---

	// 1. Sync derived.* collections: remove retracted keys previously committed, put current alive derived facts.
	for bdef, bi in s.rb.bindings {
		if bdef.kind != .Derived {
			continue
		}
		path_keys := s.rb.binding_path_hashes[bi]
		if len(path_keys) == 0 {
			continue
		}
		col_map, err := store_write_path_ensure_map_prehashed(moment_wc, path_keys)
		if err != nil {
			return .Write_Failed
		}

		// Remove stale committed derived keys that were retracted via JTMS.
		stale_keys := make([dynamic]Fact_Lookup_Key, 0, 4, context.temp_allocator)
		for lk in s.committed_derived {
			if lk.binding_idx != u16(bi) {
				continue
			}
			cur_fid, has_cur := s.facts_by_key[lk]
			if !has_cur || !s.facts[cur_fid].alive {
				kstr := session_string(s, lk.key)
				_, _ = xitdb.hash_map_remove(&col_map, kstr)
				append(&stale_keys, lk)
			}
		}
		for slk in stale_keys {
			delete_key(&s.committed_derived, slk)
		}

		schema := s.rb.schemas[bdef.schema_id]
		fhashes := s.rb.schema_field_hashes[bdef.schema_id]
		for &f in s.facts {
			if !f.alive || f.binding_idx != u16(bi) {
				continue
			}
			kstr := session_string(s, f.key)
			rec_wc := xitdb.hash_map_put_cursor(&col_map, kstr) or_return
			rec_m := xitdb.write_hash_map_init(rec_wc) or_return
			for _, sfi in schema.fields {
				if sfi >= len(f.fields) || f.fields[sfi] == nil {
					continue
				}
				pk := &fhashes[sfi]
				val := f.fields[sfi]
				switch v in val {
				case bool:
					if b_err := write_bool_to_hash_map_prehashed(&rec_m, pk, v); b_err != nil {
						return .Write_Failed
					}
				case i32:
					hash_map_put_prehashed(&rec_m, pk, i64(v)) or_return
				case i64:
					hash_map_put_prehashed(&rec_m, pk, v) or_return
				case f64:
					hash_map_put_prehashed(&rec_m, pk, v) or_return
				case String_Id:
					hash_map_put_prehashed(&rec_m, pk, session_string(s, v)) or_return
				case Entity_Id:
					hash_map_put_prehashed(&rec_m, pk, u64(v)) or_return
				case Time_Ns:
					hash_map_put_prehashed(&rec_m, pk, i64(v)) or_return
				case Enum_Val:
					hash_map_put_prehashed(&rec_m, pk, i64(v.variant)) or_return
				}
			}
			s.committed_derived[Fact_Lookup_Key{binding_idx = u16(bi), key = f.key}] = true
		}
	}

	// 2. If Provenance_Mode == .Audit_Full, atomically commit decisions, idx.*, and __tx.
	if s.provenance.mode != .Audit_Full {
		return nil
	}

	root_m := xitdb.write_hash_map_init(moment_wc^) or_return
	ak := audit_static_keys()

	dec_wc := hash_map_put_cursor_prehashed(&root_m, &ak.decisions) or_return
	dec_m := xitdb.write_hash_map_init(dec_wc) or_return

	idx_wc := hash_map_put_cursor_prehashed(&root_m, &ak.idx) or_return
	idx_m := xitdb.write_hash_map_init(idx_wc) or_return
	by_ent_wc := hash_map_put_cursor_prehashed(&idx_m, &ak.decisions_by_entity) or_return
	by_ent_m := xitdb.write_hash_map_init(by_ent_wc) or_return
	by_rule_wc := hash_map_put_cursor_prehashed(&idx_m, &ak.decisions_by_rule) or_return
	by_rule_m := xitdb.write_hash_map_init(by_rule_wc) or_return

	// Reset __tx fresh per transaction so __tx.decision_ids reflects this commit only.
	_, _ = hash_map_remove_prehashed(&root_m, &ak.tx_root)
	tx_wc := hash_map_put_cursor_prehashed(&root_m, &ak.tx_root) or_return
	tx_m := xitdb.write_hash_map_init(tx_wc) or_return

	hash_map_put_prehashed(&tx_m, &ak.tx_seq, i64(s.provenance.tx_seq)) or_return
	mod_name := interner_get(&s.rb.interner, s.rb.module_name)
	hash_map_put_prehashed(&tx_m, &ak.module, mod_name) or_return

	tx_dec_ids_wc := hash_map_put_cursor_prehashed(&tx_m, &ak.decision_ids) or_return
	tx_dec_ids_arr := xitdb.write_array_list_init(tx_dec_ids_wc) or_return

	rver_wc := hash_map_put_cursor_prehashed(&tx_m, &ak.rule_versions) or_return
	rver_m := xitdb.write_hash_map_init(rver_wc) or_return

	used_rules := make(map[u32]bool, 8, context.temp_allocator)
	rule_pks := make(map[u32]Prehashed_Key, 8, context.temp_allocator)
	unknown_rule_pk := prehashed_key_make("unknown")

	// Commit every derivation generated in the session (including retractions weighted -1 or active +1).
	n_deriv := len(s.provenance.derivs)
	for di := 1; di < n_deriv; di += 1 {
		d := s.provenance.derivs[di]
		did_str := fmt.bprintf(id_buf[:], "dec:%d", di)
		did_pk := prehashed_key_make(did_str)

		drec_wc := hash_map_put_cursor_prehashed(&dec_m, &did_pk) or_return
		drec_m := xitdb.write_hash_map_init(drec_wc) or_return

		rname_pk := &unknown_rule_pk
		rname := "unknown"
		rver := "1.0"
		if int(d.rule_id) < len(s.rb.rules) {
			rc := s.rb.rules[d.rule_id]
			if pk_ptr, has_pk := &rule_pks[d.rule_id]; has_pk {
				rname_pk = pk_ptr
			} else {
				rule_pks[d.rule_id] = prehashed_key_make(interner_get(&s.rb.interner, rc.name))
				rname_pk = &rule_pks[d.rule_id]
			}
			rname = rname_pk.key
			if rc.version != EMPTY_STRING {
				rver = interner_get(&s.rb.interner, rc.version)
			}
			used_rules[d.rule_id] = true
		}

		hash_map_put_prehashed(&drec_m, &ak.rule, rname) or_return
		hash_map_put_prehashed(&drec_m, &ak.rule_version, rver) or_return
		hash_map_put_prehashed(&drec_m, &ak.proof_height, i64(d.proof_height)) or_return
		hash_map_put_prehashed(&drec_m, &ak.weight, i64(d.weight)) or_return
		hash_map_put_prehashed(&drec_m, &ak.tx_seq, i64(d.tx_seq)) or_return
		hash_map_put_prehashed(&drec_m, &ak.derived_fact_id, i64(d.derived_fact)) or_return
		if err_b := write_bool_to_hash_map_prehashed(&drec_m, &ak.alive, d.alive); err_b != nil {
			return .Write_Failed
		}

		if d.derived_fact != INVALID_FACT && int(d.derived_fact) < len(s.facts) {
			df := &s.facts[d.derived_fact]
			dbind := interner_get(&s.rb.interner, s.rb.bindings[df.binding_idx].name)
			dkey := session_string(s, df.key)
			hash_map_put_prehashed(&drec_m, &ak.derived_binding, dbind) or_return
			hash_map_put_prehashed(&drec_m, &ak.derived_key, dkey) or_return

			ent_wc := xitdb.hash_map_put_cursor(&by_ent_m, dkey) or_return
			ent_set := xitdb.write_hash_set_init(ent_wc) or_return
			hash_set_put_prehashed(&ent_set, &did_pk) or_return
		}

		if d.table_idx != INVALID_TABLE_IDX && int(d.table_idx) < len(s.rb.tables) {
			ct := &s.rb.tables[d.table_idx]
			tname := compiled_table_string(ct, ct.table_name)
			hash_map_put_prehashed(&drec_m, &ak.table, tname) or_return
			if d.table_row_id != INVALID_ROW_ID && int(d.table_row_id) < len(ct.row_ids) {
				row_str := compiled_table_string(ct, ct.row_ids[d.table_row_id])
				hash_map_put_prehashed(&drec_m, &ak.table_row, row_str) or_return
			}
		}

		// Record parent facts & index under idx.decisions_by_entity for each parent key too.
		parents := provenance_parents(&s.provenance, Derivation_Id(di))
		_, _ = hash_map_remove_prehashed(&drec_m, &ak.parents)
		par_wc := hash_map_put_cursor_prehashed(&drec_m, &ak.parents) or_return
		par_arr := xitdb.write_array_list_init(par_wc) or_return
		for pf in parents {
			if pf != INVALID_FACT && int(pf) < len(s.facts) {
				pkey := session_string(s, s.facts[pf].key)
				if len(pkey) > 0 {
					xitdb.array_list_append(&par_arr, pkey) or_return
					pent_wc := xitdb.hash_map_put_cursor(&by_ent_m, pkey) or_return
					pent_set := xitdb.write_hash_set_init(pent_wc) or_return
					hash_set_put_prehashed(&pent_set, &did_pk) or_return
				}
			}
		}

		// Index under idx.decisions_by_rule[rname].
		rset_wc := hash_map_put_cursor_prehashed(&by_rule_m, rname_pk) or_return
		rset := xitdb.write_hash_set_init(rset_wc) or_return
		hash_set_put_prehashed(&rset, &did_pk) or_return
	}

	for did in s.provenance.last_tx_derivs {
		did_str := fmt.bprintf(id_buf[:], "dec:%d", u32(did))
		xitdb.array_list_append(&tx_dec_ids_arr, did_str) or_return
	}
	for rid in used_rules {
		rc := s.rb.rules[rid]
		rname_pk := &rule_pks[rid]
		rver := interner_get(&s.rb.interner, rc.version) if rc.version != EMPTY_STRING else "1.0"
		hash_map_put_prehashed(&rver_m, rname_pk, rver) or_return
	}
	return nil
}

// Atomically commits all alive derived facts AND Audit_Full provenance (decisions, idx.*, __tx) in one xitdb moment.
session_commit_derived_and_audit :: proc(s: ^Session, bridge: ^Store_Bridge) -> (moment_idx: i64, err: Store_Error) {
	if s == nil || s.rb == nil || bridge == nil {
		return -1, .Invalid_Config
	}
	cctx := _Commit_Audit_Ctx{sess = s}
	return store_bridge_commit_moment(bridge, _commit_derived_and_audit_tx_cb, &cctx)
}
