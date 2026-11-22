package forseti

import "core:fmt"
import xitdb "xitdb:."

@(private)
_Commit_Audit_Ctx :: struct {
	sess:           ^Session,
	is_incremental: bool,
	sync_committed: bool,
}

@(private)
_write_derived_fact_record :: proc(
	s: ^Session,
	col_map: ^xitdb.Write_Hash_Map,
	f: ^Fact,
	schema: Schema_Def,
	fhashes: []Prehashed_Key,
) -> xitdb.Error {
	kstr := session_string(s, f.key)
	hbuf: [64]u8 = ---
	h := xitdb.database_digest_string_buf(col_map.cursor.db, kstr, hbuf[:])
	_ = xitdb.hash_map_remove_by_hash(col_map, h) or_return
	xitdb.hash_map_put_key_by_hash(col_map, h, kstr) or_return
	rec_wc := xitdb.hash_map_put_cursor_by_hash(col_map, h) or_return
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
	return nil
}

@(private)
_commit_derived_and_audit_tx_cb :: proc(moment_wc: ^xitdb.Write_Cursor, user_data: rawptr) -> xitdb.Error {
	ctx := (^_Commit_Audit_Ctx)(user_data)
	s := ctx.sess
	id_buf: [64]u8 = ---

	// 1. Sync derived.* collections (O(delta) when committing incrementally to the primary bridge).
	if ctx.is_incremental {
		col_maps := make(map[u16]xitdb.Write_Hash_Map, 4, context.temp_allocator)
		get_derived_col :: proc(
			s: ^Session,
			moment_wc: ^xitdb.Write_Cursor,
			col_maps: ^map[u16]xitdb.Write_Hash_Map,
			bi: u16,
		) -> (^xitdb.Write_Hash_Map, xitdb.Error) {
			if existing, has := &col_maps^[bi]; has {
				return existing, nil
			}
			path_keys := s.rb.binding_path_hashes[bi]
			if len(path_keys) == 0 {
				return {}, .Write_Failed
			}
			cm, err := store_write_path_ensure_map_prehashed(moment_wc, path_keys)
			if err != nil {
				return {}, .Write_Failed
			}
			col_maps^[bi] = cm
			stored, _ := &col_maps^[bi]
			return stored, nil
		}

		for lk in s.retracted_derived_keys {
			cur_fid, has_cur := s.facts_by_key[lk]
			if has_cur && s.facts[cur_fid].alive {
				continue
			}
			if int(lk.binding_idx) >= len(s.rb.binding_path_hashes) || len(s.rb.binding_path_hashes[lk.binding_idx]) == 0 {
				continue
			}
			cm := get_derived_col(s, moment_wc, &col_maps, lk.binding_idx) or_return
			kstr := session_string(s, lk.key)
			_ = xitdb.hash_map_remove(cm, kstr) or_return
		}

		for fid in s.dirty_derived_fids {
			if fid == INVALID_FACT || int(fid) >= len(s.facts) {
				continue
			}
			f := &s.facts[fid]
			if !f.alive {
				continue
			}
			bi := f.binding_idx
			bdef := s.rb.bindings[bi]
			if bdef.kind != .Derived {
				continue
			}
			if int(bi) >= len(s.rb.binding_path_hashes) || len(s.rb.binding_path_hashes[bi]) == 0 {
				continue
			}
			cm := get_derived_col(s, moment_wc, &col_maps, bi) or_return
			schema := s.rb.schemas[bdef.schema_id]
			fhashes := s.rb.schema_field_hashes[bdef.schema_id]
			_write_derived_fact_record(s, cm, f, schema, fhashes) or_return
		}
	} else {
		for bdef, bi in s.rb.bindings {
			if bdef.kind != .Derived || bi >= len(s.rb.binding_path_hashes) {
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

			if ctx.sync_committed {
				for lk in s.committed_derived {
					if lk.binding_idx != u16(bi) {
						continue
					}
					cur_fid, has_cur := s.facts_by_key[lk]
					if !has_cur || !s.facts[cur_fid].alive {
						kstr := session_string(s, lk.key)
						_ = xitdb.hash_map_remove(&col_map, kstr) or_return
					}
				}
			}

			schema := s.rb.schemas[bdef.schema_id]
			fhashes := s.rb.schema_field_hashes[bdef.schema_id]
			for &f in s.facts {
				if !f.alive || f.binding_idx != u16(bi) {
					continue
				}
				_write_derived_fact_record(s, &col_map, &f, schema, fhashes) or_return
			}
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
	_ = hash_map_remove_prehashed(&root_m, &ak.tx_root) or_return
	tx_wc := hash_map_put_cursor_prehashed(&root_m, &ak.tx_root) or_return
	tx_m := xitdb.write_hash_map_init(tx_wc) or_return

	hash_map_put_prehashed(&tx_m, &ak.tx_seq, i64(s.provenance.tx_seq)) or_return
	mod_name := interner_get(&s.rb.interner, s.rb.module_name)
	hash_map_put_prehashed(&tx_m, &ak.module, mod_name) or_return

	tx_dec_ids_wc := hash_map_put_cursor_prehashed(&tx_m, &ak.decision_ids) or_return
	tx_dec_ids_arr := xitdb.write_array_list_init(tx_dec_ids_wc) or_return

	rver_wc := hash_map_put_cursor_prehashed(&tx_m, &ak.rule_versions) or_return
	rver_m := xitdb.write_hash_map_init(rver_wc) or_return

	rule_pks := make(map[u32]Prehashed_Key, 8, context.temp_allocator)
	unknown_rule_pk := prehashed_key_make("unknown")

	n_deriv := len(s.provenance.derivs)
	di_start := s.provenance.committed_deriv_len if ctx.is_incremental else 1
	if di_start < 1 {
		di_start = 1
	}

	// Commit newly created derivations since the last committed watermark (or all if full snapshot).
	for di := di_start; di < n_deriv; di += 1 {
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
		_ = hash_map_remove_prehashed(&drec_m, &ak.parents) or_return
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

	// Patch alive/weight for previously committed derivations retracted in this transaction.
	if ctx.is_incremental {
		for did in s.provenance.dirty_retracted_derivs {
			if did == INVALID_DERIVATION || int(did) >= s.provenance.committed_deriv_len {
				continue
			}
			d := s.provenance.derivs[did]
			did_str := fmt.bprintf(id_buf[:], "dec:%d", u32(did))
			did_pk := prehashed_key_make(did_str)
			drec_wc := hash_map_put_cursor_prehashed(&dec_m, &did_pk) or_return
			drec_m := xitdb.write_hash_map_init(drec_wc) or_return
			if err_b := write_bool_to_hash_map_prehashed(&drec_m, &ak.alive, d.alive); err_b != nil {
				return .Write_Failed
			}
			hash_map_put_prehashed(&drec_m, &ak.weight, i64(d.weight)) or_return
		}
	}

	for did in s.provenance.last_tx_derivs {
		did_str := fmt.bprintf(id_buf[:], "dec:%d", u32(did))
		xitdb.array_list_append(&tx_dec_ids_arr, did_str) or_return
	}
	for rid in s.provenance.rule_derivs {
		if int(rid) >= len(s.rb.rules) {
			continue
		}
		rc := s.rb.rules[rid]
		rname_pk := &rule_pks[rid]
		if _, has_pk := rule_pks[rid]; !has_pk {
			rule_pks[rid] = prehashed_key_make(interner_get(&s.rb.interner, rc.name))
			rname_pk = &rule_pks[rid]
		}
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
	is_primary := s.committed_bridge_db == nil || s.committed_bridge_db == bridge.db
	is_incremental := s.committed_bridge_db != nil && s.committed_bridge_db == bridge.db
	cctx := _Commit_Audit_Ctx{
		sess           = s,
		is_incremental = is_incremental,
		sync_committed = is_primary,
	}
	moment_idx, err = store_bridge_commit_moment(bridge, _commit_derived_and_audit_tx_cb, &cctx)
	if err == nil && is_primary {
		if is_incremental {
			for lk in s.retracted_derived_keys {
				cur_fid, has_cur := s.facts_by_key[lk]
				if has_cur && s.facts[cur_fid].alive {
					continue
				}
				delete_key(&s.committed_derived, lk)
			}
			for fid in s.dirty_derived_fids {
				if fid == INVALID_FACT || int(fid) >= len(s.facts) {
					continue
				}
				f := &s.facts[fid]
				if !f.alive || int(f.binding_idx) >= len(s.rb.bindings) || s.rb.bindings[f.binding_idx].kind != .Derived || int(f.binding_idx) >= len(s.rb.binding_path_hashes) || len(s.rb.binding_path_hashes[f.binding_idx]) == 0 {
					continue
				}
				s.committed_derived[Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}] = true
			}
		} else {
			clear(&s.committed_derived)
			for &f in s.facts {
				if !f.alive || int(f.binding_idx) >= len(s.rb.bindings) || s.rb.bindings[f.binding_idx].kind != .Derived || int(f.binding_idx) >= len(s.rb.binding_path_hashes) || len(s.rb.binding_path_hashes[f.binding_idx]) == 0 {
					continue
				}
				s.committed_derived[Fact_Lookup_Key{binding_idx = f.binding_idx, key = f.key}] = true
			}
		}
		s.committed_bridge_db = bridge.db
		s.provenance.committed_deriv_len = len(s.provenance.derivs)
		clear(&s.provenance.dirty_retracted_derivs)
		clear(&s.dirty_derived_fids)
		clear(&s.retracted_derived_keys)
	}
	return moment_idx, err
}
